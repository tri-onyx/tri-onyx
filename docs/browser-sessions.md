# Browser Sessions

Agents with `browser: true` get a headless Chromium browser inside their container. The browser loads a persistent profile from the host, so users can log into sites once and agents reuse the authenticated session.

## How it works

```
Host                                    Agent Container
workspace/browser-sessions/<agent>/  →  /home/tri_onyx/.browser-sessions/  (volume mount)
```

The gateway mounts the agent's session directory into the container. The entrypoint generates a `playwright-cli` config that points to this directory as `userDataDir`. A wrapper script at `/usr/local/bin/browser` passes the config automatically, so agents just run `browser open`, `browser goto https://...`, etc.

## Setting up a session

The `playwright-cli` package is included in the repo at `playwright-cli/`. All commands below are run from the project root.

### 1. Install dependencies (first time only)

```bash
cd playwright-cli && npm install && npx playwright install chromium && cd ..
```

This installs the Playwright npm package and downloads the Chromium browser binary.

### 2. Create the session directory

```bash
mkdir -p workspace/browser-sessions/<agent-name>
```

For example, for the `twitter` agent:

```bash
mkdir -p workspace/browser-sessions/twitter
```

### 3. Open a browser with a persistent profile

```bash
node playwright-cli/playwright-cli.js open --browser=chromium --headed --persistent --profile=workspace/browser-sessions/twitter
```

This opens a visible Chromium window using the profile directory for storage. All cookies, localStorage, and session data are written to this directory.

For convenience, you can alias this:

```bash
alias pcli='node playwright-cli/playwright-cli.js'
pcli open --browser=chromium --persistent --profile=workspace/browser-sessions/twitter
```

### 4. Log in

Navigate to the site (e.g., `https://x.com`) and log in manually. Complete any 2FA prompts. Browse around to confirm the session is working.

### 5. Close the browser

```bash
node playwright-cli/playwright-cli.js close
```

Or just close the window. The profile directory now contains the authenticated session.

### 6. Verify the session persists

Re-open to confirm:

```bash
node playwright-cli/playwright-cli.js open --browser=chromium --headed --persistent --profile=workspace/browser-sessions/twitter
node playwright-cli/playwright-cli.js goto https://x.com/home
node playwright-cli/playwright-cli.js snapshot
node playwright-cli/playwright-cli.js close
```

The snapshot should show the logged-in home timeline.

## Session for multiple sites

A single profile can hold sessions for multiple sites. Just navigate and log in to each one during the setup step. The cookies are scoped per domain.

## Refreshing an expired session

If cookies expire or the site logs you out, repeat steps 3-5. The profile directory is overwritten in place — no need to delete it first.

## Agent definition

Agents that use the browser need three things in their definition:

```yaml
tools: [..., Bash]     # browser CLI is invoked via Bash
network: outbound      # browser needs internet access
browser: true          # tells the sandbox to mount the session directory
```

## How agents use the browser

Inside the container, agents call the `browser` wrapper (which passes the config with the pre-loaded profile):

```bash
browser open https://x.com
browser snapshot
browser click e5
browser fill e3 "hello world"
browser screenshot
browser close
```

Each command returns a snapshot of the page's accessibility tree with element refs (`e1`, `e2`, ...) that the agent uses for subsequent interactions.

## Directory layout

```
workspace/browser-sessions/
  twitter/              # Chromium profile for the twitter agent
    Default/
      Cookies
      Local Storage/
      Session Storage/
      ...
  researcher/           # Chromium profile for the researcher agent
    Default/
      ...
```

These are standard Chromium user data directories. Do not manually edit files inside them.

## Troubleshooting

**Browser opens but not logged in** — The session may have expired. Re-run the setup steps to log in again.

**"browser: command not found" inside container** — The `browser` wrapper is created by the entrypoint only when `TRI_ONYX_BROWSER=true`. Check that the agent definition has `browser: true`.

**Chromium crashes inside container** — The entrypoint passes `--no-sandbox` and `--disable-dev-shm-usage` flags to Chromium. If crashes persist, check that the container has enough memory (Chromium needs ~200-300MB).

**Empty session directory** — If `workspace/browser-sessions/<agent>/` doesn't exist on the host, the volume mount creates an empty directory and the agent gets a fresh (unauthenticated) browser. Create the directory and run the setup steps.
