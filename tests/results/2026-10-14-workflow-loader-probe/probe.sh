#!/usr/bin/env bash
# Workflow loader probe (issue #293 AC-1).
# Usage: bash probe.sh <outdir>                 run the three arms (three headless `claude -p`)
#        bash probe.sh --reextract <outdir>     launch nothing: re-run ONLY the extraction, the
#                                               run-state collection, the verdicts and the
#                                               SUMMARY over an <outdir> a previous run filled,
#                                               which must still hold its arm-*.stream.jsonl
#
# Question: on the installed Claude Code, does the Workflow loader discover a
# project workflow at .claude/workflows/<stem>.js, at <stem>.mjs, and do two .js
# files with different stems but the same meta.name collide?
#
# Each arm gets its OWN fresh scratch project (git init) under <outdir> and runs one
# headless `claude -p` session. The Workflow tool_use / tool_result and the init event
# are read MECHANICALLY from the stream-json event log, never from model prose. The body
# markers say which file was DISPATCHED; whether a body RAN is read from the runtime's
# run-state record (arm-*.run-state.json) and the stream's task_updated/task_notification
# status (extracted.json .task_status). No agent() calls in any probe workflow. Re-run with
# a different <outdir> for a second measurement. Env knobs (all optional, run mode only):
#   PROBE_MODEL          default sonnet  (loader is model-independent; sonnet follows the
#                        one-call instruction reliably, and the haiku alias is unconfirmed)
#   PROBE_PERMISSION     default dontAsk (+ --allowedTools Workflow); use
#                        bypassPermissions only if the Workflow call is denied
#   PROBE_ARM_TIMEOUT    default 240 seconds per arm
#   PROBE_BUDGET_USD     default 0.50 per arm
#   PROBE_KEEP_ENV=1     do NOT scrub CLAUDE* env vars (nested-session control run)
#   PROBE_SETTING_SOURCES default empty: the flag is not passed, so the child loads the
#                        same settings as a real session. ~/.claude/workflows is checked
#                        and recorded below; set project,local to exclude user scope
set -u

PROBE_MODEL="${PROBE_MODEL:-sonnet}"
PROBE_PERMISSION="${PROBE_PERMISSION:-dontAsk}"
PROBE_ARM_TIMEOUT="${PROBE_ARM_TIMEOUT:-240}"
PROBE_BUDGET_USD="${PROBE_BUDGET_USD:-0.50}"
PROBE_KEEP_ENV="${PROBE_KEEP_ENV:-0}"
PROBE_SETTING_SOURCES="${PROBE_SETTING_SOURCES:-}"

die() { echo "probe.sh: $*" >&2; exit 2; }

MODE=run
if [ "${1:-}" = "--reextract" ]; then
  MODE=reextract
  [ "$#" -eq 2 ] || die "usage: bash probe.sh --reextract <existing-outdir>"
  shift
else
  [ "$#" -eq 1 ] || die "usage: bash probe.sh <outdir> | bash probe.sh --reextract <existing-outdir>"
fi
if [ "$MODE" = run ]; then required_tools="claude jq git timeout realpath"; else required_tools="jq git realpath"; fi
for tool in $required_tools; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# ---- outdir must be absolute-resolvable and outside every repo --------------
if [ "$MODE" = run ]; then
  mkdir -p "$1" || die "cannot create outdir: $1"
else
  [ -d "$1" ] || die "--reextract needs an existing outdir: $1"
