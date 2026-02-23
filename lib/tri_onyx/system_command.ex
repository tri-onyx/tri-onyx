defmodule TriOnyx.SystemCommand do
  @moduledoc """
  Parses and executes slash-prefixed system commands from chat messages.

  System commands are intercepted by the ConnectorHandler before they reach
  agents. They provide operators a chat-native way to manage agent sessions
  without using the HTTP API.

  ## Available Commands

  - `/restart [agent_name]` — gracefully restart an agent session (saves memory first)
  """

  require Logger

  alias TriOnyx.AgentSession
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter

  @commands %{"restart" => :restart}

  @doc """
  Parses a message content string into a system command.

  Returns `{:command, atom, args}` if the content starts with a known
  slash command, or `:not_a_command` otherwise.

  Uses an explicit allowlist to prevent atom table exhaustion.

  ## Examples

      iex> SystemCommand.parse("/restart researcher")
      {:command, :restart, ["researcher"]}

      iex> SystemCommand.parse("hello")
      :not_a_command
  """
  @spec parse(String.t()) :: {:command, atom(), [String.t()]} | :not_a_command
  def parse("/" <> rest) do
    case String.split(rest, ~r/\s+/, trim: true) do
      [] ->
        {:command, :unknown, ["/"]}

      [name | args] ->
        case Map.fetch(@commands, name) do
          {:ok, cmd} -> {:command, cmd, args}
          :error -> {:command, :unknown, ["/" <> name]}
        end
    end
  end

  def parse(_content), do: :not_a_command

  @doc """
  Executes a parsed system command.

  Accepts an optional keyword list for overriding the router and supervisor
  used for agent lookup and session management (useful in tests):

  - `:router` — TriggerRouter server (default: `TriggerRouter`)
  - `:supervisor` — AgentSupervisor server (default: `AgentSupervisor`)

  Returns `{:ok, message}` or `{:error, message}`.
  """
  @spec execute(atom(), [String.t()], map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(cmd, args, context, opts \\ [])

  def execute(:restart, args, context, opts) do
    agent_name =
      case args do
        [name | _] -> name
        [] -> Map.get(context, :agent_name)
      end

    if is_nil(agent_name) or agent_name == "" do
      {:error, "No agent specified"}
    else
      router = Keyword.get(opts, :router, TriggerRouter)
      supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)
      force = Keyword.get(opts, :force, false)
      do_restart(agent_name, router, supervisor, force)
    end
  end

  def execute(:unknown, [raw_cmd | _], _context, _opts) do
    available = @commands |> Map.keys() |> Enum.map(&("/#{&1}")) |> Enum.join(", ")
    {:error, "Unknown command '#{raw_cmd}'. Available: #{available}"}
  end

  def execute(:unknown, _, _context, _opts) do
    available = @commands |> Map.keys() |> Enum.map(&("/#{&1}")) |> Enum.join(", ")
    {:error, "Unknown command. Available: #{available}"}
  end

  # --- Private ---

  @spec do_restart(String.t(), GenServer.server(), GenServer.server(), boolean()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_restart(agent_name, router, supervisor, force) do
    case TriggerRouter.get_agent(router, agent_name) do
      {:ok, definition} ->
        case AgentSupervisor.find_session(supervisor, agent_name) do
          {:ok, pid} when force ->
            # Force restart — immediate termination, no memory save
            AgentSupervisor.stop_session(supervisor, pid, "force restart")

            case AgentSupervisor.start_session(supervisor,
                   definition: definition,
                   trigger_type: :verified_input
                 ) do
              {:ok, _pid} ->
                {:ok, "Force-restarting agent '#{agent_name}'"}

              {:error, reason} ->
                {:error, "Failed to start '#{agent_name}' after force stop: #{inspect(reason)}"}
            end

          {:ok, pid} ->
            # Session is running — stop gracefully (memory save) then start fresh.
            # This runs async because memory save can take up to 30s.
            Task.start(fn ->
              ref = Process.monitor(pid)
              AgentSession.stop(pid, "restart command")

              receive do
                {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
              after
                35_000 ->
                  Logger.warning("SystemCommand: timeout waiting for #{agent_name} to stop")
              end

              case AgentSupervisor.start_session(supervisor,
                     definition: definition,
                     trigger_type: :verified_input
                   ) do
                {:ok, _pid} ->
                  Logger.info("SystemCommand: restarted agent '#{agent_name}'")

                {:error, reason} ->
                  Logger.error(
                    "SystemCommand: failed to restart '#{agent_name}': #{inspect(reason)}"
                  )
              end
            end)

            {:ok, "Restarting agent '#{agent_name}' (saving memory first)"}

          :error ->
            # Not running — start it directly
            case AgentSupervisor.start_session(supervisor,
                   definition: definition,
                   trigger_type: :verified_input
                 ) do
              {:ok, _pid} ->
                {:ok, "Started agent '#{agent_name}' (was not running)"}

              {:error, reason} ->
                {:error, "Failed to start '#{agent_name}': #{inspect(reason)}"}
            end
        end

      :error ->
        {:error, "Unknown agent '#{agent_name}'"}
    end
  end
end
