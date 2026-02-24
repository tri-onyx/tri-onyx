defmodule TriOnyx.Application do
  @moduledoc """
  OTP Application for the TriOnyx gateway.

  Starts the supervision tree in the following order:

  1. AuditLog — append-only JSONL event logger
  2. WebhookRegistry — ETS-backed webhook endpoint store
  3. WebhookRateLimiter — token bucket rate limiter for webhook ingress
  4. AgentSupervisor — DynamicSupervisor for agent session processes
  5. TriggerRouter — dispatches triggers to agent sessions
  6. Scheduler — cron/heartbeat trigger scheduling
  7. HTTP server (Bandit) — webhook, message, and management endpoints

  After the supervision tree starts, the application loads agent definitions
  from disk, registers them with the TriggerRouter, and logs risk scores.
  """

  use Application

  require Logger

  alias TriOnyx.AgentLoader
  alias TriOnyx.RiskScorer
  alias TriOnyx.Triggers.Scheduler

  @impl Application
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    port = Application.get_env(:tri_onyx, :port, 4000)

    children = [
      # 1. Audit log — must start first so other services can log
      TriOnyx.AuditLog,

      # 2. Session logger — per-session JSONL event logs
      TriOnyx.SessionLogger,

      # 3. Event bus registry — pub/sub for SSE streaming
      {Registry, keys: :duplicate, name: TriOnyx.EventBus.Registry},

      # 3. Webhook endpoint registry — must start before Router
      TriOnyx.WebhookRegistry,

      # 4. Webhook rate limiter — must start before Router
      TriOnyx.WebhookRateLimiter,

      # 5. Agent session supervisor
      TriOnyx.AgentSupervisor,

      # 6. Trigger router — dispatches events to agent sessions
      TriOnyx.TriggerRouter,

      # 7. Cron scheduler (Quantum) — must start before Scheduler
      TriOnyx.Triggers.CronScheduler,

      # 8. Scheduler — cron/heartbeat triggers
      TriOnyx.Triggers.Scheduler,

      # 8. Definition watcher — live-reload agent definitions on file change
      # Disabled via config in test: inotifywait is unnecessary and produces
      # a harmless "kill: No such process" on shutdown from the file_system lib.
      if(Application.get_env(:tri_onyx, :definition_watcher, true),
        do: TriOnyx.DefinitionWatcher
      ),

      # 9. Connector registry — tracks active WebSocket connectors
      {Registry, keys: :unique, name: TriOnyx.ConnectorRegistry},

      # 9. BCP approval queue — human approval for Cat-3 queries/escalations
      TriOnyx.BCP.ApprovalQueue,

      # 10. Action approval queue — human approval for sensitive tool actions
      TriOnyx.ActionApprovalQueue,

      # 10. HTTP server
      {Bandit, plug: TriOnyx.Router, port: port}
    ]
    |> Enum.reject(&is_nil/1)

    # Conditionally add email poller if email configuration is present
    children =
      if Application.get_env(:tri_onyx, :email) do
        children ++ [{TriOnyx.Connectors.Email.Poller, []}]
      else
        children
      end

    # Conditionally add calendar poller if CalDAV configuration is present
    children =
      if Application.get_env(:tri_onyx, :calendar) do
        children ++ [{TriOnyx.Connectors.Calendar.Poller, []}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: TriOnyx.Supervisor]

    Logger.info("TriOnyx gateway starting")
    cleanup_orphaned_containers()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Create BCP pending queries table owned by the Application process
        # (long-lived) so it survives across Task processes that insert/pop queries
        TriOnyx.BCP.Channel.ensure_table()

        load_and_display_agents()
        TriOnyx.Workspace.ensure_initialized()
        Logger.info("TriOnyx gateway ready on port #{port}")
        {:ok, pid}

      {:error, _reason} = error ->
        error
    end
  end

  # Stop any agent containers left running by a previous gateway instance.
  # This handles the case where the gateway was killed (SIGKILL) and
  # AgentPort.terminate/2 never ran, leaving orphaned Docker containers.
  # Uses the ancestor label to match only containers spawned by the agent
  # image, avoiding compose-managed gateway/connector containers.
  @spec cleanup_orphaned_containers() :: :ok
  defp cleanup_orphaned_containers do
    image = Application.get_env(:tri_onyx, :agent_image, "tri-onyx-agent:latest")

    case System.cmd(
           "docker",
           ["ps", "-q", "--filter", "ancestor=#{image}", "--filter", "status=running"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        ids =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&(&1 != ""))

        if ids != [] do
          Logger.info("Cleaning up #{length(ids)} orphaned agent container(s)")

          Enum.each(ids, fn id ->
            {name_output, _} = System.cmd("docker", ["inspect", "--format", "{{.Name}}", id])
            name = name_output |> String.trim() |> String.trim_leading("/")
            Logger.info("Stopping orphaned container: #{name}")
            System.cmd("docker", ["stop", "--time", "5", id], stderr_to_stdout: true)
          end)
        end

      {error, _code} ->
        Logger.warning("Failed to list orphaned containers: #{error}")
    end

    :ok
  end

  @spec load_and_display_agents() :: :ok
  defp load_and_display_agents do
    case AgentLoader.load_all() do
      {:ok, definitions} ->
        Enum.each(definitions, fn definition ->
          TriOnyx.TriggerRouter.register_agent(definition)

          input_risk = RiskScorer.infer_input_risk(:external_message, definition.tools)
          taint = RiskScorer.infer_taint(:external_message, definition.tools)
          sensitivity = RiskScorer.infer_sensitivity(definition.tools)
          effective_risk = RiskScorer.effective_risk(taint, sensitivity)

          Logger.info(
            "Agent: #{definition.name} | " <>
              "input_risk=#{input_risk} " <>
              "effective_risk=#{RiskScorer.format_risk(effective_risk)}"
          )

          if definition.heartbeat_every do
            Scheduler.schedule_heartbeat(definition.name, definition.heartbeat_every)

            Logger.info(
              "Agent: #{definition.name} | heartbeat scheduled every #{definition.heartbeat_every}ms"
            )
          end

          if definition.cron_schedules != [] do
            Scheduler.schedule_agent_crons(definition.name, definition.cron_schedules)

            Logger.info(
              "Agent: #{definition.name} | #{length(definition.cron_schedules)} cron schedule(s) registered"
            )
          end
        end)

        Logger.info("Loaded #{length(definitions)} agent definition(s)")

      {:error, reason} ->
        Logger.warning("Failed to load agent definitions: #{inspect(reason)}")
    end
  end
end
