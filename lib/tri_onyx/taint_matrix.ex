defmodule TriOnyx.TaintMatrix do
  @moduledoc """
  Source-of-truth mapping from tools and input sources to taint levels.

  Taint tracks the integrity axis of the three-axis risk model — how
  trustworthy is the data? High taint indicates data that may have been
  crafted by an adversary to manipulate agent behaviour (prompt injection
  risk).

  This module is the single authoritative definition of what taint level
  each tool result and trigger source carries. `InformationClassifier` and
  `RiskScorer` both delegate to this module; they do not embed their own
  taint logic.

  ## Tool Result Taint

  Most tools operate on controlled workspace data and return `:low` taint.
  The exceptions are tools that fetch or execute content from outside the
  controlled environment:

  | Tool                  | Taint  | Reason                                       |
  |-----------------------|--------|----------------------------------------------|
  | WebFetch              | high   | Fetches arbitrary external web content       |
  | WebSearch             | high   | Returns internet search results              |
  | Bash (no network)     | low    | Shell execution, container-local only        |
  | Bash (with network)   | high   | Shell + network = can curl/wget external data|
  | Read (external path)  | high   | Reads from outside /workspace or /mnt/host   |
  | Read (controlled path)| low    | Reads from /workspace or /mnt/host           |
  | CalendarQuery          | low    | Gateway-mediated, returns structured JSON     |
  | CalendarCreate         | low    | Gateway-mediated, returns structured JSON     |
  | CalendarUpdate         | low    | Gateway-mediated, returns structured JSON     |
  | CalendarDelete         | low    | Gateway-mediated, returns structured JSON     |
  | All others            | low    | Operate entirely on controlled workspace data|

  ## Input Source Taint

  | Source                | Taint  | Reason                                       |
  |-----------------------|--------|----------------------------------------------|
  | :webhook              | high   | Untrusted external HTTP payload              |
  | :connector_unverified | high   | Unverified email or chat message             |
  | :inter_agent          | medium | Sender taint unknown at static analysis time |
  | :external_message     | low    | API-key authenticated programmatic message   |
  | :connector_verified   | low    | Chat platform message with verified sender identity |
  | :cron                 | low    | Internal schedule (no external input)        |
  | :heartbeat            | low    | Internal timer (no external input)           |
  | unknown               | low    | Default for unregistered trigger types       |
  """

  @type taint_level :: :low | :medium | :high

  # Taint levels for tool results.
  # Read has two path-context variants — see tool_taint/2.
  # Bash has two network-context variants — see tool_taint/2.
  # The entry for "Read" here is the controlled-path default (:low).
  # The entry for "Bash" here is the no-network default (:low).
  @tool_taint %{
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
    "WebFetch" => :high,
    "WebSearch" => :high,
    "SendEmail" => :low,
    "MoveEmail" => :low,
    "CreateFolder" => :low,
    "CalendarQuery" => :low,
    "CalendarCreate" => :low,
    "CalendarUpdate" => :low,
    "CalendarDelete" => :low
  }

  # Taint levels for the two Read path contexts.
  # Context resolution (controlled vs external) is done by the caller.
  @read_taint %{
    controlled: :low,
    external: :high
  }

  # Taint levels for the two Bash network contexts.
  # Without network, Bash operates on local files only (low taint).
  # With network, Bash can curl/wget external data (high taint).
  @bash_taint %{
    isolated: :low,
    network: :high
  }

  # Taint levels for trigger / input sources.
  @trigger_taint %{
    webhook: :high,
    connector_unverified: :high,
    inter_agent: :medium,
    external_message: :low,
    connector_verified: :low,
    cron: :low,
    heartbeat: :low
  }

  @doc """
  Returns the taint level for a tool's result.

  For Read, returns the default controlled-path taint (`:low`). Use
  `tool_taint/2` to get the path-specific level.

  Returns `:low` for unknown tools.
  """
  @spec tool_taint(String.t()) :: taint_level()
  def tool_taint(tool_name) when is_binary(tool_name) do
    Map.get(@tool_taint, tool_name, :low)
  end

  @doc """
  Returns the taint level for a tool result given its context.

  For Read:
  - `:controlled` — path inside `/workspace` or `/mnt/host` → `:low`
  - `:external` — any other path → `:high`

  For Bash:
  - `:isolated` — no network access → `:low`
  - `:network` — has network access → `:high`

  For other tools the context argument is ignored and the standard
  `tool_taint/1` value is returned.
  """
  @spec tool_taint(String.t(), atom()) :: taint_level()
  def tool_taint("Read", context) when context in [:controlled, :external] do
    Map.fetch!(@read_taint, context)
  end

  def tool_taint("Bash", context) when context in [:isolated, :network] do
    Map.fetch!(@bash_taint, context)
  end

  def tool_taint(tool_name, _context) when is_binary(tool_name) do
    tool_taint(tool_name)
  end

  @doc """
  Returns the taint level for an input source trigger type.

  Falls back to `:low` for unknown trigger types.
  """
  @spec trigger_taint(atom()) :: taint_level()
  def trigger_taint(trigger_type) when is_atom(trigger_type) do
    Map.get(@trigger_taint, trigger_type, :low)
  end

  @doc """
  Returns true if the tool has an explicit entry in the matrix.
  """
  @spec known_tool?(String.t()) :: boolean()
  def known_tool?(tool_name) when is_binary(tool_name) do
    Map.has_key?(@tool_taint, tool_name)
  end

  @doc """
  Returns the full tool taint map.
  """
  @spec all_tool_taints() :: %{String.t() => taint_level()}
  def all_tool_taints, do: @tool_taint

  @doc """
  Returns the full trigger taint map.
  """
  @spec all_trigger_taints() :: %{atom() => taint_level()}
  def all_trigger_taints, do: @trigger_taint
end
