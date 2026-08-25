defmodule TriOnyx.ItemFeedback do
  @moduledoc """
  Deterministic handling of item feedback reactions (👍/👎 on submitted items).

  Agents that declare a `feedback:` block in their definition get up/down
  votes on their submitted items handled entirely in the gateway — no agent
  session is spawned per reaction:

    * every vote is appended to `agents/<name>/feedback-pending.jsonl` in
      the workspace; the agent folds these into its preferences on its next
      scheduled run
    * on an upvote, the configured actions run immediately: the saved item's
      content is posted back to the channel (`content_dir`), the file is
      copied to a share directory (`copy_to`), and a peer agent is notified
      (`notify` / `notify_message`)

  Reactions with other emojis (e.g. 🔊 voice digests) and agents without a
  `feedback:` block keep the prompt-dispatch path in `ConnectorHandler`.

  Directory values are container paths as seen by the owning agent:
  `/workspace/...` for its own repo (e.g. `/workspace/plugins/newsagg/saved`)
  or `/repos/<name>/...` for a shared repo the agent has been granted.
  Reads resolve against the corresponding working tree; writes into a
  shared repo go through the gateway's tree and are committed + pushed
  immediately so notified peers see the file on their next sync. A copy
  carries its source's risk labels (`Workspace.labels_for/1`) into the
  destination repo's commit trailers and risk-manifest entry — copying a
  file must not launder its provenance.
  """

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.RepoStore
  alias TriOnyx.RiskManifest
  alias TriOnyx.Triggers.InterAgent
  alias TriOnyx.Workspace

  @queue_file "feedback-pending.jsonl"

  @typedoc "Reaction context extracted from the connector frame."
  @type vote_ctx :: %{
          url: String.t(),
          item_type: String.t(),
          vote: String.t(),
          sender: String.t(),
          channel: map()
        }

  @doc """
  Handles an up/down vote deterministically.

  Returns `{:handled, frames}` where `frames` are encoded connector frames to
  push on the reaction's websocket (may be empty), or `:not_handled` when the
  agent has no `feedback:` config or the vote isn't an up/down vote.
  """
  @spec handle_vote(AgentDefinition.t() | nil, vote_ctx()) ::
          {:handled, [binary()]} | :not_handled
  def handle_vote(nil, _ctx), do: :not_handled
  def handle_vote(%AgentDefinition{feedback: nil}, _ctx), do: :not_handled

  def handle_vote(%AgentDefinition{feedback: feedback} = definition, %{vote: vote} = ctx)
      when vote in ["up", "down"] do
    title = lookup_title(definition.name, ctx.url)
    queue_vote(definition.name, ctx, title)

    frames =
      case {vote, feedback[:upvote]} do
        {"up", %{} = action} -> run_upvote_actions(definition, action, ctx, title)
        _ -> []
      end

    {:handled, frames}
  end

  def handle_vote(_definition, _ctx), do: :not_handled

  @doc """
  Returns the host path of an agent's pending-feedback queue file (inside
  the agent's own working tree).
  """
  @spec queue_path(String.t()) :: String.t()
  def queue_path(agent_name) do
    Path.join(Workspace.agent_dir(agent_name), @queue_file)
  end

  # --- Vote queue ---

  # Appends one JSON line per vote. The agent processes and truncates the
  # file on its next scheduled run, so ordering and durability matter more
  # than structure — flat map, ISO timestamp.
  defp queue_vote(agent_name, ctx, title) do
    path = queue_path(agent_name)
    File.mkdir_p!(Path.dirname(path))

    line =
      Jason.encode!(%{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "vote" => ctx.vote,
        "item_type" => ctx.item_type,
        "url" => ctx.url,
        "title" => title,
        "sender" => ctx.sender
      })

    File.write!(path, line <> "\n", [:append])
    # The gateway may run as a different user than the agent container;
    # the agent must be able to truncate the queue after processing it.
    File.chmod(path, 0o666)
  end

  # Title lookup from the runtime-maintained submissions ledger; purely an
  # enrichment so the queued line is self-describing — nil is fine.
  defp lookup_title(agent_name, url) do
    path = Path.join(Workspace.agent_dir(agent_name), "submissions.json")

    with {:ok, raw} <- File.read(path),
         {:ok, submissions} when is_list(submissions) <- Jason.decode(raw),
         %{"title" => title} <- Enum.find(submissions, &(&1["url"] == url)) do
      title
    else
      _ -> nil
    end
  end

  # --- Upvote actions ---

  defp run_upvote_actions(definition, action, ctx, title) do
    case find_item_file(definition, action[:content_dir], ctx.url) do
      {:ok, file_path} ->
        maybe_copy(definition, action[:copy_to], file_path, action[:content_dir])
        maybe_notify(definition.name, action, Path.basename(file_path))
        [content_frame(definition.name, file_path, ctx, title)]

      :not_found ->
        Logger.warning(
          "ItemFeedback: no saved copy for #{ctx.url} under #{inspect(action[:content_dir])}"
        )

        [text_frame(definition.name, ctx.channel, missing_copy_text(ctx.url))]
    end
  end

  # Scans the configured directory for the file containing the item URL.
  # Saved items always embed their source URL, so a plain content match is
  # the deterministic equivalent of the slug bookkeeping the agent used to do.
  defp find_item_file(_definition, nil, _url), do: :not_found

  defp find_item_file(definition, dir, url) do
    with {:ok, abs_dir} <- resolve_read_dir(definition, dir),
         {:ok, entries} <- File.ls(abs_dir) do
      entries
      |> Enum.sort()
      |> Enum.map(&Path.join(abs_dir, &1))
      |> Enum.find(fn path ->
        case File.read(path) do
          {:ok, content} -> String.contains?(content, url)
          _ -> false
        end
      end)
      |> case do
        nil -> :not_found
        path -> {:ok, path}
      end
    else
      _ -> :not_found
    end
  end

  defp maybe_copy(_definition, nil, _file_path, _source_dir), do: :ok

  # Copies into the agent's own repo tree (picked up by the next
  # session-end commit or the sweeper), or into a shared repo via the
  # gateway tree with an immediate commit + push — the notified peer's
  # next session-start sync sees the file.
  defp maybe_copy(definition, dest_dir, file_path, source_dir) do
    case resolve_write_dir(definition, dest_dir) do
      {:ok, :agent_tree, abs_dir} ->
        # Stays inside the agent's own repo: the session-end commit (or the
        # sweeper) labels it with the session's own levels.
        with :ok <- File.mkdir_p(abs_dir),
             :ok <- File.cp(file_path, Path.join(abs_dir, Path.basename(file_path))) do
          :ok
        else
          error ->
            Logger.warning("ItemFeedback: copy to #{dest_dir} failed: #{inspect(error)}")
            :ok
        end

      {:ok, {:shared_repo, repo_id, rel_dir}, _} ->
        copy_into_shared_repo(definition, repo_id, rel_dir, file_path, source_dir)

      error ->
        Logger.warning("ItemFeedback: copy to #{dest_dir} rejected: #{inspect(error)}")
        :ok
    end
  end

  # Crossing a repo boundary is a labeled write: the destination inherits
  # the source file's manifest labels (conservative floor when the source
  # has none), recorded both as commit trailers — the durable record
  # RiskManifest replays — and as a manifest entry for the new path.
  defp copy_into_shared_repo(definition, repo_id, rel_dir, file_path, source_dir) do
    filename = Path.basename(file_path)
    rel_path = Path.join(rel_dir, filename)
    author = "#{definition.name}-feedback"
    {taint, sensitivity} = source_labels(definition, source_dir, filename)

    with :ok <- RepoStore.sync_tree(:gw, repo_id),
         gw_tree = RepoStore.tree_dir(:gw, repo_id),
         abs_dir = Path.join(gw_tree, rel_dir),
         :ok <- File.mkdir_p(abs_dir),
         :ok <- File.cp(file_path, Path.join(abs_dir, filename)),
         {:ok, sha} when is_binary(sha) <-
           RepoStore.commit_and_push(:gw, repo_id,
             author: author,
             message: "#{definition.name} feedback: file #{filename}",
             trailers: ["Taint-Level: #{taint}", "Sensitivity-Level: #{sensitivity}"],
             session_id: "feedback",
             paths: [rel_path]
           ) do
      canonical = Workspace.canonical_for_repo(repo_id, rel_path)
      RiskManifest.put(author, [canonical], taint, sensitivity)
      :ok
    else
      {:ok, :no_changes} ->
        :ok

      error ->
        Logger.warning(
          "ItemFeedback: shared-repo copy to #{RepoStore.ref(repo_id)} failed: #{inspect(error)}"
        )

        :ok
    end
  end

  # Labels of the file being copied, looked up by its canonical path. The
  # source dir is the owning agent's container view, so the canonical path
  # is derived the same way agent writes are.
  defp source_labels(definition, source_dir, filename) do
    with dir when is_binary(dir) <- source_dir,
         {:ok, canonical} <-
           Workspace.canonical_path(definition.name, Path.join(dir, filename)) do
      Workspace.labels_for(canonical)
    else
      _ -> Workspace.unlabeled_levels()
    end
  end

  defp maybe_notify(_agent_name, %{notify: nil}, _filename), do: :ok

  defp maybe_notify(agent_name, %{notify: to, notify_message: template}, filename)
       when is_binary(to) and is_binary(template) do
    text = String.replace(template, "{file}", filename)

    # Fire-and-forget: the notify spawns/routes to a peer agent session and
    # must not delay pushing the content frame back to the user.
    Task.start(fn ->
      message = %{
        from: agent_name,
        to: to,
        message_type: "notification",
        payload: %{"text" => text}
      }

      case InterAgent.route(message) do
        {:ok, _pid} ->
          Logger.info("ItemFeedback: notified #{to} (#{text})")

        {:error, reason} ->
          Logger.warning("ItemFeedback: notify #{to} failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp maybe_notify(_agent_name, _action, _filename), do: :ok

  # --- Frames ---

  defp content_frame(agent_name, file_path, ctx, title) do
    content =
      case File.read(file_path) do
        {:ok, body} -> "👍 **#{title || ctx.url}**\n\n#{body}\n\n🔗 #{ctx.url}"
        {:error, _} -> missing_copy_text(ctx.url)
      end

    text_frame(agent_name, ctx.channel, content)
  end

  defp missing_copy_text(url) do
    "👍 Feedback recorded, but no saved copy was found for #{url}."
  end

  defp text_frame(agent_name, channel, content) do
    Jason.encode!(%{
      "type" => "agent_text",
      "agent_name" => agent_name,
      "session_id" => "item-feedback",
      "content" => content,
      "channel" => channel
    })
  end

  # --- Path resolution ---

  # Feedback config dirs use the owning agent's container view. Reads may
  # target the agent's own tree or any repo it can read; the resolved path
  # is confined to that tree.
  defp resolve_read_dir(definition, "/workspace/" <> rest) do
    confine(Workspace.agent_dir(definition.name), rest, :agent_tree)
  end

  defp resolve_read_dir(definition, "/repos/" <> rest) do
    with {:ok, repo_id, rel} <- split_repo_path(rest) do
      %{write: write, read: read} = RepoStore.grants(definition)

      cond do
        repo_id in write -> confine(RepoStore.tree_dir(definition.name, repo_id), rel, :repo_tree)
        repo_id in read -> confine(RepoStore.tree_dir(:ro, repo_id), rel, :repo_tree)
        true -> {:error, :repo_not_granted}
      end
    end
  end

  defp resolve_read_dir(_definition, _), do: {:error, :invalid_dir}

  # Writes may target the agent's own tree, or a shared repo the agent
  # holds a write grant for (routed through the gateway tree by the caller).
  defp resolve_write_dir(definition, "/workspace/" <> rest) do
    case confine(Workspace.agent_dir(definition.name), rest, :agent_tree) do
      {:ok, abs} -> {:ok, :agent_tree, abs}
      error -> error
    end
  end

  defp resolve_write_dir(definition, "/repos/" <> rest) do
    with {:ok, repo_id, rel} <- split_repo_path(rest),
         %{write: write} = RepoStore.grants(definition),
         true <- repo_id in write or {:error, :repo_not_granted},
         {:ok, _abs} <- confine(RepoStore.tree_dir(:gw, repo_id), rel, :repo_tree) do
      {:ok, {:shared_repo, repo_id, rel}, nil}
    else
      _ -> {:error, :invalid_dir}
    end
  end

  defp resolve_write_dir(_definition, _), do: {:error, :invalid_dir}

  defp split_repo_path("agents/" <> _), do: {:error, :agent_repo_not_allowed}

  defp split_repo_path(rest) do
    case String.split(rest, "/", parts: 2) do
      [name, rel] when name != "" and rel != "" -> {:ok, {:shared, name}, rel}
      _ -> {:error, :invalid_dir}
    end
  end

  defp confine(base, rel, _kind) do
    base = Path.expand(base)
    abs = Path.join(base, rel) |> Path.expand()

    if String.starts_with?(abs, base <> "/") do
      {:ok, abs}
    else
      {:error, :outside_tree}
    end
  end
end
