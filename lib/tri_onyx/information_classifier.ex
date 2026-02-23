defmodule TriOnyx.InformationClassifier do
  @moduledoc """
  Classifies data sources along two independent security axes:

  - **Taint** (integrity) — how trustworthy is the data? Tracks prompt
    injection risk. Internet-sourced data = high taint.
  - **Sensitivity** (confidentiality) — how sensitive is the data? Tracks
    data sensitivity. Auth-required tool responses = medium floor, PII = high.

  Called by `AgentSession` whenever new data enters the LLM context — trigger
  payloads, tool results, inter-agent messages. Each source is classified on
  both axes independently.

  Both axes are monotonic within a session — they can only escalate, never
  decrease. The classifier does not hold state itself — session state is owned
  by `AgentSession`.

  ## Taint and Sensitivity Rules

  Classification delegates to `TriOnyx.TaintMatrix` and
  `TriOnyx.SensitivityMatrix`, which are the single authoritative source of
  truth for all per-tool and per-trigger values. See those modules for the
  complete tables.

  Dynamic sources (inter-agent messages, BCP responses) inherit from the
  sender's classification and are handled by dedicated functions below.
  """

  alias TriOnyx.TaintMatrix
  alias TriOnyx.SensitivityMatrix

  @type information_level :: :low | :medium | :high
  @type sensitivity_level :: :low | :medium | :high

  @type classification :: %{
          taint: information_level(),
          sensitivity: sensitivity_level(),
          reason: String.t()
        }

  @type source ::
          {:trigger, atom()}
          | {:tool_result, String.t(), map()}
          | {:inter_agent, :sanitized | :raw, information_level()}

  @doc """
  Classifies a trigger event. Triggers carry taint risk but no sensitivity
  (they don't contain sensitive response data).
  """
  @spec classify_trigger(atom()) :: classification()
  def classify_trigger(trigger_type) when is_atom(trigger_type) do
    taint = TaintMatrix.trigger_taint(trigger_type)
    sensitivity = SensitivityMatrix.trigger_sensitivity(trigger_type)
    %{taint: taint, sensitivity: sensitivity, reason: trigger_reason(trigger_type)}
  end

  @doc """
  Classifies a tool result based on the tool name, its input, and optional
  tool metadata.

  Taint and sensitivity for known tools are looked up from `TaintMatrix` and
  `SensitivityMatrix`. For unknown (custom) tools, sensitivity falls back to
  metadata-based derivation via `classify_tool_sensitivity/2`.
  """
  @spec classify_tool_result(String.t(), map(), map()) :: classification()
  def classify_tool_result(tool_name, input, tool_meta \\ %{})
      when is_binary(tool_name) and is_map(input) do
    taint = classify_tool_taint(tool_name, input)

    sensitivity =
      if tool_name == "Read" do
        classify_read_sensitivity(input)
      else
        classify_tool_sensitivity(tool_name, tool_meta)
      end

    %{taint: taint, sensitivity: sensitivity, reason: tool_reason(tool_name, input, taint, sensitivity)}
  end

  @doc """
  Classifies an inter-agent message based on sanitization mode and sender's
  classification on both axes.

  Both sanitized and raw modes inherit the sender's taint directly.
  Sanitization is a structural defence (reject malformed payloads), not a
  taint reduction — 1024-byte strings provide enough bandwidth for prompt
  injection, so stepping down is unjustified.

  Sensitivity always passes through unchanged.
  """
  @spec classify_inter_agent(:sanitized | :raw, classification() | information_level()) ::
          classification()
  def classify_inter_agent(mode, %{taint: sender_taint, sensitivity: sender_sensitivity}) do
    reason =
      case mode do
        :sanitized ->
          "sanitized inter-agent message (sender taint: #{sender_taint}, sensitivity: #{sender_sensitivity})"

        :raw ->
          "raw inter-agent message (inherits sender taint: #{sender_taint}, sensitivity: #{sender_sensitivity})"
      end

    %{taint: sender_taint, sensitivity: sender_sensitivity, reason: reason}
  end


  @doc """
  Classifies a validated BCP response.

  BCP responses are gateway-validated with bounded bandwidth. Taint is
  the sender's taint stepped down by one level — the structured validation
  reduces but does not eliminate taint. Sensitivity is always `:low` (structured
  data, no free-text leakage).

  The 2-arity form is kept for backward compatibility and assumes `:low`
  sender taint (equivalent to `classify_bcp(category, bits, :low)`).
  """
  @spec classify_bcp(1 | 2 | 3, float(), information_level()) :: classification()
  def classify_bcp(category, bandwidth_bits, sender_taint \\ :low) do
    taint = step_down(sender_taint)

    %{
      taint: taint,
      sensitivity: :low,
      reason: "BCP cat-#{category} (#{bandwidth_bits} bits, sender taint: #{sender_taint})"
    }
  end

  @doc """
  Returns the element-wise max of two classification maps.
  """
  @spec higher_levels(classification(), classification()) :: classification()
  def higher_levels(
        %{taint: t1, sensitivity: s1},
        %{taint: t2, sensitivity: s2}
      ) do
    %{
      taint: higher_level(t1, t2),
      sensitivity: higher_level(s1, s2),
      reason: "combined"
    }
  end

  @doc """
  Returns the more severe of two information levels.

  Level ordering: `:low` < `:medium` < `:high`.
  """
  @spec higher_level(information_level(), information_level()) :: information_level()
  def higher_level(a, b) do
    if level_rank(a) >= level_rank(b), do: a, else: b
  end

  @doc """
  Steps an information level down by one notch.

  `:high` → `:medium`, `:medium` → `:low`, `:low` → `:low`.
  Used only for taint (sanitization reduces taint, not sensitivity).
  """
  @spec step_down(information_level()) :: information_level()
  def step_down(:high), do: :medium
  def step_down(:medium), do: :low
  def step_down(:low), do: :low

  @doc """
  Returns true if the given level elevates above `:low`.
  """
  @spec elevating?(information_level()) :: boolean()
  def elevating?(:low), do: false
  def elevating?(:medium), do: true
  def elevating?(:high), do: true

  @doc """
  Classifies tool sensitivity based on tool name and optional custom metadata.

  For tools with entries in `SensitivityMatrix`, the matrix value is authoritative
  and the metadata argument is ignored. For unknown (custom) tools, sensitivity is
  derived from explicit metadata:

  - No auth required → `:low`
  - Auth required → `:medium`
  - Auth required + sensitive data → `:high`
  """
  @spec classify_tool_sensitivity(String.t(), map()) :: sensitivity_level()
  def classify_tool_sensitivity(tool_name, tool_meta) when is_map(tool_meta) do
    if SensitivityMatrix.known_tool?(tool_name) do
      SensitivityMatrix.tool_sensitivity(tool_name)
    else
      requires_auth = Map.get(tool_meta, :requires_auth, false)
      data_sensitivity = Map.get(tool_meta, :data_sensitivity, :low)

      cond do
        requires_auth and data_sensitivity == :high -> :high
        requires_auth -> :medium
        true -> :low
      end
    end
  end

  # --- Private ---

  @spec classify_read_sensitivity(map()) :: sensitivity_level()
  defp classify_read_sensitivity(input) do
    path = Map.get(input, "file_path", "")

    if controlled_path?(path) do
      workspace_path = TriOnyx.Workspace.workspace_dir()
      rel_path = path |> String.replace_leading("/workspace/", "")
      TriOnyx.GitProvenance.file_sensitivity(workspace_path, rel_path)
    else
      :low
    end
  end

  @spec classify_tool_taint(String.t(), map()) :: information_level()
  defp classify_tool_taint("Read", input) do
    path = Map.get(input, "file_path", "")
    context = if controlled_path?(path), do: :controlled, else: :external
    TaintMatrix.tool_taint("Read", context)
  end

  defp classify_tool_taint(tool_name, _input) do
    TaintMatrix.tool_taint(tool_name)
  end

  @spec tool_reason(String.t(), map(), information_level(), sensitivity_level()) :: String.t()
  defp tool_reason(tool_name, input, _taint, sensitivity) do
    base =
      cond do
        tool_name in ["WebFetch", "WebSearch"] ->
          "tool result from #{tool_name} (external data)"

        tool_name == "Read" ->
          path = Map.get(input, "file_path", "")

          if controlled_path?(path) do
            "Read from controlled path: #{path}"
          else
            "Read from external path: #{path}"
          end

        tool_name == "SendMessage" ->
          "SendMessage result (inter-agent routing)"

        tool_name == "SendEmail" ->
          "SendEmail result (outbound email via SMTP)"

        tool_name == "MoveEmail" ->
          "MoveEmail result (IMAP folder move)"

        tool_name == "CreateFolder" ->
          "CreateFolder result (IMAP folder creation)"

        true ->
          "tool result from #{tool_name}"
      end

    if sensitivity != :low do
      "#{base} [sensitivity: #{sensitivity}]"
    else
      base
    end
  end

  @spec trigger_reason(atom()) :: String.t()
  defp trigger_reason(:webhook), do: "webhook trigger (untrusted payload)"
  defp trigger_reason(:connector_unverified), do: "unverified connector message"
  defp trigger_reason(:cron), do: "cron trigger"
  defp trigger_reason(:heartbeat), do: "heartbeat trigger"
  defp trigger_reason(:external_message), do: "verified external message"
  defp trigger_reason(:connector_verified), do: "verified connector message"
  defp trigger_reason(other), do: "trigger: #{other}"

  @spec controlled_path?(String.t()) :: boolean()
  defp controlled_path?(""), do: false

  defp controlled_path?(path) when is_binary(path) do
    normalized = Path.expand(path, "/workspace")

    String.starts_with?(normalized, "/workspace") or
      String.starts_with?(normalized, "/mnt/host")
  end

  defp controlled_path?(_), do: false

  @spec level_rank(information_level()) :: non_neg_integer()
  defp level_rank(:low), do: 0
  defp level_rank(:medium), do: 1
  defp level_rank(:high), do: 2
end
