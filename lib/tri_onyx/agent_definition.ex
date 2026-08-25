defmodule TriOnyx.AgentDefinition do
  @moduledoc """
  Parsed representation of an agent definition file.

  Agent definitions are markdown files with YAML frontmatter that serve as
  the complete contract between the human operator and the gateway. The
  frontmatter declares the agent's identity, allowed tools, and sandbox
  constraints. The markdown body becomes the system prompt.

  ## Required Fields

  - `name` — unique agent identifier
  - `tools` — comma-separated list of allowed tool names

  ## Optional Fields

  - `description` — human-readable purpose
  - `model` — LLM model ID (must start with "claude-", e.g. "claude-sonnet-4-20250514")
  - `network` — network access policy: "none", "outbound", or list of hosts
  - `repos_read` — repos mounted read-only at `/repos/<name>`. Entries are shared
    repo names (`core`, `knowledge`, ...), `agents/<name>` for another agent's
    repo, or the `agents/*` wildcard (all agent repos). Read-only mounts show
    last-committed state, refreshed after every push.
  - `repos_write` — shared repos mounted read-write at `/repos/<name>` (the
    agent gets its own clone, synced through the bare repo at session
    boundaries). The agent's own repo is always mounted read-write at
    `/workspace` and never needs declaring.
  - `send_to` — list of agent names this agent is allowed to send messages to
  - `receive_from` — list of agent names this agent is allowed to receive messages from
  - `idle_timeout` — duration after which an idle session auto-stops (e.g. "30s", "5m", "1h")
  - `skills` — list of Claude Code skill names to load (from `.claude/skills/<name>/SKILL.md`)
  - `plugins` — list of plugin names. Plugins live inside a repo the agent
    already mounts (its own repo at `/workspace/plugins/<name>` or a shared
    repo at `/repos/<repo>/plugins/<name>`); the entrypoint installs their
    Python dependencies at container start.
  - `base_taint` — inherent taint floor from model provenance: "low", "medium", or "high" (default: "low")
  - `max_effective_risk` — permitted effective risk ceiling: "low", "moderate", "high", or
    "critical" (default: "critical"). The session is killed immediately when its effective
    risk exceeds this level. The default of "critical" can never be exceeded, so enforcement
    is opt-in per agent.
  - `exclude_from_personalization` — if true, skip this agent's logs when generating the user profile (default: false)
  - `github_repo` — GitHub repository (`owner/repo`) this agent manages via the
    gateway-mediated `GitHub` tool. Auto-injects write access to the host-side
    clone at `/workspace/repos/<owner>/<repo>/**`; the repo token stays on the
    gateway (configured via `TRI_ONYX_GITHUB_TOKENS`).
  - `github_read_repos` — list of GitHub repositories (`owner/repo`) this agent
    may read for context but not act on. Each grants a read-only FUSE view of a
    gateway-owned mirror at `/workspace/repos-ro/<owner>/<repo>/`, fast-forwarded
    to the remote default branch at session start. The GitHub tool remains
    scoped to `github_repo`.
  - `slack_channel` — Slack channel ID (e.g. `C0123ABCDEF`) this agent owns.
    Served to connectors via `GET /agents/schema` (`channel_bindings`); the
    Slack adapter routes all messages in the channel to this agent and posts
    the agent's heartbeats, approvals, and inter-agent mirrors there.
  - `reflection` — cron expression for a daily self-reflection run in an isolated
    container mode (e.g. `"0 23 * * *"`). The reflection run receives only the
    hardcoded reflection system prompt plus read-only access to today's session
    logs, and writes its findings to `/workspace/agents/<name>/reflections/`.
  """

  alias TriOnyx.ToolRegistry

  require Logger

  @type network_policy :: :none | :outbound | [String.t()]

  @type bcp_subscription :: %{
          id: String.t(),
          category: 1..3,
          fields: [map()] | nil,
          questions: [map()] | nil,
          directive: String.t() | nil,
          max_words: pos_integer() | nil
        }

  @type category_rate :: %{limit: pos_integer(), window_ms: pos_integer()} | :denied

  @type bcp_channel :: %{
          peer: String.t(),
          role: :controller | :reader,
          rates: %{cat1: category_rate(), cat2: category_rate(), cat3: category_rate()},
          max_category: 1..3,
          subscriptions: [bcp_subscription()]
        }

  @type feedback_action :: %{
          content_dir: String.t() | nil,
          copy_to: String.t() | nil,
          notify: String.t() | nil,
          notify_message: String.t() | nil
        }

  @type feedback :: %{upvote: feedback_action() | nil}

  @type cron_schedule :: %{
          schedule: String.t(),
          message: String.t(),
          label: String.t() | nil
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          model: String.t(),
          tools: [String.t()],
          network: network_policy(),
          repos_read: [String.t()],
          repos_write: [String.t()],
          send_to: [String.t()],
          receive_from: [String.t()],
          restart_targets: [String.t()],
          system_prompt: String.t(),
          heartbeat_every: pos_integer() | nil,
          idle_timeout: pos_integer() | nil,
          bcp_channels: [bcp_channel()],
          cron_schedules: [cron_schedule()],
          skills: [String.t()],
          plugins: [String.t()],
          base_taint: :low | :medium | :high,
          max_effective_risk: :low | :moderate | :high | :critical,
          input_sources: [atom()],
          browser: boolean(),
          docker_socket: boolean(),
          trionyx_repo: boolean(),
          exclude_from_personalization: boolean(),
          github_repo: String.t() | nil,
          github_read_repos: [String.t()],
          slack_channel: String.t() | nil,
          reflection: String.t() | nil,
          feedback: feedback() | nil
        }

  @default_model "claude-sonnet-4-20250514"

  @doc "Default LLM model for agents that don't specify one."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  # The agent name is used as a filesystem path segment (definition file,
  # bare repo directory, docker mount source), so it must be a single safe
  # segment: starts and ends alphanumeric, hyphens/underscores inside, no
  # dots, slashes, or whitespace. This is the single source of truth for
  # the pattern — the HTTP router validates path params against it too.
  @name_pattern ~r/\A[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?\z/
  @name_max_bytes 64

  @doc """
  Returns true if `name` is a valid agent name.

  Valid names are 1–#{@name_max_bytes} bytes of letters, digits, hyphens,
  and underscores, starting and ending with an alphanumeric character.
  Anything else could escape the directory it names.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= @name_max_bytes and
      Regex.match?(@name_pattern, name)
  end

  def valid_name?(_other), do: false

  @doc "Human-readable description of the agent name rules."
  @spec name_rules() :: String.t()
  def name_rules do
    "Agent name must be 1-#{@name_max_bytes} characters of letters, digits, " <>
      "hyphens, or underscores, starting and ending with a letter or digit"
  end

  @enforce_keys [:name, :tools, :system_prompt]
  defstruct [
    :name,
    :description,
    :system_prompt,
    model: @default_model,
    tools: [],
    network: :none,
    repos_read: [],
    repos_write: [],
    send_to: [],
    receive_from: [],
    restart_targets: [],
    heartbeat_every: nil,
    idle_timeout: nil,
    bcp_channels: [],
    cron_schedules: [],
    skills: [],
    plugins: [],
    base_taint: :low,
    max_effective_risk: :critical,
    input_sources: [],
    browser: false,
    docker_socket: false,
    trionyx_repo: false,
    exclude_from_personalization: false,
    github_repo: nil,
    github_read_repos: [],
    slack_channel: nil,
    reflection: nil,
    feedback: nil
  ]

  @doc """
  Parses an agent definition from raw file content (markdown with YAML frontmatter).

  The file format is:

      ---
      name: agent-name
      tools: Read, Grep, Glob
      ---

      System prompt text here.

  Returns `{:ok, %AgentDefinition{}}` on success or `{:error, reason}` on failure.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, frontmatter, body} <- extract_frontmatter(content),
         {:ok, yaml} <- parse_yaml(frontmatter),
         {:ok, definition} <- build_definition(yaml, body) do
      {:ok, definition}
    end
  end

  @doc """
  Like `parse/1` but raises on error.
  """
  @spec parse!(String.t()) :: t()
  def parse!(content) when is_binary(content) do
    case parse(content) do
      {:ok, definition} ->
        definition

      {:error, reason} ->
        raise ArgumentError, "Failed to parse agent definition: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a structured schema describing all agent definition fields.

  Used by the frontend agent builder to dynamically render form controls.
  This is the single source of truth for what fields exist, their types,
  defaults, and valid options.
  """
  @spec schema() :: %{fields: [map()], groups: [map()]}
  def schema do
    %{
      fields: field_descriptors(),
      groups: [
        %{key: "identity", label: "Identity", order: 0},
        %{key: "tools", label: "Tools", order: 1},
        %{key: "sandbox", label: "Sandbox", order: 2},
        %{key: "messaging", label: "Messaging", order: 3},
        %{key: "scheduling", label: "Scheduling", order: 4},
        %{key: "advanced", label: "Advanced", order: 5}
      ]
    }
  end

  @doc """
  Builds a markdown string (YAML frontmatter + body) from a JSON-decoded map.

  The map should have string keys matching YAML frontmatter fields, plus a
  `"system_prompt"` key for the body. Fields matching their defaults are omitted
  from the frontmatter to keep generated files clean.
  """
  @spec to_markdown(map()) :: String.t()
  def to_markdown(params) when is_map(params) do
    body = Map.get(params, "system_prompt", "") |> to_string()
    frontmatter_map = Map.delete(params, "system_prompt")

    yaml_lines =
      frontmatter_field_order()
      |> Enum.flat_map(fn key ->
        case Map.get(frontmatter_map, key) do
          nil -> []
          value -> serialize_yaml_field(key, value)
        end
      end)
      |> Enum.reject(&is_nil/1)

    yaml = Enum.join(yaml_lines, "\n")
    "---\n#{yaml}\n---\n\n#{body}\n"
  end

  @doc """
  Formats a parse error tuple into a frontend-friendly map.

  Returns `%{field: String.t(), message: String.t()}`.
  """
  @spec format_error(term()) :: %{field: String.t(), message: String.t()}
  def format_error({:missing_required_field, field}) do
    %{field: field, message: "#{field} is required"}
  end

  def format_error({:invalid_agent_name, _value}) do
    %{field: "name", message: name_rules()}
  end

  def format_error({:empty_tools_list}) do
    %{field: "tools", message: "At least one tool is required"}
  end

  def format_error({:invalid_field_type, field, expected}) do
    %{field: to_string(field), message: "#{field} must be #{format_expected(expected)}"}
  end

  def format_error({:invalid_model, _value, hint}) do
    %{field: "model", message: hint}
  end

  def format_error({:invalid_network_policy, value}) do
    %{field: "network", message: "Invalid network policy: #{value}. Use \"none\", \"outbound\", or a list of hostnames"}
  end

  def format_error({:invalid_network_policy_type}) do
    %{field: "network", message: "network must be a string or list of hostnames"}
  end

  def format_error({:invalid_network_hosts, _}) do
    %{field: "network", message: "Network hosts must be a list of strings"}
  end

  def format_error({:wildcard_network_hosts, wildcards, hint}) do
    %{field: "network", message: "#{hint}: #{Enum.join(wildcards, ", ")}"}
  end

  def format_error({:unknown_tools, tools}) do
    %{field: "tools", message: "Unknown tools: #{Enum.join(tools, ", ")}"}
  end

  def format_error({:invalid_heartbeat_every, _value}) do
    %{field: "heartbeat_every", message: "Invalid format. Use e.g. \"30s\", \"5m\", or \"1h\""}
  end

  def format_error({:invalid_idle_timeout, _value}) do
    %{field: "idle_timeout", message: "Invalid format. Use e.g. \"30s\", \"5m\", or \"1h\""}
  end

  def format_error({:invalid_duration_format, _str, hint}) do
    %{field: "duration", message: hint}
  end

  def format_error({:invalid_base_taint, _value, hint}) do
    %{field: "base_taint", message: hint}
  end

  def format_error({:invalid_max_effective_risk, _value, hint}) do
    %{field: "max_effective_risk", message: hint}
  end

  def format_error({:invalid_input_sources, invalid, valid}) do
    %{field: "input_sources", message: "Invalid sources: #{Enum.join(invalid, ", ")}. Valid: #{Enum.join(valid, ", ")}"}
  end

  def format_error({:invalid_reflection, {:invalid_expression, _reason}}) do
    %{field: "reflection", message: "Invalid cron expression"}
  end

  def format_error({:invalid_github_repo, _value, hint}) do
    %{field: "github_repo", message: hint}
  end

  def format_error({:invalid_slack_channel, _value, hint}) do
    %{field: "slack_channel", message: hint}
  end

  def format_error({:invalid_github_read_repo, _value, hint}) do
    %{field: "github_read_repos", message: hint}
  end

  def format_error({:invalid_feedback, hint}) do
    %{field: "feedback", message: hint}
  end

  def format_error({:invalid_repo_ref, key, ref, hint}) do
    %{field: key, message: "Invalid repo reference \"#{ref}\": #{hint}"}
  end

  def format_error({:invalid_cron_schedule, idx, {:missing_field, field}}) do
    %{field: "cron_schedules", message: "Schedule ##{idx + 1}: missing #{field}"}
  end

  def format_error({:invalid_cron_schedule, idx, {:invalid_expression, _reason}}) do
    %{field: "cron_schedules", message: "Schedule ##{idx + 1}: invalid cron expression"}
  end

  def format_error({:invalid_bcp_channel, idx, _}) do
    %{field: "bcp_channels", message: "BCP channel ##{idx + 1} is invalid"}
  end

  def format_error({:missing_bcp_channel_field, idx, field}) do
    %{field: "bcp_channels", message: "BCP channel ##{idx + 1}: missing #{field}"}
  end

  def format_error({:invalid_bcp_role, idx, role, _valid}) do
    %{field: "bcp_channels", message: "BCP channel ##{idx + 1}: invalid role \"#{role}\""}
  end

  def format_error({:all_bcp_categories_denied, idx}) do
    %{field: "bcp_channels", message: "BCP channel ##{idx + 1}: at least one category must be allowed"}
  end

  def format_error({:invalid_format}) do
    %{field: "_global", message: "Invalid format: expected YAML frontmatter between --- delimiters"}
  end

  def format_error({:frontmatter_not_a_map}) do
    %{field: "_global", message: "Frontmatter must be a YAML mapping"}
  end

  def format_error({:yaml_parse_error, _reason}) do
    %{field: "_global", message: "Failed to parse YAML frontmatter"}
  end

  def format_error(other) do
    %{field: "_global", message: "Validation error: #{inspect(other)}"}
  end

  # --- Private ---

  # --- Schema helpers ---

  @field_descriptors [
      # Identity
      %{key: "name", label: "Name", type: "string", required: true, default: nil,
        options: nil, group: "identity", order: 0, hint: "Unique agent identifier (lowercase, hyphens)"},
      %{key: "description", label: "Description", type: "string", required: false, default: nil,
        options: nil, group: "identity", order: 1, hint: "Human-readable purpose"},
      %{key: "model", label: "Model", type: "enum", required: false,
        default: @default_model,
        options: [
          %{value: @default_model, label: "Claude Sonnet 4 (2025-05-14)"},
          %{value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6"},
          %{value: "claude-opus-4-20250514", label: "Claude Opus 4 (2025-05-14)"},
          %{value: "claude-opus-4-6", label: "Claude Opus 4.6"},
          %{value: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"}
        ],
        allow_custom: true, custom_hint: "Must start with \"claude-\"",
        group: "identity", order: 2, hint: "LLM model to use"},

      # Tools
      %{key: "tools", label: "Tools", type: "tool_picker", required: true, default: [],
        options: nil, group: "tools", order: 0, hint: "Allowed tools for this agent"},
      %{key: "skills", label: "Skills", type: "list", required: false, default: [],
        options: nil, group: "tools", order: 1, hint: "Claude Code skill names to load"},
      %{key: "plugins", label: "Plugins", type: "list", required: false, default: [],
        options: nil, group: "tools", order: 2, hint: "Workspace plugin names"},

      # Sandbox
      %{key: "network", label: "Network", type: "network", required: false, default: "none",
        options: [
          %{value: "none", label: "Isolated (no network)"},
          %{value: "outbound", label: "Outbound (unrestricted)"}
        ],
        group: "sandbox", order: 0, hint: "Network access policy"},
      %{key: "repos_read", label: "Repos (read-only)", type: "list", required: false, default: [],
        options: nil, group: "sandbox", order: 1,
        hint: "Repos mounted read-only at /repos/<name>: shared names, agents/<name>, or agents/*"},
      %{key: "repos_write", label: "Repos (read-write)", type: "list", required: false, default: [],
        options: nil, group: "sandbox", order: 2,
        hint: "Shared repos mounted read-write at /repos/<name> (own repo is always writable at /workspace)"},
      %{key: "browser", label: "Browser", type: "boolean", required: false, default: false,
        options: nil, group: "sandbox", order: 3, hint: "Enable browser automation"},
      %{key: "docker_socket", label: "Docker Socket", type: "boolean", required: false, default: false,
        options: nil, group: "sandbox", order: 4, hint: "Access to Docker socket"},
      %{key: "trionyx_repo", label: "TriOnyx Repo", type: "boolean", required: false, default: false,
        options: nil, group: "sandbox", order: 5, hint: "Access to the TriOnyx repo itself"},
      %{key: "github_repo", label: "GitHub Repository", type: "string", required: false, default: nil,
        options: nil, group: "sandbox", order: 6,
        hint: "owner/repo managed via the gateway-mediated GitHub tool (token stays on the gateway)"},
      %{key: "github_read_repos", label: "GitHub Read Repos", type: "list", required: false, default: [],
        options: nil, group: "sandbox", order: 7,
        hint: "owner/repo list readable as gateway-owned mirrors (read-only, no GitHub tool access)"},

      # Messaging
      %{key: "send_to", label: "Send To", type: "agent_list", required: false, default: [],
        options: nil, group: "messaging", order: 0, hint: "Agents this agent can send messages to"},
      %{key: "receive_from", label: "Receive From", type: "agent_list", required: false, default: [],
        options: nil, group: "messaging", order: 1, hint: "Agents this agent can receive messages from"},
      %{key: "restart_targets", label: "Restart Targets", type: "agent_list", required: false, default: [],
        options: nil, group: "messaging", order: 2, hint: "Agents this agent can restart"},
      %{key: "input_sources", label: "Input Sources", type: "multi_enum", required: false, default: [],
        options: [
          %{value: "verified_input", label: "Verified Input"},
          %{value: "unverified_input", label: "Unverified Input"},
          %{value: "webhook", label: "Webhook"},
          %{value: "external_message", label: "External Message"},
          %{value: "cron", label: "Cron"},
          %{value: "heartbeat", label: "Heartbeat"}
        ],
        group: "messaging", order: 3, hint: "Accepted trigger types"},
      %{key: "slack_channel", label: "Slack Channel", type: "string", required: false, default: nil,
        options: nil, group: "messaging", order: 5,
        hint: "Slack channel ID this agent owns (e.g. C0123ABCDEF)"},
      %{key: "bcp_channels", label: "BCP Channels", type: "yaml", required: false, default: [],
        options: nil, group: "messaging", order: 4,
        hint: "Business continuity protocol channels (YAML)",
        yaml_example: "- peer: other-agent\n  role: controller\n  rates:\n    cat1: 10/minute\n    cat2: 5/minute\n    cat3: 0"},
      %{key: "feedback", label: "Item Feedback", type: "yaml", required: false, default: nil,
        options: nil, group: "messaging", order: 6,
        hint: "Deterministic gateway handling of 👍/👎 reactions on submitted items (YAML)",
        yaml_example: "upvote:\n  content_dir: /plugins/newsagg/saved\n  copy_to: /obsidian/shared/sources/articles\n  notify: wiki\n  notify_message: \"New article source filed: sources/articles/{file}\""},

      # Scheduling
      %{key: "heartbeat_every", label: "Heartbeat Interval", type: "duration", required: false,
        default: nil, options: nil, group: "scheduling", order: 0,
        hint: "e.g. 30s, 5m, 1h"},
      %{key: "idle_timeout", label: "Idle Timeout", type: "duration", required: false,
        default: nil, options: nil, group: "scheduling", order: 1,
        hint: "Auto-stop after inactivity, e.g. 30m, 1h"},
      %{key: "cron_schedules", label: "Cron Schedules", type: "yaml", required: false, default: [],
        options: nil, group: "scheduling", order: 2,
        hint: "Scheduled triggers (YAML)",
        yaml_example: "- schedule: \"0 9 * * *\"\n  message: \"Good morning\"\n  label: morning-check"},
      %{key: "reflection", label: "Reflection", type: "cron", required: false,
        default: nil, options: nil, group: "scheduling", order: 3,
        hint: "Cron expression for daily self-reflection, e.g. 0 23 * * *"},

      # Advanced
      %{key: "base_taint", label: "Base Taint", type: "enum", required: false, default: "low",
        options: [
          %{value: "low", label: "Low"},
          %{value: "medium", label: "Medium"},
          %{value: "high", label: "High"}
        ],
        group: "advanced", order: 0, hint: "Inherent taint floor from model provenance"},
      %{key: "max_effective_risk", label: "Max Effective Risk", type: "enum", required: false,
        default: "critical",
        options: [
          %{value: "low", label: "Low"},
          %{value: "moderate", label: "Moderate"},
          %{value: "high", label: "High"},
          %{value: "critical", label: "Critical (never killed)"}
        ],
        group: "advanced", order: 1,
        hint: "Session is killed immediately when effective risk exceeds this level"},
      %{key: "exclude_from_personalization", label: "Exclude from Personalization", type: "boolean",
        required: false, default: false, options: nil, group: "advanced", order: 2,
        hint: "Skip this agent's logs when generating user profile"}
  ]

  @default_values @field_descriptors
                  |> Enum.reject(fn f -> f[:default] in [nil, []] end)
                  |> Map.new(fn f -> {f.key, f.default} end)

  @spec field_descriptors() :: [map()]
  defp field_descriptors, do: @field_descriptors

  # --- Markdown serialization helpers ---

  @spec frontmatter_field_order() :: [String.t()]
  defp frontmatter_field_order do
    ~w(name description model tools network repos_read repos_write send_to receive_from
       restart_targets browser docker_socket trionyx_repo github_repo github_read_repos
       slack_channel skills plugins input_sources heartbeat_every idle_timeout
       cron_schedules reflection bcp_channels feedback base_taint max_effective_risk
       exclude_from_personalization)
  end

  @spec serialize_yaml_field(String.t(), term()) :: [String.t()] | [nil]
  defp serialize_yaml_field(key, value) do
    if value == Map.get(@default_values, key) or value == [] or value == "" do
      []
    else
      do_serialize_yaml_field(key, value)
    end
  end

  defp do_serialize_yaml_field("feedback", %{} = value) do
    ["feedback:" | serialize_nested_map(value, 1)]
  end

  defp do_serialize_yaml_field(key, value) when is_binary(value) do
    if String.contains?(value, ["\n", ":", "#", "'", "\"", "[", "]", "{", "}"]) do
      ["#{key}: #{yaml_quote(value)}"]
    else
      ["#{key}: #{value}"]
    end
  end

  defp do_serialize_yaml_field(key, value) when is_boolean(value) do
    ["#{key}: #{value}"]
  end

  defp do_serialize_yaml_field(key, value) when is_integer(value) do
    ["#{key}: #{value}"]
  end

  defp do_serialize_yaml_field(key, value) when is_list(value) do
    cond do
      value == [] ->
        []

      key in ["bcp_channels", "cron_schedules"] ->
        serialize_yaml_complex_list(key, value)

      Enum.all?(value, &is_binary/1) ->
        lines = Enum.map(value, fn v -> "  - #{yaml_quote_if_needed(v)}" end)
        ["#{key}:" | lines]

      true ->
        ["#{key}: #{inspect(value)}"]
    end
  end

  defp do_serialize_yaml_field(key, value) do
    ["#{key}: #{inspect(value)}"]
  end

  # Serializes a nested map (atom or string keys) as indented YAML, sorted
  # for stable round-trips. Nil values are omitted.
  defp serialize_nested_map(map, depth) do
    indent = String.duplicate("  ", depth)

    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.flat_map(fn
      {_k, nil} -> []
      {k, %{} = nested} -> ["#{indent}#{k}:" | serialize_nested_map(nested, depth + 1)]
      {k, v} -> ["#{indent}#{k}: #{yaml_quote_if_needed(to_string(v))}"]
    end)
  end

  defp serialize_yaml_complex_list(key, items) when is_list(items) do
    lines =
      Enum.flat_map(items, fn item ->
        case key do
          "cron_schedules" -> serialize_cron_schedule(item)
          "bcp_channels" -> serialize_bcp_channel(item)
          _ -> ["  - #{inspect(item)}"]
        end
      end)

    ["#{key}:" | lines]
  end

  defp serialize_cron_schedule(item) when is_map(item) do
    schedule = Map.get(item, "schedule", "")
    message = Map.get(item, "message", "")
    label = Map.get(item, "label")

    lines = [
      "  - schedule: #{yaml_quote(schedule)}",
      "    message: #{yaml_quote(message)}"
    ]

    if label && label != "" do
      lines ++ ["    label: #{label}"]
    else
      lines
    end
  end

  defp serialize_bcp_channel(item) when is_map(item) do
    peer = Map.get(item, "peer", "")
    role = Map.get(item, "role", "controller")
    rates = Map.get(item, "rates", %{})

    lines = [
      "  - peer: #{peer}",
      "    role: #{role}",
      "    rates:"
    ]

    rate_lines =
      ~w(cat1 cat2 cat3)
      |> Enum.map(fn cat ->
        val = Map.get(rates, cat, 0)
        "      #{cat}: #{val}"
      end)

    sub_lines =
      case Map.get(item, "subscriptions") do
        subs when is_list(subs) and subs != [] ->
          ["    subscriptions:" | Enum.flat_map(subs, &serialize_bcp_subscription/1)]
        _ ->
          []
      end

    lines ++ rate_lines ++ sub_lines
  end

  defp serialize_bcp_subscription(sub) when is_map(sub) do
    id = Map.get(sub, "id", "")
    category = Map.get(sub, "category", 1)

    base = [
      "      - id: #{id}",
      "        category: #{category}"
    ]

    case category do
      1 ->
        fields = Map.get(sub, "fields", [])
        base ++ ["        fields: #{Jason.encode!(fields)}"]

      2 ->
        questions = Map.get(sub, "questions", [])
        lines = base ++ ["        questions: #{Jason.encode!(questions)}"]
        case Map.get(sub, "max_words") do
          nil -> lines
          mw -> lines ++ ["        max_words: #{mw}"]
        end

      3 ->
        directive = Map.get(sub, "directive", "")
        max_words = Map.get(sub, "max_words", 100)
        base ++ [
          "        directive: #{yaml_quote(directive)}",
          "        max_words: #{max_words}"
        ]

      _ ->
        base
    end
  end

  defp yaml_quote(str) when is_binary(str), do: "\"#{String.replace(str, "\"", "\\\"")}\""

  defp yaml_quote_if_needed(str) when is_binary(str) do
    if String.contains?(str, [" ", ":", "#", "'", "\"", "[", "]", "{", "}", ","]) or
         String.starts_with?(str, ["*", "!", "&", "%", "@"]) do
      yaml_quote(str)
    else
      str
    end
  end

  defp format_expected(:expected_string), do: "a string"
  defp format_expected(:expected_list), do: "a list"
  defp format_expected(:expected_string_list), do: "a list of strings"
  defp format_expected(:expected_boolean), do: "true or false"
  defp format_expected(:expected_string_or_list), do: "a string or list"
  defp format_expected(other), do: inspect(other)

  # --- Private ---

  @spec extract_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_format}
  defp extract_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n(.*)\z/s, content) do
      [_full, frontmatter, body] -> {:ok, frontmatter, String.trim(body)}
      nil -> {:error, :invalid_format}
    end
  end

  @spec parse_yaml(String.t()) :: {:ok, map()} | {:error, term()}
  defp parse_yaml(frontmatter) do
    case YamlElixir.read_from_string(frontmatter) do
      {:ok, yaml} when is_map(yaml) -> {:ok, yaml}
      {:ok, _other} -> {:error, :frontmatter_not_a_map}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end

  @spec build_definition(map(), String.t()) :: {:ok, t()} | {:error, term()}
  defp build_definition(yaml, body) do
    with {:ok, name} <- require_name(yaml),
         {:ok, tools} <- parse_tools(yaml),
         {:ok, model} <- parse_model(yaml),
         {:ok, network} <- parse_network(yaml),
         {:ok, repos_read} <- parse_repo_refs(yaml, "repos_read", name, wildcard: true),
         {:ok, repos_write} <- parse_repo_refs(yaml, "repos_write", name, wildcard: false),
         {:ok, send_to} <- parse_string_list(yaml, "send_to"),
         {:ok, receive_from} <- parse_string_list(yaml, "receive_from"),
         {:ok, restart_targets} <- parse_string_list(yaml, "restart_targets"),
         :ok <- ToolRegistry.validate_tools(tools),
         {:ok, heartbeat_every} <- parse_heartbeat_every(yaml),
         {:ok, idle_timeout} <- parse_idle_timeout(yaml),
         {:ok, bcp_channels} <- parse_bcp_channels(yaml),
         {:ok, cron_schedules} <- parse_cron_schedules(yaml),
         {:ok, skills} <- parse_string_list(yaml, "skills"),
         {:ok, plugins} <- parse_string_list(yaml, "plugins"),
         {:ok, base_taint} <- parse_base_taint(yaml),
         {:ok, max_effective_risk} <- parse_max_effective_risk(yaml),
         {:ok, input_sources} <- parse_input_sources(yaml),
         {:ok, browser} <- parse_optional_boolean(yaml, "browser"),
         {:ok, docker_socket} <- parse_optional_boolean(yaml, "docker_socket"),
         {:ok, trionyx_repo} <- parse_optional_boolean(yaml, "trionyx_repo"),
         {:ok, exclude_from_personalization} <- parse_optional_boolean(yaml, "exclude_from_personalization"),
         {:ok, github_repo} <- parse_github_repo(yaml),
         {:ok, github_read_repos} <- parse_github_read_repos(yaml, github_repo),
         {:ok, slack_channel} <- parse_slack_channel(yaml),
         {:ok, reflection} <- parse_reflection(yaml),
         {:ok, feedback} <- parse_feedback(yaml) do
      if "SendMessage" in tools and send_to == [] and receive_from == [] do
        Logger.warning(
          "Agent '#{name}' has SendMessage tool but no send_to/receive_from peers declared. " <>
            "All inter-agent messages will be rejected."
        )
      end

      if "RestartAgent" in tools and restart_targets == [] do
        Logger.warning(
          "Agent '#{name}' has RestartAgent tool but no restart_targets declared. " <>
            "All restart requests will be rejected."
        )
      end

      if browser and network == :none do
        Logger.warning(
          "Agent '#{name}' has browser: true but network: none. " <>
            "Browser will not be able to reach external sites."
        )
      end

      if browser and "Bash" not in tools do
        Logger.warning(
          "Agent '#{name}' has browser: true but Bash is not in tools list. " <>
            "Agent cannot invoke playwright-cli."
        )
      end

      if "GitHub" in tools and is_nil(github_repo) do
        Logger.warning(
          "Agent '#{name}' has GitHub tool but no github_repo declared. " <>
            "All GitHub commands will be rejected."
        )
      end

      if github_repo != nil and "GitHub" not in tools do
        Logger.warning(
          "Agent '#{name}' declares github_repo but GitHub is not in tools list. " <>
            "Agent can edit the clone but cannot reach GitHub."
        )
      end

      {:ok,
       %__MODULE__{
         name: name,
         description: Map.get(yaml, "description"),
         model: model,
         tools: tools,
         network: network,
         repos_read: repos_read,
         repos_write: repos_write,
         send_to: send_to,
         receive_from: receive_from,
         restart_targets: restart_targets,
         system_prompt: body,
         heartbeat_every: heartbeat_every,
         idle_timeout: idle_timeout,
         bcp_channels: bcp_channels,
         cron_schedules: cron_schedules,
         skills: skills,
         plugins: plugins,
         base_taint: base_taint,
         max_effective_risk: max_effective_risk,
         input_sources: auto_include_cron(input_sources, cron_schedules),
         browser: browser,
         docker_socket: docker_socket,
         trionyx_repo: trionyx_repo,
         exclude_from_personalization: exclude_from_personalization,
         github_repo: github_repo,
         github_read_repos: github_read_repos,
         slack_channel: slack_channel,
         reflection: reflection,
         feedback: feedback
       }}
    end
  end

  # Every loader path (files on disk, the HTTP builder, tests) goes through
  # parsing, so validating the name here covers them all.
  @spec require_name(map()) :: {:ok, String.t()} | {:error, term()}
  defp require_name(yaml) do
    with {:ok, name} <- require_string(yaml, "name") do
      if valid_name?(name) do
        {:ok, name}
      else
        {:error, {:invalid_agent_name, name}}
      end
    end
  end

  @spec require_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp require_string(yaml, key) do
    case Map.get(yaml, key) do
      nil -> {:error, {:missing_required_field, key}}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field_type, key, :expected_string}}
    end
  end

  @spec parse_tools(map()) :: {:ok, [String.t()]} | {:error, term()}
  defp parse_tools(yaml) do
    case Map.get(yaml, "tools") do
      nil ->
        {:error, {:missing_required_field, "tools"}}

      tools when is_binary(tools) ->
        parsed =
          tools
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case parsed do
          [] -> {:error, {:empty_tools_list}}
          _tools -> {:ok, parsed}
        end

      tools when is_list(tools) ->
        if Enum.all?(tools, &is_binary/1) do
          {:ok, tools}
        else
          {:error, {:invalid_field_type, "tools", :expected_string_list}}
        end

      _other ->
        {:error, {:invalid_field_type, "tools", :expected_string_or_list}}
    end
  end

  @spec parse_model(map()) :: {:ok, String.t()} | {:error, term()}
  defp parse_model(yaml) do
    case Map.get(yaml, "model") do
      nil -> {:ok, @default_model}
      "claude-" <> _ = model -> {:ok, model}
      other -> {:error, {:invalid_model, other, "model must start with \"claude-\""}}
    end
  end

  @spec parse_base_taint(map()) :: {:ok, :low | :medium | :high} | {:error, term()}
  defp parse_base_taint(yaml) do
    case Map.get(yaml, "base_taint", "low") do
      "low" -> {:ok, :low}
      "medium" -> {:ok, :medium}
      "high" -> {:ok, :high}
      other -> {:error, {:invalid_base_taint, other, "expected \"low\", \"medium\", or \"high\""}}
    end
  end

  @spec parse_max_effective_risk(map()) ::
          {:ok, :low | :moderate | :high | :critical} | {:error, term()}
  defp parse_max_effective_risk(yaml) do
    case Map.get(yaml, "max_effective_risk", "critical") do
      "low" -> {:ok, :low}
      "moderate" -> {:ok, :moderate}
      "high" -> {:ok, :high}
      "critical" -> {:ok, :critical}
      other -> {:error, {:invalid_max_effective_risk, other, "expected \"low\", \"moderate\", \"high\", or \"critical\""}}
    end
  end

  @spec parse_network(map()) :: {:ok, network_policy()} | {:error, term()}
  defp parse_network(yaml) do
    case Map.get(yaml, "network", "none") do
      "none" ->
        {:ok, :none}

      "outbound" ->
        {:ok, :outbound}

      hosts when is_list(hosts) ->
        cond do
          not Enum.all?(hosts, &is_binary/1) ->
            {:error, {:invalid_network_hosts, :expected_string_list}}

          Enum.any?(hosts, &String.contains?(&1, "*")) ->
            wildcards = Enum.filter(hosts, &String.contains?(&1, "*"))

            {:error,
             {:wildcard_network_hosts, wildcards,
              "wildcard patterns cannot be enforced by iptables; use exact hostnames"}}

          true ->
            {:ok, hosts}
        end

      other when is_binary(other) ->
        {:error, {:invalid_network_policy, other}}

      _other ->
        {:error, {:invalid_network_policy_type}}
    end
  end

  @spec parse_heartbeat_every(map()) :: {:ok, pos_integer() | nil} | {:error, term()}
  defp parse_heartbeat_every(yaml) do
    case Map.get(yaml, "heartbeat_every") do
      nil -> {:ok, nil}
      value when is_binary(value) -> parse_duration(value)
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_heartbeat_every, other}}
    end
  end

  @spec parse_idle_timeout(map()) :: {:ok, pos_integer() | nil} | {:error, term()}
  defp parse_idle_timeout(yaml) do
    case Map.get(yaml, "idle_timeout") do
      nil -> {:ok, nil}
      value when is_binary(value) -> parse_duration(value)
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_idle_timeout, other}}
    end
  end

  @spec parse_duration(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_duration(str) do
    case Regex.run(~r/\A(\d+)(s|m|h)\z/, str) do
      [_, number, "s"] -> {:ok, String.to_integer(number) * 1_000}
      [_, number, "m"] -> {:ok, String.to_integer(number) * 60_000}
      [_, number, "h"] -> {:ok, String.to_integer(number) * 3_600_000}
      nil -> {:error, {:invalid_duration_format, str, "expected format: 30s, 5m, or 1h"}}
    end
  end

  @valid_bcp_roles ~w(controller reader)
  @valid_max_categories [1, 2, 3]

  @spec parse_bcp_channels(map()) :: {:ok, [bcp_channel()]} | {:error, term()}
  defp parse_bcp_channels(yaml) do
    case Map.get(yaml, "bcp_channels") do
      nil ->
        {:ok, []}

      channels when is_list(channels) ->
        channels
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {channel, idx}, {:ok, acc} ->
          case parse_single_bcp_channel(channel, idx) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
          error -> error
        end

      _other ->
        {:error, {:invalid_field_type, "bcp_channels", :expected_list}}
    end
  end

  @spec parse_single_bcp_channel(map(), non_neg_integer()) :: {:ok, bcp_channel()} | {:error, term()}
  defp parse_single_bcp_channel(channel, idx) when is_map(channel) do
    with {:ok, peer} <- require_bcp_field(channel, "peer", idx, &is_binary/1, :string),
         {:ok, role_str} <- require_bcp_field(channel, "role", idx, &is_binary/1, :string),
         {:ok, role} <- validate_bcp_role(role_str, idx),
         {:ok, rates} <- parse_bcp_rates(channel, idx),
         max_cat <- derive_max_category(rates),
         :ok <- validate_at_least_one_category(rates, idx),
         {:ok, subscriptions} <- parse_bcp_subscriptions(channel, role, max_cat, idx) do
      {:ok,
       %{
         peer: peer,
         role: role,
         rates: rates,
         max_category: max_cat,
         subscriptions: subscriptions
       }}
    end
  end

  defp parse_single_bcp_channel(_channel, idx) do
    {:error, {:invalid_bcp_channel, idx, :expected_map}}
  end

  defp require_bcp_field(channel, key, idx, validator, expected_type) do
    case Map.get(channel, key) do
      nil -> {:error, {:missing_bcp_channel_field, idx, key}}
      value -> if validator.(value), do: {:ok, value}, else: {:error, {:invalid_bcp_channel_field, idx, key, expected_type}}
    end
  end


  defp validate_bcp_role("controller", _idx), do: {:ok, :controller}
  defp validate_bcp_role("reader", _idx), do: {:ok, :reader}

  defp validate_bcp_role(role, idx) do
    {:error, {:invalid_bcp_role, idx, role, @valid_bcp_roles}}
  end

  @rate_pattern ~r/\A(\d+)\/(second|minute|hour)\z/

  @spec parse_bcp_rates(map(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp parse_bcp_rates(channel, idx) do
    case Map.get(channel, "rates") do
      nil ->
        {:error, {:missing_bcp_channel_field, idx, "rates"}}

      rates when is_map(rates) ->
        with {:ok, cat1} <- parse_single_rate(rates, "cat1", idx),
             {:ok, cat2} <- parse_single_rate(rates, "cat2", idx),
             {:ok, cat3} <- parse_single_rate(rates, "cat3", idx) do
          {:ok, %{cat1: cat1, cat2: cat2, cat3: cat3}}
        end

      _other ->
        {:error, {:invalid_bcp_channel_field, idx, "rates", :expected_map}}
    end
  end

  @spec parse_single_rate(map(), String.t(), non_neg_integer()) ::
          {:ok, %{limit: pos_integer(), window_ms: pos_integer()} | :denied} | {:error, term()}
  defp parse_single_rate(rates, key, idx) do
    case Map.get(rates, key, 0) do
      0 ->
        {:ok, :denied}

      value when is_integer(value) and value > 0 ->
        # Bare integer defaults to per-hour
        {:ok, %{limit: value, window_ms: 3_600_000}}

      value when is_binary(value) ->
        case Regex.run(@rate_pattern, value) do
          [_, count_str, unit] ->
            count = String.to_integer(count_str)

            if count == 0 do
              {:ok, :denied}
            else
              {:ok, %{limit: count, window_ms: unit_to_ms(unit)}}
            end

          nil ->
            {:error, {:invalid_bcp_rate, idx, key, value, "expected format: N/second, N/minute, or N/hour"}}
        end

      other ->
        {:error, {:invalid_bcp_rate, idx, key, other, "expected 0 or \"N/unit\""}}
    end
  end

  defp unit_to_ms("second"), do: 1_000
  defp unit_to_ms("minute"), do: 60_000
  defp unit_to_ms("hour"), do: 3_600_000

  @spec derive_max_category(map()) :: 1 | 2 | 3
  defp derive_max_category(%{cat3: rate}) when rate != :denied, do: 3
  defp derive_max_category(%{cat2: rate}) when rate != :denied, do: 2
  defp derive_max_category(_), do: 1

  defp validate_at_least_one_category(%{cat1: :denied, cat2: :denied, cat3: :denied}, idx) do
    {:error, {:all_bcp_categories_denied, idx}}
  end

  defp validate_at_least_one_category(_, _idx), do: :ok

  @subscription_id_pattern ~r/\A[a-z0-9][a-z0-9-]*\z/

  defp parse_bcp_subscriptions(channel, role, max_category, channel_idx) do
    case Map.get(channel, "subscriptions") do
      nil ->
        {:ok, []}

      _ when role != :controller ->
        {:error, {:subscriptions_on_reader_channel, channel_idx}}

      subs when is_list(subs) ->
        subs
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {sub, sub_idx}, {:ok, acc} ->
          case parse_single_subscription(sub, channel_idx, sub_idx, max_category) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, parsed} ->
            parsed = Enum.reverse(parsed)
            validate_subscription_id_uniqueness(parsed, channel_idx)

          error ->
            error
        end

      _other ->
        {:error, {:invalid_field_type, "subscriptions", :expected_list}}
    end
  end

  defp parse_single_subscription(sub, channel_idx, sub_idx, max_category) when is_map(sub) do
    with {:ok, id} <- parse_subscription_id(sub, channel_idx, sub_idx),
         {:ok, category} <- parse_subscription_category(sub, channel_idx, sub_idx, max_category),
         {:ok, fields, questions, directive, max_words} <-
           parse_subscription_spec(sub, channel_idx, sub_idx, category) do
      {:ok,
       %{
         id: id,
         category: category,
         fields: fields,
         questions: questions,
         directive: directive,
         max_words: max_words
       }}
    end
  end

  defp parse_single_subscription(_sub, channel_idx, sub_idx, _max_category) do
    {:error, {:invalid_subscription, channel_idx, sub_idx, :expected_map}}
  end

  defp parse_subscription_id(sub, channel_idx, sub_idx) do
    case Map.get(sub, "id") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "id"}}

      id when is_binary(id) ->
        if Regex.match?(@subscription_id_pattern, id) do
          {:ok, id}
        else
          {:error, {:invalid_subscription_id, channel_idx, sub_idx, id}}
        end

      _other ->
        {:error, {:invalid_subscription_field, channel_idx, sub_idx, "id", :expected_string}}
    end
  end

  defp parse_subscription_category(sub, channel_idx, sub_idx, max_category) do
    case Map.get(sub, "category") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "category"}}

      cat when is_integer(cat) and cat in @valid_max_categories ->
        if cat > max_category do
          {:error, {:subscription_category_exceeds_max, channel_idx, sub_idx, cat, max_category}}
        else
          {:ok, cat}
        end

      other ->
        {:error, {:invalid_subscription_category, channel_idx, sub_idx, other, @valid_max_categories}}
    end
  end

  defp parse_subscription_spec(sub, channel_idx, sub_idx, 1) do
    case Map.get(sub, "fields") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "fields"}}

      fields when is_list(fields) ->
        if Enum.all?(fields, &is_map/1) do
          {:ok, fields, nil, nil, nil}
        else
          {:error, {:invalid_subscription_field, channel_idx, sub_idx, "fields", :expected_list_of_maps}}
        end

      _other ->
        {:error, {:invalid_subscription_field, channel_idx, sub_idx, "fields", :expected_list}}
    end
  end

  defp parse_subscription_spec(sub, channel_idx, sub_idx, 2) do
    case Map.get(sub, "questions") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "questions"}}

      questions when is_list(questions) ->
        if Enum.all?(questions, &is_map/1) do
          max_words = parse_optional_max_words(sub)

          case max_words do
            {:error, _} = err -> err
            mw -> {:ok, nil, questions, nil, mw}
          end
        else
          {:error, {:invalid_subscription_field, channel_idx, sub_idx, "questions", :expected_list_of_maps}}
        end

      _other ->
        {:error, {:invalid_subscription_field, channel_idx, sub_idx, "questions", :expected_list}}
    end
  end

  defp parse_subscription_spec(sub, channel_idx, sub_idx, 3) do
    with {:ok, directive} <- parse_subscription_directive(sub, channel_idx, sub_idx),
         {:ok, max_words} <- parse_required_max_words(sub, channel_idx, sub_idx) do
      {:ok, nil, nil, directive, max_words}
    end
  end

  defp parse_subscription_directive(sub, channel_idx, sub_idx) do
    case Map.get(sub, "directive") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "directive"}}

      directive when is_binary(directive) ->
        {:ok, directive}

      _other ->
        {:error, {:invalid_subscription_field, channel_idx, sub_idx, "directive", :expected_string}}
    end
  end

  defp parse_optional_max_words(sub) do
    case Map.get(sub, "max_words") do
      nil -> nil
      mw when is_integer(mw) and mw > 0 -> mw
      _other -> {:error, {:invalid_subscription_max_words, :must_be_positive_integer}}
    end
  end

  defp parse_required_max_words(sub, channel_idx, sub_idx) do
    case Map.get(sub, "max_words") do
      nil ->
        {:error, {:missing_subscription_field, channel_idx, sub_idx, "max_words"}}

      mw when is_integer(mw) and mw > 0 ->
        {:ok, mw}

      _other ->
        {:error, {:invalid_subscription_field, channel_idx, sub_idx, "max_words", :must_be_positive_integer}}
    end
  end

  defp validate_subscription_id_uniqueness(subscriptions, channel_idx) do
    ids = Enum.map(subscriptions, & &1.id)
    unique_ids = Enum.uniq(ids)

    if length(ids) == length(unique_ids) do
      {:ok, subscriptions}
    else
      duplicate = ids -- unique_ids |> List.first()
      {:error, {:duplicate_subscription_id, channel_idx, duplicate}}
    end
  end

  @spec parse_cron_schedules(map()) :: {:ok, [cron_schedule()]} | {:error, term()}
  defp parse_cron_schedules(yaml) do
    case Map.get(yaml, "cron_schedules") do
      nil ->
        {:ok, []}

      schedules when is_list(schedules) ->
        schedules
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
          case parse_single_cron_schedule(entry, idx) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
          error -> error
        end

      _other ->
        {:error, {:invalid_field_type, "cron_schedules", :expected_list}}
    end
  end

  @spec parse_single_cron_schedule(map(), non_neg_integer()) ::
          {:ok, cron_schedule()} | {:error, term()}
  defp parse_single_cron_schedule(entry, idx) when is_map(entry) do
    with {:ok, schedule_str} <- require_cron_field(entry, "schedule", idx),
         {:ok, message} <- require_cron_field(entry, "message", idx),
         :ok <- validate_cron_expression(schedule_str, idx) do
      label = Map.get(entry, "label")

      label =
        if is_binary(label) or is_nil(label),
          do: label,
          else: nil

      {:ok, %{schedule: schedule_str, message: message, label: label}}
    end
  end

  defp parse_single_cron_schedule(_entry, idx) do
    {:error, {:invalid_cron_schedule, idx, :expected_map}}
  end

  defp require_cron_field(entry, key, idx) do
    case Map.get(entry, key) do
      nil -> {:error, {:invalid_cron_schedule, idx, {:missing_field, key}}}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_cron_schedule, idx, {:field_not_string, key}}}
    end
  end

  defp validate_cron_expression(schedule_str, idx) do
    case Crontab.CronExpression.Parser.parse(schedule_str) do
      {:ok, _expr} -> :ok
      {:error, reason} -> {:error, {:invalid_cron_schedule, idx, {:invalid_expression, reason}}}
    end
  end

  # GitHub owner and repo segments: alphanumerics, hyphens, underscores,
  # dots — but never a path-traversal segment, since the repo string is
  # joined into the host-side clone path.
  @github_repo_pattern ~r"\A[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*\z"

  @spec parse_github_repo(map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp parse_github_repo(yaml) do
    case Map.get(yaml, "github_repo") do
      nil ->
        {:ok, nil}

      repo when is_binary(repo) ->
        if Regex.match?(@github_repo_pattern, repo) and ".." not in String.split(repo, "/") do
          {:ok, repo}
        else
          {:error, {:invalid_github_repo, repo, "expected \"owner/repo\""}}
        end

      _other ->
        {:error, {:invalid_field_type, "github_repo", :expected_string}}
    end
  end

  @spec parse_github_read_repos(map(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  defp parse_github_read_repos(yaml, github_repo) do
    case Map.get(yaml, "github_read_repos") do
      nil ->
        {:ok, []}

      repos when is_list(repos) ->
        invalid =
          Enum.find(repos, fn repo ->
            not is_binary(repo) or not Regex.match?(@github_repo_pattern, repo)
          end)

        case invalid do
          nil ->
            # The agent's own repo is already fully accessible — a mirror
            # of it would only be confusing.
            {:ok, repos |> Enum.uniq() |> Enum.reject(&(&1 == github_repo))}

          bad ->
            {:error, {:invalid_github_read_repo, bad, "expected a list of \"owner/repo\""}}
        end

      _other ->
        {:error, {:invalid_field_type, "github_read_repos", :expected_list}}
    end
  end

  # Slack channel IDs are short uppercase-alphanumeric tokens (C…, G…).
  # Loose validation — just enough to catch names ("#general") and typos.
  @slack_channel_pattern ~r/\A[A-Z][A-Z0-9]{6,}\z/

  @spec parse_slack_channel(map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp parse_slack_channel(yaml) do
    case Map.get(yaml, "slack_channel") do
      nil ->
        {:ok, nil}

      channel when is_binary(channel) ->
        if Regex.match?(@slack_channel_pattern, channel) do
          {:ok, channel}
        else
          {:error,
           {:invalid_slack_channel, channel,
            "expected a Slack channel ID like \"C0123ABCDEF\" (not a #name)"}}
        end

      _other ->
        {:error, {:invalid_field_type, "slack_channel", :expected_string}}
    end
  end

  @spec parse_reflection(map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp parse_reflection(yaml) do
    case Map.get(yaml, "reflection") do
      nil ->
        {:ok, nil}

      expr when is_binary(expr) ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _parsed} -> {:ok, expr}
          {:error, reason} -> {:error, {:invalid_reflection, {:invalid_expression, reason}}}
        end

      other ->
        {:error, {:invalid_field_type, "reflection", :expected_cron_string, other}}
    end
  end

  # Repo references: a shared repo name, "agents/<name>", or (reads only)
  # the "agents/*" wildcard. Names are lowercase slugs so they map cleanly
  # onto directory names.
  @repo_name_pattern ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @spec parse_repo_refs(map(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp parse_repo_refs(yaml, key, agent_name, opts) do
    wildcard_ok = Keyword.fetch!(opts, :wildcard)

    with {:ok, refs} <- parse_string_list(yaml, key) do
      invalid =
        Enum.find(refs, fn ref ->
          not valid_repo_ref?(ref, wildcard_ok)
        end)

      foreign_write =
        if key == "repos_write" do
          Enum.find(refs, &String.starts_with?(&1, "agents/"))
        end

      cond do
        invalid != nil ->
          {:error,
           {:invalid_repo_ref, key, invalid,
            "expected a shared repo name, \"agents/<name>\"#{if wildcard_ok, do: ", or \"agents/*\"", else: ""}"}}

        foreign_write != nil ->
          {:error,
           {:invalid_repo_ref, key, foreign_write,
            "agents cannot write to other agents' repos; share a repo instead"}}

        true ->
          # The agent's own repo is always mounted — drop redundant refs.
          {:ok, refs |> Enum.uniq() |> Enum.reject(&(&1 == "agents/#{agent_name}"))}
      end
    end
  end

  defp valid_repo_ref?("agents/*", wildcard_ok), do: wildcard_ok

  defp valid_repo_ref?("agents/" <> name, _wildcard_ok),
    do: Regex.match?(@repo_name_pattern, name)

  defp valid_repo_ref?(name, _wildcard_ok), do: Regex.match?(@repo_name_pattern, name)

  @feedback_action_keys ~w(content_dir copy_to notify notify_message)

  defp parse_feedback(yaml) do
    case Map.get(yaml, "feedback") do
      nil ->
        {:ok, nil}

      %{} = map ->
        with :ok <- reject_unknown_keys(map, ["upvote"], "feedback"),
             {:ok, upvote} <- parse_feedback_action(Map.get(map, "upvote")) do
          {:ok, %{upvote: upvote}}
        end

      other ->
        {:error, {:invalid_field_type, "feedback", :expected_map, other}}
    end
  end

  defp parse_feedback_action(nil), do: {:ok, nil}

  defp parse_feedback_action(%{} = map) do
    with :ok <- reject_unknown_keys(map, @feedback_action_keys, "feedback.upvote"),
         :ok <- require_optional_strings(map, @feedback_action_keys, "feedback.upvote") do
      action = %{
        content_dir: Map.get(map, "content_dir"),
        copy_to: Map.get(map, "copy_to"),
        notify: Map.get(map, "notify"),
        notify_message: Map.get(map, "notify_message")
      }

      if action.notify != nil and action.notify_message == nil do
        {:error, {:invalid_feedback, "feedback.upvote.notify requires notify_message"}}
      else
        {:ok, action}
      end
    end
  end

  defp parse_feedback_action(other) do
    {:error, {:invalid_field_type, "feedback.upvote", :expected_map, other}}
  end

  defp reject_unknown_keys(map, allowed, context) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, {:invalid_feedback, "#{context}: unknown keys #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp require_optional_strings(map, keys, context) do
    Enum.find_value(keys, :ok, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value when is_binary(value) -> nil
        _other -> {:error, {:invalid_feedback, "#{context}.#{key} must be a string"}}
      end
    end)
  end

  @spec parse_optional_boolean(map(), String.t()) :: {:ok, boolean()} | {:error, term()}
  defp parse_optional_boolean(yaml, key) do
    case Map.get(yaml, key, false) do
      val when is_boolean(val) -> {:ok, val}
      _other -> {:error, {:invalid_field_type, key, :expected_boolean}}
    end
  end

  @spec parse_string_list(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp parse_string_list(yaml, key) do
    case Map.get(yaml, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field_type, key, :expected_string_list}}
        end

      _other ->
        {:error, {:invalid_field_type, key, :expected_list}}
    end
  end

  @valid_input_sources ~w(unverified_input verified_input webhook external_message cron heartbeat)

  @spec parse_input_sources(map()) :: {:ok, [atom()]} | {:error, term()}
  defp parse_input_sources(yaml) do
    case Map.get(yaml, "input_sources") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          invalid = Enum.reject(list, &(&1 in @valid_input_sources))

          if invalid == [] do
            {:ok, Enum.map(list, &String.to_atom/1)}
          else
            {:error, {:invalid_input_sources, invalid, @valid_input_sources}}
          end
        else
          {:error, {:invalid_field_type, "input_sources", :expected_string_list}}
        end

      _other ->
        {:error, {:invalid_field_type, "input_sources", :expected_list}}
    end
  end

  @spec auto_include_cron([atom()], [cron_schedule()]) :: [atom()]
  defp auto_include_cron(input_sources, cron_schedules) do
    if cron_schedules != [] and :cron not in input_sources do
      [:cron | input_sources]
    else
      input_sources
    end
  end
end
