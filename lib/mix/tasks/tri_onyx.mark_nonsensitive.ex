defmodule Mix.Tasks.TriOnyx.MarkNonsensitive do
  @shortdoc "Marks a workspace file as non-sensitive (overrides agent-assigned sensitivity)"

  @moduledoc """
  Commits an override that marks a file as non-sensitive, regardless of
  any prior sensitivity assigned by agent writes.

      $ mix tri_onyx.mark_nonsensitive <file_path>

  The file path is relative to the workspace directory. The override is
  recorded as a git commit with `Sc-Override: non-sensitive` so that
  subsequent Read operations classify the file as `:low` sensitivity.

  This is the human operator's escape hatch — if an agent incorrectly
  marks a file as sensitive, the operator can override it.

  ## Examples

      $ mix tri_onyx.mark_nonsensitive agents/researcher/output.txt
      $ mix tri_onyx.mark_nonsensitive shared/report.md
  """

  use Mix.Task

  alias TriOnyx.GitProvenance

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix tri_onyx.mark_nonsensitive <file_path>")
    Mix.shell().info("")
    Mix.shell().info("  file_path — path relative to the workspace directory")
  end

  def run([file_path | _rest]) do
    workspace_path = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")

    full_path = Path.join(workspace_path, file_path)

    unless File.exists?(full_path) do
      Mix.shell().error("File not found: #{full_path}")
      exit({:shutdown, 1})
    end

    current = GitProvenance.file_sensitivity(workspace_path, file_path)
    Mix.shell().info("Current sensitivity: #{current}")

    case GitProvenance.mark_non_sensitive(workspace_path, file_path) do
      :ok ->
        Mix.shell().info("Marked #{file_path} as non-sensitive (override committed)")

      {:error, reason} ->
        Mix.shell().error("Failed to mark as non-sensitive: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
