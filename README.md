# memvault-infra

Tooling for the local-execution knowledge vault design in `memvault/docs/SEED_DESIGN.md`.
Holds no vault content itself - just the install script, the shared
note-writing skill, and the background services that wire a vault directory
up to Basic Memory, mcpo, and git.

Vault content repos (work vault, personal vault) are separate, created
on-demand by running `install.sh` inside whatever directory you want each
vault to live in - this repo doesn't pre-create them.

## What one `install.sh` run does

Run from inside the target vault directory - a fresh empty folder, an
existing git repo, or a folder nested inside a larger repo are all fine:

```bash
mkdir -p ~/vaults/personal-vault && cd ~/vaults/personal-vault
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault-infra/contents/install.sh \
  | bash -s -- personal-vault
```

`gh api` (not `curl`) so this works against a private `memvault-infra` repo
too, using your existing `gh auth login` session instead of a public raw URL.

`install.sh` defaults to `ivan-avramov/memvault-infra`; override with the
`MEMVAULT_INFRA_REPO` env var to point at a fork.

It:

1. Checks `gh` is installed and authenticated (required - this is how the
   rest of the repo gets fetched, private-repo-safe).
2. Clones/updates this repo to `~/.memvault-infra/repo` via `gh repo clone`
   (so the single bootstrap script has access to the skill, scripts, and
   plist templates).
3. Installs `uv`, `fswatch`, and (via `uv tool install`) `basic-memory` and
   `mcpo` if missing.
4. Detects whether the current directory is git-tracked - **never runs
   `git init` itself**. If it's a repo (or nested inside one), adds a
   `.gitignore` for `.DS_Store` / `.basic-memory/` in the vault directory.
   If there's no git at all, the commit watcher and push timer are skipped
   (nothing to commit/push to) and `INTEGRATIONS.md` says so.
5. Copies the note-writing skill to `.claude/skills/memnote/SKILL.md` in
   the vault (picked up automatically by Claude Code).
6. Registers the current directory as a Basic Memory project, in an
   **isolated** config directory (`~/.memvault-infra/config/<vault-name>/`) - see
   "Isolation model" below.
7. Assigns the vault a local port (starting at 8100) and starts launchd
   services scoped to just this vault: always `mcpo`; `watch` and `push`
   too if git is present.
8. Writes `INTEGRATIONS.md` into the vault directory with exact per-client
   setup steps, generated with this vault's real paths/ports filled in.

Run it again, once per vault directory, for each vault (work, personal).
Re-running for the same vault is safe/idempotent - it updates the skill copy,
refreshes the mcpo config, and reloads the launchd services.

If the vault directory is nested inside a larger repo, the commit watcher
only ever stages/commits changes under the vault subtree (pathspec-scoped),
but the push timer pulls/pushes that repo's **entire current branch** every 5
minutes, since pull/push aren't path-scoped in git - including any other
commits you've made there. Give the vault its own repo if that's not what you
want.

## Isolation model

The design requires each vault to have its own Basic Memory instance with no
shared visibility between them. Basic Memory's project registry is normally
a single shared list across all projects on a machine (`~/.basic-memory/config.json`
by default) - simply running `basic-memory mcp` twice with different
"current" projects would **not** give you real isolation, since a client
connected to one instance could still call `list_memory_projects` and see the
other vault's project name and path.

The actual isolation mechanism is the `BASIC_MEMORY_CONFIG_DIR` environment
variable, which relocates the entire config/project-registry/index for a
process, not just the default project. Every vault gets its own value
(`~/.memvault-infra/config/<vault-name>/`), set both when registering the
project and in the mcpo config that spawns the server - so a client attached
to one vault's mcpo port is talking to a process that has never heard of the
other vault at all.

What this does **not** do is stop a client from being configured to point at
both vaults' endpoints/configs simultaneously - that's a client-side
discipline question, not something enforced by this infra. See the
isolation reminder in each vault's generated `INTEGRATIONS.md`.

## Background services (per vault)

Up to three launchd LaunchAgents, labeled `com.memvault-infra.<vault-name>.{mcpo,watch,push}`:

- **mcpo** - always installed. Bridges this vault's Basic Memory (stdio) to
  HTTP on its assigned port, for Open WebUI. `KeepAlive`, restarts if it dies.
