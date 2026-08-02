# Manual test plan

Verified by Claude, doesn't need re-checking (see README's "Verified"
sections for full detail):

- **Native path**: no-git install flow, mcpo bridge (incl. `mcp<2` pin),
  isolation model, `write_note`/`search_notes`/`delete_note` over HTTP, the
  memnote skill followed correctly by a fresh Claude subagent, opencode's
  stdio MCP connection.
- **Docker path**: full `install-docker.sh` flow against a git-tracked
  vault, the git-identity fix, watcher auto-commit, `write_note`,
  `docker exec -i` as a real MCP stdio bridge, **`git push` through a real
  disposable GitHub repo** (confirmed remote HEAD matched local HEAD -
  found and fixed a real bug here: naive `$SSH_AUTH_SOCK` forwarding
  doesn't cross the macOS Docker Desktop/OrbStack VM boundary, and this
  host authenticates via a static identity file with no agent identities
  loaded anyway - fixed by also mounting `~/.ssh` read-only).
- **Claude Code, for real**: registered a throwaway vault via
  `claude mcp add-json --scope local`, then ran a genuinely fresh
  non-interactive `claude -p` process (not just config validation) that
  searched, then wrote a note through the real tool. Correct schema, correct
  tag/date handling, correctly declined to force a relation with nothing to
  relate to. **One caveat**: this had to be done from *inside* an existing
  Claude Code session (`claude` spawned as a subprocess) - the first attempt
  silently registered the MCP server against this outer session's project
  instead of the throwaway vault, because the subprocess inherited
  `CLAUDECODE=1`/`CLAUDE_CODE_SESSION_ID`/etc. Worked once those were
  stripped (`env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID ...`). One resulting
  note had `</content>`/`</invoke>` tool-call-formatting artifacts leaked
  into the body text - everything else about it was correct, but this is
  worth an independent check in a normal (non-nested) Claude Code session,
  since nesting one Claude process inside another is not how you'll actually
  use this and may have contributed to the leak.
- **Open WebUI, the actual novel part**: spun up a fully isolated throwaway
  OWUI instance (separate container/port/volume, zero contact with any real
  OWUI instance) and confirmed via its own `/api/v1/configs/tool_servers`
  and `/verify` endpoints that OWUI's backend can reach a memvault-infra
  mcpo bridge over `host.docker.internal` and correctly parse its full
  OpenAPI spec. Did not go further into wiring up a model connection and
  running an actual chat completion - that's OWUI's own model-connection
  feature, not something specific to this project, and reverse-engineering
  its internal config API to test it wasn't a good use of further effort.

Everything below is left because it's GUI-only with no CLI/API escape hatch
I could find, or requires infrastructure I don't have access to from here.

## 1. Claude Desktop

Pure GUI app, no CLI, no non-interactive mode. MCP config goes in
`~/Library/Application Support/Claude/claude_desktop_config.json`; requires
a full app quit/reopen (no hot reload). Verify the tool appears under the 🔌
icon **and shows connected**, not just present - don't assume icon presence
means connected, given what happened with Claude Code's approval gate.

## 2. Zed

Confirmed (via `zed --help` in full, including checking for any hidden
headless/agent-run/ACP-server mode) that the Zed CLI only ever opens a real
GUI window - there is no scriptable equivalent to `claude -p` or
`opencode run` for it.

1. Command palette -> `agent: create skill from url`, paste the raw GitHub
   URL of `skills/memnote/SKILL.md`. Confirm it shows up under Zed's skills
   list.
2. Add an MCP context server using the command/args/env block from
   `INTEGRATIONS.md`.
3. In Zed's agent panel, ask it to write a note; specifically check the
   skill actually gets *applied* (schema followed), not just *listed* -
   loading and application are different things, as the Claude Code test
   already showed once.

## 3. Open WebUI: the GUI-only remainder

The tool-server connectivity itself is verified (see above). Still needs a
human for the parts that only exist in the UI: Workspace -> Skills -> paste
`skills/memnote/SKILL.md` as a custom skill, then a real chat with a real
model to confirm the skill actually gets applied when the model calls
`write_note` (same "listed vs. applied" distinction as the Zed test).

## 4. opencode full agentic run

Connectivity is verified (`opencode mcp list` -> `connected`). The full
agentic run (model actually writes the note) is blocked by something
unrelated to this repo: the model IDs in `~/.config/opencode/opencode.json`
don't match what `mlx-serve` is currently serving on `localhost:8000/v1/models`
- every model tried either 404'd or hit an `UnknownError`. I didn't touch
that config since it's your separate local-model setup, not a memvault-infra
concern, and I can't tell if the mismatch is intentional (e.g. mid-migration
to different models). Once reconciled: copy the skill to the vault dir as
`AGENTS.md` (opencode doesn't consume `SKILL.md`), then
`opencode run --dir <vault-dir> --auto "<task>"`.

## 5. Native install.sh: nested-in-parent-repo path

The plain git-tracked-own-repo path is implicitly covered by everything
above using git-tracked throwaway vaults. Not yet proven: a vault nested
inside a *larger* existing repo, specifically that the watcher's
pathspec-scoping actually keeps unrelated changes elsewhere in that parent
repo untouched (this is the one install.sh was rewritten to fix - worth
proving, not just trusting the diff), and that the push timer's
whole-repo-branch push behaves as documented in that case.

## 6. Docker path: Linux as the host

Only tested via OrbStack on macOS - I don't have access to a separate Linux
machine, and spinning up a Linux VM or cloud instance to get one would be a
meaningfully bigger action than "testing what's built," so I stopped short
of that rather than doing it unilaterally. Bind-mount permissions and (per
the SSH findings above) `~/.ssh` mounting are the most likely places for
host-OS-specific surprises - the agent-socket-forwarding half of the fix
should actually work *better* on native Linux than it did here.
