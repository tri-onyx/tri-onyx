defmodule TriOnyx.WebhookEndpoint do
  @moduledoc """
  Struct and validation for webhook endpoint configurations.

  Each webhook endpoint is a persistent configuration that defines an
  internet-facing ingress point. It maps an unguessable endpoint ID to
  one or more agents and carries the HMAC signing secret used to
  authenticate incoming requests.

  ## Fields

  - `id` — unique identifier, e.g. `"whk_<32 hex chars>"`
  - `label` — human-readable name, e.g. `"github-push"`
  - `agents` — list of agent names to fan-out to
  - `signing_secret` — HMAC signing secret (hex-encoded, 32 bytes)
  - `signing_mode` — verification scheme (`:default`, `:github`, `:stripe`, `:slack`, `:none`)
  - `enabled` — soft disable without deleting
  - `rate_limit` — max requests per minute per source IP
  - `allowed_ips` — optional IP allowlist (`nil` = any)
  - `created_at` — creation timestamp
  - `rotated_at` — last secret rotation timestamp
  - `previous_secret` — old secret during rotation window (1 hour)
  """

  @type signing_mode :: :default | :github | :stripe | :slack | :none

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          agents: [String.t()],
          signing_secret: String.t(),
          signing_mode: signing_mode(),
          enabled: boolean(),
          rate_limit: pos_integer(),
          allowed_ips: [String.t()] | nil,
          created_at: DateTime.t(),
          rotated_at: DateTime.t() | nil,
          previous_secret: String.t() | nil
        }

  @enforce_keys [:id, :label, :agents, :signing_secret, :signing_mode, :created_at]
  defstruct [
    :id,
    :label,
    :agents,
    :signing_secret,
    :signing_mode,
    :created_at,
    :rotated_at,
    :previous_secret,
    enabled: true,
    rate_limit: 60,
    allowed_ips: nil
  ]

  @id_prefix "whk_"
  @id_bytes 16
  @secret_bytes 32
  @allowed_signing_modes ~w(default github stripe slack none)a
  @rotation_window_ms 3_600_000

  @doc """
  Creates a new webhook endpoint from the given parameters.

  Generates a random endpoint ID and signing secret. Returns
  `{:ok, endpoint}` on success or `{:error, reason}` on validation failure.

  ## Required params

  - `"label"` — human-readable name
  - `"agents"` — list of agent names

  ## Optional params

  - `"signing_mode"` — one of "default", "github", "stripe", "slack", "none"
  - `"rate_limit"` — positive integer, requests per minute
  - `"allowed_ips"` — list of IP strings or `nil`
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(params) when is_map(params) do
    with {:ok, label} <- require_string(params, "label"),
         {:ok, agents} <- require_agent_list(params, "agents"),
         {:ok, signing_mode} <- parse_signing_mode(params),
         {:ok, rate_limit} <- parse_rate_limit(params) do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         label: label,
         agents: agents,
         signing_secret: generate_secret(),
         signing_mode: signing_mode,
         enabled: true,
         rate_limit: rate_limit,
         allowed_ips: parse_allowed_ips(params),
         created_at: DateTime.utc_now()
       }}
    end
  end

  @doc """
  Generates a new signing secret and moves the current secret to
  `previous_secret` for the rotation window.
  """
  @spec rotate_secret(t()) :: t()
  def rotate_secret(%__MODULE__{} = endpoint) do
    %{
      endpoint
      | previous_secret: endpoint.signing_secret,
        signing_secret: generate_secret(),
        rotated_at: DateTime.utc_now()
    }
  end

  @doc """
  Returns true if the previous secret is still within the rotation window.
  """
  @spec rotation_active?(t()) :: boolean()
  def rotation_active?(%__MODULE__{rotated_at: nil}), do: false

  def rotation_active?(%__MODULE__{rotated_at: rotated_at}) do
    elapsed = DateTime.diff(DateTime.utc_now(), rotated_at, :millisecond)
    elapsed < @rotation_window_ms
  end

  @doc """
  Serializes the endpoint to a JSON-safe map for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ep) do
    %{
      "id" => ep.id,
      "label" => ep.label,
      "agents" => ep.agents,
      "signing_secret" => ep.signing_secret,
      "signing_mode" => to_string(ep.signing_mode),
      "enabled" => ep.enabled,
      "rate_limit" => ep.rate_limit,
      "allowed_ips" => ep.allowed_ips,
      "created_at" => DateTime.to_iso8601(ep.created_at),
      "rotated_at" => if(ep.rotated_at, do: DateTime.to_iso8601(ep.rotated_at)),
      "previous_secret" => ep.previous_secret
    }
  end

  @doc """
  Deserializes an endpoint from a persisted map. Returns `{:ok, endpoint}`
  or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- require_string(map, "id"),
         {:ok, label} <- require_string(map, "label"),
         {:ok, agents} <- require_agent_list(map, "agents"),
         {:ok, signing_secret} <- require_string(map, "signing_secret"),
         {:ok, signing_mode} <- parse_signing_mode(map),
         {:ok, created_at} <- parse_datetime(map, "created_at") do
      rotated_at =
        case parse_datetime(map, "rotated_at") do
          {:ok, dt} -> dt
          _ -> nil
        end

      {:ok,
       %__MODULE__{
         id: id,
         label: label,
         agents: agents,
         signing_secret: signing_secret,
         signing_mode: signing_mode,
         enabled: Map.get(map, "enabled", true),
         rate_limit: Map.get(map, "rate_limit", 60),
         allowed_ips: Map.get(map, "allowed_ips"),
         created_at: created_at,
         rotated_at: rotated_at,
         previous_secret: Map.get(map, "previous_secret")
       }}
    end
  end

  @doc """
  Returns the public-safe representation (no secrets).
  """
  @spec to_public_map(t()) :: map()
  def to_public_map(%__MODULE__{} = ep) do
    %{
      "id" => ep.id,
      "label" => ep.label,
      "agents" => ep.agents,
      "signing_mode" => to_string(ep.signing_mode),
      "enabled" => ep.enabled,
      "rate_limit" => ep.rate_limit,
      "allowed_ips" => ep.allowed_ips,
      "created_at" => DateTime.to_iso8601(ep.created_at),
      "rotated_at" => if(ep.rotated_at, do: DateTime.to_iso8601(ep.rotated_at)),
      "rotation_active" => rotation_active?(ep)
    }
  end

  @doc """
  Generates a random endpoint ID with the `whk_` prefix.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    @id_prefix <> Base.hex_encode32(:crypto.strong_rand_bytes(@id_bytes), case: :lower, padding: false)
  end

  @doc """
  Generates a hex-encoded random signing secret.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    Base.encode16(:crypto.strong_rand_bytes(@secret_bytes), case: :lower)
  end

  # --- Validation Helpers ---

  @spec require_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp require_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key, "expected non-empty string"}}
    end
  end

  @spec require_agent_list(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp require_agent_list(map, key) do
    case Map.get(map, key) do
      nil ->
        {:error, {:missing_field, key}}

      agents when is_list(agents) and length(agents) > 0 ->
        if Enum.all?(agents, &(is_binary(&1) and byte_size(&1) > 0)) do
          {:ok, agents}
        else
          {:error, {:invalid_field, key, "expected list of non-empty strings"}}
        end

      _ ->
        {:error, {:invalid_field, key, "expected non-empty list of agent names"}}
    end
  end

  @spec parse_signing_mode(map()) :: {:ok, signing_mode()} | {:error, term()}
  defp parse_signing_mode(map) do
    case Map.get(map, "signing_mode", "default") do
      mode when is_binary(mode) ->
        try do
          atom = String.to_existing_atom(mode)

          if atom in @allowed_signing_modes do
            {:ok, atom}
          else
            {:error, {:invalid_signing_mode, mode, @allowed_signing_modes}}
          end
        rescue
          ArgumentError ->
            {:error, {:invalid_signing_mode, mode, @allowed_signing_modes}}
        end

      _ ->
        {:error, {:invalid_signing_mode, nil, @allowed_signing_modes}}
    end
  end

  @spec parse_rate_limit(map()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_rate_limit(map) do
    case Map.get(map, "rate_limit", 60) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:invalid_rate_limit, other, "expected positive integer"}}
    end
  end

  @spec parse_allowed_ips(map()) :: [String.t()] | nil
  defp parse_allowed_ips(map) do
    case Map.get(map, "allowed_ips") do
      nil -> nil
      ips when is_list(ips) -> ips
      _ -> nil
    end
  end

  @spec parse_datetime(map(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp parse_datetime(map, key) do
    case Map.get(map, key) do
      nil ->
        {:error, {:missing_field, key}}

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, reason} -> {:error, {:invalid_datetime, key, reason}}
        end

      _ ->
        {:error, {:invalid_field, key, "expected ISO 8601 datetime string"}}
    end
  end
end
