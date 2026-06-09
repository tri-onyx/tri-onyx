defmodule TriOnyx.RiskKillTest do
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSession
  alias TriOnyx.RiskScorer

  describe "RiskScorer.exceeds?/2" do
    test "orders risk levels low < moderate < high < critical" do
      assert RiskScorer.exceeds?(:moderate, :low)
      assert RiskScorer.exceeds?(:high, :moderate)
      assert RiskScorer.exceeds?(:critical, :high)
      refute RiskScorer.exceeds?(:low, :low)
      refute RiskScorer.exceeds?(:high, :high)
      refute RiskScorer.exceeds?(:critical, :critical)
      refute RiskScorer.exceeds?(:low, :critical)
    end
  end

  describe "max_effective_risk parsing" do
    defp parse_with(frontmatter_extra) do
      AgentDefinition.parse("""
      ---
      name: test-agent
      tools: Read
      #{frontmatter_extra}
      ---

      Prompt.
      """)
    end

    test "defaults to :critical when absent" do
      assert {:ok, definition} = parse_with("")
      assert definition.max_effective_risk == :critical
    end

    test "parses all valid levels" do
      for {value, expected} <- [
            {"low", :low},
            {"moderate", :moderate},
            {"high", :high},
            {"critical", :critical}
          ] do
        assert {:ok, definition} = parse_with("max_effective_risk: #{value}")
        assert definition.max_effective_risk == expected
      end
    end

    test "rejects invalid values with a field-specific error" do
      assert {:error, {:invalid_max_effective_risk, "banana", _hint}} =
               parse_with("max_effective_risk: banana")

      assert %{field: "max_effective_risk"} =
               AgentDefinition.format_error({:invalid_max_effective_risk, "banana", "hint"})
    end

    test "is exposed in the builder schema" do
      field =
        AgentDefinition.schema().fields
        |> Enum.find(&(&1.key == "max_effective_risk"))

      assert field != nil
      assert field.type == "enum"
      assert field.default == "critical"
      assert Enum.map(field.options, & &1.value) == ~w(low moderate high critical)
    end
  end

  describe "elevate_risk/2 kill trigger" do
    defp base_state(max_risk, capability) do
      %{
        id: "kill-test",
        definition: %{name: "test-agent", max_effective_risk: max_risk},
        capability_level: capability,
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }
    end

    test "sends kill message when escalation exceeds the ceiling" do
      # high taint x low sensitivity x high capability = :high > :moderate
      state = base_state(:moderate, :high)

      new_state =
        AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "webhook"})

      assert new_state.effective_risk == :high
      assert_receive {:kill_risk_exceeded, :high, :moderate, "webhook"}
    end

    test "no kill message when escalation stays within the ceiling" do
      state = base_state(:high, :high)

      AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :low, reason: "webhook"})

      refute_receive {:kill_risk_exceeded, _, _, _}, 50
    end

    test "default ceiling of :critical is never exceeded" do
      state = base_state(:critical, :high)

      AgentSession.elevate_risk(state, %{taint: :high, sensitivity: :high, reason: "worst case"})

      refute_receive {:kill_risk_exceeded, _, _, _}, 50
    end
  end
end
