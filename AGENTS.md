# memvault

Local-execution tooling for the MemVault knowledge-vault design (`DESIGN.md` has
the what/why; this file is how-to-work-in-this-repo only).

## Two-step install model

Installing the tool and provisioning a vault are separate, deliberate steps:

1. **System install, once per machine, not tied to any vault**: `install.sh`
   (native - uv tool installs + macOS launchd) or `install-docker.sh` (builds
   the image, cross-platform). Both clone/update `~/.memvault/repo`, put
   `memvaultctl` on PATH, install the `vnote` skill to `~/.claude/skills/`
   (per-user, so it's loaded in every Claude Code session regardless of
   which directory it's started from - not just ones started inside a
   vault), and record the backend choice in `~/.memvault/backend` (`native`
   or `docker`) - no vault directory, no vault name, no network dependency
   after this point. **Backend is a whole-machine choice, not a per-vault
   one** - every vault created afterward uses whatever's in that file;
   there's no way to mix native and Docker vaults on the same machine by
   passing a flag. Re-running the other installer switches it going forward
   (existing vaults keep running on whatever backend they were created
   with).
2. **Vault provisioning, repeatable, one per folder**: `cd` into the folder
   you want as a vault, then `memvaultctl create <name> [--port N]`. This is
   where a project-level copy of the skill also gets written (Zed's `file://`
   import and OpenCode's `AGENTS.md` convention need a real file inside the
   vault directory - they have no per-user skill concept to point at
   instead), `.gitignore` gets its entries, the port gets assigned and
   persisted, and the container/launchd services get started. The MCP server
   itself stays directory-scoped (`claude mcp add-json ... --scope local`,
   per `INTEGRATIONS.md`) - deliberately not global, so having several
   vaults doesn't put every vault's write/search tools into every unrelated
   Claude Code session at once. See `DESIGN.md` for the isolation reasoning
   behind that choice.

Upgrading the tool itself is `memvaultctl upgrade` (global - pulls the repo,
rebuilds the image / upgrades the uv tools, does not touch any running
vault). Applying that upgrade to a given vault is the separate `memvaultctl
restart <name>`, which recreates the container (or reloads the launchd
services) against whatever was just built. Nothing lives in the vault
directory itself except vault content (skill copy, `INTEGRATIONS.md`,
notes) - no generated per-vault control script.

## What's here

- `install.sh` / `install-docker.sh` - system installers, see above.
- `uninstall.sh` - removes the tool only: `memvaultctl` symlink, repo
  checkout, backend marker, per-user skill, unused `memvault:*` Docker
  images. Deliberately never stops or removes a vault's container/services,
  never touches `~/.memvault/config`/`logs`/`ports.txt`/`vaults.txt`, and
  never touches vault directories or their git history - keep it that way.
  Dry-run by default, `--yes` to execute.
- `skills/vnote/SKILL.md` - the note-writing skill, shared verbatim across every
  client (Claude Code, Zed, Open WebUI, opencode-as-`AGENTS.md`).
- `scripts/watch-commit.sh` / `push-timer.sh` - shared by both backends and by
  the Docker entrypoint. One implementation, not duplicated per path.
- `scripts/memvaultctl.sh` - the one control surface: `create`, `upgrade`,
  `status`/`start`/`stop`/`restart`/`logs`/`uninstall`. Auto-detects native vs.
  Docker backend per vault. Owns the `~/.memvault/ports.txt` (stable per-vault
  port) and `~/.memvault/vaults.txt` (name -> backend/dir) registries.
- `docker/` - Dockerfile + entrypoint for the Docker path.
- `TESTING.md` - what's verified vs. still needs a human, with exact steps.

## Rules, not suggestions

- **`skills/vnote/SKILL.md` is AI-facing: terse and directive only.** State the
  rule, not the reason. Explanatory prose belongs in `DESIGN.md` or commit
  messages, not in a file an agent parses as instructions.
- **Never use bare `mv`/`cp` in scripts - always `-f`.** This repo's own scripts
  silently no-op'd once already because the invoking shell had them aliased to
  `-i`, and the non-interactive overwrite prompt defaulted to no with no error.
  Don't reintroduce it.
- **Both backends must stay behaviorally consistent.** A change to the skill
  schema, the isolation model, or the watch/push behavior applies to both the
  native and Docker branches of `memvaultctl create` - check both before
  considering a change done. The Docker container-run logic (bind mounts, SSH/
  gitconfig mounting) lives in exactly one place, `docker_start_vault` in
  `scripts/memvaultctl.sh`, shared by `create`/`start`/`restart` - don't
  reintroduce a second copy of it.
- **Claude Code MCP registration is `claude mcp add-json ... --scope local`,
  never a hand-edited `.mcp.json`.** Project-scoped `.mcp.json` servers need an
  approval step Claude Code doesn't surface clearly - from inside a session,
  "unapproved" and "never configured" look identical.
- **`mcpo` needs `mcp<2` pinned** (`uv tool install mcpo --with "mcp<2"`) until
  mcpo ships a release compatible with `mcp>=2.0`'s renamed import
  (`streamablehttp_client` -> `streamable_http_client`). Tracked upstream at
  open-webui/mcpo#303 - don't drop the pin without confirming that's fixed.
- **Docker git push needs both `~/.gitconfig` and `~/.ssh` mounted**, not just
  `$SSH_AUTH_SOCK` forwarding. Agent-socket bind-mounting doesn't reliably cross
  the macOS Docker Desktop/OrbStack VM boundary, and plenty of hosts authenticate
  via a static identity file with no agent identities loaded at all.
- **Isolation is `BASIC_MEMORY_CONFIG_DIR`, not just picking a "current"
  project.** Every vault gets its own value. Don't add a code path that shares a
  config dir across vaults, even temporarily.

## Testing discipline

- Smoke-test against a real throwaway vault before calling a change done - reading
  the diff isn't enough. Every real bug found in this repo so far was found by
  actually running the install and checking the resulting files/processes, not by
  review.
- Never touch a real running vault to test something new. Use a disposable,
  clearly-named directory and, if testing push, a disposable GitHub repo.
- Tear down completely afterward: `memvaultctl uninstall <name>`, remove the
  throwaway directory, and separately clean up anything outside `memvaultctl`'s
  reach - stray `claude mcp` registrations (check `~/.claude.json`'s `projects`
  key), throwaway GitHub repos, Docker images/volumes made for the test.
