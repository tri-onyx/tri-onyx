defmodule TriOnyx.Connectors.Social do
  @moduledoc """
  Social media connector for TriOnyx agents.

  Provides posting, replying, feed reading, notification reading, DM reading,
  and scheduled posting across Twitter/X and LinkedIn. Credentials are held by
  the gateway — agents never see API keys or OAuth tokens.

  ## Public API

  - `post/1` — reads a draft JSON file and posts to the platform
  - `reply/1` — reads a draft JSON file and replies to a post
  - `read_feed/2` — reads the timeline/feed for a platform
  - `read_notifications/2` — reads notifications/mentions
  - `read_dms/2` — reads direct messages
  - `schedule_post/1` — reads a draft JSON file and schedules a post

  ## Draft Format

  Draft JSON files must contain at minimum:
  - `platform` — `"twitter"` or `"linkedin"`
  - `text` — the post content

  For replies, also include:
  - `in_reply_to` — the ID of the post being replied to

  For scheduled posts, also include:
  - `scheduled_at` — ISO 8601 datetime for when to publish
  """

  require Logger

  # --- Post ---

  @doc """
  Posts to social media from a draft JSON file.

  Returns `{:ok, post_id}` on success.
  """
  @spec post(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def post(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_draft(contents),
         {:ok, platform} <- extract_platform(draft) do
      dispatch_post(platform, draft)
    end
  end

  # --- Reply ---

  @doc """
  Replies to a social media post from a draft JSON file.

  The draft must include `in_reply_to` with the target post ID.
  Returns `{:ok, reply_id}` on success.
  """
  @spec reply(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def reply(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_draft(contents),
         {:ok, platform} <- extract_platform(draft) do
      unless Map.has_key?(draft, "in_reply_to") do
        {:error, "draft missing required field: in_reply_to"}
      else
        dispatch_reply(platform, draft)
      end
    end
  end

  # --- Read Feed ---

  @doc """
  Reads the social media feed/timeline.

  Params must include `"platform"`. Optional: `"max_results"` (default 20).
  Results are also written to the agent workspace directory.
  Returns `{:ok, [post_map]}` on success.
  """
  @spec read_feed(map(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read_feed(params, agent_dir) do
    with {:ok, platform} <- extract_platform(params) do
      max_results = Map.get(params, "max_results", 20)
      dispatch_read_feed(platform, max_results, agent_dir)
    end
  end

  # --- Read Notifications ---

  @doc """
  Reads social media notifications/mentions.

  Params must include `"platform"`. Optional: `"max_results"` (default 20).
  Returns `{:ok, [notification_map]}` on success.
  """
  @spec read_notifications(map(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read_notifications(params, agent_dir) do
    with {:ok, platform} <- extract_platform(params) do
      max_results = Map.get(params, "max_results", 20)
      dispatch_read_notifications(platform, max_results, agent_dir)
    end
  end

  # --- Read DMs ---

  @doc """
  Reads social media direct messages.

  Params must include `"platform"`. Optional: `"max_results"` (default 20).
  Returns `{:ok, [message_map]}` on success.
  """
  @spec read_dms(map(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read_dms(params, agent_dir) do
    with {:ok, platform} <- extract_platform(params) do
      max_results = Map.get(params, "max_results", 20)
      dispatch_read_dms(platform, max_results, agent_dir)
    end
  end

  # --- Schedule Post ---

  @doc """
  Schedules a social media post from a draft JSON file.

  The draft must include `scheduled_at` with an ISO 8601 datetime.
  Returns `{:ok, scheduled_id}` on success.
  """
  @spec schedule_post(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def schedule_post(host_draft_path) do
    with {:ok, contents} <- read_draft(host_draft_path),
         {:ok, draft} <- parse_draft(contents),
         {:ok, platform} <- extract_platform(draft) do
      unless Map.has_key?(draft, "scheduled_at") do
        {:error, "draft missing required field: scheduled_at"}
      else
        dispatch_schedule_post(platform, draft)
      end
    end
  end

  # --- Private Helpers ---

  @spec read_draft(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_draft(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "failed to read draft: #{inspect(reason)}"}
    end
  end

  @spec parse_draft(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_draft(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = draft} -> {:ok, draft}
      {:ok, _other} -> {:error, "draft must be a JSON object"}
      {:error, reason} -> {:error, "invalid JSON in draft: #{inspect(reason)}"}
    end
  end

  @spec extract_platform(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp extract_platform(%{"platform" => platform}) when platform in ["twitter", "linkedin"] do
    {:ok, platform}
  end

  defp extract_platform(%{"platform" => other}) do
    {:error, "unsupported platform: #{other} (supported: twitter, linkedin)"}
  end

  defp extract_platform(_) do
    {:error, "missing required field: platform"}
  end

  @spec get_config() :: {:ok, map()} | {:error, String.t()}
  defp get_config do
    case Application.get_env(:tri_onyx, :social) do
      nil -> {:error, "social media connector not configured"}
      config -> {:ok, config}
    end
  end

  # --- Platform Dispatch (stubs for Phase 1) ---

  defp dispatch_post("twitter", draft) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      # TODO: Phase 2 — implement Twitter API v2 posting
      text = Map.get(draft, "text", "")
      Logger.info("Social: would post tweet: #{String.slice(text, 0, 50)}...")
      {:error, "twitter posting not yet implemented — draft validated successfully"}
    end
  end

  defp dispatch_post("linkedin", _draft) do
    {:error, "linkedin posting not yet implemented"}
  end

  defp dispatch_reply("twitter", draft) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      Logger.info("Social: would reply to tweet #{draft["in_reply_to"]}")
      {:error, "twitter reply not yet implemented — draft validated successfully"}
    end
  end

  defp dispatch_reply("linkedin", _draft) do
    {:error, "linkedin reply not yet implemented"}
  end

  defp dispatch_read_feed("twitter", max_results, _agent_dir) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      Logger.info("Social: would read twitter feed (max_results=#{max_results})")
      {:error, "twitter feed reading not yet implemented"}
    end
  end

  defp dispatch_read_feed("linkedin", _max_results, _agent_dir) do
    {:error, "linkedin feed reading not yet implemented"}
  end

  defp dispatch_read_notifications("twitter", max_results, _agent_dir) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      Logger.info("Social: would read twitter notifications (max_results=#{max_results})")
      {:error, "twitter notification reading not yet implemented"}
    end
  end

  defp dispatch_read_notifications("linkedin", _max_results, _agent_dir) do
    {:error, "linkedin notification reading not yet implemented"}
  end

  defp dispatch_read_dms("twitter", max_results, _agent_dir) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      Logger.info("Social: would read twitter DMs (max_results=#{max_results})")
      {:error, "twitter DM reading not yet implemented"}
    end
  end

  defp dispatch_read_dms("linkedin", _max_results, _agent_dir) do
    {:error, "linkedin DM reading not yet implemented"}
  end

  defp dispatch_schedule_post("twitter", draft) do
    with {:ok, config} <- get_config(),
         {:ok, _twitter_config} <- get_twitter_config(config) do
      Logger.info("Social: would schedule tweet for #{draft["scheduled_at"]}")
      {:error, "twitter scheduled posting not yet implemented — draft validated successfully"}
    end
  end

  defp dispatch_schedule_post("linkedin", _draft) do
    {:error, "linkedin scheduled posting not yet implemented"}
  end

  @spec get_twitter_config(map()) :: {:ok, map()} | {:error, String.t()}
  defp get_twitter_config(config) do
    case Map.get(config, :twitter) do
      nil -> {:error, "twitter not configured"}
      twitter -> {:ok, twitter}
    end
  end
end

defmodule TriOnyx.Connectors.Social.Poller do
  @moduledoc """
  GenServer polling for new social media notifications and dispatching triggers.

  Periodically checks for new mentions, replies, and DMs on configured social
  media platforms and dispatches triggers to the social agent.
  """

  use GenServer

  require Logger

  # alias TriOnyx.TriggerRouter  # TODO: Phase 2 — dispatch triggers on new mentions

  defstruct [:config, :agent_name, :poll_interval_ms, :timer_ref]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case Application.get_env(:tri_onyx, :social) do
      nil ->
        {:stop, :social_not_configured}

      config ->
        twitter = Map.get(config, :twitter, %{})

        state = %__MODULE__{
          config: config,
          agent_name: Map.get(twitter, :agent_name, "social"),
          poll_interval_ms: Map.get(twitter, :poll_interval_ms, 300_000)
        }

        send(self(), :poll)
        Logger.info("Social.Poller started (interval=#{state.poll_interval_ms}ms)")
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = do_poll(state)
    {:noreply, schedule_poll(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_poll(state) do
    # TODO: Phase 2 — check for new mentions/DMs via Twitter API
    # When implemented, this will:
    # 1. Fetch new mentions since last poll
    # 2. Write mention JSON files to workspace/agents/social/notifications/
    # 3. Dispatch trigger to the social agent
    Logger.debug("Social.Poller: poll cycle (no-op until Twitter API is implemented)")
    state
  end

  defp schedule_poll(state) do
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %{state | timer_ref: ref}
  end
end
