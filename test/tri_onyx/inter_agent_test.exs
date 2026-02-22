defmodule TriOnyx.Triggers.InterAgentTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.Triggers.InterAgent
  alias TriOnyx.TriggerRouter
  alias TriOnyx.AuditLog

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
end
