# MemVault — Design

Status: local-execution v1 built and smoke-tested. This doc is the design record —
what was decided, why, and what's still open — for the tooling in this repo. For
hands-on setup, see `README.md`; for what's verified vs. still needs manual
checking, see `TESTING.md`.

## 1. Purpose

A personal/professional knowledge vault to capture synthesized understanding from
daily learning — typically produced by agentically "interrogating" a source (docs,
articles, PDFs, YouTube, handwritten notes) until a clear mental model emerges —
plus the source material itself, kept queryable and graph-connected, and reachable
from whichever AI agent/model the user is working in, including from a phone.

## 2. Hard requirements

- **Markdown is the source of truth.** No proprietary/opaque storage format.
- **Self-hosted.** No SaaS product holds the data. (One deliberate, narrow exception
  made since — see §3b.)
- **No third party gets data access** beyond the model/agent the user explicitly
  chooses for a given task. Concretely:
  - Anthropic is an accepted processor *only* when Claude is the chosen model (mobile
    relay through Anthropic's infra counts as the same accepted party, not a new one).
  - A local model (via mlx-serve, accessed through OpenCode) is the zero-network-egress
    alternative.
  - Any other party (hosting providers, SaaS wrappers, analytics) is out of scope by
    default and must be called out explicitly if a design needs one.
- **MCP-native agent access.** No dedicated vault app (explicitly not building a GUI —
  Obsidian was considered and dropped; access is agentic-only).
- **Supports professional/commercial use**, not just personal knowledge.
- **Graph-connected**, not a flat store: notes reference each other, and the system must
  support reverse lookups ("what points to this") without hand-built tooling.
- **No auto-archiving.** Only deliberate, "questioned" (interrogated-and-synthesized)
  summaries get written in. No passive session capture, no background scraping.

## 3. Two independent vault stacks

Not one vault with two projects — two fully separate stacks, each with its own
directory, own Basic Memory instance, own git repo, own git history, and **its own
Claude subscription/account**. No agent or session in one stack ever has access to the
other.

The actual isolation mechanism, confirmed by direct testing, not assumed: Basic
Memory's project registry is normally a single shared list across everything on a
machine. Real isolation comes from `BASIC_MEMORY_CONFIG_DIR`, which relocates the
entire config/index for a process, not just which project is "current" — without it,
a client on one vault could still call `list_memory_projects` and see the other
vault's name and path. `memvault-infra` gives every vault its own value for this.
Client sessions can still be *configured* to point at both vaults at once regardless
of server-side isolation — that's a client-discipline question, documented per-vault
in each vault's generated `INTEGRATIONS.md`, not something enforced by the infra.

### 3a. Work vault
- **Use case:** professional/commercial knowledge.
- **Access:** local tools only — Claude Code, Claude Desktop, Open WebUI (OWUI), Zed,
  OpenCode. No internet exposure at all, no mobile access, no cloud services of any
  kind — no exception has been made here, unlike the personal vault (§3b).
- **Git remote:** the company's own git hosting (internal infra, governed by whatever
  IT/security policy already applies — **still OPEN: confirm with employer's IT/security
  before storing work knowledge here**, especially given the tool is community-maintained
  open source and may be locally modified. This is the one remaining item that gates
  actually using this vault for real work content, not a technical blocker — the stack
  itself is built and works).

### 3b. Personal vault
- **Use case:** lower-stakes personal knowledge.
- **Access:** local tools (same as work vault) **plus mobile**.
- **Git remote:** the user's own GitHub. A deliberate, conscious exception to the
  no-third-party rule, accepted specifically because this vault is lower-stakes.
  (Do not extend this exception to the work vault.)
