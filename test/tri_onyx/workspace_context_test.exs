defmodule TriOnyx.WorkspaceContextTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RepoStore
  alias TriOnyx.Workspace

  setup do
    tmp = Path.join(["test", "tmp", "workspace_context_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)
    original = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, tmp)

    on_exit(fn ->
      Application.put_env(:tri_onyx, :workspace_dir, original)
      File.rm_rf!(tmp)
    end)

    tree = Workspace.agent_dir("mallory")
    File.mkdir_p!(Path.join(tree, "memory"))

    # Stands in for anything on the gateway host outside mallory's mount set
    # (another agent's tree, the gateway's own environment, ...).
    secret = Path.expand(Path.join(tmp, "gateway-only.txt"))
    File.write!(secret, "GATEWAY-ONLY-SECRET")

    {:ok, tmp: tmp, tree: tree, secret: secret}
  end

  test "read_context still returns regular notes and daily memory", %{tree: tree} do
    today = Date.utc_today() |> Date.to_iso8601()
    File.write!(Path.join(tree, "NOTES.md"), "my notes")
    File.write!(Path.join(tree, "memory/#{today}.md"), "today")

    ctx = Workspace.read_context("mallory")
    assert ctx.notes == "my notes"
    assert ctx.daily_memory == "today"
    assert {:ok, "my notes"} = Workspace.read_agent_file("mallory", "NOTES.md")
  end

  test "read_context does not follow an agent-planted NOTES.md symlink", %{
    tree: tree,
    secret: secret
  } do
    # The agent owns its rw tree and can `ln -s` in it; the gateway resolves
    # the link on the host and would paste the target into the agent's next
    # system prompt.
    :ok = File.ln_s(secret, Path.join(tree, "NOTES.md"))

    ctx = Workspace.read_context("mallory")

    refute ctx.notes == "GATEWAY-ONLY-SECRET",
           "the gateway followed a symlink in the agent tree and leaked a file outside its mount set into the prompt context"

    assert ctx.notes == nil
  end

  test "read_context does not follow a symlinked memory/ directory", %{tmp: tmp, tree: tree} do
    today = Date.utc_today() |> Date.to_iso8601()
    other = Path.expand(Path.join(tmp, "other-agent-tree"))
    File.mkdir_p!(other)
    File.write!(Path.join(other, "#{today}.md"), "OTHER-AGENT-PRIVATE")
    File.rm_rf!(Path.join(tree, "memory"))
    :ok = File.ln_s(other, Path.join(tree, "memory"))

    ctx = Workspace.read_context("mallory")

    refute ctx.daily_memory == "OTHER-AGENT-PRIVATE",
           "a symlinked directory in the agent tree must not expose another tree to the prompt context"
  end

  test "read_context does not follow a symlink committed to the core repo checkout", %{
    secret: secret
  } do
    core_tree = RepoStore.tree_dir(:ro, {:shared, "core"})
    File.mkdir_p!(Path.join(core_tree, "personality"))
    :ok = File.ln_s(secret, Path.join(core_tree, "personality/SOUL.md"))

    ctx = Workspace.read_context("mallory")

    refute ctx.soul == "GATEWAY-ONLY-SECRET",
           "a symlink checked out from a shared repo must not be resolved on the gateway host"
  end

  test "read_agent_file does not follow symlinks", %{tree: tree, secret: secret} do
    :ok = File.ln_s(secret, Path.join(tree, "HEARTBEAT.md"))

    assert {:error, :symlink} = Workspace.read_agent_file("mallory", "HEARTBEAT.md")
  end
end