fi
OUT="$(realpath "$1")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TOP="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
for forbidden in "$SCRIPT_TOP" "/mnt/d/dev/p"; do
  [ -n "$forbidden" ] || continue
  case "$OUT/" in
    "$forbidden"/*) die "outdir $OUT is inside $forbidden - refusing (use the scratchpad)";;
  esac
done
if [ -n "$(git -C "$OUT" rev-parse --show-toplevel 2>/dev/null || true)" ]; then
  die "outdir $OUT is inside a git repository - refusing"
fi

if [ "$MODE" = run ]; then
  # No ancestor of outdir may carry its own .claude/workflows (project walk goes up).
  ancestor="$OUT"
  while [ "$ancestor" != "/" ]; do
    [ -d "$ancestor/.claude/workflows" ] && die "ancestor $ancestor has .claude/workflows - would contaminate"
    ancestor="$(dirname "$ancestor")"
  done
  [ -z "$(ls -A "$OUT" 2>/dev/null)" ] || die "outdir $OUT is not empty - use a fresh directory"
  ORIG_OUT="$OUT"
else
  # The run's own record says where its arms ran; the transcript slug is derived from that
  # path, not from where the outdir sits now. The version and model are the run's, too.
  [ -f "$OUT/meta.txt" ] || die "$OUT/meta.txt is missing - not a probe outdir"
  meta_field() { sed -n "s/^$1: //p" "$OUT/meta.txt" | head -1; }
  ORIG_OUT="$(meta_field outdir)"
  case "$ORIG_OUT" in /*) ;; *) die "meta.txt has no absolute 'outdir:' line: '$ORIG_OUT'";; esac
  CLAUDE_VERSION="$(meta_field claude_version)"
  PROBE_MODEL="$(meta_field model)"
  RUN_DATE="$(meta_field date_utc)"
  for arm in A B C; do
    [ -f "$OUT/arm-$arm.stream.jsonl" ] || die "$OUT/arm-$arm.stream.jsonl is missing - nothing to re-extract"
    [ -f "$OUT/arm-$arm.exitcode.txt" ] || die "$OUT/arm-$arm.exitcode.txt is missing"
  done
fi

if [ "$MODE" = run ]; then
  # ---- user scope: refuse if it already holds a probe-arm-* workflow -------
  USER_WF_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/workflows"
  {
    echo "user workflows dir: $USER_WF_DIR"
    if [ -d "$USER_WF_DIR" ]; then
      ls -la "$USER_WF_DIR"
    else
      echo "(does not exist)"
    fi
  } > "$OUT/user-scope-listing.txt" 2>&1
  if [ -d "$USER_WF_DIR" ] && grep -rEl 'probe-arm-' "$USER_WF_DIR" >/dev/null 2>&1; then
    die "user scope $USER_WF_DIR already contains probe-arm-* (see $OUT/user-scope-listing.txt)"
  fi

  # ---- nested-session env scrub --------------------------------------------
  env_unset_args=()
  env_scrubbed_names=()
  if [ "$PROBE_KEEP_ENV" != "1" ]; then
    while IFS= read -r name; do
      case "$name" in
        CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_USE_*|CLAUDE_CODE_API_KEY_HELPER*) continue;;
      esac
      env_unset_args+=(-u "$name")
      env_scrubbed_names+=("$name")
    done < <(env | cut -d= -f1 | grep -E '^(CLAUDECODE$|CLAUDE_CODE_|CLAUDE_PID$|CLAUDE_EFFORT$)' || true)
  fi

  CLAUDE_VERSION="$(claude --version 2>&1)"
  {
    echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "claude_version: $CLAUDE_VERSION"
    echo "model: $PROBE_MODEL"
    echo "permission: $PROBE_PERMISSION (+ --allowedTools Workflow)"
    echo "setting_sources: ${PROBE_SETTING_SOURCES:-(flag not passed: default sources)}"
    echo "keep_env: $PROBE_KEEP_ENV"
    echo "env_scrubbed_names: ${env_scrubbed_names[*]:-}"
    echo "outdir: $OUT"
  } > "$OUT/meta.txt"
  cat "$OUT/meta.txt"
else
  echo "reextract: $OUT (run at $RUN_DATE, arms ran under $ORIG_OUT, claude=$CLAUDE_VERSION)"
fi

# ---- workflow bodies (pure-literal meta, no agent()) -----------------------
write_workflow() { # path name marker arm_id body_tag
  cat > "$1" <<EOF
export const meta = { name: '$2', description: 'loader probe, no agents' }
log('$3')
return { arm: '$4', body: '$5', marker: '$3' }
EOF
}

make_project() { # dir
  mkdir "$1" && mkdir -p "$1/.claude/workflows" && git -C "$1" init -q || die "cannot create project $1"
}

# The tool_result paired, by tool_use_id, to the FIRST name-only Workflow call for <want>.
# A call carrying a scriptPath is skipped: per a static read of 2.1.299 the tool resolves
# scriptPath before it looks the name up, so such a call measures nothing about discovery
# (a call with `script` still reaches the lookup and is kept). Prints nothing when the arm
# made no such call. Reading results by position instead pairs a verdict with another call.
paired_result() { # extracted.json want
  jq -c --arg w "$2" '
    ([.workflow_tool_uses[]? | select(.input.name == $w and ((.input.scriptPath // "") == ""))][0].id) as $id
    | if $id == null then empty else ([.workflow_tool_results[]? | select(.tool_use_id == $id)][0] // {}) end' "$1" 2>/dev/null
}

extract_arm() { # arm_id workflow_name -- reads arm-<id>.stream.jsonl, writes the derived files
  local arm="$1" wfname="$2"
  local raw="$OUT/arm-$arm.stream.jsonl" ex="$OUT/arm-$arm.extracted.json"

  # mechanical extraction from the event log. New keys go at the END of the object, so a
  # re-extraction leaves every earlier key byte-identical (see RESULT.md, --reextract).
  jq -cR 'fromjson? | select(. != null)' "$raw" 2>/dev/null | jq -s '
    def txt: if type=="string" then . elif type=="array" then (map(.text? // "") | join("\n")) else tostring end;
    . as $ev
    | ([$ev[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Workflow")]) as $uses
    | ([$ev[] | select(.type=="user") | .message.content[]? | select(.type=="tool_result")]) as $res
    | ([$ev[] | select(.type=="system" and .subtype=="init")][0] // {}) as $init
    | { init_has_workflow_tool: (($init.tools // []) | index("Workflow") != null),
        init_probe_slash_commands: (($init.slash_commands // []) | map(select(test("probe-arm")))),
        event_count: ($ev | length),
        workflow_tool_uses: ($uses | map({id, input})),
        workflow_tool_results: ($uses | map(.id) as $ids
          | $res | map(select(.tool_use_id as $t | $ids | index($t) != null))
          | map({tool_use_id, is_error: (.is_error // false), text: (.content | txt)})),
        init_slash_command_count: (($init.slash_commands // []) | length),
        init_slash_commands_starting_probe: (($init.slash_commands // []) | map(select(test("^probe")))),
        task_status: [$ev[] | select(.type=="system" and (.subtype=="task_updated" or .subtype=="task_notification"))
          | {subtype, task_id, tool_use_id, status: (.status // .patch.status)}] }
  ' > "$ex" 2>/dev/null || echo '{"extract_failed":true}' > "$ex"

  # The tool_result names the persisted copy of the script it resolved ("Script file: <path>").
  # Its marker says which file the loader DISPATCHED. It does not say the body ran.
  local sf
  sf="$(paired_result "$ex" "$wfname" | jq -r '.text // ""' 2>/dev/null \
    | sed -n 's/^.*Script file: \(\/[^ ]*\.js\).*$/\1/p' | head -1)"
  if [ -n "$sf" ] && [ -f "$sf" ]; then
    echo "$sf" > "$OUT/arm-$arm.script-file.txt"
    cp "$sf" "$OUT/arm-$arm.script-copy.js"
    grep -oE 'PROBE_BODY_[A-Za-z0-9_]+' "$sf" | sort -u > "$OUT/arm-$arm.script-markers.txt"
  else
    echo "(no Script file path in the tool_result, or the file is absent: '${sf}')" > "$OUT/arm-$arm.script-file.txt"
    : > "$OUT/arm-$arm.script-markers.txt"
  fi

  # Markers from system/user events only (a `result` event's .result is the model's final
  # text, so it is excluded). task_started.prompt carries the dispatched script source, the
  # same bytes as the script copy: this is DISPATCH evidence, not execution, and it is
  # model-free only while the call passes `name` alone (the input is in extracted.json).
  jq -cR 'fromjson? | select(. != null and (.type == "system" or .type == "user"))' "$raw" 2>/dev/null \
    | grep -oE 'PROBE_BODY_[A-Za-z0-9_]+' | sort -u > "$OUT/arm-$arm.markers.txt"

  # The session's directory on disk, by cwd slug. It holds the script copy, the run-state
  # record (which embeds the script source) and the session .jsonl (which includes the
  # model's reply), so its marker grep is NOT independent of the script copy or of the
  # model. It is kept as a record of what the directory held.
  local slug; slug="$(printf '%s' "$ORIG_OUT/arm-$arm" | sed 's/[^A-Za-z0-9]/-/g')"
  local tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"
  if [ -d "$tdir" ]; then
    grep -rhoE 'PROBE_BODY_[A-Za-z0-9_]+' "$tdir" 2>/dev/null | sort -u > "$OUT/arm-$arm.transcript-markers.txt"
    ls -laR "$tdir" > "$OUT/arm-$arm.transcript-listing.txt" 2>&1
  else
    echo "(no transcript dir $tdir)" > "$OUT/arm-$arm.transcript-listing.txt"; : > "$OUT/arm-$arm.transcript-markers.txt"
  fi

  # Execution evidence: the runtime's own run-state record of each run (status, the log()
  # lines, the return value). Only these four fields are kept; the record also carries
  # scriptPath and the script itself. Always one JSON array, [] when the arm ran nothing.
  local rs_files=() f
  for f in "$tdir"/*/workflows/wf_*.json; do [ -f "$f" ] && rs_files+=("$f"); done
  if [ "${#rs_files[@]}" -gt 0 ]; then
    jq -n '[inputs | {workflowName, status, logs, result}]' "${rs_files[@]}" > "$OUT/arm-$arm.run-state.json" 2>/dev/null \
      || echo '{"run_state_extract_failed":true}' > "$OUT/arm-$arm.run-state.json"
  else
    printf '[]\n' > "$OUT/arm-$arm.run-state.json"
  fi
}

