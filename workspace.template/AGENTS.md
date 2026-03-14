# Agents

<!-- Agent roster and routing metadata -->

## Routing Rules

These rules govern how the main agent delegates to specialized agents. Follow them before deciding to handle a request inline.

| Topic / Request Type | Route To | Notes |
|---|---|---|
| News articles, news pieces, current events | **news agent** | Do not query researcher directly for news. Always delegate to the news agent. |
| Bookmarks, saving links, curating content | **bookmarks agent** | Send URLs and tags via SendMessage. The bookmarks agent enriches them via BCP queries to the researcher. |

## Routing Guidance

- **News queries**: When Sondre asks about a news article, news piece, or anything resembling current events coverage, route to the **news agent** — not the researcher. This applies even if the query looks like general research.
- When in doubt about routing, check this table before defaulting to inline handling or researcher delegation.
