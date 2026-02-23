defmodule TriOnyx.RiskScorerTest do
  use ExUnit.Case, async: true

  alias TriOnyx.RiskScorer

  describe "effective_risk/2 (taint x sensitivity 2D matrix)" do
    test "low taint + low sensitivity = low" do
      assert :low = RiskScorer.effective_risk(:low, :low)
    end

    test "low taint + medium sensitivity = low" do
      assert :low = RiskScorer.effective_risk(:low, :medium)
    end

    test "low taint + high sensitivity = moderate" do
      assert :moderate = RiskScorer.effective_risk(:low, :high)
    end

    test "medium taint + low sensitivity = low" do
      assert :low = RiskScorer.effective_risk(:medium, :low)
    end

    test "medium taint + medium sensitivity = moderate" do
      assert :moderate = RiskScorer.effective_risk(:medium, :medium)
    end

    test "medium taint + high sensitivity = high" do
      assert :high = RiskScorer.effective_risk(:medium, :high)
    end

    test "high taint + low sensitivity = moderate" do
      assert :moderate = RiskScorer.effective_risk(:high, :low)
    end

    test "high taint + medium sensitivity = high" do
      assert :high = RiskScorer.effective_risk(:high, :medium)
    end

    test "high taint + high sensitivity = critical" do
      assert :critical = RiskScorer.effective_risk(:high, :high)
    end
  end

  describe "infer_taint/2" do
    test "cron trigger with read-only tools = low" do
      assert :low = RiskScorer.infer_taint(:cron, ["Read", "Grep", "Glob"])
    end

    test "webhook trigger = high" do
      assert :high = RiskScorer.infer_taint(:webhook, ["Read"])
    end

    test "cron with WebFetch elevates to high" do
      assert :high = RiskScorer.infer_taint(:cron, ["Read", "WebFetch"])
    end

    test "cron with Bash stays low (no-network default)" do
      assert :low = RiskScorer.infer_taint(:cron, ["Read", "Bash"])
    end
  end

  describe "infer_sensitivity/1" do
    test "non-auth tools return low" do
      assert :low = RiskScorer.infer_sensitivity(["Read", "Write", "Bash", "WebFetch"])
    end

    test "SendEmail elevates to medium" do
      assert :medium = RiskScorer.infer_sensitivity(["SendEmail"])
    end

    test "MoveEmail stays low sensitivity" do
      assert :low = RiskScorer.infer_sensitivity(["Read", "MoveEmail"])
    end
  end

  describe "infer_input_risk/2 (backward compat)" do
    test "cron trigger with read-only tools = low" do
      assert :low = RiskScorer.infer_input_risk(:cron, ["Read", "Grep", "Glob"])
    end

    test "webhook trigger = high" do
      assert :high = RiskScorer.infer_input_risk(:webhook, ["Read"])
    end

    test "cron with WebFetch elevates to high (tool data access)" do
      assert :high = RiskScorer.infer_input_risk(:cron, ["Read", "WebFetch"])
    end

    test "cron with Bash stays low (no-network default)" do
      assert :low = RiskScorer.infer_input_risk(:cron, ["Read", "Bash"])
    end
  end

  describe "effective_risk/3 (taint × sensitivity × capability — lethal trifecta)" do
    test "high taint + high sensitivity + low capability = high (contained)" do
      assert :high = RiskScorer.effective_risk(:high, :high, :low)
    end

    test "high taint + high sensitivity + medium capability = critical (baseline)" do
      assert :critical = RiskScorer.effective_risk(:high, :high, :medium)
    end

    test "high taint + high sensitivity + high capability = critical (armed)" do
      assert :critical = RiskScorer.effective_risk(:high, :high, :high)
    end

    test "low taint + low sensitivity + high capability = low (no ammunition)" do
      assert :low = RiskScorer.effective_risk(:low, :low, :high)
    end

    test "medium taint + medium sensitivity + high capability = high (stepped up from moderate)" do
      assert :high = RiskScorer.effective_risk(:medium, :medium, :high)
    end

    test "medium taint + high sensitivity + low capability = moderate (stepped down from high)" do
      assert :moderate = RiskScorer.effective_risk(:medium, :high, :low)
    end

    test "low capability steps down all levels" do
      assert :low = RiskScorer.effective_risk(:low, :low, :low)
      assert :low = RiskScorer.effective_risk(:low, :medium, :low)
      assert :low = RiskScorer.effective_risk(:low, :high, :low)
      assert :low = RiskScorer.effective_risk(:medium, :low, :low)
      assert :low = RiskScorer.effective_risk(:medium, :medium, :low)
      assert :moderate = RiskScorer.effective_risk(:medium, :high, :low)
      assert :low = RiskScorer.effective_risk(:high, :low, :low)
      assert :moderate = RiskScorer.effective_risk(:high, :medium, :low)
      assert :high = RiskScorer.effective_risk(:high, :high, :low)
    end

    test "high capability steps up all levels" do
      assert :low = RiskScorer.effective_risk(:low, :low, :high)
      assert :low = RiskScorer.effective_risk(:low, :medium, :high)
      assert :high = RiskScorer.effective_risk(:low, :high, :high)
      assert :low = RiskScorer.effective_risk(:medium, :low, :high)
      assert :high = RiskScorer.effective_risk(:medium, :medium, :high)
      assert :critical = RiskScorer.effective_risk(:medium, :high, :high)
      assert :high = RiskScorer.effective_risk(:high, :low, :high)
      assert :critical = RiskScorer.effective_risk(:high, :medium, :high)
      assert :critical = RiskScorer.effective_risk(:high, :high, :high)
    end
  end

  describe "infer_capability/2" do
    test "read-only tools with no network = low" do
      assert :low = RiskScorer.infer_capability(["Read", "Write"], :none)
    end

    test "Bash without network = medium" do
      assert :medium = RiskScorer.infer_capability(["Read", "Bash"], :none)
    end

    test "Bash with network = high" do
      assert :high = RiskScorer.infer_capability(["Read", "Bash"], :outbound)
    end

    test "SendEmail without network = high" do
      assert :high = RiskScorer.infer_capability(["Read", "SendEmail"], :none)
    end

    test "WebFetch without Bash = medium" do
      assert :medium = RiskScorer.infer_capability(["Read", "WebFetch"], :none)
    end

    test "filesystem-only tools with network = low (network alone doesn't elevate)" do
      assert :low = RiskScorer.infer_capability(["Read", "Write", "Grep"], :outbound)
    end

    test "Bash with host list = high" do
      assert :high = RiskScorer.infer_capability(["Bash"], ["api.example.com"])
    end

    test "empty tools = low" do
      assert :low = RiskScorer.infer_capability([], :none)
    end
  end

  describe "format_risk/1" do
    test "formats all risk levels" do
      assert "low" = RiskScorer.format_risk(:low)
      assert "moderate" = RiskScorer.format_risk(:moderate)
      assert "high" = RiskScorer.format_risk(:high)
      assert "critical \u26A0" = RiskScorer.format_risk(:critical)
    end
  end
end
