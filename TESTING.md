# Manual test plan

Verified by Claude, doesn't need re-checking (see `DESIGN.md` §5 for full
detail): native no-git install flow, mcpo bridge (incl.
`mcp<2` pin), isolation model, `write_note`/`search_notes`/`delete_note` over
HTTP, the memnote skill followed correctly by a fresh Claude subagent,
opencode's stdio MCP connection; the full Docker install flow against a
git-tracked vault including a real `git push` to a disposable GitHub repo;
Claude Code end to end via a genuinely fresh `claude -p` process; and, as of
2026-08-02, the full Docker-path client integration for Claude Code, Zed (via
ACP with Claude Code as the backing agent), and Open WebUI - a real chat in
each client actually writing a correctly-schemed note to the bind-mounted
vault, not just connectivity. See `DESIGN.md` §5 for the Open WebUI gotchas
that testing surfaced (tool-server URL, per-chat activation, built-in Notes
collision).

Everything below is left because it's GUI-only with no CLI/API escape hatch,
or needs infrastructure only you have access to. Each section is
copy-pasteable as written except for placeholders in `<angle brackets>`.

## 1. Claude Desktop

```bash
# system install, skip if already done on this machine
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault/contents/install.sh \
  | bash

mkdir -p ~/vaults/test-desktop && cd ~/vaults/test-desktop
memvaultctl create test-desktop
```

1. Open `~/Library/Application Support/Claude/claude_desktop_config.json`
   (create it if it doesn't exist yet). Merge the `mcpServers` block from
   the vault's generated `INTEGRATIONS.md` into it (don't overwrite any
   other servers already configured there).
2. **Fully quit** Claude Desktop (Cmd+Q, not just closing the window) and
   reopen it - no hot reload.
3. Start a new chat, check the 🔌/tools icon: confirm `test-desktop` shows
   as connected, not just present or in an error state.
4. Ask it to write a note about something you actually read recently. Open
   the resulting file and check the frontmatter matches the skill schema
   (`note_type: summary`, `metadata.date`, `source_url` or `source_path`,
   sensible tags).

Teardown:
```bash
memvaultctl uninstall test-desktop
rm -rf ~/vaults/test-desktop
```
Then remove the `test-desktop` entry from `claude_desktop_config.json` and
quit/reopen Claude Desktop again.

## 2. Zed's native agent panel (not ACP)

Only the ACP path (Zed driving Claude Code as the backing agent) has been
verified (2026-08-02, Docker-backed vault) - that path reads Claude Code's
own project config (`.claude/skills/`, `claude mcp add-json --scope local`)
directly, so it's already covered by the Claude Code checks elsewhere. Zed's
*native* agent panel - its own model provider, its own "context servers" MCP
config, its own separate Skills store - is a different code path and remains
unverified.

```bash
# system install, skip if already done on this machine
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault/contents/install-docker.sh \
  | bash

mkdir -p ~/vaults/test-zed-native && cd ~/vaults/test-zed-native
memvaultctl create test-zed-native
zed ~/vaults/test-zed-native
```

1. Command palette (Cmd+Shift+P) -> `agent: create skill from url`. Expect
   this specific flow to fail either way against this private repo: a
   `raw.githubusercontent.com` URL 404s unauthenticated, and Zed rejects
   `file://` URLs outright ("github urls must be https://" - confirmed
   2026-08-02). The only working import path found so far is pasting the
   skill's frontmatter (`name`/`description` into their own fields) and body
   by hand into Zed's create-skill dialog. Leave "disable model invocation"
   **off** - the skill needs to apply automatically, not only via a manual
   slash command.
2. In Zed's agent panel settings, add an MCP context server using the
   command/args/env block from `~/vaults/test-zed-native/INTEGRATIONS.md`.
3. Switch the agent panel to Zed's own native agent (not Claude Code/ACP),
   ask it to write a note about something real. Check that the skill was
   actually *applied* (correct schema in the resulting file) - not just that
   it's listed as installed.

Teardown: remove the skill and the MCP context server from Zed's settings,
then:
```bash
memvaultctl uninstall test-zed-native
rm -rf ~/vaults/test-zed-native
```

## 3. opencode full agentic run

Connectivity is already verified. This is blocked on a mismatch between the
model IDs in `~/.config/opencode/opencode.json` and what `mlx-serve` is
actually serving right now - reconcile that first (check
`curl -s http://localhost:8000/v1/models | jq .` for what's actually being
served, and either update the `models` block under the `mlx-local` provider
in `opencode.json` to match, or point `-m` at a model that's already
declared there).