run_arm() { # arm_id workflow_name
  local arm="$1" wfname="$2"
  local dir="$OUT/arm-$arm" raw="$OUT/arm-$arm.stream.jsonl" err="$OUT/arm-$arm.stderr.txt"
  local prompt="Run the saved workflow named $wfname using the Workflow tool: pass only the name parameter, no script and no scriptPath. If the tool returns an error, show it verbatim and stop. If it succeeds, wait for it to complete, report its exact return value verbatim, then stop."
  local cmd=(env "${env_unset_args[@]}" claude -p "$prompt"
    --output-format stream-json --verbose
    --model "$PROBE_MODEL" --effort low
    --permission-mode "$PROBE_PERMISSION"
    --strict-mcp-config
    --max-budget-usd "$PROBE_BUDGET_USD"
    --allowedTools Workflow)
  if [ -n "$PROBE_SETTING_SOURCES" ]; then cmd+=(--setting-sources "$PROBE_SETTING_SOURCES"); fi
  printf '%q ' "${cmd[@]}" > "$OUT/arm-$arm.cmdline.txt"; echo >> "$OUT/arm-$arm.cmdline.txt"
  echo "[arm $arm] cwd=$dir"
  ( cd "$dir" && timeout "$PROBE_ARM_TIMEOUT" "${cmd[@]}" < /dev/null > "$raw" 2> "$err" )
  echo "$?" > "$OUT/arm-$arm.exitcode.txt"
  echo "[arm $arm] exit=$(cat "$OUT/arm-$arm.exitcode.txt") raw=$raw"
  extract_arm "$arm" "$wfname"
}

