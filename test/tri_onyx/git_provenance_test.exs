defmodule TriOnyx.GitProvenanceTest do
  use ExUnit.Case, async: false

  alias TriOnyx.GitProvenance
  alias TriOnyx.RepoStore

  @moduletag :tmp_dir

  # Each test gets a fresh workspace with one agent repo ("prov") whose
  # files are addressed by canonical path "agents/prov/<file>".
  setup %{tmp_dir: tmp_dir} do
    ws = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(ws)

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, ws)

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :workspace_dir, previous)
      else
        Application.delete_env(:tri_onyx, :workspace_dir)
      end
    end)

    :ok = RepoStore.ensure_tree("prov", {:agent, "prov"})
    %{tree: RepoStore.tree_dir("prov", {:agent, "prov"})}
  end

  defp write_and_commit(tree, file_path, content, message, trailers \\ []) do
    full_path = Path.join(tree, file_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)

    {:ok, _} =
      RepoStore.commit_and_push("prov", {:agent, "prov"},
        author: "prov",
        message: message,
        trailers: trailers,
        session_id: "test",
        paths: [file_path]
      )
  end

  defp canonical(file), do: "agents/prov/#{file}"

  describe "file_sensitivity/1" do
    test "file with no git history returns :low" do
      assert :low = GitProvenance.file_sensitivity(canonical("nonexistent.txt"))
    end

    test "invalid canonical path returns :low" do
      assert :low = GitProvenance.file_sensitivity("not-canonical.txt")
    end

    test "file committed without trailer returns :low", %{tree: tree} do
      write_and_commit(tree, "plain.txt", "hello", "just a plain commit")
      assert :low = GitProvenance.file_sensitivity(canonical("plain.txt"))
    end

    test "file with Sc-Sensitivity: high returns :high", %{tree: tree} do
      write_and_commit(tree, "secret.txt", "secret data", "[sc] agent write", ["Sc-Sensitivity: high"])
      assert :high = GitProvenance.file_sensitivity(canonical("secret.txt"))
    end

    test "file with session-end Sensitivity-Level trailer works too", %{tree: tree} do
      write_and_commit(tree, "auth.txt", "auth data", "prov session s1", [
        "Taint-Level: low",
        "Sensitivity-Level: medium"
      ])

      assert :medium = GitProvenance.file_sensitivity(canonical("auth.txt"))
    end

    test "file with Sc-Sensitivity: low returns :low", %{tree: tree} do
      write_and_commit(tree, "public.txt", "public data", "[sc] agent write", ["Sc-Sensitivity: low"])
      assert :low = GitProvenance.file_sensitivity(canonical("public.txt"))
    end

    test "override commit returns :low regardless of prior sensitivity", %{tree: tree} do
      write_and_commit(tree, "data.txt", "sensitive", "[sc] agent write", ["Sc-Sensitivity: high"])
      assert :high = GitProvenance.file_sensitivity(canonical("data.txt"))

      write_and_commit(tree, "data.txt", "sensitive but overridden", "[sc] sensitivity override", [
        "Sc-Override: non-sensitive",
        "Sc-Override-By: user"
      ])

      assert :low = GitProvenance.file_sensitivity(canonical("data.txt"))
    end

    test "uses most recent commit only", %{tree: tree} do
      write_and_commit(tree, "evolving.txt", "v1", "[sc] agent write", ["Sc-Sensitivity: low"])
      assert :low = GitProvenance.file_sensitivity(canonical("evolving.txt"))

      write_and_commit(tree, "evolving.txt", "v2", "[sc] agent write", ["Sc-Sensitivity: high"])
      assert :high = GitProvenance.file_sensitivity(canonical("evolving.txt"))
    end

    test "trailer parsing is case-insensitive", %{tree: tree} do
      write_and_commit(tree, "caps.txt", "data", "[sc] agent write", ["Sc-Sensitivity: HIGH"])
      assert :high = GitProvenance.file_sensitivity(canonical("caps.txt"))
    end
  end

  describe "non_sensitive_override?/1" do
    test "returns false for file with no history" do
      refute GitProvenance.non_sensitive_override?(canonical("nope.txt"))
    end

    test "returns false for file with sensitivity trailer only", %{tree: tree} do
      write_and_commit(tree, "file.txt", "data", "[sc] agent write", ["Sc-Sensitivity: high"])
      refute GitProvenance.non_sensitive_override?(canonical("file.txt"))
    end

    test "returns true for file with override commit", %{tree: tree} do
      write_and_commit(tree, "file.txt", "data", "[sc] sensitivity override", [
        "Sc-Override: non-sensitive"
      ])

      assert GitProvenance.non_sensitive_override?(canonical("file.txt"))
    end
  end

  describe "mark_non_sensitive/1" do
    test "overrides prior high sensitivity to low", %{tree: tree} do
      write_and_commit(tree, "data.txt", "sensitive", "[sc] agent write", ["Sc-Sensitivity: high"])
      assert :high = GitProvenance.file_sensitivity(canonical("data.txt"))

      assert :ok = GitProvenance.mark_non_sensitive(canonical("data.txt"))
      assert :low = GitProvenance.file_sensitivity(canonical("data.txt"))
      assert GitProvenance.non_sensitive_override?(canonical("data.txt"))
    end

    test "returns an error for an invalid path" do
      assert {:error, :invalid_path} = GitProvenance.mark_non_sensitive("bogus.txt")
    end
  end
end
