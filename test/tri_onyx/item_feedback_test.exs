defmodule TriOnyx.ItemFeedbackTest do
  use ExUnit.Case, async: false

  alias TriOnyx.AgentDefinition
  alias TriOnyx.ItemFeedback
  alias TriOnyx.RepoStore
  alias TriOnyx.RiskManifest

  @url "https://example.com/articles/some-story"
  @channel %{"platform" => "slack", "room_id" => "C123"}

  setup do
    workspace = Path.join("test/tmp", "item_feedback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, workspace)

    :ok = RepoStore.ensure_tree("newsy", {:agent, "newsy"})
    tree = RepoStore.tree_dir("newsy", {:agent, "newsy"})
    File.mkdir_p!(Path.join(tree, "plugins/newsagg/saved"))

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

  defp definition(feedback) do
    %AgentDefinition{
      name: "newsy",
      tools: ["Read"],
      system_prompt: "News agent.",
      repos_write: ["knowledge"],
      feedback: feedback
    }
  end

  defp upvote_config(overrides \\ %{}) do
    Map.merge(
      %{
        content_dir: "/workspace/plugins/newsagg/saved",
        copy_to: "/repos/knowledge/obsidian/shared/sources/articles",
        notify: nil,
        notify_message: nil
      },
      overrides
    )
  end

  defp ctx(vote) do
    %{url: @url, item_type: "article", vote: vote, sender: "sondre", channel: @channel}
  end

  defp write_saved_article(tree) do
    path = Path.join(tree, "plugins/newsagg/saved/some-story.md")
    File.write!(path, "# Some Story\n\nBody text.\n\nSource: #{@url}\n")
    path
  end

  defp copied_article_path do
    Path.join(
      RepoStore.tree_dir(:gw, {:shared, "knowledge"}),
      "obsidian/shared/sources/articles/some-story.md"
    )
  end

  defp read_queue(_workspace) do
    "newsy"
    |> TriOnyx.Workspace.agent_dir()
    |> Path.join("feedback-pending.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  describe "handle_vote/2 dispatch decisions" do
    test "not handled without a feedback config" do
      assert ItemFeedback.handle_vote(definition(nil), ctx("up")) == :not_handled
      assert ItemFeedback.handle_vote(nil, ctx("up")) == :not_handled
    end

    test "not handled for non-vote emojis (voice digests stay agent-handled)" do
      assert ItemFeedback.handle_vote(definition(%{upvote: upvote_config()}), ctx("🔊")) ==
               :not_handled
    end
  end

  describe "vote queueing" do
    test "queues up and down votes as JSONL", %{workspace: workspace} do
      defn = definition(%{upvote: nil})

      assert {:handled, []} = ItemFeedback.handle_vote(defn, ctx("up"))
      assert {:handled, []} = ItemFeedback.handle_vote(defn, ctx("down"))

      assert [up, down] = read_queue(workspace)
      assert %{"vote" => "up", "url" => @url, "sender" => "sondre"} = up
      assert %{"vote" => "down", "item_type" => "article"} = down
      assert up["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "enriches queue line with title from submissions.json", %{workspace: workspace} do
      submissions = [%{"url" => @url, "title" => "[EX] Some Story", "type" => "article"}]

      File.write!(
        Path.join(TriOnyx.Workspace.agent_dir("newsy"), "submissions.json"),
        Jason.encode!(submissions)
      )

      assert {:handled, []} = ItemFeedback.handle_vote(definition(%{upvote: nil}), ctx("up"))
      assert [%{"title" => "[EX] Some Story"}] = read_queue(workspace)
    end

    test "rapid successive votes all land in the queue", %{workspace: workspace} do
      defn = definition(%{upvote: nil})

      for i <- 1..5 do
        assert {:handled, []} =
                 ItemFeedback.handle_vote(defn, %{ctx("up") | url: "#{@url}-#{i}"})
      end

      assert length(read_queue(workspace)) == 5
    end
  end

  describe "upvote actions" do
    test "posts saved content to the channel and copies it", %{workspace: workspace, tree: tree} do
      write_saved_article(tree)
      defn = definition(%{upvote: upvote_config()})

      assert {:handled, [frame]} = ItemFeedback.handle_vote(defn, ctx("up"))

      decoded = Jason.decode!(frame)
      assert decoded["type"] == "agent_text"
      assert decoded["agent_name"] == "newsy"
      assert decoded["channel"] == @channel
      assert decoded["content"] =~ "Body text."
      assert decoded["content"] =~ @url

      copied = copied_article_path()
      assert File.exists?(copied)
      assert File.read!(copied) =~ "Body text."

      # The copy is committed and pushed so peers see it on their next sync
      assert {:ok, files} = RepoStore.ls_tree({:shared, "knowledge"})
      assert "obsidian/shared/sources/articles/some-story.md" in files
    end

    test "downvotes queue but trigger no actions", %{workspace: workspace, tree: tree} do
      write_saved_article(tree)
      defn = definition(%{upvote: upvote_config()})

      assert {:handled, []} = ItemFeedback.handle_vote(defn, ctx("down"))
      refute File.exists?(copied_article_path())
      assert [%{"vote" => "down"}] = read_queue(workspace)
    end

    test "missing saved copy still queues and posts a notice", %{workspace: workspace} do
      defn = definition(%{upvote: upvote_config()})

      assert {:handled, [frame]} = ItemFeedback.handle_vote(defn, ctx("up"))

      assert Jason.decode!(frame)["content"] =~ "no saved copy"
      assert [%{"vote" => "up"}] = read_queue(workspace)
    end

    test "content_dir outside the agent tree is treated as not found", %{tree: tree} do
      write_saved_article(tree)
      defn = definition(%{upvote: upvote_config(%{content_dir: "/workspace/../../../etc"})})

      assert {:handled, [frame]} = ItemFeedback.handle_vote(defn, ctx("up"))
      assert Jason.decode!(frame)["content"] =~ "no saved copy"
    end

    test "queue-only upvote config posts nothing", %{workspace: workspace, tree: tree} do
      write_saved_article(tree)
      defn = definition(%{upvote: nil})

      assert {:handled, []} = ItemFeedback.handle_vote(defn, ctx("up"))
      assert [%{"vote" => "up"}] = read_queue(workspace)
    end
  end

  describe "provenance of shared-repo copies" do
    setup do
      RiskManifest.clear()
      on_exit(fn -> RiskManifest.clear() end)
      :ok
    end

    @source_canonical "agents/newsy/plugins/newsagg/saved/some-story.md"
    @dest_canonical "shared/knowledge/obsidian/shared/sources/articles/some-story.md"

    defp copy_commit_body do
      {out, 0} =
        System.cmd(
          "git",
          [
            "--git-dir",
            RepoStore.bare_dir({:shared, "knowledge"}),
            "log",
            "-1",
            "--format=%an|%B"
          ],
          stderr_to_stdout: true
        )

      out
    end

    test "the copy carries the source file's labels", %{tree: tree} do
      write_saved_article(tree)
      :ok = RiskManifest.put("newsy", [@source_canonical], :high, :medium)

      assert {:handled, [_frame]} =
               ItemFeedback.handle_vote(definition(%{upvote: upvote_config()}), ctx("up"))

      body = copy_commit_body()
      assert body =~ "newsy-feedback|"
      assert body =~ "Taint-Level: high"
      assert body =~ "Sensitivity-Level: medium"

      assert {:ok, %{"taint_level" => "high", "sensitivity_level" => "medium"}} =
               RiskManifest.lookup(@dest_canonical)
    end

    test "an unlabeled source copies at the conservative floor", %{tree: tree} do
      write_saved_article(tree)

      assert {:handled, [_frame]} =
               ItemFeedback.handle_vote(definition(%{upvote: upvote_config()}), ctx("up"))

      body = copy_commit_body()
      assert body =~ "Taint-Level: high"
      assert body =~ "Sensitivity-Level: high"

      assert {:ok, %{"taint_level" => "high", "sensitivity_level" => "high"}} =
               RiskManifest.lookup(@dest_canonical)
    end
  end
end
