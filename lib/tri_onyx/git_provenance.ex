defmodule TriOnyx.GitProvenance do
  @moduledoc """
  Tracks file sensitivity through git commit metadata.

  Every file carries a sensitivity level derived from the most recent
  commit that touched it in its owning repo. Session-end commits carry
  `Sensitivity-Level:` trailers (see `TriOnyx.Workspace.commit_session/4`);
  this module also honours the older `Sc-Sensitivity:` trailer for
  history predating the repo split.

  Files are addressed by canonical path (`agents/<name>/<path>` or
  `shared/<name>/<path>`), resolved to the owning repo via
  `TriOnyx.Workspace.resolve_canonical/1`.

  A human operator can override any file's sensitivity to `:low` via
  `mark_non_sensitive/1`, which commits with `Sc-Override: non-sensitive`.
  """

  require Logger

  alias TriOnyx.RepoStore
  alias TriOnyx.Workspace

  @sensitivity_trailers ["Sc-Sensitivity:", "Sensitivity-Level:"]
  @override_prefix "Sc-Override:"

  @doc """
  Returns the git-provenance sensitivity level for a canonical path.

  Parses the most recent commit message that touched the file in its
  owning repo, looking for a sensitivity trailer. Returns `:low` if no
  trailer is found, the file has no history, or the path is invalid.

  If the most recent commit has `Sc-Override: non-sensitive`, returns
  `:low` regardless of any prior sensitivity.
  """
  @spec file_sensitivity(String.t()) :: :low | :medium | :high
  def file_sensitivity(canonical_path) when is_binary(canonical_path) do
    case last_commit_message(canonical_path) do
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
  @spec non_sensitive_override?(String.t()) :: boolean()
  def non_sensitive_override?(canonical_path) when is_binary(canonical_path) do
    case last_commit_message(canonical_path) do
      {:ok, message} -> has_override?(message)
      :error -> false
    end
  end

  @doc """
  Marks a file as non-sensitive by committing an override.

  Touches the file in the appropriate working tree (the agent's own tree
  for agent repos, the gateway tree for shared repos) so git records a
  change, then commits with `Sc-Override: non-sensitive`.
  """
  @spec mark_non_sensitive(String.t()) :: :ok | {:error, term()}
  def mark_non_sensitive(canonical_path) when is_binary(canonical_path) do
    with {:ok, {repo_id, rel_path}} <- resolve(canonical_path) do
      principal =
        case repo_id do
          {:agent, name} -> name
          {:shared, _} -> :gw
        end

      with :ok <- RepoStore.sync_tree(principal, repo_id),
           :ok <- touch_file(RepoStore.tree_dir(principal, repo_id), rel_path) do
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        case RepoStore.commit_and_push(principal, repo_id,
               author: "user",
               message: "[sc] sensitivity override: non-sensitive",
               trailers: [
                 "Sc-Override: non-sensitive",
                 "Sc-Override-By: user",
                 "Sc-Override-At: #{timestamp}"
               ],
               session_id: "override",
               paths: [rel_path]
             ) do
          {:ok, sha} when is_binary(sha) -> :ok
          {:ok, :no_changes} -> {:error, :no_changes}
          {:ok, {:conflict, branch}} -> {:error, {:conflict, branch}}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # --- Private ---

  defp resolve(canonical_path) do
    case Workspace.resolve_canonical(canonical_path) do
      {:ok, resolved} -> {:ok, resolved}
      :error -> {:error, :invalid_path}
    end
  end

  # Toggle the trailing newline to guarantee a diff from the previous
  # version so the override commit appears in `git log -- <path>`.
  defp touch_file(tree, rel_path) do
    full_path = Path.join(tree, rel_path)

    case File.read(full_path) do
      {:ok, content} ->
        touched =
          if String.ends_with?(content, "\n") do
            String.trim_trailing(content, "\n")
          else
            content <> "\n"
          end

        File.write!(full_path, touched)
        :ok

      {:error, reason} ->
        Logger.warning("GitProvenance: cannot read file #{full_path}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  @spec last_commit_message(String.t()) :: {:ok, String.t()} | :error
  defp last_commit_message(canonical_path) do
    with {:ok, {repo_id, rel_path}} <- resolve(canonical_path),
         {:ok, output} when output != "" <-
           RepoStore.log(repo_id, ["--format=%B", "-1", "--", rel_path]) do
      {:ok, String.trim(output)}
    else
      _ -> :error
    end
  end

  @spec parse_sensitivity(String.t()) :: :low | :medium | :high
  defp parse_sensitivity(message) do
    message
    |> String.split("\n")
    |> Enum.find_value(:low, fn line ->
      line = String.trim(line)

      prefix = Enum.find(@sensitivity_trailers, &String.starts_with?(line, &1))

      if prefix do
        line
        |> String.trim_leading(prefix)
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
end
