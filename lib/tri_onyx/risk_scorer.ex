defmodule TriOnyx.RiskScorer do
  @moduledoc """
  Computes effective risk scores for agent sessions.

  Risk is computed as a 3-axis model: `taint × sensitivity × capability`
  (the "lethal trifecta" from ADR-010).

  **Step 1:** Compute 2D baseline from `taint × sensitivity`:

  |              | low       | medium   | high     |
  |--------------|-----------|----------|----------|
  | **low**      | low       | low      | moderate |
  | **medium**   | low       | moderate | high     |
  | **high**     | moderate  | high     | critical |

  **Step 2:** Modulate by capability:

  - **Low capability** (step down): moderate→low, high→moderate, critical→high
  - **Medium capability** (no change): baseline preserved
  - **High capability** (step up): low→low, moderate→high, high→critical, critical→critical

  Capability is derived from `(tools, network_policy)` via `infer_capability/2`.
  Bash is the only unmediated-by-gateway tool; it is promoted from medium to
  high capability when the agent has network access.

  The gateway computes this at agent creation and displays it to the
  operator. The gateway warns but does not block — the human is the
  final authority.
  """

  alias TriOnyx.ToolRegistry
  alias TriOnyx.TaintMatrix
  alias TriOnyx.SensitivityMatrix

  @type risk_level :: :low | :moderate | :high | :critical

  # 2D risk matrix: {taint, sensitivity} => effective_risk
  @risk_matrix %{
    {:low, :low} => :low,
    {:low, :medium} => :low,
    {:low, :high} => :moderate,
    {:medium, :low} => :low,
    {:medium, :medium} => :moderate,
    {:medium, :high} => :high,
    {:high, :low} => :moderate,
    {:high, :medium} => :high,
    {:high, :high} => :critical
  }

  @doc """
  Returns the full 2D risk matrix as a map of `{taint, sensitivity} => risk`.
  """
  @spec risk_matrix() :: %{{atom(), atom()} => risk_level()}
  def risk_matrix, do: @risk_matrix

  @doc """
  Computes effective risk from taint and sensitivity (2D baseline).

  Uses the 2D risk matrix where rows are taint and columns are sensitivity.
  Assumes medium capability (no modulation). This is the backward-compatible
  entry point that preserves pre-ADR-010 behavior exactly.
  """
  @spec effective_risk(atom(), atom()) :: risk_level()
  def effective_risk(taint_level, sensitivity_level)
      when taint_level in [:low, :medium, :high] and
             sensitivity_level in [:low, :medium, :high] do
    Map.fetch!(@risk_matrix, {taint_level, sensitivity_level})
  end

  @doc """
  Computes effective risk from taint, sensitivity, and capability (3D trifecta).

  Computes the 2D baseline from `taint × sensitivity`, then modulates by
  capability:

  - `:low` — step down one level (contained agent)
  - `:medium` — no change (baseline)
  - `:high` — step up one level (armed agent)

  Floors at `:low`, caps at `:critical`.
  """
  @spec effective_risk(atom(), atom(), atom()) :: risk_level()
  def effective_risk(taint_level, sensitivity_level, capability_level)
      when taint_level in [:low, :medium, :high] and
             sensitivity_level in [:low, :medium, :high] and
             capability_level in [:low, :medium, :high] do
    baseline = Map.fetch!(@risk_matrix, {taint_level, sensitivity_level})
    modulate_by_capability(baseline, capability_level)
  end

  @doc """
  Infers the aggregate capability level from an agent's tools and network policy.

  Returns the maximum capability across all tools, with Bash promoted from
  `:medium` to `:high` when the agent has network access. Bash is the only
  tool that executes unmediated by the gateway; network access determines
  whether it can reach outside the container.
  """
  @spec infer_capability([String.t()], atom() | [String.t()]) :: :low | :medium | :high
  def infer_capability(tools, network_policy) when is_list(tools) do
    has_network = has_network?(network_policy)

    tools
    |> Enum.map(fn tool ->
      base = ToolRegistry.capability_level(tool)

      if tool == "Bash" and has_network and base == :medium do
        :high
      else
        base
      end
    end)
    |> Enum.reduce(:low, &higher_capability/2)
  end

  @doc """
  Infers input taint from trigger type and agent configuration.

  This is a heuristic for worst-case taint. The actual taint status is
  tracked at runtime by `TriOnyx.AgentSession`.

  Trigger taint and per-tool taint are both sourced from `TaintMatrix`.
  """
  @spec infer_taint(atom(), [String.t()]) :: atom()
  def infer_taint(trigger_type, tools) when is_atom(trigger_type) and is_list(tools) do
    base_risk = TaintMatrix.trigger_taint(trigger_type)
    tool_data_risk = tool_data_access_risk(tools)
    higher_level(base_risk, tool_data_risk)
  end

  @doc """
  Infers input sensitivity from agent tool configuration.

  Returns the worst-case sensitivity across the agent's tool list, sourced from
  `SensitivityMatrix`. Email tools (SendEmail, MoveEmail, CreateFolder) that
  require gateway-injected credentials return `:medium`.
  """
  @spec infer_sensitivity([String.t()]) :: atom()
  def infer_sensitivity(tools) when is_list(tools) do
    tools
    |> Enum.map(&SensitivityMatrix.tool_sensitivity/1)
    |> Enum.reduce(:low, &TriOnyx.InformationClassifier.higher_level/2)
  end

  @doc """
  Infers input_risk from trigger type and agent configuration.

  Returns `max(infer_taint, infer_sensitivity)`.
  """
  @spec infer_input_risk(atom(), [String.t()]) :: atom()
  def infer_input_risk(trigger_type, tools) when is_atom(trigger_type) and is_list(tools) do
    taint = infer_taint(trigger_type, tools)
    sensitivity = infer_sensitivity(tools)
    higher_level(taint, sensitivity)
  end

  @doc """
  Returns a human-readable risk summary for display.
  """
  @spec format_risk(risk_level()) :: String.t()
  def format_risk(:low), do: "low"
  def format_risk(:moderate), do: "moderate"
  def format_risk(:high), do: "high"
  def format_risk(:critical), do: "critical \u26A0"

  # --- Private ---

  @spec tool_data_access_risk([String.t()]) :: atom()
  defp tool_data_access_risk(tools) do
    tools
    |> Enum.map(&TaintMatrix.tool_taint/1)
    |> Enum.reduce(:low, &higher_level/2)
  end

  @spec higher_level(atom(), atom()) :: atom()
  defp higher_level(a, b) do
    rank = %{low: 0, medium: 1, high: 2}
    if rank[a] >= rank[b], do: a, else: b
  end

  # Capability modulation: shift risk level up or down by one step.
  @spec modulate_by_capability(risk_level(), :low | :medium | :high) :: risk_level()
  defp modulate_by_capability(risk, :medium), do: risk
  defp modulate_by_capability(:low, :low), do: :low
  defp modulate_by_capability(:moderate, :low), do: :low
  defp modulate_by_capability(:high, :low), do: :moderate
  defp modulate_by_capability(:critical, :low), do: :high
  defp modulate_by_capability(:low, :high), do: :low
  defp modulate_by_capability(:moderate, :high), do: :high
  defp modulate_by_capability(:high, :high), do: :critical
  defp modulate_by_capability(:critical, :high), do: :critical

  @spec higher_capability(atom(), atom()) :: atom()
  defp higher_capability(a, b) do
    rank = %{low: 0, medium: 1, high: 2}
    if rank[a] >= rank[b], do: a, else: b
  end

  @spec has_network?(atom() | [String.t()]) :: boolean()
  defp has_network?(:none), do: false
  defp has_network?(:outbound), do: true
  defp has_network?(hosts) when is_list(hosts) and hosts != [], do: true
  defp has_network?(_), do: false

end
