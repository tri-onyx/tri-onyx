defmodule TriOnyx.Speech do
  @moduledoc """
  Local text-to-speech synthesis via Piper.

  Backs the `Speak` tool: renders text to an Opus-in-Ogg audio file that is
  served to the web chat (`GET /audio/...`) and pushed to chat platforms as a
  voice message via the connector's `send_file` action.

  The gateway image bakes in the Piper binary, voice models, and ffmpeg
  (see `gateway.Dockerfile`). Voices are selected by short language code;
  paths can be overridden via the `:speech` application env for tests.
  """

  require Logger

  @default_piper_bin "/opt/piper/piper"
  @default_voices %{
    "no" => "/opt/piper/voices/no_NO-talesyntese-medium.onnx",
    "en" => "/opt/piper/voices/en_US-lessac-medium.onnx"
  }

  @max_text_bytes 8_000

  @doc """
  Returns the list of supported voice codes.
  """
  @spec voices() :: [String.t()]
  def voices, do: Map.keys(voice_models())

  @doc """
  Synthesizes `text` with the given voice and writes an Ogg/Opus file to
  `dest_path`. Returns `{:ok, duration_ms}` or `{:error, reason}`.
  """
  @spec synthesize(String.t(), String.t(), Path.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def synthesize(text, voice, dest_path) do
    with :ok <- validate_text(text),
         {:ok, model} <- voice_model(voice),
         :ok <- ensure_available() do
      do_synthesize(text, model, dest_path)
    end
  end

  @doc """
  Returns `:ok` when the Piper binary and ffmpeg are present, otherwise an
  error describing what is missing (e.g. gateway image not rebuilt).
  """
  @spec ensure_available() :: :ok | {:error, String.t()}
  def ensure_available do
    cond do
      not File.exists?(piper_bin()) ->
        {:error, "piper binary not found at #{piper_bin()} (rebuild the gateway image)"}

      System.find_executable("ffmpeg") == nil ->
        {:error, "ffmpeg not found (rebuild the gateway image)"}

      true ->
        :ok
    end
  end

  defp validate_text(text) do
    cond do
      String.trim(text) == "" -> {:error, "text is empty"}
      byte_size(text) > @max_text_bytes -> {:error, "text exceeds #{@max_text_bytes} bytes"}
      true -> :ok
    end
  end

  defp voice_model(voice) do
    case Map.fetch(voice_models(), voice) do
      {:ok, model} ->
        if File.exists?(model),
          do: {:ok, model},
          else: {:error, "voice model missing: #{model} (rebuild the gateway image)"}

      :error ->
        {:error, "unknown voice #{inspect(voice)}; supported: #{Enum.join(voices(), ", ")}"}
    end
  end

  defp do_synthesize(text, model, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))
    tmp_base = Path.join(System.tmp_dir!(), "speak-#{random_id()}")
    text_path = tmp_base <> ".txt"
    wav_path = tmp_base <> ".wav"

    try do
      File.write!(text_path, text)

      with :ok <- run_piper(model, text_path, wav_path),
           :ok <- transcode_to_ogg(wav_path, dest_path) do
        {:ok, probe_duration_ms(dest_path)}
      end
    after
      File.rm(text_path)
      File.rm(wav_path)
    end
  end

  defp run_piper(model, text_path, wav_path) do
    args = ["--model", model, "--output_file", wav_path]

    case System.cmd("sh", ["-c", "exec \"$0\" \"$@\" < #{text_path}", piper_bin() | args],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning("Speech: piper failed (exit #{code}): #{String.slice(out, 0, 500)}")
        {:error, "piper synthesis failed (exit #{code})"}
    end
  end

  defp transcode_to_ogg(wav_path, dest_path) do
    args = ["-y", "-loglevel", "error", "-i", wav_path, "-c:a", "libopus", "-b:a", "32k", dest_path]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning("Speech: ffmpeg failed (exit #{code}): #{String.slice(out, 0, 500)}")
        {:error, "audio transcode failed (exit #{code})"}
    end
  end

  # Duration is advisory (used for the voice-message UI); 0 on probe failure.
  defp probe_duration_ms(path) do
    args = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]

    with {out, 0} <- System.cmd("ffprobe", args, stderr_to_stdout: true),
         {seconds, _} <- Float.parse(String.trim(out)) do
      round(seconds * 1000)
    else
      _ -> 0
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp piper_bin do
    Application.get_env(:tri_onyx, :speech, [])
    |> Keyword.get(:piper_bin, @default_piper_bin)
  end

  defp voice_models do
    Application.get_env(:tri_onyx, :speech, [])
    |> Keyword.get(:voices, @default_voices)
  end
end
