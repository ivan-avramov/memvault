# memvault

Tooling for the local-execution knowledge vault design in [`DESIGN.md`](DESIGN.md)
(read that for the *why*; this file is just setup instructions). This repo holds
no vault content itself - it's the installer, the shared `memnote` note-writing
skill, and the background services that wire a vault directory up to
[Basic Memory](https://github.com/basicmachines-co/basic-memory), `mcpo`, and git.

Vault content (work vault, personal vault, ...) lives in separate directories.
Installing memvault itself and provisioning a vault are two separate steps:
install once per machine (below), then create a vault with `memvaultctl
create <name>` from inside whichever directory you want to become that vault
- one `create` per vault, this repo never creates or pre-populates those
directories.

There are two backends, same end result. **Docker is recommended** -
cross-platform, and it only touches a container plus the directories you mount
in. Native only works on macOS and installs tools/services onto the host
directly; use it if you specifically want zero container overhead. The
backend is a one-time, whole-machine choice made by whichever installer you
run below - it's not something you pick per vault.

Both backends are managed afterward the same way, via `memvaultctl`, and both
write a per-vault `INTEGRATIONS.md` with copy-pasteable client config.

## Install with Docker (recommended)

Prerequisite: Docker (Desktop or OrbStack) running.

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-avramov/memvault/main/install-docker.sh \
  | bash
```

This clones the repo to `~/.memvault/repo`, builds the `memvault:local` image,
and puts `memvaultctl` on your `PATH`. Run it once per machine - it's not tied
to any vault. Then, for each vault:

```bash
mkdir -p ~/vaults/personal-vault && cd ~/vaults/personal-vault
memvaultctl create personal-vault
```

Run `create` from inside the directory you want to become the vault - a fresh
empty folder, an existing git repo, or a folder nested inside a larger repo
are all fine; the name defaults to the directory name if omitted. This starts
one container per vault, with the vault directory bind-mounted in. If the
directory is git-tracked, a commit watcher and push timer run inside the
container too; otherwise they're skipped.

## Install natively (macOS only)

Prerequisite: none beyond `bash`/`curl`/`git` - `uv` and `fswatch` are
installed automatically if missing (via Homebrew for `fswatch`).

```bash
curl -fsSL https://raw.githubusercontent.com/ivan-avramov/memvault/main/install.sh \
  | bash
```

Same two-step usage as the Docker path: this installs `basic-memory`/`mcpo`
via `uv tool install` and puts `memvaultctl` on your `PATH`, once per machine.
Then `cd` into each vault's directory and run `memvaultctl create <name>`,
which registers `launchd` LaunchAgents (`mcpo` always; `watch`/`push` only if
the directory is git-tracked) instead of starting a container.

Override the source repo for either installer with
`MEMVAULT_REPO=<owner>/<repo>` if you're running your own fork.

## Upgrading

`memvaultctl upgrade` pulls the repo and rebuilds the image / upgrades the uv
tools - once, for the whole machine, not any particular vault. It never
restarts a running vault; apply the upgrade to a given vault explicitly with
`memvaultctl restart <name>`, which recreates the container (or reloads the
native services) against whatever was just built.

## Managing a vault

Either path installs `memvaultctl` on your `PATH`, which auto-detects whether a
given vault is native or Docker-backed:

```bash
memvaultctl status [vault]                       # all vaults, or one vault's services
memvaultctl start|stop|restart <vault> [service]  # default: all services
memvaultctl logs <vault> [service] [-f]
memvaultctl uninstall <vault>                     # stop + remove services/config/logs/container
                                                   # leaves the vault directory and git repo alone
```

## Resource usage

Measured on the Docker path (2026-08-02): idle CPU sits around ~1.5% of one
core per vault, with zero measured `/proc` CPU ticks from the file watcher
itself while idle - `fswatch -o | while read` blocks on a kernel FSEvents
pipe, it isn't polling. A real file write gets committed within the same
second, too briefly to even show as a spike. The ~1.5% baseline is just
`mcpo`/`basic-memory`'s Python/asyncio processes being alive, not vault
activity - negligible on any modern multi-core machine. The push timer
(`sleep 300` loop, no-ops if no git remote is configured) adds nothing
between wakeups.

## Connecting a client

Each vault's install writes `INTEGRATIONS.md` **into that vault's directory**
with exact, ready-to-paste config for your ports/paths - use that, not this
section, when actually setting up a client. Summary of what's involved:

- **Claude Code, Claude Desktop, OpenCode** - stdio, no network bridge needed.
- **Zed via ACP** (Zed driving Claude Code as the backing agent) - no
  Zed-specific setup needed; it reads Claude Code's own project config
  (`.claude/skills/`, registered MCP servers) directly, same as the CLI.
  Zed's own *native* agent panel is a separate code path with its own
  skill store and MCP config - see `TESTING.md` if you use that instead.
- **Open WebUI** - HTTP, via the `mcpo` bridge each vault already runs; add it
  as a tool server using a host-resolvable URL (`127.0.0.1`/`localhost`, not
  `host.docker.internal` - OWUI's tool-server calls are made client-side from
  your browser, not proxied through its backend container) and paste the
  skill into OWUI's Skills workspace. Both the tool server and the skill are
  disabled by default and need explicit per-chat activation (or per-model
  attachment) - if you skip that, OWUI's own built-in Notes feature will
  silently answer instead, using tool names that look the same but produce
  notes that don't match this skill's schema.

Never point two vaults' configs at the same client session/workspace at once -
each vault is fully isolated server-side, but nothing stops a client from being
configured to see both.

## More detail

- [`DESIGN.md`](DESIGN.md) - what this is for, architecture, and why it's built
  this way (isolation model, why two install paths, why not Docker for the
  native watcher, etc.).
- [`TESTING.md`](TESTING.md) - what's been verified vs. what still needs a human,
  with exact steps for the rest.
- [`AGENTS.md`](AGENTS.md) - conventions for working in this repo.