- **Mobile access: Basic Memory Cloud**, adopted as the near-term plan. A published
  connector in Claude's own directory (Claude Directory → search "Basic Memory Cloud"
  → Install → authorize) handles the OAuth 2.1 hosted-redirect flow end to end — no
  self-hosted gateway, no OIDC provider, no owned hardware. Works across Claude web,
  desktop, mobile, and Claude Code once authorized. This is a **second** deliberate,
  conscious exception to the no-third-party rule, scoped to the personal vault only,
  accepted specifically to validate the mobile capture/write UX before investing in
  self-hosted infrastructure for it.
  - **Why not a read-only on-device alternative instead** (e.g. Noema/LocalRAG doing
    on-device RAG over a synced copy of the vault, zero network calls at all):
    considered and explicitly rejected. It only ever solves retrieval/search, never
    capture — the actual want is authoring/saving notes from the Claude app on mobile,
    which a read-only tool can never do regardless of how well it searches. Adopting it
    wouldn't have reduced the work needed for the real requirement, just added a second,
    unrelated tool.
  - **Not locked in:** `bm cloud push` / `bm cloud pull` sync bidirectionally, plain
    markdown preserved throughout; `bm project set-cloud <name>` / `set-local` toggles a
    project's routing; ZIP export also available. Confirmed in Basic Memory's own docs.
  - **OPEN: pricing not published** — only "active subscription required" anywhere in
    the docs. Confirm actual cost at basicmemory.com/subscribe before treating this as
    a long-term arrangement rather than a trial.
  - **OPEN: no documented conflict resolution** for simultaneous local + cloud edits.
    Discipline until resolved: don't route a project through `bm cloud` while also
    running `memvault-infra`'s own git watcher against the same directory — that's two
    independent, uncoordinated sync mechanisms on one directory, the same two-writer
    risk the deferred self-hosted plan below was already careful about, just via
    `bm cloud push/pull` instead of raw git.
  - **Deferred, not abandoned: self-hosted always-on-host plan.** ContextForge (gateway,
    virtual-server tool scoping) + Pocket-ID (self-hosted OIDC provider), on hardware the
    user actually owns (not a rented VPS, which would reintroduce a real third party with
    hypervisor-level disk access) — documented working for Claude on iOS/Desktop/web as
    the fallback if Cloud's cost/trust tradeoff stops being worth it, or once the
    desired mobile feature set is validated and worth re-implementing without the third
    party. Specifics preserved in git history of this doc rather than re-stated here in
    full, since it's not the active plan; the short version: GitHub is the sync hub
    (git remote) between laptop and host, never the compute host itself — no GitHub
    product runs an arbitrary always-on server for you (Actions is ephemeral,
    Codespaces auto-suspends); the host needs to be reachable via a public HTTPS
    endpoint (Cloudflare Tunnel vs. self-hosted WireGuard still undecided); sizing is
    driven by whichever LLM runs on the box, not by Basic Memory's own CPU-only
    FastEmbed search embeddings, which are negligible; and a second writer (mobile via
    the host, alongside the laptop) needs pull-before-write discipline to avoid merge
    conflicts.

### Cross-vault bridging (manual only, by design)
- No auto-sync, no shared context, no single agent ever sees both.
- **Mechanism:** copy the relevant markdown file(s) directly from one vault's directory
  into the other's, then commit in the destination repo. Basic Memory's background file
  watcher picks up externally-added/modified files automatically — no manual reindex
  step needed.
- **Cross-vault relation refs go dangling.** Each vault's graph is scoped to its own
  directory; a `relates_to [[note]]` line copied into the other vault won't resolve
  unless the target note is copied too. Handle per-case: strip the ref, bundle the
  referenced note(s) along with it, or leave a plain-text stub noting where full context
  lives.

## 4. Core technology choices

### Basic Memory (basicmachines-co) — the MCP layer
- Markdown files on disk are canonical; SQLite (FTS + metadata index) and vector
  embeddings (FastEmbed, CPU-only, no GPU needed) are derived/rebuildable.
- MCP tools actually used: `write_note`, `edit_note`, `read_note`, `search_notes`,
  `build_context`, `delete_note`, `list_memory_projects`. `write_note` takes
  structured params (`title`, `content`, `directory`, `tags`, `note_type`, a
  `metadata` dict for custom frontmatter) — it does **not** take hand-authored YAML
  frontmatter in `content`. This tripped up the first version of the note-writing
  skill; confirmed and fixed by directly testing real `write_note` calls, not by
  reading docs alone.
