# Manual test plan

What's already been smoke-tested by Claude and doesn't need re-checking:
install.sh's no-git path, the mcpo bridge (incl. the `mcp<2` pin), the
isolation model (`BASIC_MEMORY_CONFIG_DIR`/`BASIC_MEMORY_MCP_PROJECT`),
`write_note`/`search_notes`/`delete_note` over HTTP, the memnote skill
followed correctly by a fresh Claude subagent, and opencode's stdio MCP
connection (config block in `INTEGRATIONS.md` confirmed correct - `opencode
mcp list` reports "connected"). Also now verified: `install-docker.sh`
end to end against a git-tracked vault (image build, container start, the
git-identity fix, watcher auto-commit, `write_note`, `docker exec -i` as a
real MCP stdio bridge, `memvaultctl` against the Docker backend) - see
the README's "Verified (Docker path)" section for the full list. Everything
below still needs a human because it's GUI-driven, blocked on something
outside this repo, or specifically Docker+`git push` (identity/commit was
tested, the actual push through the forwarded SSH agent wasn't).

## 1. Claude Code (skill auto-load + tool use)

**Already manually tested once - failed on step 3, root cause found and
fixed.** The skill loaded fine (showed up in Claude's skill list), but no
`write_note`/`search_notes` tools were available. Cause: the MCP config went
into (or was described vaguely enough to imply) a hand-edited `.mcp.json`,
which Claude Code treats as project-scoped and requires an explicit approval
step for (`claude mcp get <name>` shows `⏸ Pending approval` until then) -
skill-loaded-but-tools-missing looks identical to
never-configured-at-all from inside the session, so this is easy to miss.
`INTEGRATIONS.md` now generates the `claude mcp add-json ... --scope local`
command instead, which skips the approval prompt entirely. Re-test with that:

1. `cd` into a throwaway dir, run the installer, name the vault e.g. `test-cc`.
2. Open that folder in Claude Code. Confirm `.claude/skills/memnote/SKILL.md`
   is picked up (ask Claude to list its available skills) - this part already
   passed, shouldn't need re-checking, but worth a quick glance.
3. Run the `claude mcp add-json` command from the generated `INTEGRATIONS.md`
   (not a hand-edited `.mcp.json`). Restart the session, then `claude mcp
   list` and confirm `✔ Connected`, not pending.
4. Ask Claude to search for and then write a note about some real thing
   you've read recently. Check the resulting file's frontmatter matches the
   skill schema (`note_type: summary`, `metadata.date`, `source_url` or
   `source_path`, tags).
5. Tear down: unload the launchd plists, `rm -rf` the config/log dirs under
   `~/.memvault-infra/`, delete the throwaway dir - same steps Claude used
   during its own smoke test, see git log for the exact commands if needed.
   Also `claude mcp remove <name> --scope local` to undo step 3.

## 2. Claude Desktop

Same as above, but the MCP config goes in
`~/Library/Application Support/Claude/claude_desktop_config.json` and you
need to fully quit/reopen the app for it to pick up the change (no hot
reload). Verify the tool appears under the 🔌 icon **and shows connected**
before testing a write - given what just happened with Claude Code, don't
assume the icon showing up means it actually connected; check for an error
state on it too.

## 3. Zed

1. Command palette -> `agent: create skill from url`, paste the raw GitHub
   URL of `skills/memnote/SKILL.md` from this repo. Confirm it shows up
   under Zed's skills list.
2. Add an MCP context server using the same command/args/env block from
   `INTEGRATIONS.md` (Zed's MCP config UI, not a JSON file - see Zed's MCP
   docs if the field names don't match).
3. In Zed's agent panel, ask it to write a note; verify the skill actually
   gets applied (Zed's skill-loading behavior wasn't verified in the smoke
   test, so specifically check the skill isn't just installed but silently
   ignored).

## 4. Open WebUI

Not attempted at all (would've meant standing up a docker container just to
exercise a REST API - partial coverage for real cost, since the actual steps
that need checking, adding a tool server and pasting a skill, are both
GUI-only anyway).

1. Get OWUI running (docker or pip, your call).
2. Settings -> Tools -> add server pointing at
   `http://127.0.0.1:<port>/<vault-name>` (mcpo is already running per-vault
   after `install.sh` - reuse a real vault or spin up a throwaway one).
3. Workspace -> Skills -> new skill, paste `skills/memnote/SKILL.md`'s
   contents.
4. New chat, enable the tool + skill, ask it to write a note. Check the file
   on disk.

## 5. Git-tracked and nested-repo install.sh paths

Only the no-git path was smoke-tested. Still needs checking:

- **Own repo**: `git init` a throwaway dir first, then run the installer.
  Confirm `watch`/`push` services get installed this time (`launchctl list |
  grep memvault-infra` should show three, not one), and that editing a file
  triggers an automatic commit within a couple seconds.
- **Nested in a parent repo**: create a throwaway *parent* repo with some
  unrelated file already modified (uncommitted), then run the installer
  inside a subdirectory of it. Edit a file inside the vault subdirectory and
  confirm the auto-commit only stages/commits that subtree - the unrelated
  parent-repo change should remain untouched and uncommitted. This is the
  one install.sh rewrote specifically to avoid a bug (naive `git add -A`
  would have staged the whole parent repo) - worth actually proving it,
  not just trusting the diff.
- **Push timer**: point either repo above at a real (throwaway) GitHub
  remote, wait for the 5-minute `StartInterval` tick or just run
  `scripts/push-timer.sh <vault-dir>` directly, confirm it pushes.

## 6. opencode full agentic run

Blocked during the smoke test by something unrelated to this repo: the model
IDs in `~/.config/opencode/opencode.json` (`mlx-local/Qwen3.6-27B-UD-MLX-6bit`
etc.) don't match what `mlx-serve` is actually currently serving on
`localhost:8000/v1/models` - every model tried either 404'd or hit an
`UnknownError`. Once that's reconciled: re-run the connectivity test
(`opencode mcp add <name> --type local --command '["uvx","basic-memory","mcp"]'
--environment ...`, or hand-edit `opencode.json` per the "local" MCP schema),
copy the skill to the vault dir as `AGENTS.md` (opencode doesn't consume
`SKILL.md`), then `opencode run --dir <vault-dir> --auto "<task>"` and check
the resulting note the same way as the Claude Code test.

## 7. Docker path: git push through the forwarded SSH agent

The container's own git identity/commit was verified (a real host-attributed
commit landed correctly), but push wasn't - no throwaway GitHub remote was
set up during the smoke test. Point a throwaway vault's git remote at a real
(disposable) GitHub repo, run `install-docker.sh` on it, edit a file, and
either wait for the container's 5-minute push loop or exec into it directly
to force one sooner. Confirm the commit actually lands on the remote, not
just that `git push` didn't error locally.

## 8. Docker path: clients other than the raw protocol/HTTP checks already done

`docker exec -i <container> uvx basic-memory mcp` was confirmed to complete
a real MCP `initialize` handshake by hand, and `write_note` was confirmed
through the container's mcpo HTTP bridge directly - neither was tested
through an actual client. Repeat tests 1-4 above, but against a
Docker-backed vault (`install-docker.sh` instead of `install.sh`), using the
`docker exec -i ...` command block from that vault's generated
`INTEGRATIONS.md` instead of the native stdio command.

## 9. Docker path: Linux as the host

Only tested via OrbStack on macOS. The whole point of the Docker path is
cross-platform reach - worth confirming `install-docker.sh` actually works
unmodified on a Linux Docker host (bind mount permissions and SSH agent
socket forwarding are the most likely places for host-OS-specific surprises).
