defmodule TriOnyx do
  @moduledoc """
  TriOnyx is a non-agentic gateway that serves as the control plane for
  autonomous AI agent sessions.

  The gateway is a deterministic security boundary built on Elixir/OTP. It
  contains no LLM logic and makes no autonomous decisions. It manages agent
  sessions as BEAM processes under OTP supervision trees, enforcing agent
  definitions as hard constraints, executing tool calls on behalf of agents,
  and mediating all inter-agent communication.

  Security is modeled as: `effective_risk = max(taint, sensitivity)`

  The gateway computes and displays risk to the human operator, who remains
  the final authority. Transparency over restriction.
  """
end