- **Relations**: written as wiki-links in the note body (`relates_to [[Target]]`).
  Reverse index (backlinks) is computed automatically — the target note does not need
  a matching line, and inverse relation types (`extended_by`, etc.) should never be
  hand-written for the same reason. **Forward references are supported**: linking to a
  note that doesn't exist yet stores an unresolved relation; it resolves automatically
  once the target note is created. Confirmed by direct testing (a forward reference
  correctly showed "Resolved: 0 / Unresolved: 1" immediately after `write_note`).
- **Tags**: first-class frontmatter field, server-indexed, queryable directly.
- **No git integration** — confirmed from their own docs. Git is a fully separate,
  orthogonal layer run on the same directory.
- **License: AGPL-3.0.** Not a constraint here — network copyleft only triggers if a
  modified version is offered as a network service to *other* users. Local
  self-hosted use, including in a professional context, and local modification of the
  source, does not trigger it.
- **No native graph algorithms.** If wanted later, build as an external script reading
  the local SQLite DB directly. Not needed at expected vault scale — still
  deprioritized.
- **Official skill package exists but isn't used as-is.** Checked directly: it does
  **not** instruct the agent to check existing tags/relations before minting new ones
  — it explicitly favors free-form vocabulary ("no fixed list, use whatever's
  descriptive"). `memvault-infra` ships its own skill (`memnote`, below) instead of
  forking or extending the official one.

### The `memnote` skill
Lives at `skills/memnote/SKILL.md` in `memvault-infra`, copied into
`.claude/skills/memnote/` on every vault by the installer, and portable to every
other client without format conversion: Zed imports it directly by URL
(`agent: create skill from url` in the command palette), pointed at the local
`file://` copy the installer already placed in the vault — **not** a
`raw.githubusercontent.com` URL, which 404s unauthenticated against this
private repo (Zed's URL import has no GitHub auth of its own; `gh repo clone`
during install is what actually fetched the file, so no further fetch is
needed). Open WebUI takes the same file pasted as a custom skill in its
Skills workspace.
AI-facing docs are written terse and directive, not explanatory — rationale for *why*
belongs in this design doc and commit messages, not in a file an agent parses as
instructions.

**Frontmatter schema (fixed, finalized):**

| Field | Notes |
|---|---|
| `title`, `tags` | passed as top-level `write_note` params |
| `type` | always `summary`, no other values in v1 |
| `date` | note creation date, **immutable** — never updated on edit. Not auto-populated by Basic Memory; must be passed explicitly. Edit history lives in git, not this field. |
| `source_path` / `source_url` | mutually exclusive. `source_path`: repo-relative, for a file dropped directly in the vault (git-tracked). `source_url`: a web article, or a file in already-approved external storage (company OneDrive/SharePoint, personal cloud) that isn't in the repo — a share link counts as a URL. |
| `source_published_date` / `source_updated_date` | both optional, best-effort only from whatever the source already exposes (Open Graph tags, JSON-LD, PDF metadata, a visible byline) — no dedicated extraction step. Deliberately *not* mirrored for local files: git already versions those, so a hand-maintained hash/date would just duplicate what git gives for free. Kept for URLs specifically because git has no visibility into a page it doesn't control. |

Directory convention: `Sources/<slug>/` — the note and, if kept, the raw source file
live together there.

**Relation vocabulary (fixed, finalized):** `relates_to` (neutral), `extends`
(positive), `contradicts` (negative — both notes remain valid, unresolved tension),
`supersedes` (temporal — this note replaces the target as current understanding; use
instead of `contradicts` when the target is just an earlier, weaker pass at the same
topic. Added deliberately because the "no auto-archiving" rule means superseded notes
are never deleted — `supersedes` is how staleness gets marked without deleting
history). Kept to four on purpose: richer vocabulary was tempting but directly
increases the vocabulary-drift surface the whole schema exists to avoid.

**Large source files:** if a file to drop in the vault is large enough to matter
(rule of thumb >50MB), the skill stops and flags it rather than committing silently.
Explicitly rejected: reaching for a raw blob store (S3 or similar) as the fallback —
that would reintroduce a new, unvetted third party outside the trust boundary in §2.
Acceptable options: reference via `source_url` pointing at storage already approved
(company OneDrive/SharePoint for the work vault — folds into the same IT/security
conversation as the git remote, not a separate approval; the user's own trusted
storage for the personal vault), or git-lfs for that one file if keeping it in-repo
matters more.

**Vocabulary discipline** (tags and relation types both): not enforced by Basic
Memory itself. The skill instructs `search_notes` before minting a new tag; periodic
drift cleanup is a defragmentation pass, not something prevented at write time.

### Git — versioning/audit layer
- One repo per vault, entirely independent histories.
- **Raw source docs: plain git, not git-lfs, not outside-git.** Decided: since raw
  docs are already reference-only and never embedded, and mobile access only ever
  needs the markdown, LFS didn't unlock anything real — it would only have added
  tooling and (for the personal vault specifically) real GitHub LFS billing exposure
  once the always-on host started pulling on an interval. The tradeoff accepted: a
  deleted large file's bytes stay in git history permanently unless rewritten with
  `git filter-repo`. Not solved preemptively; handled case-by-case if it ever
  actually matters (see "large source files" above).
- **Auto-commit: yes**, via a filesystem watcher, not manual-only. `fswatch`
  (FSEvents backend on macOS — kernel-level, not polling, confirmed to scale to
  500GB+ trees with no degradation) triggers an immediate, pathspec-scoped
  `git add`/`commit` on any change. Pathspec-scoping matters specifically when a
  vault is nested inside a larger existing repo: a naive `git add -A` would stage
  the *entire* parent repo, not just the vault subtree — caught and fixed before
  shipping, not discovered by a user. A separate 5-minute timer does
  `git pull --rebase --autostash && push`, decoupled from commits so a network
  hiccup on push never blocks local commits, and already includes
  pull-before-push even with a single writer today, since retrofitting that once
  a second writer (mobile, if ever self-hosted) exists is more annoying than
  including it from the start.

### Transport / gateway layer
- **Claude Code, Claude Desktop, OpenCode**: connect to Basic Memory over stdio,
  directly, no bridge needed.
  - **Claude Code specifically**: register via `claude mcp add-json ... --scope
    local`, never by hand-editing `.mcp.json`. Project-scoped servers in `.mcp.json`
    need an explicit approval step (`⏸ Pending approval` in `claude mcp get`) that's
    easy to miss — from inside a session, "unapproved" and "never configured" look
    identical (skill shows as loaded either way, since skill-loading and tool
    connection are independent). Found by a failed manual test, not anticipated in
    advance.
  - **OpenCode specifically**: doesn't consume `SKILL.md` — the same skill content
    goes in as `AGENTS.md` in the vault directory instead. Confirmed the stdio MCP
    connection itself works (`opencode mcp list` → `connected`) using the `"type":
    "local"` config schema (`command`/`environment` keys, not `command`/`env`).
- **Zed**: MCP support confirmed real, not assumed — tools + prompts, multi-server,
  hot-reloads its tool list on server-side changes. Skill import via URL confirmed
  working (above).
- **Open WebUI** (HTTP-only, no stdio client): needs a bridge. **`mcpo` chosen over
  ContextForge** — ContextForge's value (OAuth, virtual-server scoping) doesn't apply
  to a single local user with no network exposure; mcpo is OWUI's own purpose-built
  stdio→OpenAPI proxy for exactly this case. Confirmed end-to-end, including that
  OWUI's backend can actually reach and correctly parse a `memvault-infra` mcpo
  bridge's OpenAPI spec via `host.docker.internal` when OWUI itself runs in Docker.
  - **Known, currently-open upstream bug, not ours to fix**: mcpo 0.0.20 (latest at
    time of writing) crash-loops against `mcp>=2.0` (a Python SDK rewrite that
    renamed an import mcpo still uses) — tracked at
    [mcpo#303](https://github.com/open-webui/mcpo/issues/303), opened days before this
    was found. Fixed on our side by pinning `mcp<2`, which is the SDK maintainers' own
    documented recommendation for anyone not ready to migrate, not a workaround
    invented here. Revisit the pin once mcpo ships a compatible release.

## 5. Deployment: `memvault-infra`

Separate repo, not vault content — install script(s), the `memnote` skill, and the
background services that wire a vault directory up to Basic Memory. Vault content
repos (work, personal) are created on-demand by running an installer inside whatever
directory the user wants each vault to live in; the infra repo never pre-creates them.

Two install paths, chosen per vault, same end result:

- **Native** (`install.sh`): `uv tool install` for `basic-memory`/`mcpo`, `launchd`
  LaunchAgents for the background services. Zero container overhead, but macOS-only
  and touches global host tools.
- **Docker** (`install-docker.sh`): one container per vault (mcpo + basic-memory +
  optional git watch/push loops, all built locally from a checked-in `Dockerfile`).
  Cross-platform, much smaller footprint on the host (only touches a container and
  whatever directories are explicitly mounted in) — the intended path for anyone not
  on macOS, or for open-source adopters who shouldn't have a stranger's install
  script modifying their global toolchain. Plain `docker run` with `--name` and a
  container-port-only `-p` (Docker assigns a free host port itself) — no Compose;
  collapsing to one container per vault removed the multi-service orchestration
  Compose would have been for.
  - Git push from inside the container needs care most naive setups get wrong:
    mounts both `~/.ssh` (read-only — a real trust-boundary tradeoff, made explicit
    rather than silent) and forwards `$SSH_AUTH_SOCK`, because which one actually
    authenticates varies by host setup and isn't always what you'd guess. Confirmed
    by testing against a real disposable GitHub repo, not assumed: this machine
    authenticates via a static identity file with no agent identities loaded at all,
    and separately, naive agent-socket bind-mounting doesn't cross the macOS Docker
    Desktop/OrbStack VM boundary regardless.

Both paths install a `memvaultctl` CLI (`status`/`start`/`stop`/`restart`/`logs`/
`uninstall`), auto-detecting which backend a given vault uses, so day-to-day
management doesn't require raw `launchctl`/`docker` commands.

**Considered and rejected: Docker for the whole local stack, including the watcher
and push timer.** The watcher needs FSEvents on the real host filesystem and needs
to run real `git commit`s against the actual host repo — under Docker it would
either stay on the host anyway (splitting one vault's stack across two management
systems) or run against a bind-mounted volume (slower/flakier file-change
notification on macOS). launchd already provides what a container runtime would for
the native path — auto-restart, start/stop, logs — without adding Docker Desktop's
own background VM as a second daemon.

**Considered and rejected: mempalace** (a different open-source "AI memory" project
the user found independently, evaluated on request). Solves a genuinely different
problem — verbatim conversation-history capture and recall via a vector-DB backend
(ChromaDB by default) — and fails two of this project's hard requirements outright:
storage isn't markdown, and its core design is exactly the passive/automatic session
capture §2 explicitly rejects. Not a fit regardless of feature richness.

**Verified by direct testing** (not just written and assumed correct): the full
native install flow; the full Docker install flow including a real `git push` to a
disposable GitHub repo; the isolation model (`list_memory_projects` on a locked
server reports "constrained to a single project," not just an empty list);
`write_note`/`search_notes`/`delete_note` over HTTP; a fresh Claude Code process
(not just the existing session) correctly following the skill end-to-end; `docker
exec -i` as a real MCP stdio bridge (a raw `initialize` handshake completed
successfully); opencode's stdio MCP connection.

As of 2026-08-02, full Docker-path client integration for three clients, each via
a real chat writing a correctly-schemed note to the bind-mounted vault (not just
connectivity): **Claude Code**; **Zed via ACP** with Claude Code as the backing
agent (this reads Claude Code's own project config directly — `.claude/skills/`,
`claude mcp add-json --scope local` — so it needed no Zed-specific setup at all;
Zed's own *native* agent panel, a separate code path, remains unverified); and
**Open WebUI**, which surfaced three real gotchas worth keeping: (1) the
tool-server URL must be host-resolvable (`127.0.0.1`/`localhost`) — OWUI's
OpenAPI tool-server calls are made client-side, from the browser itself, not
proxied through its backend container, so `host.docker.internal` (which only
resolves inside containers) silently fails there even though the backend
container can reach it fine; (2) both the tool server and the skill are
disabled by default and need explicit per-chat activation (or per-model
attachment in Workspace → Models), not just being saved/connected in Admin
Settings; (3) OWUI ships its own built-in Notes feature with identically-named
functions (`write_note`/`search_notes`) — if the external tool isn't actually
toggled on for that chat, the model silently answers with the built-in one
instead, producing a note that looks superficially right but doesn't match
this skill's schema (e.g. missing the required `date` field).

**Still needs a human** (GUI-only, or needs infrastructure only the user has access
to — full list with exact steps in `TESTING.md`): Claude Desktop end-to-end (pure
GUI app, confirmed no scriptable/headless path exists); Zed's native (non-ACP)
agent panel specifically; opencode's full agentic run (blocked on an unrelated
local model-config mismatch on this machine); the native install's
nested-inside-a-parent-repo case specifically;
Linux as the Docker host (only tested via OrbStack on macOS so far).

## 6. Capture workflow

1. User uploads a source doc to the model in an active agent session (Claude, or local
   model via OpenCode — local-model doc-ingestion path already verified working by the
   user via a separate tool call that converts the doc into a format the local model
   can ingest before summarization; reuse this, don't rebuild it).
2. Model produces an initial summary; user interrogates/refines with the agent until
   satisfied.
3. On deliberate commit (not automatic), the agent writes the note per the `memnote`
   skill (§4) into `Sources/<slug>/`, plus the original source doc alongside it if one
   was dropped locally — reference only, never chunked or embedded into the semantic
   index (this falls out naturally: Basic Memory only indexes markdown, so a non-.md
   file sitting in the same directory is retrievable by path and otherwise ignored,
   no configuration needed to achieve this).
4. **Tags and relations are generated by the same agent call that produces the
   summary** — no separate model, no standing extraction service. Deliberate
   simplification: since notes are already authored through an active agent session,
   folding tag/relation proposal into that same turn avoids needing a dedicated
   always-on extraction model (originally considered running something like
   Qwen3.5/3.6-35B-A3B for this — correctly identified as needing real memory for its
   35B *total* parameters regardless of the 3B *active* parameter count, but
   unnecessary once tagging/linking happens inline during authoring instead of as a
   background job).
5. Vocabulary discipline lives in the `memnote` skill (§4), not in Basic Memory
   itself.

## 7. Explicitly out of scope for v1

- Auto-archiving of full agent sessions (rejected — only deliberate summaries get
  written in).
- Graph algorithms (PageRank/clustering/ANN) — external tooling only, if/when wanted.
- Any hosted/SaaS convenience layer, **except Basic Memory Cloud for the personal
  vault's mobile access specifically** — an explicit exception made the way GitHub
  was (§3b). Khoj's hosted tier, GitMCP's hosted tier, mempalace, etc. remain
  excluded, as does any hosted layer for the work vault, full stop.
- Read-only on-device mobile RAG (Noema/LocalRAG-style) as an alternative to Basic
  Memory Cloud — considered, rejected (§3b): doesn't solve the write/capture need
  that's actually wanted from mobile.

## 8. Open items

Genuinely unresolved, in rough priority order:

- [ ] Confirm work-vault git remote against employer IT/security policy — the one
      item gating real use of the work vault; everything else about it is built.
- [ ] Confirm Basic Memory Cloud's actual subscription price before treating it as a
      long-term arrangement rather than a trial.
- [ ] Work out (or accept the absence of) a conflict-resolution discipline for
      Basic Memory Cloud's `bm cloud push/pull` if a project ever gets edited from
      both a local client and mobile at close to the same time.
- [ ] Work through the remaining manual client tests in `TESTING.md`
      (Claude Desktop, Zed, Open WebUI's GUI-only remainder, opencode's full run
      once its model-config mismatch is fixed, the native nested-repo case, Linux as
      the Docker host).
- [ ] Decide whether/when to actually put the work vault and personal vault into
      daily use now that the stack is built, vs. continuing to iterate on tooling.

**Deferred, not open** (revisit only if migrating the personal vault off Basic Memory
Cloud — see §3b for the reasoning, preserved rather than re-litigated here):
spec/provision the self-hosted always-on host; decide Cloudflare Tunnel vs.
self-hosted WireGuard; test ContextForge against GitHub OAuth vs. Pocket-ID; define
git pull-before-write discipline for a second (mobile) writer.
