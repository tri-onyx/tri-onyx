defmodule TriOnyx.ConnectorHandlerTest do
  use ExUnit.Case, async: true

  alias TriOnyx.ConnectorHandler
  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskScorer

  describe "init/1" do
    test "initializes with unauthenticated state" do
      assert {:ok, state} = ConnectorHandler.init([])
      assert state.authenticated == false
      assert state.connector_id == nil
      assert state.platform == nil
      assert state.session_channels == %{}
      assert state.health_timer == nil
    end
  end

  describe "register/auth protocol" do
    setup do
      Application.put_env(:tri_onyx, :connector_token, "test-secret-token")
      on_exit(fn -> Application.delete_env(:tri_onyx, :connector_token) end)
      {:ok, state} = ConnectorHandler.init([])
      {:ok, state: state}
    end

    test "successful registration with valid token", %{state: state} do
      frame =
        Jason.encode!(%{
          "type" => "register",
          "connector_id" => "matrix-1",
          "platform" => "matrix",
          "token" => "test-secret-token"
        })

      assert {:push, [{:text, reply}], new_state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "registered"
      assert decoded["connector_id"] == "matrix-1"
      assert new_state.authenticated == true
      assert new_state.connector_id == "matrix-1"
      assert new_state.platform == "matrix"
      assert new_state.health_timer != nil
    end

    test "auth rejection with bad token", %{state: state} do
      frame =
        Jason.encode!(%{
          "type" => "register",
          "connector_id" => "matrix-1",
          "platform" => "matrix",
          "token" => "wrong-token"
        })

      assert {:push, [{:text, reply}], new_state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "authentication failed"
      assert new_state.authenticated == false
    end

    test "auth rejection with missing token", %{state: state} do
      frame =
        Jason.encode!(%{
          "type" => "register",
          "connector_id" => "matrix-1",
          "platform" => "matrix"
        })

      assert {:push, [{:text, reply}], new_state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert new_state.authenticated == false
    end

    test "duplicate registration returns error", %{state: state} do
      authed_state = %{state | authenticated: true, connector_id: "matrix-1"}

      frame =
        Jason.encode!(%{
          "type" => "register",
          "connector_id" => "matrix-2",
          "platform" => "matrix",
          "token" => "test-secret-token"
        })

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, authed_state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "already registered"
    end
  end

  describe "unauthenticated message handling" do
    setup do
      {:ok, state} = ConnectorHandler.init([])
      {:ok, state: state}
    end

    test "message before auth is rejected", %{state: state} do
      frame =
        Jason.encode!(%{
          "type" => "message",
          "agent_name" => "coder",
          "content" => "hello",
          "channel" => %{},
          "trust" => %{"level" => "verified"}
        })

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "not authenticated"
    end
  end

  describe "trust level to trigger type mapping" do
    test "verified trust level maps to connector_verified trigger" do
      # Verified connector messages should be low taint
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:connector_verified)
    end

    test "unverified trust level maps to connector_unverified trigger" do
      # Unverified connector messages should be high taint
      assert %{taint: :high} = InformationClassifier.classify_trigger(:connector_unverified)
    end
  end

  describe "information classification for connector triggers" do
    test "connector_verified is low risk" do
      result = InformationClassifier.classify_trigger(:connector_verified)
      assert %{taint: :low, reason: reason} = result
      assert reason =~ "verified connector"
    end

    test "connector_unverified is high risk" do
      result = InformationClassifier.classify_trigger(:connector_unverified)
      assert %{taint: :high, reason: reason} = result
      assert reason =~ "unverified connector"
    end
  end

  describe "risk scoring for connector triggers" do
    test "connector_verified trigger with read-only tools = low" do
      assert :low = RiskScorer.infer_input_risk(:connector_verified, ["Read", "Grep"])
    end

    test "connector_unverified trigger = high" do
      assert :high = RiskScorer.infer_input_risk(:connector_unverified, ["Read"])
    end

    test "connector_verified with WebFetch elevates to high" do
      assert :high = RiskScorer.infer_input_risk(:connector_verified, ["Read", "WebFetch"])
    end

    test "connector_unverified has high taint" do
      assert :high = RiskScorer.infer_taint(:connector_unverified, ["Read"])
    end
  end

  describe "health tracking" do
    setup do
      {:ok, state} = ConnectorHandler.init([])

      authed_state = %{
        state
        | authenticated: true,
          connector_id: "matrix-1",
          platform: "matrix",
          health_timer: Process.send_after(self(), :noop, 60_000)
      }

      {:ok, state: authed_state}
    end

    test "health message resets timer", %{state: state} do
      old_timer = state.health_timer

      frame =
        Jason.encode!(%{
          "type" => "health",
          "connector_id" => "matrix-1",
          "adapters" => ["matrix"]
        })

      assert {:ok, new_state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      assert new_state.health_timer != old_timer
      assert new_state.health_timer != nil
    end

    test "health timeout triggers disconnect", %{state: state} do
      assert {:stop, :normal, _state} = ConnectorHandler.handle_info(:health_timeout, state)
    end
  end

  describe "event routing back with correct channel envelope" do
    setup do
      {:ok, state} = ConnectorHandler.init([])

      channel = %{
        "platform" => "matrix",
        "room_id" => "!abc:matrix.org",
        "thread_id" => "$event123"
      }

      authed_state = %{
        state
        | authenticated: true,
          connector_id: "matrix-1",
          platform: "matrix",
          session_channels: %{"session-abc" => {channel, "test-agent"}}
      }

      {:ok, state: authed_state, channel: channel}
    end

    test "text event is wrapped as agent_text with channel", %{state: state, channel: channel} do
      event = %{"type" => "text", "content" => "Hello world", "session_id" => "session-abc"}

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_info({:event_bus, "session-abc", event}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "agent_text"
      assert decoded["session_id"] == "session-abc"
      assert decoded["content"] == "Hello world"
      assert decoded["channel"] == channel
    end

    test "result event is wrapped as agent_result with channel", %{state: state, channel: channel} do
      event = %{"type" => "result", "duration_ms" => 1500, "session_id" => "session-abc"}

      assert {:push, [{:text, typing_reply}, {:text, result_reply}, {:text, step_reply}], _state} =
               ConnectorHandler.handle_info({:event_bus, "session-abc", event}, state)

      typing_decoded = Jason.decode!(typing_reply)
      assert typing_decoded["type"] == "agent_typing"
      assert typing_decoded["is_typing"] == false

      decoded = Jason.decode!(result_reply)
      assert decoded["type"] == "agent_result"
      assert decoded["channel"] == channel
      assert decoded["duration_ms"] == 1500

      step_decoded = Jason.decode!(step_reply)
      assert step_decoded["type"] == "agent_step"
      assert step_decoded["step_type"] == "result"
      assert step_decoded["duration_ms"] == 1500
    end

    test "error event is wrapped as agent_error with channel", %{state: state, channel: channel} do
      event = %{"type" => "error", "message" => "something broke", "session_id" => "session-abc"}

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_info({:event_bus, "session-abc", event}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "agent_error"
      assert decoded["channel"] == channel
      assert decoded["message"] == "something broke"
    end

    test "tool_use event is wrapped as agent_typing and agent_step", %{state: state, channel: channel} do
      event = %{
        "type" => "tool_use",
        "id" => "tool-1",
        "name" => "Read",
        "input" => %{"file_path" => "/tmp/test.txt"},
        "session_id" => "session-abc"
      }

      assert {:push, [{:text, typing_reply}, {:text, step_reply}], _state} =
               ConnectorHandler.handle_info({:event_bus, "session-abc", event}, state)

      typing_decoded = Jason.decode!(typing_reply)
      assert typing_decoded["type"] == "agent_typing"
      assert typing_decoded["is_typing"] == true

      step_decoded = Jason.decode!(step_reply)
      assert step_decoded["type"] == "agent_step"
      assert step_decoded["step_type"] == "tool_use"
      assert step_decoded["name"] == "Read"
      assert step_decoded["input"] == %{"file_path" => "/tmp/test.txt"}
      assert step_decoded["channel"] == channel
    end

    test "events for unknown sessions are ignored", %{state: state} do
      event = %{"type" => "text", "content" => "hello", "session_id" => "unknown"}

      assert {:ok, _state} =
               ConnectorHandler.handle_info({:event_bus, "unknown-session", event}, state)
    end
  end

  describe "reaction frame handling" do
    setup do
      Application.put_env(:tri_onyx, :connector_token, "test-secret-token")
      on_exit(fn -> Application.delete_env(:tri_onyx, :connector_token) end)

      {:ok, state} = ConnectorHandler.init([])

      authed_state = %{
        state
        | authenticated: true,
          connector_id: "matrix-1",
          platform: "matrix",
          health_timer: Process.send_after(self(), :noop, 60_000)
      }

      {:ok, state: authed_state}
    end

    test "thumbsup approval reaction calls ApprovalQueue.approve", %{state: state} do
      {:ok, approval_id} =
        TriOnyx.BCTP.ApprovalQueue.submit(%{
          query: %{},
          from_agent: "controller",
          to_agent: "reader",
          justification: "test"
        })

      frame =
        Jason.encode!(%{
          "type" => "reaction",
          "approval_id" => approval_id,
          "emoji" => "👍",
          "sender" => "@human:matrix.org",
          "channel" => %{"platform" => "matrix", "room_id" => "!room:matrix.org"}
        })

      assert {:ok, _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      # Verify it was approved
      assert [] = TriOnyx.BCTP.ApprovalQueue.list_pending()
    end

    test "thumbsdown approval reaction calls ApprovalQueue.reject", %{state: state} do
      {:ok, approval_id} =
        TriOnyx.BCTP.ApprovalQueue.submit(%{
          query: %{},
          from_agent: "controller",
          to_agent: "reader",
          justification: "test"
        })

      frame =
        Jason.encode!(%{
          "type" => "reaction",
          "approval_id" => approval_id,
          "emoji" => "👎",
          "sender" => "@human:matrix.org",
          "channel" => %{"platform" => "matrix", "room_id" => "!room:matrix.org"}
        })

      assert {:ok, _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      # Verify it was rejected (no longer pending)
      assert [] = TriOnyx.BCTP.ApprovalQueue.list_pending()
    end

    test "reaction with no approval_id or agent_name is handled gracefully", %{state: state} do
      frame =
        Jason.encode!(%{
          "type" => "reaction",
          "emoji" => "🎉",
          "sender" => "@user:matrix.org",
          "channel" => %{"platform" => "matrix", "room_id" => "!room:matrix.org"}
        })

      assert {:ok, _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)
    end
  end

  describe "invalid input handling" do
    setup do
      {:ok, state} = ConnectorHandler.init([])
      authed_state = %{state | authenticated: true, connector_id: "test-1", platform: "test"}
      {:ok, state: authed_state}
    end

    test "invalid JSON returns error", %{state: state} do
      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({"not json", [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "invalid JSON"
    end

    test "binary frames return error", %{state: state} do
      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({<<0, 1, 2>>, [opcode: :binary]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "binary frames not supported"
    end

    test "unknown frame type returns error", %{state: state} do
      frame = Jason.encode!(%{"type" => "nonsense"})

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "unknown frame type"
    end

    test "missing type field returns error", %{state: state} do
      frame = Jason.encode!(%{"data" => "no type"})

      assert {:push, [{:text, reply}], _state} =
               ConnectorHandler.handle_in({frame, [opcode: :text]}, state)

      decoded = Jason.decode!(reply)
      assert decoded["type"] == "error"
      assert decoded["message"] =~ "missing type"
    end
  end
end
