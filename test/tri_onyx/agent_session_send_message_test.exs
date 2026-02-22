defmodule TriOnyx.AgentSessionSendMessageTest do
  use ExUnit.Case

  alias TriOnyx.AgentSession

  describe "elevate_information/3 with inter-agent metadata" do
    test "elevates session from low when receiving medium inter-agent message" do
      state = %{
        id: "send-msg-test",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state =
        AgentSession.elevate_information(state, :medium, "inter-agent message from researcher")

      assert new_state.information_level == :medium
      assert "inter-agent message from researcher" in new_state.information_sources
      assert new_state.input_risk == :medium
    end

    test "high inter-agent message elevates to high and recomputes risk" do
      state = %{
        id: "send-msg-test",
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low
      }

      new_state =
        AgentSession.elevate_information(state, :high, "inter-agent message from web-scraper")

      assert new_state.information_level == :high
      assert new_state.input_risk == :high
      # high taint x low sensitivity = moderate
      assert new_state.effective_risk == :moderate
    end

    test "low inter-agent message does not elevate existing medium session" do
      state = %{
        id: "send-msg-test",
        taint_level: :medium,
        sensitivity_level: :low,
        information_level: :medium,
        information_sources: ["previous source"],
        input_risk: :medium,
        effective_risk: :low
      }

      new_state =
        AgentSession.elevate_information(state, :low, "inter-agent message from safe-agent")

      assert new_state.information_level == :medium
      # low-level sources are not recorded when already at higher level
      assert length(new_state.information_sources) == 1
    end
  end
end
