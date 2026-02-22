defmodule TriOnyx.GitProvenance do
  @moduledoc """
  Tracks file sensitivity through git commit metadata.

  Every file in the workspace carries a sensitivity level derived from the
  most recent TriOnyx commit that touched it. This is encoded as a
  `Sc-Sensitivity:` trailer in the commit message.

  Read operations consult this provenance to determine the sensitivity of
  the data entering the agent context. Write operations record the agent's
  current taint and sensitivity levels in a new commit.

  A human operator can override any file's sensitivity to `:low` by
  committing with `Sc-Override: non-sensitive`.
  """

  require Logger

  @trailer_prefix "Sc-Sensitivity:"
  @override_prefix "Sc-Override:"

  @doc """
  Returns the git-provenance sensitivity level for a file.

  Parses the most recent commit message that touched `file_path` in the
  given workspace directory, looking for a `Sc-Sensitivity:` trailer.
  Returns `:low` if no trailer is found or if the file has no git history.

  If the most recent TriOnyx commit has `Sc-Override: non-sensitive`,
  returns `:low` regardless of any prior sensitivity.
  """
  @spec file_sensitivity(String.t(), String.t()) :: :low | :medium | :high
  def file_sensitivity(workspace_path, file_path)
      when is_binary(workspace_path) and is_binary(file_path) do
    case last_commit_message(workspace_path, file_path) do
      {:ok, message} ->
        if has_override?(message) do
          :low
        else
          parse_sensitivity(message)
        end

      :error ->
        :low
    end
  end

  @doc """
  Returns true if the most recent commit for the file is an override commit.
  """
  @spec non_sensitive_override?(String.t(), String.t()) :: boolean()
  def non_sensitive_override?(workspace_path, file_path)
      when is_binary(workspace_path) and is_binary(file_path) do
    case last_commit_message(workspace_path, file_path) do
      {:ok, message} -> has_override?(message)
      :error -> false
    end
  end

  @doc """
  Records an agent write by committing the file with sensitivity metadata.

  Stages the file, then commits with `Sc-Agent`, `Sc-Taint`, and
  `Sc-Sensitivity` trailers in the commit message.
  """
  @spec record_write(String.t(), String.t(), String.t(), atom(), atom()) ::
          :ok | {:error, term()}
  def record_write(workspace_path, file_path, agent_name, taint, sensitivity)
      when is_binary(workspace_path) and is_binary(file_path) and is_binary(agent_name) and
             is_atom(taint) and is_atom(sensitivity) do
    safe = safe_dir_args(workspace_path)

    case System.cmd("git", safe ++ ["add", "--", file_path],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        commit_msg =
          "[sc] agent write: #{agent_name}\n\n" <>
            "Sc-Agent: #{agent_name}\n" <>
            "Sc-Taint: #{taint}\n" <>
            "Sc-Sensitivity: #{sensitivity}"

        author = "#{agent_name} <#{agent_name}@tri_onyx>"

        case System.cmd(
               "git",
               safe ++ ["commit", "--author=#{author}", "-m", commit_msg],
               cd: workspace_path,
               stderr_to_stdout: true,
               env: committer_env()
             ) do
          {_, 0} ->
            :ok

          {output, code} ->
            Logger.warning("GitProvenance: commit failed (exit #{code}): #{output}")
            {:error, {:commit_failed, output}}
        end

      {output, code} ->
        Logger.warning("GitProvenance: git add failed (exit #{code}): #{output}")
        {:error, {:add_failed, output}}
    end
  end

  @doc """
  Marks a file as non-sensitive by committing an override.

  Creates a commit with `Sc-Override: non-sensitive` that overrides any
  prior sensitivity recorded by agent writes.
  """
  @spec mark_non_sensitive(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_non_sensitive(workspace_path, file_path)
      when is_binary(workspace_path) and is_binary(file_path) do
    safe = safe_dir_args(workspace_path)
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    full_path = Path.join(workspace_path, file_path)

    # Touch the file so git records a change and the override commit appears
    # in `git log -- <file_path>`. We read and re-write with a trailing newline.
    case File.read(full_path) do
      {:ok, content} ->
        # Toggle trailing newline to guarantee a diff from the previous version
        touched =
          if String.ends_with?(content, "\n") do
            String.trim_trailing(content, "\n")
          else
            content <> "\n"
          end

        File.write!(full_path, touched)

        case System.cmd("git", safe ++ ["add", "--", file_path],
               cd: workspace_path,
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            commit_msg =
              "[sc] sensitivity override: non-sensitive\n\n" <>
                "Sc-Override: non-sensitive\n" <>
                "Sc-Override-By: user\n" <>
                "Sc-Override-At: #{timestamp}"

            case System.cmd(
                   "git",
                   safe ++ ["commit", "-m", commit_msg],
                   cd: workspace_path,
                   stderr_to_stdout: true,
                   env: committer_env()
                 ) do
              {_, 0} ->
                :ok

              {output, code} ->
                Logger.warning("GitProvenance: override commit failed (exit #{code}): #{output}")
                {:error, {:commit_failed, output}}
            end

          {output, code} ->
            Logger.warning("GitProvenance: git add failed (exit #{code}): #{output}")
            {:error, {:add_failed, output}}
        end

      {:error, reason} ->
        Logger.warning("GitProvenance: cannot read file #{full_path}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  # --- Private ---

  @spec last_commit_message(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp last_commit_message(workspace_path, file_path) do
    safe = safe_dir_args(workspace_path)

    case System.cmd(
           "git",
           safe ++ ["log", "--format=%B", "-1", "--", file_path],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        # No commits for this file
        :error

      {output, 0} ->
        {:ok, String.trim(output)}

      {_, _} ->
        :error
    end
  end

  @spec parse_sensitivity(String.t()) :: :low | :medium | :high
  defp parse_sensitivity(message) do
    message
    |> String.split("\n")
    |> Enum.find_value(:low, fn line ->
      line = String.trim(line)

      if String.starts_with?(line, @trailer_prefix) do
        line
        |> String.trim_leading(@trailer_prefix)
        |> String.trim()
        |> String.downcase()
        |> case do
          "high" -> :high
          "medium" -> :medium
          "low" -> :low
          _ -> nil
        end
      end
    end)
  end

  @spec has_override?(String.t()) :: boolean()
  defp has_override?(message) do
    message
    |> String.split("\n")
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, @override_prefix) and
        trimmed
        |> String.trim_leading(@override_prefix)
        |> String.trim()
        |> String.downcase() == "non-sensitive"
    end)
  end

  @spec safe_dir_args(String.t()) :: [String.t()]
  defp safe_dir_args(workspace_path) do
    ["-c", "safe.directory=#{Path.expand(workspace_path)}"]
  end

  @spec committer_env() :: [{String.t(), String.t()}]
  defp committer_env do
    [
      {"GIT_COMMITTER_NAME", "TriOnyx"},
      {"GIT_COMMITTER_EMAIL", "gateway@tri_onyx"}
    ]
  end
end
