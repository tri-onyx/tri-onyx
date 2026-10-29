defmodule TriOnyx.WorkspaceHostPathTest do
  use ExUnit.Case, async: false

  alias TriOnyx.Workspace

  setup do
    tmp = Path.join(["test", "tmp", "host_path_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)
    original = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, tmp)

    on_exit(fn ->
      Application.put_env(:tri_onyx, :workspace_dir, original)
      File.rm_rf!(tmp)
    end)

    base = Workspace.agent_dir("alice")
    File.mkdir_p!(base)
    {:ok, tmp: Path.expand(tmp), base: base}
  end

  test "resolves regular files inside the agent tree", %{base: base} do
    File.write!(Path.join(base, "ok.png"), "x")
    assert {:ok, host} = Workspace.agent_host_path("alice", "/workspace/ok.png")
    assert host == Path.join(Path.expand(base), "ok.png")
    assert {:ok, _} = Workspace.agent_host_path("alice", "not-yet-created.png")
  end

  test "rejects a symlinked file that points outside the agent tree", %{tmp: tmp, base: base} do
    # The agent controls its own rw tree and can `ln -s` inside it. The gateway
    # resolves the link on the host, so it must never follow it.
    secret = Path.join(tmp, "outside-secret.txt")
    File.write!(secret, "gateway-only data")
    :ok = File.ln_s(secret, Path.join(base, "leak.png"))

    assert {:error, :path_traversal} = Workspace.agent_host_path("alice", "/workspace/leak.png"),
           "a symlink in the agent tree must not let the gateway read outside the mount set"
  end

  test "rejects a path that traverses a symlinked directory", %{tmp: tmp, base: base} do
    other = Path.join(tmp, "other-agent-tree")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "page.html"), "<p>other</p>")
    :ok = File.ln_s(other, Path.join(base, "link"))

    assert {:error, :path_traversal} =
             Workspace.agent_host_path("alice", "/workspace/link/page.html"),
           "a symlinked directory must not expose another tree to gateway-side reads"
  end
end
