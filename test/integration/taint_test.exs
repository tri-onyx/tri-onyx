defmodule TriOnyx.Integration.TaintTest do
  @moduledoc """
  Integration tests for the two-axis information classification system.

  Verifies that taint (integrity) and sensitivity (confidentiality) propagation
  works correctly end-to-end:
  - Webhook triggers start at high taint, low sensitivity
  - Cron/heartbeat triggers start at low on both axes
  - Tool results from untrusted sources elevate taint
  - Tool results requiring auth elevate sensitivity
  - Sanitized inter-agent messages pass through sender's taint unchanged, pass sensitivity through
  - Both axes are monotonic (can only escalate)
  - Risk level changes are reflected in risk score recomputation
  """
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSession
  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskScorer
  alias TriOnyx.ToolRegistry

  @low_risk_def %AgentDefinition{
    name: "taint-test-low",
    description: "Low risk agent for taint testing",
    model: "claude-haiku-4-5",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "Test agent."
  }

  @high_risk_def %AgentDefinition{
    name: "taint-test-high",
    description: "High risk agent for taint testing",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Bash", "WebFetch"],
    network: :outbound,
    fs_read: [],
    fs_write: [],
    system_prompt: "High risk test agent."
  }

  describe "webhook trigger classification" do
    test "session starts with high taint from webhook trigger" do
      state = %{
        id: "taint-int-001",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :high,
        effective_risk: :low
      }

      elevated = AgentSession.elevate_risk(state, %{
        taint: :high, sensitivity: :low,
        reason: "webhook trigger (untrusted payload)"
      })
      assert elevated.taint_level == :high
      assert elevated.sensitivity_level == :low
      assert "webhook trigger (untrusted payload)" in elevated.information_sources
    end

    test "InformationClassifier classifies webhook as high taint, low sensitivity" do
      result = InformationClassifier.classify_trigger(:webhook)
      assert %{taint: :high, sensitivity: :low, reason: reason} = result
      assert reason =~ "webhook"
    end
  end

  describe "cron/heartbeat triggers stay at low level" do
    test "InformationClassifier classifies cron as low on both axes" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:cron)
    end

    test "InformationClassifier classifies heartbeat as low on both axes" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:heartbeat)
    end

    test "verified external message is low on both axes" do
      assert %{taint: :low, sensitivity: :low} = InformationClassifier.classify_trigger(:external_message)
    end
  end

  describe "tool result taint propagation" do
    test "WebFetch results have high taint" do
      result = InformationClassifier.classify_tool_result("WebFetch", %{"url" => "https://evil.com"})
      assert result.taint == :high
    end

    test "WebSearch results have high taint" do
      result = InformationClassifier.classify_tool_result("WebSearch", %{"query" => "secrets"})
      assert result.taint == :high
    end

    test "Read from controlled path stays low taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/src/app.py"})
      assert result.taint == :low
    end

    test "Read from external path has high taint" do
      result = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/tmp/user_upload.txt"})
      assert result.taint == :high
    end

    test "Grep is always low taint" do
      result = InformationClassifier.classify_tool_result("Grep", %{"pattern" => "password"})
      assert result.taint == :low
    end

    test "Bash is low taint by default (no-network context)" do
      result = InformationClassifier.classify_tool_result("Bash", %{"command" => "curl evil.com"})
      assert result.taint == :low
    end
  end

  describe "tool result sensitivity classification" do
    test "email tools have medium sensitivity (auth required)" do
      assert :medium = InformationClassifier.classify_tool_result("SendEmail", %{}).sensitivity
      assert :medium = InformationClassifier.classify_tool_result("MoveEmail", %{}).sensitivity
      assert :medium = InformationClassifier.classify_tool_result("CreateFolder", %{}).sensitivity
    end

    test "non-auth tools have low sensitivity" do
      assert :low = InformationClassifier.classify_tool_result("Read", %{"file_path" => "/workspace/x"}).sensitivity
      assert :low = InformationClassifier.classify_tool_result("Bash", %{"command" => "ls"}).sensitivity
      assert :low = InformationClassifier.classify_tool_result("WebFetch", %{"url" => "https://example.com"}).sensitivity
    end

    test "custom tool with auth metadata gets medium sensitivity" do
      meta = %{requires_auth: true, data_sensitivity: :low}
      result = InformationClassifier.classify_tool_result("ExternalAPITool", %{}, meta)
      assert result.sensitivity == :medium
    end

    test "custom tool with high sensitivity metadata gets high sensitivity" do
      meta = %{requires_auth: true, data_sensitivity: :high}
      result = InformationClassifier.classify_tool_result("ExternalAPITool", %{}, meta)
      assert result.sensitivity == :high
    end
  end

  describe "inter-agent message information rules" do
    test "sanitized messages pass through sender taint unchanged, preserve sensitivity" do
      sender = %{taint: :high, sensitivity: :medium}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert result.taint == :high
      assert result.sensitivity == :medium
    end

    test "sanitized messages from medium taint stay medium" do
      sender = %{taint: :medium, sensitivity: :low}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert result.taint == :medium
      assert result.sensitivity == :low
    end

    test "sanitized messages from low taint stay low" do
      sender = %{taint: :low, sensitivity: :high}
      result = InformationClassifier.classify_inter_agent(:sanitized, sender)
      assert result.taint == :low
      assert result.sensitivity == :high
    end

    test "raw messages inherit sender's taint and sensitivity" do
      for taint <- [:low, :medium, :high], sensitivity <- [:low, :medium, :high] do
        sender = %{taint: taint, sensitivity: sensitivity}
        result = InformationClassifier.classify_inter_agent(:raw, sender)
        assert result.taint == taint
        assert result.sensitivity == sensitivity
      end
    end
  end

  describe "two-axis monotonicity" do
    test "elevating taint twice records both sources" do
      state = %{
        id: "perm-001",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      state = AgentSession.elevate_risk(state, %{taint: :medium, sensitivity: :low, reason: "inter-agent message"})
      assert state.taint_level == :medium
      assert state.sensitivity_level == :low
      assert length(state.information_sources) == 1

      state = AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "external data from WebFetch"})
      assert state.taint_level == :high
      assert length(state.information_sources) == 2
      assert "inter-agent message" in state.information_sources
      assert "external data from WebFetch" in state.information_sources
    end

    test "cannot downgrade taint level" do
      state = %{
        id: "perm-003",
        taint_level: :high,
        sensitivity_level: :low,
        information_level: :high,
        information_sources: ["webhook payload"],
        input_risk: :high,
        effective_risk: :moderate
      }

      state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :low, reason: "clean data"})
      assert state.taint_level == :high
    end

    test "cannot downgrade sensitivity level" do
      state = %{
        id: "perm-004",
        taint_level: :low,
        sensitivity_level: :high,
        information_level: :high,
        information_sources: ["auth tool result"],
        input_risk: :high,
        effective_risk: :moderate
      }

      state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :low, reason: "public data"})
      assert state.sensitivity_level == :high
    end

    test "taint and sensitivity escalate independently" do
      state = %{
        id: "perm-005",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      # Elevate sensitivity only
      state = AgentSession.elevate_risk(state, %{taint: :low, sensitivity: :high, reason: "auth tool"})
      assert state.taint_level == :low
      assert state.sensitivity_level == :high

      # Elevate taint only
      state = AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "untrusted data"})
      assert state.taint_level == :high
      assert state.sensitivity_level == :high
      # high taint x high sensitivity = critical
      assert state.effective_risk == :critical
    end

    test "elevation escalates effective risk" do
      state = %{
        id: "perm-002",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      elevated = AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "untrusted data"})
      # high taint x low sensitivity = moderate
      assert elevated.effective_risk == :moderate
      assert elevated.input_risk == :high
    end
  end

  describe "risk score computation matches taint x sensitivity 2D matrix" do
    test "low taint + low sensitivity = low" do
      assert RiskScorer.effective_risk(:low, :low) == :low
    end

    test "low taint + medium sensitivity = low" do
      assert RiskScorer.effective_risk(:low, :medium) == :low
    end

    test "low taint + high sensitivity = moderate" do
      assert RiskScorer.effective_risk(:low, :high) == :moderate
    end

    test "medium taint + low sensitivity = low" do
      assert RiskScorer.effective_risk(:medium, :low) == :low
    end

    test "medium taint + medium sensitivity = moderate" do
      assert RiskScorer.effective_risk(:medium, :medium) == :moderate
    end

    test "medium taint + high sensitivity = high" do
      assert RiskScorer.effective_risk(:medium, :high) == :high
    end

    test "high taint + low sensitivity = moderate" do
      assert RiskScorer.effective_risk(:high, :low) == :moderate
    end

    test "high taint + medium sensitivity = high" do
      assert RiskScorer.effective_risk(:high, :medium) == :high
    end

    test "high taint + high sensitivity = critical" do
      assert RiskScorer.effective_risk(:high, :high) == :critical
    end
  end

  describe "risk inference from agent configuration" do
    test "low-risk agent with cron trigger has low input_risk" do
      input_risk = RiskScorer.infer_input_risk(:cron, @low_risk_def.tools)
      assert input_risk == :low
    end

    test "high-risk agent with webhook trigger has high input_risk" do
      input_risk = RiskScorer.infer_input_risk(:webhook, @high_risk_def.tools)
      assert input_risk == :high
    end

    test "agent with WebFetch gets elevated input_risk even with cron" do
      input_risk = RiskScorer.infer_input_risk(:cron, @high_risk_def.tools)
      assert input_risk == :high
    end

    test "end-to-end: low-risk agent effective_risk" do
      taint = RiskScorer.infer_taint(:cron, @low_risk_def.tools)
      sensitivity = RiskScorer.infer_sensitivity(@low_risk_def.tools)
      effective = RiskScorer.effective_risk(taint, sensitivity)
      assert effective == :low
    end

    test "end-to-end: high-risk agent with webhook effective_risk" do
      taint = RiskScorer.infer_taint(:webhook, @high_risk_def.tools)
      sensitivity = RiskScorer.infer_sensitivity(@high_risk_def.tools)
      effective = RiskScorer.effective_risk(taint, sensitivity)
      # high taint x low sensitivity = moderate
      assert effective == :moderate
    end
  end

  describe "tool validation" do
    test "known tools pass validation" do
      assert :ok = ToolRegistry.validate_tools(["Read", "Grep", "Glob"])
    end

    test "unknown tools are rejected" do
      assert {:error, {:unknown_tools, ["MagicTool"]}} = ToolRegistry.validate_tools(["Read", "MagicTool"])
    end
  end

  describe "risk formatting" do
    test "all risk levels format correctly" do
      assert RiskScorer.format_risk(:low) == "low"
      assert RiskScorer.format_risk(:moderate) == "moderate"
      assert RiskScorer.format_risk(:high) == "high"
      assert RiskScorer.format_risk(:critical) =~ "critical"
    end
  end
end