```bash
# system install, skip if already done on this machine
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault/contents/install.sh \
  | bash

mkdir -p ~/vaults/test-opencode && cd ~/vaults/test-opencode
memvaultctl create test-opencode
cp .claude/skills/memnote/SKILL.md AGENTS.md   # opencode doesn't read SKILL.md
```

Register the MCP server (opencode doesn't consume the same JSON shape as
Claude - see `INTEGRATIONS.md` for the exact block, or hand-edit
`~/.config/opencode/opencode.json`'s `mcp` key with `"type": "local"`), then:

```bash
opencode run --dir ~/vaults/test-opencode --auto \
  "Discuss and write a note about something real, following AGENTS.md."
```

Check the resulting file's schema, same as the other client tests.

Teardown: remove the `test-opencode` entry from `opencode.json`'s `mcp` key,
then:
```bash
memvaultctl uninstall test-opencode
rm -rf ~/vaults/test-opencode
```

## 4. Native `memvaultctl create`: nested-in-parent-repo path

This is the one case `memvaultctl create` was specifically written to handle
correctly (pathspec-scoped commits, so the watcher never touches unrelated
files elsewhere in a larger repo) - worth proving, not just trusting the
diff.

```bash
# system install, skip if already done on this machine
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault/contents/install.sh \
  | bash

mkdir -p ~/parent-repo-test && cd ~/parent-repo-test
git init -q
echo "pre-existing file" > unrelated.txt
git add unrelated.txt && git commit -q -m "initial"
echo "uncommitted change - should stay untouched" >> unrelated.txt

mkdir vault-subdir && cd vault-subdir
memvaultctl create nested-test
```

1. `launchctl list | grep memvault` - confirm three services
   (`mcpo`, `watch`, `push`) got installed for `nested-test`, not just one.
2. `echo "test" > vault-subdir/note.md`, wait ~3 seconds.
3. From `~/parent-repo-test` (the parent root, not the subdir):
   `git status --short` - `unrelated.txt`'s uncommitted change from setup
   must **still be uncommitted**. `git log --oneline` - a new
   `auto: vault update` commit must exist, and `git show --stat HEAD` must
   show only files under `vault-subdir/`, never `unrelated.txt`.
4. Point `origin` at a real (disposable) GitHub repo, force a push cycle
   (`scripts/push-timer.sh vault-subdir` from the infra checkout, or wait
   5 minutes), and confirm the *whole* repo's branch pushed - including the
   `unrelated.txt` commit history, per how the docs describe this case.

Teardown:
```bash
memvaultctl uninstall nested-test
rm -rf ~/parent-repo-test
```

## 5. Docker path: Linux as the host

Needs an actual Linux machine or VM with Docker - a cloud instance, or a
local VM (UTM/Multipass/Lima). On it:

```bash
gh auth login   # needs its own auth on that machine
gh api -H "Accept: application/vnd.github.raw" \
  /repos/ivan-avramov/memvault/contents/install-docker.sh \
  | bash

mkdir -p ~/vaults/linux-test && cd ~/vaults/linux-test
memvaultctl create linux-test
```

Run through the same checks as the macOS Docker smoke test (mcpo reachable,
`write_note` round-trips to the bind-mounted directory, watcher commits on
edit). Specifically worth comparing against the macOS results:

- **SSH agent forwarding** (the `$SSH_AUTH_SOCK` half of the git-push fix)
  should work reliably here, since there's no Docker-Desktop/OrbStack VM
  boundary between the host and the container the way there is on macOS -
  confirms whether that part of the fix was actually macOS-specific or a
  more general issue.
- **Bind-mount ownership/permissions** - macOS's Docker Desktop/OrbStack
  does UID translation somewhat transparently; native Linux Docker doesn't
  always, so this is the most likely place for a new, Linux-specific
  surprise (e.g. the container's root user unable to write to the mounted
  vault directory depending on host directory ownership).

Teardown: `memvaultctl uninstall linux-test` (or, if `memvaultctl` didn't
land on PATH, `bash ~/.memvault/repo/scripts/memvaultctl.sh uninstall
linux-test`) - this also removes the `linux-test` lines from
`~/.memvault/ports.txt`/`vaults.txt`.
