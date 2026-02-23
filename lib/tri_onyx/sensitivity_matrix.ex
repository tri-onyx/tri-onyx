defmodule TriOnyx.SensitivityMatrix do
  @moduledoc """
  Source-of-truth mapping from tools and input sources to sensitivity levels.

  Sensitivity tracks the confidentiality axis of the three-axis risk model --
  how sensitive is the data? High sensitivity indicates data that must not be
  exposed outside authorised channels.

  This module is the single authoritative definition of what sensitivity level
  each tool result and trigger source carries. `InformationClassifier` and
  `RiskScorer` both delegate to this module for known tools; custom tools
  declared in agent definitions may specify their own levels via explicit
  metadata.

  ## Tool Result Sensitivity

  Tools that operate with gateway-injected credentials produce at least
  `:medium` sensitivity results -- the response is tied to an authenticated
  session and should not flow to unauthenticated destinations.

  | Tool          | Sensitivity | Reason                                          |
  |---------------|-------------|-------------------------------------------------|
  | SendEmail     | medium      | Uses gateway-injected SMTP credentials          |
  | MoveEmail     | medium      | Uses gateway-injected IMAP credentials          |
  | CreateFolder  | medium      | Uses gateway-injected IMAP credentials          |
  | CalendarQuery | medium      | Uses gateway-injected CalDAV credentials        |
  | CalendarCreate| medium      | Uses gateway-injected CalDAV credentials        |
  | CalendarUpdate| medium      | Uses gateway-injected CalDAV credentials        |
  | CalendarDelete| medium      | Uses gateway-injected CalDAV credentials        |
  | Read          | provenance  | Dynamic: derived from git commit metadata       |
  | All others    | low         | No auth required; results are not session-tied  |

  ## Input Source Sensitivity

  All trigger sources produce `:low` sensitivity. Triggers carry event metadata
  (timestamps, identifiers, payloads), not sensitive data from authenticated
  services.

  | Source                | Sensitivity | Reason                           |
  |-----------------------|-------------|----------------------------------|
  | :webhook              | low         | Event metadata only              |
  | :connector_unverified | medium      | Unverified source, may carry PII |
  | :external_message     | low         | API-key authenticated, no auth data |
  | :connector_verified   | low         | Platform-verified sender, no auth data |
  | :cron                 | low         | Internal schedule signal         |
  | :heartbeat            | low         | Internal timer signal            |
  | unknown               | low         | Default for unregistered types   |
  """

  @type sensitivity_level :: :low | :medium | :high

  @tool_sensitivity %{
    "Read" => :low,
    "Grep" => :low,
    "Glob" => :low,
    "Write" => :low,
    "Edit" => :low,
    "NotebookEdit" => :low,
    "SendMessage" => :low,
    "BCPQuery" => :low,
    "BCPRespond" => :low,
    "RestartAgent" => :low,
    "Bash" => :low,
    "WebFetch" => :low,
    "WebSearch" => :low,
    "SendEmail" => :medium,
    "MoveEmail" => :medium,
    "CreateFolder" => :medium,
    "CalendarQuery" => :medium,
    "CalendarCreate" => :medium,
    "CalendarUpdate" => :medium,
    "CalendarDelete" => :medium
  }

  @trigger_sensitivity %{
    webhook: :low,
    connector_unverified: :medium,
    external_message: :low,
    connector_verified: :low,
    cron: :low,
    heartbeat: :low
  }

  @doc """
  Returns the sensitivity level for a tool's result.

  Returns `:low` for unknown tools.
  """
  @spec tool_sensitivity(String.t()) :: sensitivity_level()
  def tool_sensitivity(tool_name) when is_binary(tool_name) do
    Map.get(@tool_sensitivity, tool_name, :low)
  end

  @doc """
  Returns the sensitivity level for an input source trigger type.

  All known triggers return `:low`. Falls back to `:low` for unknown types.
  """
  @spec trigger_sensitivity(atom()) :: sensitivity_level()
  def trigger_sensitivity(trigger_type) when is_atom(trigger_type) do
    Map.get(@trigger_sensitivity, trigger_type, :low)
  end

  @doc """
  Returns true if the tool has an explicit entry in the matrix.
  """
  @spec known_tool?(String.t()) :: boolean()
  def known_tool?(tool_name) when is_binary(tool_name) do
    Map.has_key?(@tool_sensitivity, tool_name)
  end

  @doc """
  Returns the full tool sensitivity map.
  """
  @spec all_tool_sensitivities() :: %{String.t() => sensitivity_level()}
  def all_tool_sensitivities, do: @tool_sensitivity

  @doc """
  Returns the full trigger sensitivity map.
  """
  @spec all_trigger_sensitivities() :: %{atom() => sensitivity_level()}
  def all_trigger_sensitivities, do: @trigger_sensitivity

end
