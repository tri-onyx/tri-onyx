defmodule TriOnyx.WorkspaceTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RepoStore
  alias TriOnyx.Workspace

  setup do
    workspace = Path.join("test/tmp", "workspace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, workspace)

    :ok = RepoStore.ensure_tree("evil", {:agent, "evil"})
    tree = RepoStore.tree_dir("evil", {:agent, "evil"})

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :workspace_dir, previous)
      else
        Application.delete_env(:tri_onyx, :workspace_dir)
      end

      File.rm_rf!(workspace)
    end)

    %{workspace: workspace, tree: tree}
  end

  describe "agent_host_path/2" do
    test "resolves regular files inside the agent's tree", %{tree: tree} do
      File.write!(Path.join(tree, "ok.png"), "x")
      assert {:ok, path} = Workspace.agent_host_path("evil", "/workspace/ok.png")
      assert path == Path.expand(Path.join(tree, "ok.png"))
      assert {:ok, _} = Workspace.agent_host_path("evil", "/workspace/not-yet-created.html")
    end

    test "rejects lexical traversal" do
      assert {:error, :path_traversal} = Workspace.agent_host_path("evil", "../../secret.png")
    end

    test "rejects symlinks that point outside the agent's tree", %{workspace: workspace, tree: tree} do
      secret = Path.join(workspace, "outside-secret.txt")
      File.write!(secret, "gateway-only data")
      outside_dir = Path.join(workspace, "outside-dir")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "a.png"), "x")

      File.ln_s!(Path.expand(secret), Path.join(tree, "leak.png"))
      File.ln_s!(Path.expand(outside_dir), Path.join(tree, "linkdir"))

      assert {:error, :path_traversal} = Workspace.agent_host_path("evil", "/workspace/leak.png"),
             "a symlink in the agent's tree must not let SubmitImage/SubmitPage read gateway-side files"

      assert {:error, :path_traversal} =
               Workspace.agent_host_path("evil", "/workspace/linkdir/a.png"),
             "a symlinked directory must not let paths escape the agent's tree"
    end
  end
end
