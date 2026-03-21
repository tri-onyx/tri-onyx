defmodule TriOnyx.Triggers.Scheduler do
  @moduledoc """
  Cron and heartbeat trigger scheduling.

  Uses Quantum for cron-style scheduling and `Process.send_after` for
  heartbeat intervals. All scheduled triggers are trusted (clean) since
  they contain no external input.

  ## Cron Triggers

  Agent definitions can declare cron schedules. The scheduler creates
  Quantum jobs that dispatch trigger events to the TriggerRouter at the
  specified times.

  ## Heartbeat Triggers

  Heartbeat triggers fire at a fixed interval (configurable per agent).
  They are implemented via recursive `Process.send_after` calls.
  """

  use GenServer

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.CronScheduler
  alias TriOnyx.Workspace

  @heartbeat_template "# Heartbeat\n\n<!-- Current state and ongoing work -->\n"

  @heartbeat_prompt """
  This is an automated heartbeat check. Your current state is in the "# Heartbeat" section of your system prompt (inside the <persona> block).

  If the Heartbeat section contains no actionable items or issues that need attention, respond with exactly: HEARTBEAT_OK

  If there are items that need attention, analysis, or action, respond with a summary of what needs to be done and any recommendations.
  """

  @type heartbeat :: %{
          agent_name: String.t(),
          interval_ms: pos_integer(),
          timer_ref: reference() | nil
        }

  @type state :: %{
          router: GenServer.server(),
          heartbeats: %{String.t() => heartbeat()},
          cron_jobs: %{String.t() => [atom()]},
          enabled: boolean()
        }

  # --- Public API ---

  @doc """
  Starts the Scheduler GenServer.

  ## Options

  - `:name` — GenServer name (default: `__MODULE__`)
  - `:router` — TriggerRouter server (default: `TriOnyx.TriggerRouter`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Schedules a heartbeat trigger for the given agent.

  The heartbeat fires every `interval_ms` milliseconds, dispatching a
  trigger event to the TriggerRouter. Trust level: clean.
  """
  @spec schedule_heartbeat(GenServer.server(), String.t(), pos_integer()) :: :ok
  def schedule_heartbeat(server \\ __MODULE__, agent_name, interval_ms)
      when is_binary(agent_name) and is_integer(interval_ms) and interval_ms > 0 do
    GenServer.call(server, {:schedule_heartbeat, agent_name, interval_ms})
  end

  @doc """
  Cancels a heartbeat trigger for the given agent.
  """
  @spec cancel_heartbeat(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def cancel_heartbeat(server \\ __MODULE__, agent_name) when is_binary(agent_name) do
    GenServer.call(server, {:cancel_heartbeat, agent_name})
  end

  @doc """
  Lists all active heartbeat schedules.
  """
  @spec list_heartbeats(GenServer.server()) :: [%{agent_name: String.t(), interval_ms: pos_integer()}]
  def list_heartbeats(server \\ __MODULE__) do
    GenServer.call(server, :list_heartbeats)
  end

  @doc """
  Sets the global enabled/disabled state for heartbeat dispatch.

  When disabled, heartbeat timers continue to fire and reschedule, but
  dispatch to the TriggerRouter is skipped.
  """
  @spec set_enabled(GenServer.server(), boolean()) :: :ok
  def set_enabled(server \\ __MODULE__, enabled) when is_boolean(enabled) do
    GenServer.call(server, {:set_enabled, enabled})
  end

  @doc """
  Returns whether heartbeat dispatch is globally enabled.
  """
  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server \\ __MODULE__) do
    GenServer.call(server, :enabled?)
  end

  @doc """
  Manually triggers a heartbeat for the given agent.

  Builds the same heartbeat event as the timer path and dispatches it
  through TriggerRouter. Skips enabled/empty checks since this is an
  explicit manual trigger.
  """
  @spec trigger_heartbeat(String.t()) :: {:ok, pid()} | {:error, term()}
  def trigger_heartbeat(agent_name) when is_binary(agent_name) do
    event = %{
      type: :heartbeat,
      agent_name: agent_name,
      payload: @heartbeat_prompt,
      metadata: %{fired_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    }

    TriggerRouter.dispatch(event)
  end

  @doc """
  Registers Quantum cron jobs for the given agent's cron schedules.

  Each schedule becomes a named Quantum job. Job names follow the convention
  `:"cron_{agent_name}_{index}"`. Existing cron jobs for the agent are
  cancelled before registering new ones.
  """
  @spec schedule_agent_crons(GenServer.server(), String.t(), [AgentDefinition.cron_schedule()]) ::
          :ok
  def schedule_agent_crons(server \\ __MODULE__, agent_name, cron_schedules)
      when is_binary(agent_name) and is_list(cron_schedules) do
    GenServer.call(server, {:schedule_agent_crons, agent_name, cron_schedules})
  end

  @doc """
  Cancels all Quantum cron jobs for the given agent.
  """
  @spec cancel_agent_crons(GenServer.server(), String.t()) :: :ok
  def cancel_agent_crons(server \\ __MODULE__, agent_name) when is_binary(agent_name) do
    GenServer.call(server, {:cancel_agent_crons, agent_name})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    router = Keyword.get(opts, :router, TriggerRouter)

    Logger.info("Scheduler started")

    {:ok, %{router: router, heartbeats: %{}, cron_jobs: %{}, enabled: true}}
  end

  @impl GenServer
  def handle_call({:schedule_heartbeat, agent_name, interval_ms}, _from, state) do
    # Cancel existing heartbeat if any
    state = cancel_existing_heartbeat(state, agent_name)

    # Schedule first heartbeat
    timer_ref = Process.send_after(self(), {:heartbeat, agent_name}, interval_ms)

    heartbeat = %{
      agent_name: agent_name,
      interval_ms: interval_ms,
      timer_ref: timer_ref
    }

    Logger.info("Scheduler: heartbeat scheduled for '#{agent_name}' every #{interval_ms}ms")

    new_heartbeats = Map.put(state.heartbeats, agent_name, heartbeat)
    {:reply, :ok, %{state | heartbeats: new_heartbeats}}
  end

  def handle_call({:cancel_heartbeat, agent_name}, _from, state) do
    if Map.has_key?(state.heartbeats, agent_name) do
      state = cancel_existing_heartbeat(state, agent_name)
      new_heartbeats = Map.delete(state.heartbeats, agent_name)
      Logger.info("Scheduler: heartbeat cancelled for '#{agent_name}'")
      {:reply, :ok, %{state | heartbeats: new_heartbeats}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_heartbeats, _from, state) do
    heartbeats =
      state.heartbeats
      |> Map.values()
      |> Enum.map(fn hb -> %{agent_name: hb.agent_name, interval_ms: hb.interval_ms} end)

    {:reply, heartbeats, state}
  end

  def handle_call({:set_enabled, enabled}, _from, state) do
    Logger.info("Scheduler: heartbeats #{if enabled, do: "enabled", else: "disabled"}")
    {:reply, :ok, %{state | enabled: enabled}}
  end

  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  def handle_call({:schedule_agent_crons, agent_name, cron_schedules}, _from, state) do
    # Cancel any existing cron jobs for this agent first
    state = do_cancel_agent_crons(state, agent_name)

    job_names =
      cron_schedules
      |> Enum.with_index()
      |> Enum.map(fn {%{schedule: schedule_str, message: message, label: label}, idx} ->
        job_name = :"cron_#{agent_name}_#{idx}"
        {:ok, cron_expr} = Crontab.CronExpression.Parser.parse(schedule_str)

        job =
          CronScheduler.new_job()
          |> Quantum.Job.set_name(job_name)
          |> Quantum.Job.set_schedule(cron_expr)
          |> Quantum.Job.set_task(fn ->
            event = %{
              type: :cron,
              agent_name: agent_name,
              payload: message,
              metadata: %{
                label: label,
                fired_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }
            }

            case TriggerRouter.dispatch(event) do
              {:ok, _pid} ->
                Logger.debug("Scheduler: cron job '#{job_name}' dispatched for '#{agent_name}'")

              {:error, reason} ->
                Logger.warning(
                  "Scheduler: cron dispatch failed for '#{agent_name}' job '#{job_name}': #{inspect(reason)}"
                )
            end
          end)

        CronScheduler.add_job(job)

        Logger.info(
          "Scheduler: cron job '#{job_name}' registered for '#{agent_name}' (schedule: #{schedule_str})"
        )

        job_name
      end)

    new_cron_jobs = Map.put(state.cron_jobs, agent_name, job_names)
    {:reply, :ok, %{state | cron_jobs: new_cron_jobs}}
  end

  def handle_call({:cancel_agent_crons, agent_name}, _from, state) do
    state = do_cancel_agent_crons(state, agent_name)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:heartbeat, agent_name}, state) do
    case Map.fetch(state.heartbeats, agent_name) do
      {:ok, heartbeat} ->
        Logger.debug("Scheduler: heartbeat firing for '#{agent_name}'")

        # Always reschedule regardless of dispatch outcome
        timer_ref = Process.send_after(self(), {:heartbeat, agent_name}, heartbeat.interval_ms)
        updated = %{heartbeat | timer_ref: timer_ref}
        new_heartbeats = Map.put(state.heartbeats, agent_name, updated)
        state = %{state | heartbeats: new_heartbeats}

        cond do
          not state.enabled ->
            Logger.debug("Scheduler: heartbeats disabled, skipping dispatch for '#{agent_name}'")

          heartbeat_content_empty?(agent_name) ->
            Logger.debug(
              "Scheduler: HEARTBEAT.md is template-only, skipping dispatch for '#{agent_name}'"
            )

          true ->
            event = %{
              type: :heartbeat,
              agent_name: agent_name,
              payload: @heartbeat_prompt,
              metadata: %{fired_at: DateTime.utc_now() |> DateTime.to_iso8601()}
            }

            case TriggerRouter.dispatch(state.router, event) do
              {:ok, _pid} ->
                Logger.debug("Scheduler: heartbeat dispatched for '#{agent_name}'")

              {:error, reason} ->
                Logger.warning(
                  "Scheduler: heartbeat dispatch failed for '#{agent_name}': #{inspect(reason)}"
                )
            end
        end

        {:noreply, state}

      :error ->
        Logger.warning("Scheduler: heartbeat fired for unknown agent '#{agent_name}', ignoring")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("Scheduler: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  @spec heartbeat_content_empty?(String.t()) :: boolean()
  defp heartbeat_content_empty?(agent_name) do
    case Workspace.read_file("agents/#{agent_name}/HEARTBEAT.md") do
      {:ok, content} -> String.trim(content) == String.trim(@heartbeat_template)
      {:error, _} -> true
    end
  end

  @spec do_cancel_agent_crons(state(), String.t()) :: state()
  defp do_cancel_agent_crons(state, agent_name) do
    case Map.fetch(state.cron_jobs, agent_name) do
      {:ok, job_names} ->
        Enum.each(job_names, fn job_name ->
          CronScheduler.delete_job(job_name)

          Logger.info(
            "Scheduler: cron job '#{job_name}' cancelled for '#{agent_name}'"
          )
        end)

        %{state | cron_jobs: Map.delete(state.cron_jobs, agent_name)}

      :error ->
        state
    end
  end

  @spec cancel_existing_heartbeat(state(), String.t()) :: state()
  defp cancel_existing_heartbeat(state, agent_name) do
    case Map.fetch(state.heartbeats, agent_name) do
      {:ok, %{timer_ref: ref}} when is_reference(ref) ->
        Process.cancel_timer(ref)
        state

      _ ->
        state
    end
  end
end
