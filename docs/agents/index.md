# Agents

TriOnyx ships with the following agent definitions. Each agent runs in its own Docker container with isolated filesystem, network, and tool access.

| Agent | Description | Model | Network |
|-------|-------------|-------|---------|
| [bookmarks](bookmarks.md) | Maintains a structured markdown knowledge base of bookmarks and curated content | sonnet-4-6 | none |
| [cheerleader](cheerleader.md) | Friendly agent that checks in periodically with encouragement and nice things | sonnet-4-6 | none |
| [concierge](concierge.md) | Public-facing assistant for external Slack users | sonnet-4-6 | none |
| [diary](diary.md) | Accepts diary entries and stores them as dated markdown files | haiku-4-5 | none |
| [email](email.md) | Processes email from a personal email account | sonnet-4-6 | none |
| [finn](finn.md) | Browses finn.no via headless Chromium to search listings, track prices, and monitor ads | sonnet-4-6 | outbound |
| [introspector](introspector.md) | System introspection agent that can inspect containers, read source code, and diagnose issues | opus-4-6 | none |
| [linkedin](linkedin.md) | Browses LinkedIn via headless Chromium to read feeds, post, and interact | sonnet-4-6 | outbound |
| [main](main.md) | General-purpose helper with wide tool access but no direct taint sources | sonnet-4-6 | none |
| [news](news.md) | Fetches and formats news headlines from configured sources on demand | sonnet-4-6 | outbound |
| [researcher](researcher.md) | Searches the web and summarizes findings for other agents | haiku-4-5 | outbound |
| [twitter](twitter.md) | Browses X/Twitter via headless Chromium to read feeds, post, and interact | sonnet-4-6 | outbound |
| [webhook-handler](webhook-handler.md) | Processes incoming webhook events from external services | haiku-4-5 | 2 hosts |

## Architecture

All agents communicate through the Elixir/OTP gateway. Inter-agent messaging is governed by `send_to`/`receive_from` declarations, and cross-trust-boundary communication uses the [Bandwidth-Constrained Protocol](../bcp.md). See [Agent Runtime](../agent-runtime.md) for details on how sessions work.
