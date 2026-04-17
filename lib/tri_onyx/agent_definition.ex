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
  - `fs_read` — glob patterns for filesystem read access
  - `fs_write` — glob patterns for filesystem write access (implies read)
  - `send_to` — list of agent names this agent is allowed to send messages to
  - `receive_from` — list of agent names this agent is allowed to receive messages from
  - `idle_timeout` — duration after which an idle session auto-stops (e.g. "30s", "5m", "1h")
  - `skills` — list of Claude Code skill names to load (from `.claude/skills/<name>/SKILL.md`)
  - `plugins` — list of workspace plugin names (auto-injects FUSE read paths for `/plugins/<name>/**`)
  - `base_taint` — inherent taint floor from model provenance: "low", "medium", or "high" (default: "low")
  - `exclude_from_personalization` — if true, skip this agent's logs when generating the user profile (default: false)
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

  @type bcp_channel :: %{
          peer: String.t(),
          role: :controller | :reader,
          max_category: 1..3,
          budget_bits: pos_integer(),
          max_cat2_queries: non_neg_integer(),
          max_cat3_queries: non_neg_integer(),
          subscriptions: [bcp_subscription()]
        }

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
          fs_read: [String.t()],
          fs_write: [String.t()],
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
          input_sources: [atom()],
          browser: boolean(),
          docker_socket: boolean(),
          trionyx_repo: boolean(),
          exclude_from_personalization: boolean(),
          reflection: String.t() | nil
        }

  @enforce_keys [:name, :tools, :system_prompt]
  defstruct [
    :name,
    :description,
    :system_prompt,
    model: "claude-sonnet-4-20250514",
    tools: [],
    network: :none,
    fs_read: [],
    fs_write: [],
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
    input_sources: [],
    browser: false,
    docker_socket: false,
    trionyx_repo: false,
    exclude_from_personalization: false,
    reflection: nil
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
    with {:ok, name} <- require_string(yaml, "name"),
         {:ok, tools} <- parse_tools(yaml),
         {:ok, model} <- parse_model(yaml),
         {:ok, network} <- parse_network(yaml),
         {:ok, fs_read} <- parse_string_list(yaml, "fs_read"),
         {:ok, fs_write} <- parse_string_list(yaml, "fs_write"),
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
         {:ok, input_sources} <- parse_input_sources(yaml),
         {:ok, browser} <- parse_optional_boolean(yaml, "browser"),
         {:ok, docker_socket} <- parse_optional_boolean(yaml, "docker_socket"),
         {:ok, trionyx_repo} <- parse_optional_boolean(yaml, "trionyx_repo"),
         {:ok, exclude_from_personalization} <- parse_optional_boolean(yaml, "exclude_from_personalization"),
         {:ok, reflection} <- parse_reflection(yaml) do
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

      {:ok,
       %__MODULE__{
         name: name,
         description: Map.get(yaml, "description"),
         model: model,
         tools: tools,
         network: network,
         fs_read: fs_read,
         fs_write: fs_write,
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
         input_sources: auto_include_cron(input_sources, cron_schedules),
         browser: browser,
         docker_socket: docker_socket,
         trionyx_repo: trionyx_repo,
         exclude_from_personalization: exclude_from_personalization,
         reflection: reflection
       }}
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
      nil -> {:ok, "claude-sonnet-4-20250514"}
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
         {:ok, max_cat} <- require_bcp_field(channel, "max_category", idx, &is_integer/1, :integer),
         :ok <- validate_max_category(max_cat, idx),
         {:ok, budget_bits} <- require_bcp_field(channel, "budget_bits", idx, &is_integer/1, :integer),
         :ok <- validate_positive(budget_bits, "budget_bits", idx),
         {:ok, max_cat2} <- get_bcp_field(channel, "max_cat2_queries", idx, &is_integer/1, :integer, 0),
         :ok <- validate_non_negative(max_cat2, "max_cat2_queries", idx),
         {:ok, max_cat3} <- get_bcp_field(channel, "max_cat3_queries", idx, &is_integer/1, :integer, 0),
         :ok <- validate_non_negative(max_cat3, "max_cat3_queries", idx),
         {:ok, subscriptions} <- parse_bcp_subscriptions(channel, role, max_cat, idx) do
      {:ok,
       %{
         peer: peer,
         role: role,
         max_category: max_cat,
         budget_bits: budget_bits,
         max_cat2_queries: max_cat2,
         max_cat3_queries: max_cat3,
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

  defp get_bcp_field(channel, key, idx, validator, expected_type, default) do
    case Map.get(channel, key) do
      nil -> {:ok, default}
      value -> if validator.(value), do: {:ok, value}, else: {:error, {:invalid_bcp_channel_field, idx, key, expected_type}}
    end
  end

  defp validate_bcp_role("controller", _idx), do: {:ok, :controller}
  defp validate_bcp_role("reader", _idx), do: {:ok, :reader}

  defp validate_bcp_role(role, idx) do
    {:error, {:invalid_bcp_role, idx, role, @valid_bcp_roles}}
  end

  defp validate_max_category(cat, _idx) when cat in @valid_max_categories, do: :ok

  defp validate_max_category(cat, idx) do
    {:error, {:invalid_bcp_max_category, idx, cat, @valid_max_categories}}
  end

  defp validate_positive(val, _field, _idx) when is_integer(val) and val > 0, do: :ok
  defp validate_positive(_val, field, idx), do: {:error, {:invalid_bcp_channel_field, idx, field, :must_be_positive}}

  defp validate_non_negative(val, _field, _idx) when is_integer(val) and val >= 0, do: :ok
  defp validate_non_negative(_val, field, idx), do: {:error, {:invalid_bcp_channel_field, idx, field, :must_be_non_negative}}

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
