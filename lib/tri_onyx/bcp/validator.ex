defmodule TriOnyx.BCP.Validator do
  @moduledoc """
  Validates agent responses against BCP query definitions.

  This module is the core security mechanism of the protocol. It runs entirely
  in the gateway (Elixir) with zero LLM involvement. Each category has
  progressively stricter validation:

  - **Category 1** — Pure type checking. No interpretation, no flexibility.
  - **Category 2** — Format and word-count enforcement with anomaly detection.
  - **Category 3** — Word-count enforcement with anomaly detection. Always
    requires human approval.
  """

  alias TriOnyx.BCP.Query

  @type anomaly :: %{field: String.t(), reason: String.t()}

  @type validation_result ::
          {:ok, map()}
          | {:ok, map(), [anomaly()]}
          | {:ok, map(), [anomaly()], :requires_approval}
          | {:error, String.t()}

  @anomaly_patterns [
    {~r/\bignore\b/i, "contains instruction-like language: 'ignore'"},
    {~r/\binstead\b/i, "contains instruction-like language: 'instead'"},
    {~r/\byou should\b/i, "contains instruction-like language: 'you should'"},
    {~r/\bforget\b/i, "contains instruction-like language: 'forget'"},
    {~r{https?://}i, "contains URL"},
    {~r/```/, "contains code block"}
  ]

  @doc """
  Validates a response map against a query definition.

  Dispatches to the appropriate category-specific validator.
  """
  @spec validate_response(Query.t(), map()) :: validation_result()
  def validate_response(%Query{category: 1} = query, response) do
    validate_cat1(query, response)
  end

  def validate_response(%Query{category: 2} = query, response) do
    validate_cat2(query, response)
  end

  def validate_response(%Query{category: 3} = query, response) do
    validate_cat3(query, response)
  end

  @doc """
  Category 1: Pure type checking.

  Boolean must be exactly true or false. Enum must be one of the listed options.
  Integer must be within [min, max]. Any invalid field causes full rejection.
  """
  @spec validate_cat1(Query.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate_cat1(%Query{category: 1, fields: fields}, response) when is_list(fields) do
    validated =
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
        name = field.name
        value = Map.get(response, name)

        case validate_field(field, value) do
          {:ok, validated_value} ->
            {:cont, {:ok, Map.put(acc, name, validated_value)}}

          {:error, reason} ->
            {:halt, {:error, "field '#{name}': #{reason}"}}
        end
      end)

    validated
  end

  @doc """
  Category 2: Format validation with word-count enforcement and anomaly detection.

  Returns anomalies as warnings but does not reject based on them alone.
  """
  @spec validate_cat2(Query.t(), map()) ::
          {:ok, map(), [anomaly()]} | {:error, String.t()}
  def validate_cat2(%Query{category: 2, questions: questions}, response)
      when is_list(questions) do
    result =
      Enum.reduce_while(questions, {:ok, %{}, []}, fn question, {:ok, acc, anomalies} ->
        name = question.name
        value = Map.get(response, name, "")
        value = if is_binary(value), do: String.trim(value), else: to_string(value)

        with :ok <- check_word_count(value, question.max_words),
             :ok <- check_format(value, question.format) do
          field_anomalies = detect_anomalies(name, value)
          {:cont, {:ok, Map.put(acc, name, value), anomalies ++ field_anomalies}}
        else
          {:error, reason} ->
            {:halt, {:error, "field '#{name}': #{reason}"}}
        end
      end)

    result
  end

  @doc """
  Category 3: Free-text with word-count enforcement.

  Always returns with :requires_approval flag. Anomalies are detected and reported.
  """
  @spec validate_cat3(Query.t(), map()) ::
          {:ok, map(), [anomaly()], :requires_approval} | {:error, String.t()}
  def validate_cat3(%Query{category: 3, max_words: max_words}, response) do
    value = Map.get(response, "response", Map.get(response, :response, ""))
    value = if is_binary(value), do: String.trim(value), else: to_string(value)

    case check_word_count(value, max_words) do
      :ok ->
        anomalies = detect_anomalies("response", value)
        {:ok, %{response: value}, anomalies, :requires_approval}

      {:error, reason} ->
        {:error, "response: #{reason}"}
    end
  end

  # -- Field validation (Cat-1) --

  defp validate_field(%{type: :boolean}, value) when is_boolean(value), do: {:ok, value}

  defp validate_field(%{type: :boolean}, value) do
    {:error, "expected boolean (true/false), got: #{inspect(value)}"}
  end

  defp validate_field(%{type: :enum, options: options}, value)
       when is_list(options) and is_binary(value) do
    if value in options do
      {:ok, value}
    else
      {:error, "value '#{value}' not in allowed options: #{inspect(options)}"}
    end
  end

  defp validate_field(%{type: :enum}, value) do
    {:error, "expected string enum value, got: #{inspect(value)}"}
  end

  defp validate_field(%{type: :integer, min: min, max: max}, value)
       when is_integer(value) and is_integer(min) and is_integer(max) do
    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, "integer #{value} out of range [#{min}, #{max}]"}
    end
  end

  defp validate_field(%{type: :integer}, value) when not is_integer(value) do
    {:error, "expected integer, got: #{inspect(value)}"}
  end

  defp validate_field(%{type: :integer}, value) do
    {:error, "integer #{value} failed range check (missing min/max)"}
  end

  # -- Word count --

  defp check_word_count("", _max_words), do: :ok

  defp check_word_count(value, max_words) when is_binary(value) and is_integer(max_words) do
    word_count = value |> String.split(~r/\s+/, trim: true) |> length()

    if word_count <= max_words do
      :ok
    else
      {:error, "word count #{word_count} exceeds limit of #{max_words}"}
    end
  end

  defp check_word_count(_, _), do: :ok

  # -- Format validation (Cat-2) --

  defp check_format(_value, :short_text), do: :ok

  defp check_format(value, :person_name) do
    if Regex.match?(~r/^[\p{L}\s\-'\.]+$/u, value) do
      :ok
    else
      {:error, "invalid person name format (only letters, spaces, hyphens, apostrophes, periods allowed)"}
    end
  end

  defp check_format(value, :date) do
    case Date.from_iso8601(value) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "invalid date format (expected ISO 8601, e.g. 2024-01-15)"}
    end
  end

  defp check_format(value, :email) do
    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value) do
      :ok
    else
      {:error, "invalid email format"}
    end
  end

  defp check_format(value, :short_list) do
    items = String.split(value, ",", trim: true)

    if length(items) > 0 do
      :ok
    else
      {:error, "short_list must contain at least one comma-separated item"}
    end
  end

  defp check_format(_value, _format), do: :ok

  # -- Anomaly detection --

  defp detect_anomalies(field_name, value) when is_binary(value) do
    Enum.reduce(@anomaly_patterns, [], fn {pattern, reason}, acc ->
      if Regex.match?(pattern, value) do
        [%{field: field_name, reason: reason} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp detect_anomalies(_, _), do: []
end
