# memvault

Local-execution tooling for the MemVault knowledge-vault design (`DESIGN.md` has
the what/why; this file is how-to-work-in-this-repo only).

## What's here

- `install.sh` - native install (uv tool installs + macOS launchd services).
- `install-docker.sh` - Docker install (one container per vault, cross-platform).
- `skills/memnote/SKILL.md` - the note-writing skill, shared verbatim across every
  client (Claude Code, Zed, Open WebUI, opencode-as-`AGENTS.md`).
- `scripts/watch-commit.sh` / `push-timer.sh` - shared by both install paths and by
  the Docker entrypoint. One implementation, not duplicated per path.
- `scripts/memvaultctl.sh` - management CLI, auto-detects native vs. Docker backend
  per vault.
- `docker/` - Dockerfile + entrypoint for the Docker path.
- `TESTING.md` - what's verified vs. still needs a human, with exact steps.

## Rules, not suggestions

- **`skills/memnote/SKILL.md` is AI-facing: terse and directive only.** State the
  rule, not the reason. Explanatory prose belongs in `DESIGN.md` or commit
  messages, not in a file an agent parses as instructions.
- **Never use bare `mv`/`cp` in scripts - always `-f`.** This repo's own scripts
  silently no-op'd once already because the invoking shell had them aliased to
  `-i`, and the non-interactive overwrite prompt defaulted to no with no error.
  Don't reintroduce it.
- **Both install paths must stay behaviorally consistent.** A change to the skill
  schema, the isolation model, or the watch/push behavior applies to both
  `install.sh` and `install-docker.sh` - check both before considering a change
  done.
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