# ---- arms ------------------------------------------------------------------
if [ "$MODE" = run ]; then
  make_project "$OUT/arm-A"; write_workflow "$OUT/arm-A/.claude/workflows/probe-a.js"  probe-arm-a PROBE_BODY_A_91c2 probe-arm-a a
  make_project "$OUT/arm-B"; write_workflow "$OUT/arm-B/.claude/workflows/probe-b.mjs" probe-arm-b PROBE_BODY_B_4d7e probe-arm-b b
  make_project "$OUT/arm-C"
  write_workflow "$OUT/arm-C/.claude/workflows/probe-c1.js" probe-arm-c PROBE_BODY_c1_5e1d probe-arm-c c1
  write_workflow "$OUT/arm-C/.claude/workflows/probe-c2.js" probe-arm-c PROBE_BODY_c2_b83f probe-arm-c c2
  for f in "$OUT"/arm-*/.claude/workflows/*; do echo "== $f"; cat "$f"; done > "$OUT/workflow-sources.txt"

  run_arm A probe-arm-a
  run_arm B probe-arm-b
  run_arm C probe-arm-c
else
  extract_arm A probe-arm-a
  extract_arm B probe-arm-b
  extract_arm C probe-arm-c
fi

# ---- verdicts --------------------------------------------------------------
verdict() { # arm expected_name -> prints: discovered|invoked|detail
  local arm="$1" want="$2"
  local ex="$OUT/arm-$arm.extracted.json"
  local res result_text is_error discovered detail
  res="$(paired_result "$ex" "$want")"
  if [ -z "$res" ]; then
    # No name-only call for this name: discovery was not measured, so "unknown", never "no".
    echo "unknown|no|no name-only Workflow tool_use with name=$want (init_has_workflow_tool=$(jq -r '.init_has_workflow_tool' "$ex" 2>/dev/null))"; return
  fi
  result_text="$(printf '%s' "$res" | jq -r '.text // ""')"
  is_error="$(printf '%s' "$res" | jq -r '.is_error // false')"
  # "no" only for the lookup's own failure text, matched as a fixed string; any other
  # error (or no result at all) measured nothing about discovery.
  if printf '%s' "$result_text" | grep -qF "Workflow \"$want\" not found."; then
    discovered=no
  elif [ -z "$result_text" ] || [ "$is_error" = "true" ]; then
    discovered=unknown
  else
    discovered=yes
  fi
  detail="$(printf '%s' "$result_text" | tr '\n' ' ' | cut -c1-300)"
  echo "$discovered|yes|$detail"
}

IFS='|' read -r a_disc a_inv a_detail <<< "$(verdict A probe-arm-a)"
IFS='|' read -r b_disc b_inv b_detail <<< "$(verdict B probe-arm-b)"
IFS='|' read -r c_disc c_inv c_detail <<< "$(verdict C probe-arm-c)"

c_body="none"
c_marks="$(cat "$OUT/arm-C.markers.txt" "$OUT/arm-C.transcript-markers.txt" "$OUT/arm-C.script-markers.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
case "$c_marks" in
  *PROBE_BODY_c1_5e1d*PROBE_BODY_c2_b83f*|*PROBE_BODY_c2_b83f*PROBE_BODY_c1_5e1d*) c_body="BOTH(?)";;
  *PROBE_BODY_c1_5e1d*) c_body="c1 (probe-c1.js)";;
  *PROBE_BODY_c2_b83f*) c_body="c2 (probe-c2.js)";;
esac
a_marks="$(cat "$OUT/arm-A.markers.txt" "$OUT/arm-A.transcript-markers.txt" "$OUT/arm-A.script-markers.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
b_marks="$(cat "$OUT/arm-B.markers.txt" "$OUT/arm-B.transcript-markers.txt" "$OUT/arm-B.script-markers.txt" 2>/dev/null | sort -u | tr '\n' ' ')"

gate="OK"
if [ "$a_disc" != "yes" ]; then gate="CONTROL-FAILED (arm A not discovered/invoked): every other row is INCONCLUSIVE"; fi
# A row is INCONCLUSIVE when the control failed, or when that row measured nothing. The
# control row itself is tagged only when it measured nothing; the gate line covers a "no".
tag() { if [ "$gate" != "OK" ] || [ "$1" = "unknown" ]; then echo " [INCONCLUSIVE]"; else echo ""; fi; }
tag_control() { if [ "$1" = "unknown" ]; then echo " [INCONCLUSIVE]"; else echo ""; fi; }

ran() { # arm -> "<status> [<log() lines>] (stream task status: ...)" from the run-state record
  local arm="$1" rs ts
  rs="$(jq -r 'if type == "array" and length > 0
               then map("\(.status) [\((.logs // []) | join(","))]") | join("; ")
               elif type == "array" then "no run-state record" else "run-state unreadable" end' \
        "$OUT/arm-$arm.run-state.json" 2>/dev/null || echo "run-state unreadable")"
  ts="$(jq -r '(.task_status // []) | if length > 0 then map("\(.subtype)=\(.status)") | join(",") else "none" end' \
        "$OUT/arm-$arm.extracted.json" 2>/dev/null || echo "unreadable")"
  echo "$rs (stream task status: $ts)"
}

if [ "$MODE" = run ]; then mode_note=""; else mode_note="  mode=reextract (raw streams of the run at $RUN_DATE)"; fi
{
  echo "SUMMARY  date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)  claude=$CLAUDE_VERSION  model=$PROBE_MODEL$mode_note"
  echo "control gate: $gate"
  printf '%-4s %-22s %-11s %-9s %-14s %s\n' ARM FILES DISCOVERED INVOKED DISPATCHED DETAIL
  printf '%-4s %-22s %-11s %-9s %-14s %s\n' A "probe-a.js$(tag_control "$a_disc")" "$a_disc" "$a_inv" "${a_marks:-none}" "exit=$(cat "$OUT/arm-A.exitcode.txt") $a_detail"
  printf '%-4s %-22s %-11s %-9s %-14s %s\n' B "probe-b.mjs$(tag "$b_disc")"        "$b_disc" "$b_inv" "${b_marks:-none}" "exit=$(cat "$OUT/arm-B.exitcode.txt") $b_detail"
  printf '%-4s %-22s %-11s %-9s %-14s %s\n' C "probe-c1.js+c2.js$(tag "$c_disc")"  "$c_disc" "$c_inv" "file=$c_body" "exit=$(cat "$OUT/arm-C.exitcode.txt") $c_detail"
  echo "ran (run-state record: status [log() lines]):"
  echo "  A  $(ran A)"
  echo "  B  $(ran B)"
  echo "  C  $(ran C)"
  echo "per-arm files: $OUT/arm-{A,B,C}.{cmdline.txt,stream.jsonl,stderr.txt,exitcode.txt,extracted.json,markers.txt,run-state.json}"
  echo "C script copy (which file the loader dispatched): $(cat "$OUT/arm-C.script-file.txt" 2>/dev/null) markers: $(tr '\n' ' ' < "$OUT/arm-C.script-markers.txt" 2>/dev/null)"
  echo "user scope listing: $OUT/user-scope-listing.txt"
} | tee "$OUT/SUMMARY.txt"
