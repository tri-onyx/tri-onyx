defmodule TriOnyx.GitProvenanceTest do
  use ExUnit.Case, async: true

  alias TriOnyx.GitProvenance

  @moduletag :tmp_dir

  # Each test gets a fresh git repo in a unique tmp directory.
  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)

    # Initialize git repo
    {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@test"], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: repo, stderr_to_stdout: true)

    %{repo: repo}
  end

  describe "file_sensitivity/2" do
    test "file with no git history returns :low", %{repo: repo} do
      assert :low = GitProvenance.file_sensitivity(repo, "nonexistent.txt")
    end

    test "file committed without trailer returns :low", %{repo: repo} do
      write_and_commit(repo, "plain.txt", "hello", "just a plain commit")
      assert :low = GitProvenance.file_sensitivity(repo, "plain.txt")
    end

    test "file with Sc-Sensitivity: high returns :high", %{repo: repo} do
      msg = "[sc] agent write: test-agent\n\nSc-Sensitivity: high"
      write_and_commit(repo, "secret.txt", "secret data", msg)
      assert :high = GitProvenance.file_sensitivity(repo, "secret.txt")
    end

    test "file with Sc-Sensitivity: medium returns :medium", %{repo: repo} do
      msg = "[sc] agent write: test-agent\n\nSc-Sensitivity: medium"
      write_and_commit(repo, "auth.txt", "auth data", msg)
      assert :medium = GitProvenance.file_sensitivity(repo, "auth.txt")
    end

    test "file with Sc-Sensitivity: low returns :low", %{repo: repo} do
      msg = "[sc] agent write: test-agent\n\nSc-Sensitivity: low"
      write_and_commit(repo, "public.txt", "public data", msg)
      assert :low = GitProvenance.file_sensitivity(repo, "public.txt")
    end

    test "override commit returns :low regardless of prior sensitivity", %{repo: repo} do
      # First commit with high sensitivity
      msg1 = "[sc] agent write: test-agent\n\nSc-Sensitivity: high"
      write_and_commit(repo, "data.txt", "sensitive", msg1)
      assert :high = GitProvenance.file_sensitivity(repo, "data.txt")

      # Override commit
      override_msg =
        "[sc] sensitivity override: non-sensitive\n\n" <>
          "Sc-Override: non-sensitive\n" <>
          "Sc-Override-By: user"

      write_and_commit(repo, "data.txt", "sensitive but overridden", override_msg)
      assert :low = GitProvenance.file_sensitivity(repo, "data.txt")
    end

    test "uses most recent commit only", %{repo: repo} do
      # First: low sensitivity
      msg1 = "[sc] agent write: agent-a\n\nSc-Sensitivity: low"
      write_and_commit(repo, "evolving.txt", "v1", msg1)
      assert :low = GitProvenance.file_sensitivity(repo, "evolving.txt")

      # Second: high sensitivity
      msg2 = "[sc] agent write: agent-b\n\nSc-Sensitivity: high"
      write_and_commit(repo, "evolving.txt", "v2", msg2)
      assert :high = GitProvenance.file_sensitivity(repo, "evolving.txt")
    end

    test "trailer parsing is case-insensitive", %{repo: repo} do
      msg = "[sc] agent write: test-agent\n\nSc-Sensitivity: HIGH"
      write_and_commit(repo, "caps.txt", "data", msg)
      assert :high = GitProvenance.file_sensitivity(repo, "caps.txt")
    end
  end

  describe "non_sensitive_override?/2" do
    test "returns false for file with no history", %{repo: repo} do
      refute GitProvenance.non_sensitive_override?(repo, "nope.txt")
    end

    test "returns false for file with sensitivity trailer only", %{repo: repo} do
      msg = "[sc] agent write: agent\n\nSc-Sensitivity: high"
      write_and_commit(repo, "file.txt", "data", msg)
      refute GitProvenance.non_sensitive_override?(repo, "file.txt")
    end

    test "returns true for file with override commit", %{repo: repo} do
      msg = "[sc] sensitivity override: non-sensitive\n\nSc-Override: non-sensitive"
      write_and_commit(repo, "file.txt", "data", msg)
      assert GitProvenance.non_sensitive_override?(repo, "file.txt")
    end
  end

  describe "record_write/5" do
    test "creates a commit with sensitivity trailer", %{repo: repo} do
      # Need an initial commit first
      write_and_commit(repo, ".gitkeep", "", "init")

      File.write!(Path.join(repo, "output.txt"), "agent output")
      assert :ok = GitProvenance.record_write(repo, "output.txt", "researcher", :medium, :high)

      # Verify the sensitivity is recorded
      assert :high = GitProvenance.file_sensitivity(repo, "output.txt")
    end

    test "roundtrip: write with high sensitivity, read back as high", %{repo: repo} do
      write_and_commit(repo, ".gitkeep", "", "init")

      File.write!(Path.join(repo, "result.txt"), "sensitive result")
      assert :ok = GitProvenance.record_write(repo, "result.txt", "email-agent", :low, :high)
      assert :high = GitProvenance.file_sensitivity(repo, "result.txt")
    end

    test "roundtrip: write with low sensitivity, read back as low", %{repo: repo} do
      write_and_commit(repo, ".gitkeep", "", "init")

      File.write!(Path.join(repo, "public.txt"), "public data")
      assert :ok = GitProvenance.record_write(repo, "public.txt", "coder", :low, :low)
      assert :low = GitProvenance.file_sensitivity(repo, "public.txt")
    end
  end

  describe "mark_non_sensitive/2" do
    test "overrides prior high sensitivity to low", %{repo: repo} do
      msg = "[sc] agent write: agent\n\nSc-Sensitivity: high"
      write_and_commit(repo, "data.txt", "sensitive", msg)
      assert :high = GitProvenance.file_sensitivity(repo, "data.txt")

      assert :ok = GitProvenance.mark_non_sensitive(repo, "data.txt")
      assert :low = GitProvenance.file_sensitivity(repo, "data.txt")
      assert GitProvenance.non_sensitive_override?(repo, "data.txt")
    end
  end

  # --- Helpers ---

  defp write_and_commit(repo, file_path, content, message) do
    full_path = Path.join(repo, file_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)

    {_, 0} = System.cmd("git", ["add", "--", file_path], cd: repo, stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["commit", "-m", message],
        cd: repo,
        stderr_to_stdout: true,
        env: [
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@test"}
        ]
      )
  end
end