- **watch** - only if git-tracked. `fswatch` (FSEvents backend on macOS -
  kernel-level change notification, not polling) triggers an immediate,
  pathspec-scoped `git add -A -- <vault-dir> && git commit` on any change
  under the vault directory. `KeepAlive`.
- **push** - only if git-tracked. `git pull --rebase --autostash && git push`
  against the repo root, run once every 5 minutes via `StartInterval` (not an
  internal loop). No-ops if no git remote is configured yet.

Logs: `~/.memvault-infra/logs/<vault-name>/{mcpo,watch,push}.{out,err}.log`.

Manage these with `memvaultctl` (symlinked onto `PATH` by `install.sh`)
instead of hand-typing `launchctl` commands and plist paths:

```bash
memvaultctl status [vault]              # all vaults, or one vault's services
memvaultctl start|stop|restart <vault> [service]   # default: all services
memvaultctl logs <vault> [service] [-f]
memvaultctl uninstall <vault>           # stop + remove services/config/logs/
                                         # port assignment. Leaves the vault
                                         # directory and its git repo alone.
```

**Why not Docker for this?** launchd already provides the auto-restart/start/
stop/logs a container runtime would - it's the OS's native service manager,
running for free, without Docker Desktop's own background VM as a second
daemon. `uv tool install` already gives per-tool dependency isolation
(demonstrated directly by the `mcp<2` pin above having zero effect on Basic
Memory's separate environment). The one piece that would get *worse* under
Docker is the watcher: it needs FSEvents on the real host filesystem and
needs to run real `git commit`s against your actual host repo, so it would
either stay on the host anyway (splitting one vault's stack across two
management systems) or run against a bind-mounted volume inside the
container (slower/flakier file-change notification on macOS, plus wiring
host git identity/SSH keys into the container for no benefit). Docker is the
right call for the future always-on host in `SEED_DESIGN.md` §4 - a real
Linux server solving a genuinely different problem - not for this Mac-local
stack.

## Client integration

Each vault's generated `INTEGRATIONS.md` has the filled-in version of this
with real paths/ports. Summary:

- **Claude Code, Claude Desktop, OpenCode** - stdio, no bridge. MCP config
  points `command`/`args` at `basic-memory mcp` (via `uvx`) with
  `BASIC_MEMORY_CONFIG_DIR` and `BASIC_MEMORY_MCP_PROJECT` set in `env`.
- **Zed** - same stdio MCP config, plus `agent: create skill from url` in the
  command palette pointed at this repo's `skills/memnote/SKILL.md` raw
  URL.
- **Open WebUI** - add a tool server pointing at
  `http://127.0.0.1:<port>/<vault-name>` (mcpo), and paste
  `skills/memnote/SKILL.md` into OWUI's Skills workspace as a custom
  skill.

## Verified (smoke-tested 2026-08-01, no-git path)

Full `install.sh` run against a fresh, non-git directory: fswatch/basic-memory/mcpo
install, isolated project registration, `list_memory_projects` confirmed
server-side lock to the single project (`BASIC_MEMORY_MCP_PROJECT` really does
constrain operations, not just hide the registry), `write_note` through mcpo's
HTTP bridge produced correct on-disk frontmatter, forward-reference relations
resolved as "unresolved" as expected, `delete_note` cleaned up correctly.

**Bug found and fixed:** `mcpo` 0.0.20 (latest on PyPI) imports
`streamablehttp_client`, which `mcp>=2.0` renamed to `streamable_http_client` -
without a pin, `uv tool install mcpo` resolves `mcp` 2.x and mcpo crash-loops
on startup (`ImportError`, visible in `mcpo.err.log`). `install.sh` now pins
`mcp<2` via `--with`. If mcpo ships a 2.x-compatible release later, drop the
pin.

**Skill corrected against the real API:** `write_note`'s actual schema takes
`note_type` and a `metadata` dict, not hand-authored YAML frontmatter in
`content` - the skill originally assumed the latter. Also, `date` is not
auto-populated by Basic Memory; it must be passed explicitly. Fixed in both
`SKILL.md` and this README's mental model - if you're recalling the schema
from memory rather than reading `SKILL.md` fresh, assume it changed.

Not yet tested: the git-tracked and nested-repo paths (`watch`/`push`
services), Claude Code/Zed/OWUI client integration end-to-end, Linux.
Everything here targets macOS (launchd, FSEvents-backed fswatch, Homebrew for
`fswatch`) - no Linux/systemd path yet.
