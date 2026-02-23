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
  - `base_taint` — inherent taint floor from model provenance: "low", "medium", or "high" (default: "low")
  """

  alias TriOnyx.ToolRegistry

  require Logger

  @type network_policy :: :none | :outbound | [String.t()]

  @type bcp_channel :: %{
          peer: String.t(),
          role: :controller | :reader,
          max_category: 1..3,
          budget_bits: pos_integer(),
          max_cat2_queries: non_neg_integer(),
          max_cat3_queries: non_neg_integer()
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
          base_taint: :low | :medium | :high,
          input_sources: [atom()]
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
    base_taint: :low,
    input_sources: []
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
         {:ok, base_taint} <- parse_base_taint(yaml),
         {:ok, input_sources} <- parse_input_sources(yaml) do
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
         base_taint: base_taint,
         input_sources: auto_include_cron(input_sources, cron_schedules)
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
         :ok <- validate_non_negative(max_cat3, "max_cat3_queries", idx) do
      {:ok,
       %{
         peer: peer,
         role: role,
         max_category: max_cat,
         budget_bits: budget_bits,
         max_cat2_queries: max_cat2,
         max_cat3_queries: max_cat3
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
