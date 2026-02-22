defmodule TriOnyx.AgentLoader do
  @moduledoc """
  Loads agent definitions from a directory of markdown files.

  Scans the configured agents directory for `.md` files, parses each into
  an `AgentDefinition` struct, and returns the results. Invalid files are
  reported as errors but do not prevent other files from loading.
  """

  alias TriOnyx.AgentDefinition

  require Logger

  @type load_result ::
          {:ok, [AgentDefinition.t()]}
          | {:error, :directory_not_found}

  @doc """
  Loads all agent definitions from the configured agents directory.

  Reads `agents_dir` from application config (`:tri_onyx`, `:agents_dir`).
  """
  @spec load_all() :: load_result()
  def load_all do
    agents_dir = Application.get_env(:tri_onyx, :agents_dir, "./workspace/agent-definitions")
    load_from(agents_dir)
  end

  @doc """
  Loads all agent definitions from the given directory path.

  Returns `{:ok, definitions}` with successfully parsed definitions.
  Invalid files are logged as warnings and skipped.

  Returns `{:error, :directory_not_found}` if the directory doesn't exist.
  """
  @spec load_from(String.t()) :: load_result()
  def load_from(dir) when is_binary(dir) do
    expanded = Path.expand(dir)

    if File.dir?(expanded) do
      definitions =
        expanded
        |> Path.join("*.md")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.flat_map(&load_file/1)

      validate_messaging_topology(definitions)

      Logger.info("Loaded #{length(definitions)} agent definition(s) from #{expanded}")
      {:ok, definitions}
    else
      Logger.warning("Agents directory not found: #{expanded}")
      {:error, :directory_not_found}
    end
  end

  @spec load_file(String.t()) :: [AgentDefinition.t()]
  defp load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case AgentDefinition.parse(content) do
          {:ok, definition} ->
            Logger.info(
              "Loaded agent '#{definition.name}' from #{Path.basename(path)} " <>
                "(tools: #{Enum.join(definition.tools, ", ")}, " <>
                "network: #{format_network(definition.network)})"
            )

            [definition]

          {:error, reason} ->
            Logger.warning("Failed to parse agent definition #{path}: #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        Logger.warning("Failed to read agent definition #{path}: #{inspect(reason)}")
        []
    end
  end

  @spec validate_messaging_topology([AgentDefinition.t()]) :: :ok
  defp validate_messaging_topology(definitions) do
    known_names = MapSet.new(definitions, & &1.name)

    Enum.each(definitions, fn definition ->
      Enum.each(definition.send_to, fn target ->
        unless MapSet.member?(known_names, target) do
          Logger.warning(
            "Agent '#{definition.name}' declares send_to '#{target}' " <>
              "but no agent with that name was loaded"
          )
        end
      end)

      Enum.each(definition.receive_from, fn source ->
        unless MapSet.member?(known_names, source) do
          Logger.warning(
            "Agent '#{definition.name}' declares receive_from '#{source}' " <>
              "but no agent with that name was loaded"
          )
        end
      end)
    end)
  end

  @spec format_network(AgentDefinition.network_policy()) :: String.t()
  defp format_network(:none), do: "none"
  defp format_network(:outbound), do: "outbound"
  defp format_network(hosts) when is_list(hosts), do: Enum.join(hosts, ", ")
end
