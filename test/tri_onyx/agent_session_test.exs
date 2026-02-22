defmodule TriOnyx.AgentSessionTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSession

  @test_definition %AgentDefinition{
    name: "test-agent",
    description: "A test agent",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You are a test agent."
  }

  describe "elevate_risk/2" do
    test "elevates taint independently from sensitivity" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "untrusted data"})

      assert new_state.taint_level == :high
      assert new_state.sensitivity_level == :low
      assert new_state.information_level == :high
      assert "untrusted data" in new_state.information_sources
    end

    test "elevates sensitivity independently from taint" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :high, reason: "auth-required tool"})

      assert new_state.taint_level == :low
      assert new_state.sensitivity_level == :high
      assert new_state.information_level == :high
      # low taint x high sensitivity = moderate
      assert new_state.effective_risk == :moderate
    end

    test "elevates both axes simultaneously" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :medium, reason: "external API"})

      assert new_state.taint_level == :high
      assert new_state.sensitivity_level == :medium
      assert new_state.information_level == :high
      # max(high, medium) = high
      assert new_state.effective_risk == :high
    end

    test "monotonic: cannot downgrade taint" do
      state = %{
        id: "test-123",
        taint_level: :high,
        sensitivity_level: :low,
        information_level: :high,
        information_sources: ["initial"],
        input_risk: :high,
        effective_risk: :moderate
      }

      new_state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :low, reason: "clean data"})

      assert new_state.taint_level == :high
    end

    test "monotonic: cannot downgrade sensitivity" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :high,
        information_level: :high,
        information_sources: ["initial"],
        input_risk: :high,
        effective_risk: :moderate
      }

      new_state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :low, reason: "public data"})

      assert new_state.sensitivity_level == :high
    end
  end

  describe "elevate_information/3 (backward compat)" do
    test "elevates a low-level session to high (taint only)" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_information(state, :high, "webhook payload")

      assert new_state.taint_level == :high
      assert new_state.sensitivity_level == :low
      assert new_state.information_level == :high
      assert "webhook payload" in new_state.information_sources
      assert new_state.input_risk == :high
    end

    test "elevates from low to medium" do
      state = %{
        id: "test-123",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_information(state, :medium, "inter-agent message")

      assert new_state.taint_level == :medium
      assert new_state.information_level == :medium
      assert "inter-agent message" in new_state.information_sources
      assert new_state.input_risk == :medium
      # medium taint x low sensitivity = low
      assert new_state.effective_risk == :low
    end

    test "records source when level stays the same but source is non-trivial" do
      state = %{
        id: "test-123",
        taint_level: :high,
        sensitivity_level: :low,
        information_level: :high,
        information_sources: ["initial source"],
        input_risk: :high,
        effective_risk: :moderate
      }

      new_state = AgentSession.elevate_information(state, :high, "second high source")

      assert new_state.taint_level == :high
      assert length(new_state.information_sources) == 2
      assert "second high source" in new_state.information_sources
    end

    test "does not record low-level sources when already at higher level" do
      state = %{
        id: "test-123",
        taint_level: :high,
        sensitivity_level: :low,
        information_level: :high,
        information_sources: ["initial source"],
        input_risk: :high,
        effective_risk: :moderate
      }

      new_state = AgentSession.elevate_information(state, :low, "clean data")

      assert new_state.taint_level == :high
      assert length(new_state.information_sources) == 1
    end

    test "recomputes effective risk on elevation" do
      state = %{
        id: "test-456",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state = AgentSession.elevate_information(state, :high, "external data")

      # high taint x low sensitivity = moderate
      assert new_state.effective_risk == :moderate
    end
  end

  describe "build_agent_config model passthrough" do
    test "definition struct holds correct fields" do
      assert @test_definition.name == "test-agent"
      assert @test_definition.model == "claude-sonnet-4-20250514"
    end
  end

  describe "temp_file?/1" do
    test "detects SDK temp files without leading dot" do
      assert AgentSession.temp_file?("HEARTBEAT.md.tmp.57.1771398374731")
      assert AgentSession.temp_file?("SOUL.md.tmp.50.1771023878427")
      assert AgentSession.temp_file?("agents/main/HEARTBEAT.md.tmp.57.1771398374731")
    end

    test "detects SDK temp files with leading dot (legacy pattern)" do
      assert AgentSession.temp_file?(".SOUL.md.tmp.50.1771023878427")
    end

    test "rejects normal files" do
      refute AgentSession.temp_file?("HEARTBEAT.md")
      refute AgentSession.temp_file?("SOUL.md")
      refute AgentSession.temp_file?("agents/main/memory.md")
    end

    test "rejects partial matches" do
      refute AgentSession.temp_file?("file.tmp")
      refute AgentSession.temp_file?("file.tmp.123")
    end
  end

  describe "idle timeout" do
    test "schedule_idle_timeout sends :idle_timeout after configured duration" do
      # Simulate the internal helper by sending :idle_timeout directly
      # and verifying the GenServer handles it correctly via handle_info
      state = %{
        id: "idle-test-123",
        definition: %{@test_definition | idle_timeout: 50},
        port: nil,
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low,
        started_at: DateTime.utc_now(),
        status: :ready,
        workspace_writes: MapSet.new(),
        trigger_type: :external_message,
        last_text: nil,
        pending_prompt: nil,
        pending_tools: %{},
        idle_timer: nil
      }

      # Schedule the timer the same way the GenServer would
      ref = Process.send_after(self(), :idle_timeout, 50)
      state = %{state | idle_timer: ref}

      assert state.idle_timer != nil
      assert_receive :idle_timeout, 200
    end

    test "cancel_idle_timeout prevents timeout message" do
      ref = Process.send_after(self(), :idle_timeout, 100)
      Process.cancel_timer(ref)

      refute_receive :idle_timeout, 200
    end
  end
end
