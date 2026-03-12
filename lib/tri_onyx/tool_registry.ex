defmodule TriOnyx.ToolRegistry do
  @moduledoc """
  Registry of known tools and their metadata.

  ## Auth Metadata

  Each tool declares:
  - `requires_auth` — whether the gateway attaches credentials for this tool

  Taint and sensitivity classification for tool results is owned by
  `TriOnyx.TaintMatrix` and `TriOnyx.SensitivityMatrix` respectively.
  """

  @known_tools ~w(
    Read Grep Glob Write Edit NotebookEdit SendMessage
    BCPQuery BCPRespond RestartAgent Bash WebFetch WebSearch
    SendEmail MoveEmail CreateFolder
    CalendarQuery CalendarCreate CalendarUpdate CalendarDelete
    SubmitItem
  )

  # Auth and capability metadata for built-in tools.
  # `requires_auth` indicates whether the gateway injects credentials when
  # executing this tool. `capability_level` is the tool's intrinsic capability
  # for the lethal trifecta risk model (ADR-010). Bash is stored as :medium
  # here; promotion to :high based on network policy happens in
  # RiskScorer.infer_capability/2.
  #
  # Taint and sensitivity classification is owned by TaintMatrix and
  # SensitivityMatrix respectively.
  @tool_meta %{
    "Read" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "Grep" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "Glob" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "Write" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "Edit" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "NotebookEdit" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "SendMessage" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "BCPQuery" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "BCPRespond" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "RestartAgent" => %{requires_auth: false, capability_level: :low, requires_approval: false},
    "Bash" => %{requires_auth: false, capability_level: :medium, requires_approval: false},
    "WebFetch" => %{requires_auth: false, capability_level: :medium, requires_approval: false},
    "WebSearch" => %{requires_auth: false, capability_level: :medium, requires_approval: false},
    "SendEmail" => %{requires_auth: true, capability_level: :high, requires_approval: true},
    "MoveEmail" => %{requires_auth: true, capability_level: :low, requires_approval: false},
    "CreateFolder" => %{requires_auth: true, capability_level: :low, requires_approval: false},
    "CalendarQuery" => %{requires_auth: true, capability_level: :medium, requires_approval: false},
    "CalendarCreate" => %{requires_auth: true, capability_level: :medium, requires_approval: false},
    "CalendarUpdate" => %{requires_auth: true, capability_level: :medium, requires_approval: false},
    "CalendarDelete" => %{requires_auth: true, capability_level: :medium, requires_approval: false},
    "SubmitItem" => %{requires_auth: false, capability_level: :low, requires_approval: false}
  }

  # Display metadata for the classification matrix UI.
  # Read appears twice (controlled vs external path) since each variant has a different taint level.
  @display_entries [
    %{key: "Read/controlled", display: "Read", variant: "controlled path", group: "Filesystem",        note: nil},
    %{key: "Read/external",   display: "Read", variant: "external path",   group: "Filesystem",        note: nil},
    %{key: "Grep",            display: "Grep",        variant: nil, group: "Filesystem",        note: nil},
    %{key: "Glob",            display: "Glob",        variant: nil, group: "Filesystem",        note: nil},
    %{key: "Write",           display: "Write",       variant: nil, group: "Filesystem",        note: nil},
    %{key: "Edit",            display: "Edit",        variant: nil, group: "Filesystem",        note: nil},
    %{key: "NotebookEdit",    display: "NotebookEdit",variant: nil, group: "Filesystem",        note: nil},
    %{key: "SendMessage",     display: "SendMessage", variant: nil, group: "Messaging",         note: nil},
    %{key: "BCPQuery",       display: "BCPQuery",   variant: nil, group: "Messaging",         note: nil},
    %{key: "BCPRespond",     display: "BCPRespond", variant: nil, group: "Messaging",         note: nil},
    %{key: "Bash/isolated",   display: "Bash",        variant: "no network",    group: "Execution / Web",   note: "shell execution, container-local only"},
    %{key: "Bash/network",    display: "Bash",        variant: "with network",  group: "Execution / Web",   note: "shell + network = can exfiltrate/act externally"},
    %{key: "WebFetch",        display: "WebFetch",    variant: nil, group: "Execution / Web",   note: "fetches arbitrary external web content"},
    %{key: "WebSearch",       display: "WebSearch",   variant: nil, group: "Execution / Web",   note: "returns internet search results"},
    %{key: "SendEmail",       display: "SendEmail",   variant: nil, group: "Email (IMAP/SMTP)",  note: nil},
    %{key: "MoveEmail",       display: "MoveEmail",   variant: nil, group: "Email (IMAP/SMTP)",  note: nil},
    %{key: "CreateFolder",    display: "CreateFolder",variant: nil, group: "Email (IMAP/SMTP)",  note: nil},
    %{key: "RestartAgent",    display: "RestartAgent",variant: nil, group: "Control",            note: nil},
    %{key: "CalendarQuery",  display: "CalendarQuery",  variant: nil, group: "Calendar (CalDAV)", note: nil},
    %{key: "CalendarCreate", display: "CalendarCreate", variant: nil, group: "Calendar (CalDAV)", note: nil},
    %{key: "CalendarUpdate", display: "CalendarUpdate", variant: nil, group: "Calendar (CalDAV)", note: nil},
    %{key: "CalendarDelete", display: "CalendarDelete", variant: nil, group: "Calendar (CalDAV)", note: nil},
    %{key: "SubmitItem", display: "SubmitItem", variant: nil, group: "Messaging",         note: "posts formatted item to chat (articles, listings, etc.)"}
  ]

  @doc """
  Returns display entries for the classification matrix UI.

  Each entry includes `key`, `display`, `variant`, `group`, and `note`.
  Read appears as two entries (controlled vs external path variant).
  """
  @spec display_entries() :: [map()]
  def display_entries, do: @display_entries

  @doc """
  Returns the list of all known tool names.
  """
  @spec known_tools() :: [String.t()]
  def known_tools, do: @known_tools

  @doc """
  Returns true if the tool name is recognized.
  """
  @spec known?(String.t()) :: boolean()
  def known?(tool_name) when is_binary(tool_name) do
    tool_name in @known_tools
  end

  @doc """
  Returns the metadata for a tool.

  Returns a map with `:requires_auth` (boolean) and `:capability_level`
  (`:low | :medium | :high`). Returns default metadata for unknown tools.

  Taint and sensitivity classification is owned by `TaintMatrix` and
  `SensitivityMatrix` respectively.
  """
  @spec tool_meta(String.t()) :: %{requires_auth: boolean(), capability_level: atom()}
  def tool_meta(tool_name) when is_binary(tool_name) do
    Map.get(@tool_meta, tool_name, %{requires_auth: false, capability_level: :low})
  end

  @doc """
  Returns the intrinsic capability level of a tool.

  This is the tool's base capability without considering network policy.
  Bash is `:medium` here; it is promoted to `:high` by
  `RiskScorer.infer_capability/2` when the agent has network access.

  Returns `:low` for unknown tools.
  """
  @spec capability_level(String.t()) :: :low | :medium | :high
  def capability_level(tool_name) when is_binary(tool_name) do
    meta = tool_meta(tool_name)
    Map.get(meta, :capability_level, :low)
  end

  @doc """
  Returns whether a tool requires gateway-attached credentials.
  """
  @spec requires_auth?(String.t()) :: boolean()
  def requires_auth?(tool_name) when is_binary(tool_name) do
    meta = tool_meta(tool_name)
    meta.requires_auth
  end

  @doc """
  Returns whether a tool requires human approval before execution.
  """
  @spec requires_approval?(String.t()) :: boolean()
  def requires_approval?(tool_name) when is_binary(tool_name) do
    meta = tool_meta(tool_name)
    Map.get(meta, :requires_approval, false)
  end

  @doc """
  Validates that all tool names in a list are known.

  Returns `:ok` if all tools are known.
  Returns `{:error, {:unknown_tools, list}}` if any tools are unrecognized.
  """
  @spec validate_tools([String.t()]) :: :ok | {:error, {:unknown_tools, [String.t()]}}
  def validate_tools(tool_names) when is_list(tool_names) do
    unknown = Enum.reject(tool_names, &known?/1)

    case unknown do
      [] -> :ok
      _unknown_list -> {:error, {:unknown_tools, unknown}}
    end
  end
end
