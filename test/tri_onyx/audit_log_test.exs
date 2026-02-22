defmodule TriOnyx.AuditLogTest do
  use ExUnit.Case

  alias TriOnyx.AuditLog

  @audit_dir "test/tmp/audit_log_test"

  setup do
    File.rm_rf!(@audit_dir)
    {:ok, pid} = AuditLog.start_link(name: :test_audit, audit_dir: @audit_dir)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(@audit_dir)
    end)

    %{server: :test_audit}
  end

  describe "log_session_start/4" do
    test "writes session start event to JSONL file", %{server: server} do
      AuditLog.log_session_start(server, "sess-001", "test-agent", %{
        input_risk: :low,
        effective_risk: :low,
        information_level: :low
      })

      # Allow async cast to complete
      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "session_start"
      assert entry["session_id"] == "sess-001"
      assert entry["agent_name"] == "test-agent"
      assert entry["input_risk"] == "low"
      assert entry["information_level"] == "low"
      assert entry["timestamp"]
    end
  end

  describe "log_session_stop/4" do
    test "writes session stop event", %{server: server} do
      AuditLog.log_session_stop(server, "sess-002", "test-agent", %{
        information_level: :high,
        effective_risk: :critical,
        reason: "operator requested"
      })

      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "session_stop"
      assert entry["session_id"] == "sess-002"
      assert entry["reason"] == "operator requested"
    end
  end

  describe "log_tool_call/5" do
    test "writes tool call event", %{server: server} do
      AuditLog.log_tool_call(server, "sess-003", "tu-1", "Read", %{"file_path" => "/workspace/f.ex"})

      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "tool_call"
      assert entry["tool_name"] == "Read"
      assert entry["tool_use_id"] == "tu-1"
    end
  end

  describe "log_information_change/6" do
    test "writes information change event", %{server: server} do
      AuditLog.log_information_change(server, "sess-004", "agent-x", :low, :high, "webhook payload")

      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "information_change"
      assert entry["old_level"] == "low"
      assert entry["new_level"] == "high"
      assert entry["source"] == "webhook payload"
    end
  end

  describe "log_inter_agent_message/5" do
    test "writes inter-agent message event", %{server: server} do
      AuditLog.log_inter_agent_message(server, "sess-005", "target-agent", "status_update", true)

      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "inter_agent_message"
      assert entry["from_session"] == "sess-005"
      assert entry["to_agent"] == "target-agent"
      assert entry["sanitized"] == true
    end
  end

  describe "log_trigger/4" do
    test "writes trigger event", %{server: server} do
      AuditLog.log_trigger(server, :webhook, "webhook-handler", :untrusted)

      :sys.get_state(server)

      entry = read_last_entry()
      assert entry["type"] == "trigger"
      assert entry["trigger_type"] == "webhook"
      assert entry["trust_level"] == "untrusted"
    end
  end

  describe "file rotation" do
    test "creates daily JSONL file", %{server: server} do
      AuditLog.log_event(server, %{type: :test_event, data: "hello"})

      :sys.get_state(server)

      today = Date.utc_today() |> Date.to_iso8601()
      path = Path.join(@audit_dir, "#{today}.jsonl")
      assert File.exists?(path)
    end
  end

  # --- Helpers ---

  defp read_last_entry do
    today = Date.utc_today() |> Date.to_iso8601()
    path = Path.join(@audit_dir, "#{today}.jsonl")

    path
    |> File.read!()
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> Jason.decode!()
  end
end
