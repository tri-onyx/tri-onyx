defmodule Mix.Tasks.TriOnyx.MarkNonsensitive do
  @shortdoc "Marks a workspace file as non-sensitive (overrides agent-assigned sensitivity)"

  @moduledoc """
  Commits an override that marks a file as non-sensitive, regardless of
  any prior sensitivity assigned by agent writes.

      $ mix tri_onyx.mark_nonsensitive <canonical_path>

  The path is canonical: `agents/<name>/<path>` for an agent repo or
  `shared/<name>/<path>` for a shared repo. The override is recorded as
  a git commit with `Sc-Override: non-sensitive` so that subsequent Read
  operations classify the file as `:low` sensitivity.

  This is the human operator's escape hatch — if an agent incorrectly
  marks a file as sensitive, the operator can override it.

  ## Examples

      $ mix tri_onyx.mark_nonsensitive agents/researcher/output.txt
      $ mix tri_onyx.mark_nonsensitive shared/knowledge/report.md
  """

  use Mix.Task

  alias TriOnyx.GitProvenance

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix tri_onyx.mark_nonsensitive <canonical_path>")
    Mix.shell().info("")
    Mix.shell().info("  canonical_path — agents/<name>/<path> or shared/<name>/<path>")
  end

  def run([file_path | _rest]) do
    current = GitProvenance.file_sensitivity(file_path)
    Mix.shell().info("Current sensitivity: #{current}")

    case GitProvenance.mark_non_sensitive(file_path) do
      :ok ->
        Mix.shell().info("Marked #{file_path} as non-sensitive (override committed)")

      {:error, reason} ->
        Mix.shell().error("Failed to mark as non-sensitive: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
