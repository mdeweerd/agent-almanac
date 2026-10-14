## Run: 2026-10-14-workflow-loader-probe

**Observer**: Claude (Opus 5.5 main loop; probe designed by a Sonnet subagent, reviewed and amended by the main loop before any run; second measurement by an independent Sonnet subagent) | **Issue**: #293 (AC-1) | **Relates**: #288, #294

### Objective

#293 asks whether the repository's install instruction for a workflow is true. Several docs teach copying the source file under its own extension:

```text
cp workflows/<name>.mjs .claude/workflows/<name>.mjs
```

A static read of the Claude Code 2.1.293/2.1.299 bundle says the Workflow loader keeps an entry only when its file name ends in `.js`. A `.mjs`, `.cjs` or `.ts` name increments a `nearMissExt` counter and is dropped. The bundle also keys the merged workflow map by `meta.name`. A static read of minified code is a hypothesis, so AC-1 asks for a live run before any doc is changed on its strength. This record is that run.

### Environment

| Field | Value |
|-------|-------|
| Binary | Claude Code **2.1.299** (`claude --version`) |
| Session type | Headless `claude -p` child sessions, one per arm, launched by `probe.sh` |
| Model | `claude-sonnet-5-5` (`--model sonnet`; the loader does not depend on the model) |
| Permissions | `--permission-mode dontAsk --allowedTools Workflow` |
| Setting sources | default; the flag is not passed, so the child loads the same settings as a real session |
| User-scope workflows | `~/.claude/workflows` **does not exist** (recorded per run in `run*/user-scope-listing.txt`) |
| Environment | `CLAUDECODE`, `CLAUDE_CODE_*` (except OAuth and API-key helpers), `CLAUDE_PID` and `CLAUDE_EFFORT` are removed with `env -u` so that each child is a fresh top-level session. The names are listed in `run*/meta.txt` and in each `arm-*.cmdline.txt`. |
| Date | 2026-10-14. Run 1 at 14:16Z by the main loop; run 2 at 14:19Z by a separate agent, each in a fresh output directory |

### Method

`probe.sh <outdir>` builds three throwaway projects (`git init`) under a scratch directory outside every repository, and runs one headless session in each. It refuses an output directory inside a repository, or any ancestor that carries `.claude/workflows`.

| Arm | `.claude/workflows/` contents | `meta.name` | What it tests |
|---|---|---|---|
| A (control) | `probe-a.js` | `probe-arm-a` | The setup works at all. If A is not discovered, every other row is reported INCONCLUSIVE. |
| B | `probe-b.mjs` | `probe-arm-b` | Whether a `.mjs` file is discovered. |
| C | `probe-c1.js`, `probe-c2.js` | both `probe-arm-c` | Two files with different stems and the same name. |

Each workflow body is three lines: a pure-literal `meta`, a `log()` of a unique marker, and a `return`. There are no `agent()` calls.

A `.js`/`.mjs` pair that shares one `meta.name` in one directory is deliberately **not** an arm. Because the map is keyed by name, it could not tell "skipped" from "loaded and shadowed".

The prompt asks the child to "Run the saved workflow named `<name>` using the Workflow tool: pass only the name parameter". Each observable is read **mechanically**, never from the model's prose:

- **The tool call itself.** The `tool_use` input and the paired `tool_result` (with `is_error`) are extracted from the `--output-format stream-json` event log with `jq`.
- **Session-start registration.** The `init` event's `slash_commands`, filtered to `probe-arm-*`, show whether each workflow was registered when the session started.
- **Which file ran.** The body markers are read from three sources: the non-assistant events of the stream, the session transcript on disk, and **the persisted copy of the resolved script**, whose path the `tool_result` names. The last source does not depend on the background run finishing before `-p` exits, so it says which file the loader picked.

### Results

Both runs agree on every arm and every source.

| Arm | Run | `tool_result` (verbatim, first line) | `is_error` | `init` slash command | Body marker (stream / transcript / script copy) |
|---|---|---|---|---|---|
| A | 1 | `Workflow launched in background. Task ID: w9hcqvb10` | false | `probe-arm-a` | `PROBE_BODY_A_91c2` in all three |
| A | 2 | `Workflow launched in background. Task ID: w4u6korui` | false | `probe-arm-a` | `PROBE_BODY_A_91c2` in all three |
| B | 1 | `<tool_use_error>Workflow "probe-arm-b" not found. Available: deep-research</tool_use_error>` | true | *(none)* | none |
| B | 2 | `<tool_use_error>Workflow "probe-arm-b" not found. Available: deep-research</tool_use_error>` | true | *(none)* | none |
| C | 1 | `Workflow launched in background. Task ID: w1xci5fa5` | false | `probe-arm-c` (one entry) | `PROBE_BODY_c1_5e1d` in all three; `c2` absent |
| C | 2 | `Workflow launched in background. Task ID: wla99s9tj` | false | `probe-arm-c` (one entry) | `PROBE_BODY_c1_5e1d` in all three; `c2` absent |

