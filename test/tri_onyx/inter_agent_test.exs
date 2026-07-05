defmodule TriOnyx.Triggers.InterAgentTest.FakeSession do
  @moduledoc """
  Minimal stand-in for an AgentSession process. Responds to `:get_status`
  (used by AgentSupervisor.find_session and InterAgent's sender lookup)
  and `{:prompt, content, metadata}` (used by TriggerRouter dispatch),
  forwarding received prompts to the test process.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:get_status, _from, state) do
    status = %{
      id: Map.get(state, :id, "fake-session"),
      definition: state.definition,
      taint_level: Map.get(state, :taint_level, :low),
      sensitivity_level: Map.get(state, :sensitivity_level, :low),
      information_level: Map.get(state, :information_level, :low),
      status: :ready,
      session_key: nil
    }

    {:reply, status, state}
  end

  def handle_call({:prompt, content, metadata}, _from, state) do
    if pid = Map.get(state, :test_pid) do
      send(pid, {:prompt_received, state.definition.name, content, metadata})
    end

    {:reply, :ok, state}
  end
end

defmodule TriOnyx.Triggers.InterAgentTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Triggers.InterAgent
  alias TriOnyx.TriggerRouter
  alias TriOnyx.AuditLog
  alias TriOnyx.Triggers.InterAgentTest.FakeSession

  defp make_def(attrs) do
    defaults = %{
      description: nil,
      model: "claude-sonnet-4-20250514",
      tools: ["Read"],
      network: :none,
      fs_read: [],
      fs_write: [],
      send_to: [],
      receive_from: [],
      system_prompt: "test prompt",
      heartbeat_every: nil
    }

    merged = Map.merge(defaults, attrs)

    %AgentDefinition{
      name: merged.name,
      description: merged[:description],
      model: merged.model,
      tools: merged.tools,
      network: merged.network,
      fs_read: merged.fs_read,
      fs_write: merged.fs_write,
      send_to: merged.send_to,
      receive_from: merged.receive_from,
      system_prompt: merged.system_prompt,
      heartbeat_every: merged[:heartbeat_every]
    }
  end

  describe "validate_message/1" do
    test "accepts valid message" do
      message = %{
        from: "agent-a",
        to: "agent-b",
        message_type: "status_update",
        payload: %{"status" => "complete"}
      }

      assert :ok = InterAgent.validate_message(message)
    end

    test "rejects empty from field" do
      message = %{from: "", to: "agent-b", message_type: "test", payload: %{}}
      assert {:error, {:invalid_field, :from, _}} = InterAgent.validate_message(message)
    end

    test "rejects empty to field" do
      message = %{from: "agent-a", to: "", message_type: "test", payload: %{}}
      assert {:error, {:invalid_field, :to, _}} = InterAgent.validate_message(message)
    end

    test "rejects empty message_type" do
      message = %{from: "agent-a", to: "agent-b", message_type: "", payload: %{}}
      assert {:error, {:invalid_field, :message_type, _}} = InterAgent.validate_message(message)
    end

    test "rejects self-message" do
      message = %{from: "agent-a", to: "agent-a", message_type: "test", payload: %{}}
      assert {:error, :self_message} = InterAgent.validate_message(message)
    end

    test "rejects invalid structure" do
      assert {:error, :invalid_message_structure} = InterAgent.validate_message(%{})
      assert {:error, :invalid_message_structure} = InterAgent.validate_message("not a map")
    end
  end

  describe "sanitize/1" do
    test "accepts simple payload" do
      payload = %{"key" => "value", "count" => 42}
      assert {:ok, ^payload} = InterAgent.sanitize(payload)
    end

    test "accepts nested payload" do
      payload = %{"data" => %{"items" => [1, 2, 3], "active" => true}}
      assert {:ok, ^payload} = InterAgent.sanitize(payload)
    end

    test "accepts payload with nil values" do
      payload = %{"key" => nil}
      assert {:ok, ^payload} = InterAgent.sanitize(payload)
    end

    test "rejects payload with oversized strings" do
      large_string = String.duplicate("x", 1025)
      payload = %{"data" => large_string}
      assert {:error, :sanitization_failed} = InterAgent.sanitize(payload)
    end

    test "rejects payload with oversized strings in nested structure" do
      large_string = String.duplicate("x", 1025)
      payload = %{"nested" => %{"deep" => large_string}}
      assert {:error, :sanitization_failed} = InterAgent.sanitize(payload)
    end

    test "accepts payload at exactly max string length" do
      max_string = String.duplicate("x", 1024)
      payload = %{"data" => max_string}
      assert {:ok, ^payload} = InterAgent.sanitize(payload)
    end
  end

  describe "messaging policy enforcement via route/2" do
    setup do
      # Start an AuditLog for logging
      audit_name = :"audit_#{:erlang.unique_integer([:positive])}"
      {:ok, _audit} = AuditLog.start_link(name: audit_name, audit_dir: "./tmp/test-audit-#{:erlang.unique_integer([:positive])}")

      # Create agent definitions with declared messaging peers
      sender = make_def(%{
        name: "sender-agent",
        tools: ["Read", "SendMessage"],
        send_to: ["receiver-agent"],
        receive_from: ["receiver-agent"]
      })

      receiver = make_def(%{
        name: "receiver-agent",
        tools: ["Read", "SendMessage"],
        send_to: ["sender-agent"],
        receive_from: ["sender-agent"]
      })

      # An agent that doesn't declare any messaging peers
      isolated = make_def(%{
        name: "isolated-agent",
        tools: ["Read", "SendMessage"],
        send_to: [],
        receive_from: []
      })

      # Start TriggerRouter with these definitions
      router_name = :"router_#{:erlang.unique_integer([:positive])}"
      {:ok, _router} = TriggerRouter.start_link(
        name: router_name,
        definitions: [sender, receiver, isolated]
      )

      %{router: router_name, audit_log: audit_name}
    end

    test "accepts message between declared peers", %{router: router, audit_log: audit_log} do
      message = %{
        from: "sender-agent",
        to: "receiver-agent",
        message_type: "request",
        payload: %{"data" => "hello"}
      }

      # route/2 will fail at dispatch (no supervisor) but should pass policy check
      # We check that the error is NOT a policy rejection
      result = InterAgent.route(message, router: router, audit_log: audit_log)

      case result do
        {:error, {:send_not_allowed, _, _}} -> flunk("Should not reject declared peer")
        {:error, {:receive_not_allowed, _, _}} -> flunk("Should not reject declared peer")
        _ -> :ok
      end
    end

    test "rejects message when sender doesn't list target in send_to", %{router: router, audit_log: audit_log} do
      message = %{
        from: "isolated-agent",
        to: "receiver-agent",
        message_type: "request",
        payload: %{"data" => "sneaky"}
      }

      assert {:error, {:send_not_allowed, "isolated-agent", "receiver-agent"}} =
               InterAgent.route(message, router: router, audit_log: audit_log)
    end

    test "rejects message when receiver doesn't list sender in receive_from", %{router: router, audit_log: audit_log} do
      # isolated-agent is not in receiver-agent's receive_from
      # But we need sender to list target in send_to first.
      # Create a scenario: sender lists receiver, but receiver doesn't list sender

      one_way_sender = make_def(%{
        name: "one-way-sender",
        tools: ["Read", "SendMessage"],
        send_to: ["receiver-agent"],
        receive_from: []
      })

      # Register the one-way sender
      TriggerRouter.register_agent(router, one_way_sender)

      message = %{
        from: "one-way-sender",
        to: "receiver-agent",
        message_type: "request",
        payload: %{"data" => "one-way"}
      }

      assert {:error, {:receive_not_allowed, "receiver-agent", "one-way-sender"}} =
               InterAgent.route(message, router: router, audit_log: audit_log)
    end
  end

  describe "risk axis propagation via route/2" do
    setup do
      audit_name = :"audit_#{:erlang.unique_integer([:positive])}"

      {:ok, _audit} =
        AuditLog.start_link(
          name: audit_name,
          audit_dir: "./tmp/test-audit-#{:erlang.unique_integer([:positive])}"
        )

      sender = make_def(%{
        name: "sender-agent",
        tools: ["Read", "SendMessage"],
        send_to: ["receiver-agent"],
        receive_from: ["receiver-agent"]
      })

      receiver = make_def(%{
        name: "receiver-agent",
        tools: ["Read", "SendMessage"],
        send_to: ["sender-agent"],
        receive_from: ["sender-agent"]
      })

      sup_name = :"sup_#{:erlang.unique_integer([:positive])}"
      {:ok, _sup} = AgentSupervisor.start_link(name: sup_name)

      router_name = :"router_#{:erlang.unique_integer([:positive])}"

      {:ok, _router} =
        TriggerRouter.start_link(
          name: router_name,
          supervisor: sup_name,
          definitions: [sender, receiver]
        )

      %{
        router: router_name,
        audit_log: audit_name,
        supervisor: sup_name,
        sender: sender,
        receiver: receiver
      }
    end

    defp start_fake_session(supervisor, opts) do
      spec = %{
        id: make_ref(),
        start: {FakeSession, :start_link, [opts]},
        restart: :temporary
      }

      {:ok, pid} = DynamicSupervisor.start_child(supervisor, spec)
      pid
    end

    test "passes sender taint and sensitivity as separate axes in metadata",
         %{router: router, audit_log: audit_log, supervisor: sup, sender: sender, receiver: receiver} do
      # High-sensitivity but LOW-taint sender — the receiver's metadata must
      # carry taint :low (not the combined :high level) and sensitivity :high.
      start_fake_session(sup,
        definition: sender,
        taint_level: :low,
        sensitivity_level: :high,
        information_level: :high
      )

      start_fake_session(sup, definition: receiver, test_pid: self())

      message = %{
        from: "sender-agent",
        to: "receiver-agent",
        message_type: "status_update",
        payload: %{"status" => "done"}
      }

      assert {:ok, _pid} =
               InterAgent.route(message,
                 router: router,
                 audit_log: audit_log,
                 supervisor: sup
               )

      assert_receive {:prompt_received, "receiver-agent", _payload, metadata}
      assert metadata.taint_level == :low
      assert metadata.sensitivity_level == :high
      # Combined level kept for backward compat
      assert metadata.information_level == :high
      assert metadata.sender_information_level == :high
    end

    test "passes high sender taint through as taint",
         %{router: router, audit_log: audit_log, supervisor: sup, sender: sender, receiver: receiver} do
      start_fake_session(sup,
        definition: sender,
        taint_level: :high,
        sensitivity_level: :medium,
        information_level: :high
      )

      start_fake_session(sup, definition: receiver, test_pid: self())

      message = %{
        from: "sender-agent",
        to: "receiver-agent",
        message_type: "status_update",
        payload: %{"status" => "done"}
      }

      assert {:ok, _pid} =
               InterAgent.route(message,
                 router: router,
                 audit_log: audit_log,
                 supervisor: sup
               )

      assert_receive {:prompt_received, "receiver-agent", _payload, metadata}
      assert metadata.taint_level == :high
      assert metadata.sensitivity_level == :medium
    end

    test "defaults both axes to low when sender has no active session",
         %{router: router, audit_log: audit_log, supervisor: sup, receiver: receiver} do
      start_fake_session(sup, definition: receiver, test_pid: self())

      message = %{
        from: "sender-agent",
        to: "receiver-agent",
        message_type: "status_update",
        payload: %{"status" => "done"}
      }

      assert {:ok, _pid} =
               InterAgent.route(message,
                 router: router,
                 audit_log: audit_log,
                 supervisor: sup
               )

      assert_receive {:prompt_received, "receiver-agent", _payload, metadata}
      assert metadata.taint_level == :low
      assert metadata.sensitivity_level == :low
      assert metadata.information_level == :low
    end
  end
end
