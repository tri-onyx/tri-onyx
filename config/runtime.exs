import Config

# Runtime configuration from environment variables
# These are read at application startup, not compile time

# Only override from env vars when not in test (test uses config/test.exs values)
unless config_env() == :test do
  config :tri_onyx,
    agents_dir: System.get_env("TRI_ONYX_AGENTS_DIR", "./workspace/agent-definitions"),
    audit_dir: System.get_env("TRI_ONYX_AUDIT_DIR", "~/.tri-onyx/audit"),
    workspace_dir: System.get_env("TRI_ONYX_WORKSPACE_DIR", "./workspace"),
    port: String.to_integer(System.get_env("TRI_ONYX_PORT", "4000"))
end

# Claude API token — passed through to agent runtime processes
if token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN") do
  config :tri_onyx, claude_token: token
end

# Shared secret for connector authentication
if connector_token = System.get_env("TRI_ONYX_CONNECTOR_TOKEN") do
  config :tri_onyx, connector_token: connector_token
end

# Email connector — IMAP polling + SMTP sending
# Only enabled when TRI_ONYX_IMAP_HOST is set
if imap_host = System.get_env("TRI_ONYX_IMAP_HOST") do
  config :tri_onyx, :email,
    imap: %{
      host: imap_host,
      port: String.to_integer(System.get_env("TRI_ONYX_IMAP_PORT", "993")),
      username: System.get_env("TRI_ONYX_IMAP_USERNAME", ""),
      password: System.get_env("TRI_ONYX_IMAP_PASSWORD", ""),
      ssl: System.get_env("TRI_ONYX_IMAP_SSL", "true") == "true",
      poll_interval_ms:
        String.to_integer(System.get_env("TRI_ONYX_IMAP_POLL_INTERVAL", "300000")),
      agent_name: System.get_env("TRI_ONYX_EMAIL_AGENT", "email")
    },
    smtp: %{
      host: System.get_env("TRI_ONYX_SMTP_HOST", imap_host),
      port: String.to_integer(System.get_env("TRI_ONYX_SMTP_PORT", "587")),
      username:
        System.get_env(
          "TRI_ONYX_SMTP_USERNAME",
          System.get_env("TRI_ONYX_IMAP_USERNAME", "")
        ),
      password:
        System.get_env(
          "TRI_ONYX_SMTP_PASSWORD",
          System.get_env("TRI_ONYX_IMAP_PASSWORD", "")
        ),
      ssl: System.get_env("TRI_ONYX_SMTP_SSL", "true") == "true"
    }
end

# Calendar connector — CalDAV polling + event management
# Only enabled when TRI_ONYX_CALDAV_URL is set
if caldav_url = System.get_env("TRI_ONYX_CALDAV_URL") do
  config :tri_onyx, :calendar,
    caldav: %{
      url: caldav_url,
      username: System.get_env("TRI_ONYX_CALDAV_USERNAME", ""),
      password: System.get_env("TRI_ONYX_CALDAV_PASSWORD", ""),
      calendar_base_path:
        System.get_env(
          "TRI_ONYX_CALDAV_BASE_PATH",
          "/caldav"
        ),
      calendars:
        System.get_env("TRI_ONYX_CALDAV_CALENDARS", "personal")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1),
      poll_interval_ms:
        String.to_integer(System.get_env("TRI_ONYX_CALDAV_POLL_INTERVAL", "900000")),
      agent_name: System.get_env("TRI_ONYX_CALENDAR_AGENT", "calendar")
    }
end

# Social media connector — Twitter/X + LinkedIn
# Only enabled when TRI_ONYX_TWITTER_API_KEY is set
if twitter_api_key = System.get_env("TRI_ONYX_TWITTER_API_KEY") do
  config :tri_onyx, :social,
    twitter: %{
      api_key: twitter_api_key,
      api_secret: System.get_env("TRI_ONYX_TWITTER_API_SECRET", ""),
      access_token: System.get_env("TRI_ONYX_TWITTER_ACCESS_TOKEN", ""),
      access_token_secret: System.get_env("TRI_ONYX_TWITTER_ACCESS_TOKEN_SECRET", ""),
      bearer_token: System.get_env("TRI_ONYX_TWITTER_BEARER_TOKEN", ""),
      poll_interval_ms:
        String.to_integer(System.get_env("TRI_ONYX_SOCIAL_POLL_INTERVAL", "300000")),
      agent_name: System.get_env("TRI_ONYX_SOCIAL_AGENT", "social")
    }
end