The control gate passed in both runs. Every child exited 0 with empty stderr.

### Findings (scoped to Claude Code 2.1.299, project scope)

1. **A project workflow saved as `.claude/workflows/<name>.mjs` is not discovered.** It is not registered as a slash command at session start. Invoking it by name fails with `Workflow "<name>" not found`, and the error's `Available:` list does not include it. The live run agrees with the static read.
2. **A `.js` file is discovered and runs**, both by name through the Workflow tool and as a registered slash command.
3. **The invocation name is `meta.name`, not the file stem.** `probe-a.js` registers and is invoked as `probe-arm-a`. No arm registered a name derived from its file name. This was read from the **raw** event logs, which are not committed: in both runs, filtering the `init` event's `slash_commands` with `test("^probe")` gives only `probe-feature-flag-state` (an existing skill) and the `meta.name` values, with no `probe-a`, `probe-b`, `probe-c1` or `probe-c2`. The committed `extracted.json` filters on `probe-arm` and so cannot show a stem-derived name on its own. The docs' phrasing `.claude/workflows/<name>.mjs` → `Workflow({ name })` reads as if the stem were the name.
4. **Two `.js` files with the same `meta.name` collide silently.** One slash command is registered, the tool call succeeds with no warning, and one file's body runs. In both runs that was `probe-c1.js`. The tie-break rule (sort order, directory order, or something else) was **not** read and is not claimed.

Consequence for this repository: the install instruction `cp workflows/<name>.mjs .claude/workflows/<name>.mjs` installs a workflow the Workflow tool never finds. These sites teach it, measured with `rg` at `25a165bca` (English sources only):

- `skills/create-workflow/SKILL.md:65`, `:168`, `:171` and `:299` (`:171` sits in a frozen fence that has 4 stub mirrors)
- `guides/creating-workflows.md:107` and `:118`
- `guides/understanding-the-system.md:131`, and `:254` ("discovered by filename"; finding 3)
- `workflows/README.md:37`
- `CLAUDE.md:25` and `:70`
- `SECURITY.md:16`, generated from `scripts/generate-readmes.js:~940`
- a comment at `scripts/lib/mutation-parse.js:73`

Correcting them is Sprint 4's #293 docs slice, which this record licenses. It is **not** done here. The planned shape keeps `.mjs` as the repository's source extension and teaches `cp workflows/<name>.mjs .claude/workflows/<name>.js`. Finding 4 also argues that a curated install should prefix its file names, as `create-workflow:171`'s comment already suggests, and that a doc should say name collisions are silent.

### What this record does not establish

- **Other versions.** Only 2.1.299 was measured.
- **User scope.** `~/.claude/workflows` did not exist and was not exercised.
- **The collision tie-break,** as above.
- **Whether the background runs completed.** The script copies and the markers show which body the loader resolved. Each run's later completion was not awaited.
- **Interactive sessions.** These were headless `-p` sessions with the `CLAUDE*` session variables removed. An unscrubbed control (`PROBE_KEEP_ENV=1`) was not run.

### Files

- `probe.sh` — the probe. Re-run with `bash probe.sh <fresh-outdir-outside-any-repo>`.
- `run1/` and `run2/` — per run: `SUMMARY.txt` and `meta.txt`, plus per arm `cmdline`, `exitcode`, `stderr`, `extracted.json` (the Workflow `tool_use`/`tool_result` and the filtered `init` fields), the three marker files, `script-file.txt`, and `arm-*.script-copy.js.txt` (the persisted copy of the resolved script, renamed so it is not mistaken for runnable code).

Not committed: the raw `stream.jsonl` event logs. Their `init` events carry the operator's whole local environment (plugin list, 446 slash commands, agent definitions, a messaging socket path), which is not this repository's to publish. They are kept outside the repository with the session record.

Redaction: `/home/<operator>` was rewritten to `~` in the derived files (28 replacements). The remaining `tools/check-redaction.sh` findings are 14 `project-store-slug` hits, the `~/.claude/projects/<scratch-slug>/<uuid>/…` paths of the persisted script copies. They were classified as evidence with no secret in them, as in `tests/results/2026-09-17-repo-safety-rm-audit/`.
