# Agents

TriOnyx ships with the following agent definitions. Each agent runs in its own Docker container with isolated filesystem, network, and tool access.

## Agent roster

<div class="tx-agent-grid">
  <div class="tx-agent-card" onclick="location.href='main/'">
    <div class="tx-agent-card__name"><a href="main/">main</a></div>
    <div class="tx-agent-card__desc">General-purpose helper with wide tool access but no direct taint sources</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='introspector/'">
    <div class="tx-agent-card__name"><a href="introspector/">introspector</a></div>
    <div class="tx-agent-card__desc">System introspection agent that inspects containers, reads source code, and diagnoses issues</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">opus-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='researcher/'">
    <div class="tx-agent-card__name"><a href="researcher/">researcher</a></div>
    <div class="tx-agent-card__desc">Searches the web and summarizes findings for other agents via BCP</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">haiku-4-5</span><span class="tx-badge tx-badge--network-outbound">outbound</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='email/'">
    <div class="tx-agent-card__name"><a href="email/">email</a></div>
    <div class="tx-agent-card__desc">Processes email from a personal email account</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='news/'">
    <div class="tx-agent-card__name"><a href="news/">news</a></div>
    <div class="tx-agent-card__desc">Fetches and formats news headlines from configured sources on demand</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-outbound">outbound</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='twitter/'">
    <div class="tx-agent-card__name"><a href="twitter/">twitter</a></div>
    <div class="tx-agent-card__desc">Browses X/Twitter via headless Chromium to read feeds, post, and interact</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-outbound">outbound</span><span class="tx-badge tx-badge--browser">browser</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='linkedin/'">
    <div class="tx-agent-card__name"><a href="linkedin/">linkedin</a></div>
    <div class="tx-agent-card__desc">Browses LinkedIn via headless Chromium to read feeds, post, and interact</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-outbound">outbound</span><span class="tx-badge tx-badge--browser">browser</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='finn/'">
    <div class="tx-agent-card__name"><a href="finn/">finn</a></div>
    <div class="tx-agent-card__desc">Browses finn.no via headless Chromium to search listings and track prices</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-outbound">outbound</span><span class="tx-badge tx-badge--browser">browser</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='concierge/'">
    <div class="tx-agent-card__name"><a href="concierge/">concierge</a></div>
    <div class="tx-agent-card__desc">Public-facing assistant for external Slack users</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='bookmarks/'">
    <div class="tx-agent-card__name"><a href="bookmarks/">bookmarks</a></div>
    <div class="tx-agent-card__desc">Maintains a structured markdown knowledge base of bookmarks and curated content</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='diary/'">
    <div class="tx-agent-card__name"><a href="diary/">diary</a></div>
    <div class="tx-agent-card__desc">Accepts diary entries and stores them as dated markdown files</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">haiku-4-5</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='cheerleader/'">
    <div class="tx-agent-card__name"><a href="cheerleader/">cheerleader</a></div>
    <div class="tx-agent-card__desc">Friendly agent that checks in periodically with encouragement</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">sonnet-4-6</span><span class="tx-badge tx-badge--network-none">no network</span></div>
  </div>
  <div class="tx-agent-card" onclick="location.href='webhook-handler/'">
    <div class="tx-agent-card__name"><a href="webhook-handler/">webhook-handler</a></div>
    <div class="tx-agent-card__desc">Processes incoming webhook events from external services</div>
    <div class="tx-badges"><span class="tx-badge tx-badge--model">haiku-4-5</span><span class="tx-badge tx-badge--network-restricted">2 hosts</span></div>
  </div>
</div>

## Architecture

All agents communicate through the Elixir/OTP gateway. Inter-agent messaging is governed by `send_to`/`receive_from` declarations, and cross-trust-boundary communication uses the [Bandwidth-Constrained Protocol](../bcp.md).

!!! info "How agent sessions work"
    See [Agent Runtime](../agent-runtime.md) for details on the execution lifecycle, tool enforcement, and taint tracking.
