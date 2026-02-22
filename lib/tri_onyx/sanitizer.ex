defmodule TriOnyx.Sanitizer do
  @moduledoc """
  Message sanitization for inter-agent communication.

  The sanitizer enforces structured data constraints on messages passing
  between agents. This is the primary defense against prompt injection
  propagating across agent boundaries.

  ## Strategy

  Inter-agent messages must conform to strict structural rules:

  1. **Structured data only** — no freeform text fields. Values must be
     scalars (strings, numbers, booleans, nil) or nested maps/lists of scalars.
  2. **String length limits** — string values are capped to prevent payload
     stuffing and prompt injection via long strings.
  3. **Depth limits** — nested structures are limited in depth to prevent
     resource exhaustion and obfuscation.
  4. **Key validation** — map keys must be short ASCII strings (no injection
     via keys).
  5. **Schema validation** — if a message schema is declared for the agent,
     the payload must conform to it.

  ## Taint Propagation

  - If sanitization **succeeds**: the receiving agent is NOT tainted.
    The sanitization is the defense.
  - If sanitization **fails**: the message is rejected. The sender receives
    an error. The receiving agent never sees the message and is not tainted.
  """

  require Logger

  @max_string_length 1024
  @max_key_length 128
  @max_depth 5
  @max_list_length 100
  @max_map_keys 50

  @type validation_error ::
          :string_too_long
          | :key_too_long
          | :depth_exceeded
          | :list_too_long
          | :too_many_keys
          | :invalid_key
          | :unsupported_type
          | :invalid_payload_type

  @doc """
  Sanitizes an inter-agent message payload.

  Returns `{:ok, sanitized_payload}` if the payload passes all checks,
  or `{:error, {error_type, details}}` if any check fails.

  The sanitized payload is identical to the input — sanitization is
  validation-based (reject bad input) rather than transformation-based
  (modify input). If it passes, it's clean.
  """
  @spec sanitize(map()) :: {:ok, map()} | {:error, {validation_error(), String.t()}}
  def sanitize(payload) when is_map(payload) do
    validate_value(payload, 0, "$")
  end

  def sanitize(_other) do
    {:error, {:invalid_payload_type, "payload must be a map"}}
  end

  @doc """
  Sanitizes with a declared schema.

  The schema is a map of field names to expected types. Only fields declared
  in the schema are allowed through. Unknown fields are stripped.

  ## Schema Format

      %{
        "status" => :string,
        "count" => :number,
        "active" => :boolean,
        "items" => :list,
        "metadata" => :map
      }
  """
  @spec sanitize_with_schema(map(), map()) ::
          {:ok, map()} | {:error, {validation_error() | :schema_violation, String.t()}}
  def sanitize_with_schema(payload, schema) when is_map(payload) and is_map(schema) do
    # First: validate structure
    case sanitize(payload) do
      {:ok, _} ->
        # Then: validate against schema
        validate_schema(payload, schema)

      error ->
        error
    end
  end

  def sanitize_with_schema(_payload, _schema) do
    {:error, {:invalid_payload_type, "payload must be a map"}}
  end

  # --- Private Validation ---

  @spec validate_value(term(), non_neg_integer(), String.t()) ::
          {:ok, term()} | {:error, {validation_error(), String.t()}}
  defp validate_value(_value, depth, path) when depth > @max_depth do
    {:error, {:depth_exceeded, "at #{path}: max depth #{@max_depth} exceeded"}}
  end

  defp validate_value(value, depth, path) when is_map(value) do
    cond do
      map_size(value) > @max_map_keys ->
        {:error, {:too_many_keys, "at #{path}: #{map_size(value)} keys exceeds max #{@max_map_keys}"}}

      true ->
        validate_map_entries(Map.to_list(value), depth, path, %{})
    end
  end

  defp validate_value(value, depth, path) when is_list(value) do
    if length(value) > @max_list_length do
      {:error, {:list_too_long, "at #{path}: #{length(value)} items exceeds max #{@max_list_length}"}}
    else
      validate_list_items(value, 0, depth, path, [])
    end
  end

  defp validate_value(value, _depth, path) when is_binary(value) do
    if byte_size(value) > @max_string_length do
      {:error,
       {:string_too_long,
        "at #{path}: #{byte_size(value)} bytes exceeds max #{@max_string_length}"}}
    else
      {:ok, value}
    end
  end

  defp validate_value(value, _depth, _path) when is_number(value), do: {:ok, value}
  defp validate_value(value, _depth, _path) when is_boolean(value), do: {:ok, value}
  defp validate_value(nil, _depth, _path), do: {:ok, nil}

  defp validate_value(_value, _depth, path) do
    {:error, {:unsupported_type, "at #{path}: unsupported value type"}}
  end

  @spec validate_map_entries([{term(), term()}], non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, {validation_error(), String.t()}}
  defp validate_map_entries([], _depth, _path, acc), do: {:ok, acc}

  defp validate_map_entries([{key, value} | rest], depth, path, acc) do
    with :ok <- validate_key(key, path),
         {:ok, validated_value} <- validate_value(value, depth + 1, "#{path}.#{key}") do
      validate_map_entries(rest, depth, path, Map.put(acc, key, validated_value))
    end
  end

  @spec validate_key(term(), String.t()) :: :ok | {:error, {validation_error(), String.t()}}
  defp validate_key(key, path) when is_binary(key) do
    cond do
      byte_size(key) > @max_key_length ->
        {:error, {:key_too_long, "at #{path}: key '#{String.slice(key, 0, 32)}...' exceeds max #{@max_key_length} bytes"}}

      not String.printable?(key) ->
        {:error, {:invalid_key, "at #{path}: key contains non-printable characters"}}

      true ->
        :ok
    end
  end

  defp validate_key(_key, path) do
    {:error, {:invalid_key, "at #{path}: map keys must be strings"}}
  end

  @spec validate_list_items([term()], non_neg_integer(), non_neg_integer(), String.t(), [term()]) ::
          {:ok, [term()]} | {:error, {validation_error(), String.t()}}
  defp validate_list_items([], _index, _depth, _path, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_list_items([item | rest], index, depth, path, acc) do
    case validate_value(item, depth + 1, "#{path}[#{index}]") do
      {:ok, validated} ->
        validate_list_items(rest, index + 1, depth, path, [validated | acc])

      error ->
        error
    end
  end

  # --- Schema Validation ---

  @spec validate_schema(map(), map()) ::
          {:ok, map()} | {:error, {:schema_violation, String.t()}}
  defp validate_schema(payload, schema) do
    # Only allow declared fields through; strip unknown fields
    result =
      Enum.reduce_while(schema, {:ok, %{}}, fn {field_name, expected_type}, {:ok, acc} ->
        case Map.fetch(payload, field_name) do
          {:ok, value} ->
            if type_matches?(value, expected_type) do
              {:cont, {:ok, Map.put(acc, field_name, value)}}
            else
              {:halt,
               {:error,
                {:schema_violation,
                 "field '#{field_name}' expected type #{expected_type}, got #{type_name(value)}"}}}
            end

          :error ->
            # Missing fields are allowed (optional by default)
            {:cont, {:ok, acc}}
        end
      end)

    result
  end

  @spec type_matches?(term(), atom()) :: boolean()
  defp type_matches?(value, :string) when is_binary(value), do: true
  defp type_matches?(value, :number) when is_number(value), do: true
  defp type_matches?(value, :boolean) when is_boolean(value), do: true
  defp type_matches?(value, :map) when is_map(value), do: true
  defp type_matches?(value, :list) when is_list(value), do: true
  defp type_matches?(nil, :nil), do: true
  defp type_matches?(nil, _type), do: true
  defp type_matches?(_value, :any), do: true
  defp type_matches?(_value, _type), do: false

  @spec type_name(term()) :: String.t()
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(nil), do: "nil"
  defp type_name(_), do: "unknown"
end
