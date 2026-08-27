#!/usr/bin/env bash
# test_approver.sh — Tests for claude-yolo, focused on Bash, Bash(rm:*), and WebFetch approval
#
# Usage: bash test_approver.sh
#        bash test_approver.sh -v          # verbose — show pass details
#        bash test_approver.sh <pattern>   # run only tests matching pattern

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── test harness ─────────────────────────────────────────────────────────────

PASS=0 FAIL=0 SKIP=0 TOTAL=0
VERBOSE="${VERBOSE:-0}"
FILTER="${1:-}"
[[ "$FILTER" == "-v" ]] && { VERBOSE=1; FILTER="${2:-}"; }
CURRENT_SECTION=""
FAILURES=()

_red=$'\033[0;31m' _green=$'\033[0;32m' _yellow=$'\033[0;33m' _reset=$'\033[0m'

_print_block() {
    local label="$1" content="$2"
    if [[ -z "$content" ]]; then
        echo "        $label: <empty>"
        return 0
    fi

    echo "        $label:"
    while IFS= read -r line; do
        echo "          $line"
    done <<< "$content"
}

_record_failure() {
    local desc="$1" detail="${2:-}"
    local section="$CURRENT_SECTION"
    [[ -z "$section" ]] && section="(no section)"

    FAILURES+=("$section :: $desc${detail:+ :: $detail}")
}

assert_ok() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    local output output_file status
    output_file="$(mktemp)"
    "$@" >"$output_file" 2>&1
    status=$?
    output="$(cat "$output_file")"
    rm -f "$output_file"
    if (( status == 0 )); then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
        echo "        exit status: $status"
        _print_block "output" "$output"
        _record_failure "$desc" "exit status $status"
    fi
}

assert_fail() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    local output output_file status
    output_file="$(mktemp)"
    "$@" >"$output_file" 2>&1
    status=$?
    output="$(cat "$output_file")"
    rm -f "$output_file"
    if (( status == 0 )); then
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc  (expected failure, got success)"
        _print_block "output" "$output"
        _record_failure "$desc" "expected failure, got success"
    else
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
        _record_failure "$desc" "expected $(printf '%q' "$expected"), actual $(printf '%q' "$actual")"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
        echo "        missing '$needle' in output"
        _print_block "haystack" "$haystack"
        _record_failure "$desc" "missing $(printf '%q' "$needle")"
    fi
}

section() {
    CURRENT_SECTION="$1"
    echo "${_yellow}▸ $1${_reset}"
}

# ── source the units under test ──────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"

# Source detect_prompt, detect_collapsed and friends without running the daemon's main_loop.
# We extract the functions only.
eval "$(sed -n '/^declare -A LAST_APPROVED/p; /^declare -A LAST_SENT_HASH/p; /^declare -A SEND_STREAK/p; /^declare -A HIDDEN_NUDGES/p; /^declare -A HIDDEN_PREV_HASH/p; /^declare -A HIDDEN_CHANGES/p; /^declare -A HIDDEN_MARK_TS/p; /^declare -A HIDDEN_GATED_LOGGED/p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^audit()/,/^}/p; /^audit_event()/,/^}/p; /^in_cooldown()/,/^}/p; /^send_should_skip()/,/^}/p; /^note_key_sent()/,/^}/p; /^detect_prompt()/,/^}/p; /^prompt_approval_key()/,/^}/p; /^detect_question_prompt()/,/^}/p; /^question_approval_key()/,/^}/p; /^detect_plan_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^detect_collapsed()/,/^}/p; /^plan_approval_file()/,/^}/p; /^slash_approval_file()/,/^}/p; /^clear_plan_approval_marker()/,/^}/p; /^clear_slash_approval_marker()/,/^}/p; /^plan_approval_marker_valid()/,/^}/p; /^slash_approval_marker_valid()/,/^}/p; /^notify_waiting_dir()/,/^}/p; /^notify_marker_fresh()/,/^}/p; /^notify_marker_ts()/,/^}/p; /^notify_marker_msg()/,/^}/p; /^notify_marker_blindable()/,/^}/p; /^clear_notify_marker()/,/^}/p; /^reset_hidden_state()/,/^}/p; /^hidden_candidate()/,/^}/p' "$SCRIPT_DIR/lib/approver-daemon.sh")"

# Source build_agent_cmd from the launcher
eval "$(sed -n '/^build_agent_cmd()/,/^}/p' "$SCRIPT_DIR/claude-yolo")"

# Source control-pane helpers without running the interactive loop.
source "$SCRIPT_DIR/lib/control-pane.sh" "" "" "standard"

# ── helper to build realistic pane captures ──────────────────────────────────

# Simulates Claude Code pane output: scrollback context + permission prompt at bottom.
# $1 = tool line (e.g. "Claude wants to execute Bash")
# $2 = command/detail line
# $3 = optional extra context lines before the prompt
make_prompt() {
    local tool_line="$1" detail_line="$2" extra="${3:-}"
    local output=""
    # Typical scrollback: agent working text
    output+="  Claude is working on your task...
  Analyzing the codebase structure.
  Reading files to understand the project.
"
    [[ -n "$extra" ]] && output+="$extra
"
    # The permission box
    output+="  ╭──────────────────────────────────────────────────╮
  │ $tool_line
  │
  │   $detail_line
  │
  │   Allow                  Deny
  ╰──────────────────────────────────────────────────╯"
    echo "$output"
}

# Simulates Claude Code v2.x "Yes/No" numbered prompt style.
# $1 = tool name (e.g. "Bash", "Bash(rm:*)", "WebFetch")
# $2 = command/detail line
make_yesno_prompt() {
    local tool="$1" detail_line="$2"
    cat <<EOF
  Claude is working on your task...
  Analyzing the codebase structure.

 $tool command

   $detail_line
   List current directory contents

 Permission rule $tool requires confirmation for this command.

 Do you want to proceed?
 > 1. Yes
   2. No

 Esc to cancel
EOF
}

###############################################################################
#                   YES/NO STYLE — BASH PERMISSION PROMPTS                    #
###############################################################################

section "detect_prompt — Yes/No style: Bash"

assert_ok "YesNo Bash: ls command" \
    detect_prompt "$(make_yesno_prompt "Bash" "ls /home/user/git/claude_yolo/")"

assert_ok "YesNo Bash: git status" \
    detect_prompt "$(make_yesno_prompt "Bash" "git status")"

assert_ok "YesNo Bash: pytest" \
    detect_prompt "$(make_yesno_prompt "Bash" "python3 -m pytest tests/ -v")"

assert_ok "YesNo Bash: npm command" \
    detect_prompt "$(make_yesno_prompt "Bash" "npm install --save-dev jest")"

# Exact copy of what the user saw stuck
assert_ok "YesNo Bash: exact real prompt" \
    detect_prompt "$(cat <<'PANE'
 Bash command

   ls /home/user/git/claude_yolo/
   List current directory contents

 Permission rule Bash requires confirmation for this command.

 Do you want to proceed?
 > 1. Yes
   2. No

 Esc to cancel · Tab to amend · ctrl+e to explain
PANE
)"

_out="$(detect_prompt "$(make_yesno_prompt "Bash" "ls")")"
assert_contains "YesNo Bash: pattern includes +tool" "$_out" "+tool"
assert_contains "YesNo Bash: pattern includes +context" "$_out" "+context"

###############################################################################
#            WRITE/EDIT FILE DIALOGS — GARBLED No, ESC FOOTER                 #
###############################################################################

section "detect_prompt — Write/Edit file dialogs (garbled No, Esc footer)"

# Exact shape of a real stuck prompt (phone-width pane, 2026-07-11): the
# Write tool's file preview scrolled the tool header off-screen, and option
# 2's wrapped "(shift+tab)" suffix overwrote option 3, leaving "3. Nohift+tab)"
# — so the \bNo\b option regex can never match.
_write_dialog_garbled="$(cat <<'PANE'
  130 "tmux": "tmux",
  131 "v%@": "v%@",
  132 "⚠ Keep this secret — anyone with the private key can authenticate"
  133 }
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create hi.json?
 ❯ 1. Yes
   2. Yes, allow all edits in l10n-out/ during this session
   3. Nohift+tab)

 Esc to cancel · Tab to amend
PANE
)"

assert_ok "WriteDialog: garbled No detected via Esc footer" \
    detect_prompt "$_write_dialog_garbled"

_out="$(detect_prompt "$_write_dialog_garbled")"
assert_contains "WriteDialog: garbled No pattern is Yes+Esc" "$_out" "Yes+Esc"

assert_eq "WriteDialog: garbled No approved with Enter" \
    "Enter" "$(prompt_approval_key "$_write_dialog_garbled")"

# Clean render of the same dialog still detects through the classic No path
assert_ok "WriteDialog: clean render detected" \
    detect_prompt "$(cat <<'PANE'
  133 }
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create hi.json?
 ❯ 1. Yes
   2. Yes, allow all edits in l10n-out/ during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)
PANE
)"

# The Edit-tool variant's question line is enough context on its own
assert_ok "WriteDialog: 'make this edit' question detected" \
    detect_prompt "$(cat <<'PANE'
 Do you want to make this edit to config.yaml?
 ❯ 1. Yes
   2. No

 Esc to cancel
PANE
)"

# Esc footer alone (no numbered Yes option) must not fire
assert_fail "WriteDialog: Esc footer without Yes option ignored" \
    detect_prompt "$(cat <<'PANE'
 Search results for "cancel":
   help.txt: press Esc to cancel the current operation
 Do you want to proceed with the write-up? It requires approval.
PANE
)"

# A quoted/cat'ed menu with a bare ">" marker and no No option must not fire
# via the Esc fallback — only a real ❯/› selection marker qualifies
assert_fail "WriteDialog: quoted fixture without live marker ignored" \
    detect_prompt "$(cat <<'PANE'
 $ cat docs/dialog-example.txt
 Do you want to create hi.json?
 > 1. Yes
   2. Yes, allow all edits in l10n-out/ during this session

 Esc to cancel · Tab to amend
PANE
)"

# Agent narration containing "want to create" is not dialog context
assert_fail "WriteDialog: narration 'want to create' ignored" \
    detect_prompt "$(cat <<'PANE'
 I want to create the localization files next. Here is the plan:
 ❯ 1. Yes we keep the existing keys
   2. Yesterday's extraction had gaps

 Press Esc to cancel the build when done.
PANE
)"

section "detect_prompt — Yes/No style: Bash(rm:*)"

assert_ok "YesNo Bash(rm:*): rm -rf" \
    detect_prompt "$(make_yesno_prompt "Bash(rm:*)" "rm -rf /tmp/test-dir")"

assert_ok "YesNo Bash(rm:*): rm single file" \
    detect_prompt "$(make_yesno_prompt "Bash(rm:*)" "rm /tmp/obsolete.log")"

assert_ok "YesNo Bash(rm:*): rm with glob" \
    detect_prompt "$(make_yesno_prompt "Bash(rm:*)" "rm -f /tmp/*.bak")"

assert_ok "YesNo Bash(rm:*): exact real prompt" \
    detect_prompt "$(cat <<'PANE'
 Bash(rm:*) command

   rm -rf dist/ build/
   Clean build artifacts

 Permission rule Bash(rm:*) requires confirmation for this command.

 Do you want to proceed?
 > 1. Yes
   2. No

 Esc to cancel · Tab to amend · ctrl+e to explain
PANE
)"

_out="$(detect_prompt "$(make_yesno_prompt "Bash(rm:*)" "rm -rf /tmp")")"
assert_contains "YesNo Bash(rm:*): pattern includes +tool" "$_out" "+tool"

###############################################################################
#                YES/NO STYLE — WEBFETCH PERMISSION PROMPTS                   #
###############################################################################

section "detect_prompt — Yes/No style: WebFetch"

assert_ok "YesNo WebFetch: simple URL" \
    detect_prompt "$(make_yesno_prompt "WebFetch" "https://example.com")"

assert_ok "YesNo WebFetch: API docs" \
    detect_prompt "$(make_yesno_prompt "WebFetch" "https://docs.python.org/3/library/json.html")"

assert_ok "YesNo WebFetch: exact real prompt" \
    detect_prompt "$(cat <<'PANE'
 WebFetch

   url: https://docs.rs/tokio/latest/tokio/
   prompt: Extract the main API docs

 Permission rule WebFetch requires confirmation for this command.

 Do you want to proceed?
 > 1. Yes
   2. No

 Esc to cancel · Tab to amend · ctrl+e to explain
PANE
)"

_out="$(detect_prompt "$(make_yesno_prompt "WebFetch" "https://example.com")")"
assert_contains "YesNo WebFetch: pattern includes +tool" "$_out" "+tool"

# Exact shape of a real stuck prompt (phone-width pane, 2026-08-27): a fetch
# requested by a workflow subagent. Its header reads "Fetch" (not
# "WebFetch"), the long prompt argument pushes that header out of the menu
# region, and the question is "Do you want to allow Claude to fetch this
# content?" — which matched none of the old tool keywords or context phrases,
# so the dialog sat unanswered.
_fetch_dialog_subagent="$(cat <<'PANE'
 One caveat on process: one of the 22 review agents never returned, so I
 acted on 21 verdicts rather than the full set.

✳ Waiting for 1 dynamic workflow to finish

 Fetch · from the "review-onscreen-batch" workflow

   url: https://sw.kovidgoyal.net/kitty/graphics-protocol/
   │ prompt: What happens when a client transmits an image with the SAME
     image id (i=) as a previously transmitted image — is the old image
     replaced, and are its existing placements deleted? Quote the exact
     wording about image ids being reused/replaced and about placement
     ids.
  Claude wants to fetch content from sw.kovidgoyal.net

Do you want to allow Claude to fetch this content?
❯ 1. Yes
  2. Yes, and don't ask again for sw.kovidgoyal.net
  3. No, and tell Claude what to do differently (esc)
PANE
)"

assert_ok "Fetch dialog: subagent fetch prompt detected" \
    detect_prompt "$_fetch_dialog_subagent"

assert_eq "Fetch dialog: approved with Enter (marker on 1. Yes)" \
    "Enter" "$(prompt_approval_key "$_fetch_dialog_subagent")"

# Both new signals must carry it on their own: the "Claude wants to fetch"
# summary line and the "Do you want to allow" question are each enough
# context, and "fetch" alone satisfies the tool keyword.
assert_ok "Fetch dialog: question line alone is enough context" \
    detect_prompt "$(cat <<'PANE'
   file: /etc/hosts

Do you want to allow Claude to read this file?
❯ 1. Yes
  2. Yes, and don't ask again this session
  3. No, and tell Claude what to do differently (esc)
PANE
)"

_out="$(detect_prompt "$_fetch_dialog_subagent")"
assert_contains "Fetch dialog: pattern includes +tool" "$_out" "+tool"
assert_contains "Fetch dialog: pattern includes +context" "$_out" "+context"

# Prose that merely talks about fetching must still not fire — the numbered
# Yes/No menu at the pane bottom is what makes it a dialog.
assert_fail "Fetch dialog: narration about fetching ignored" \
    detect_prompt "$(cat <<'PANE'
 I want to allow the client to fetch this content lazily. Do you want to
 allow that? I listed the options in docs/fetching.md.
PANE
)"

###############################################################################
#              YES/NO STYLE — FALSE POSITIVE RESISTANCE                       #
###############################################################################

section "detect_prompt — Yes/No style: false positives"

# Numbered list in normal output, no tool/context
assert_fail "YesNo FP: numbered list without tool or context" \
    detect_prompt "$(cat <<'PANE'
  Choose an option:
  1. Yes, continue
  2. No, abort
PANE
)"

# "1. Yes" / "2. No" in code output without tool keywords
assert_fail "YesNo FP: code output with Yes/No" \
    detect_prompt "$(cat <<'PANE'
  options = {
    "1. Yes": handle_yes,
    "2. No": handle_no,
  }
PANE
)"

# Has proceed but no numbered options
assert_fail "YesNo FP: context phrase but no Yes/No or Allow/Deny" \
    detect_prompt "$(cat <<'PANE'
  Do you want to proceed?
  Bash command completed.
  Type 'y' to confirm.
PANE
)"

###############################################################################
#              YES/NO STYLE — TRUST FOLDER PROMPT                             #
###############################################################################

section "detect_prompt — Yes/No style: Trust folder"

assert_ok "Trust folder: exact real prompt" \
    detect_prompt "$(cat <<'PANE'

 Accessing workspace:

 /home/user/git/snake-game

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's
 in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ 1. Yes, I trust this folder
   2. No, exit
 ?
PANE
)"

assert_ok "Trust folder: minimal" \
    detect_prompt "$(cat <<'PANE'
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
PANE
)"

assert_ok "Trust folder: trust this project variant" \
    detect_prompt "$(cat <<'PANE'
 Do you trust this project?
 ❯ 1. Yes, I trust this project
   2. No, exit
PANE
)"

_out="$(detect_prompt "$(cat <<'PANE'
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
PANE
)")"
assert_contains "Trust folder: pattern includes +context" "$_out" "+context"

###############################################################################
#          YES/NO STYLE — LONG "DON'T ASK AGAIN" MENUS (WIDE WINDOW)          #
###############################################################################

section "detect_prompt — Yes/No style: long don't-ask-again menus"

# Exact real capture: a multi-line command echoed inside option 2 pushes
# "❯ 1. Yes" (and "Do you want to proceed?") above the 20-line tail window,
# and a task list fills the bottom of the pane.
_long_dontask_prompt="$(cat <<'PANE'
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: timeout 120 docker exec
      codex-telegram-bot-1 sh -c '
      cd /tmp
      for tier in fast priority unset; do
        if [ "$tier" = unset ]; then arg=""; else arg="-c
      service_tier=$tier"; fi
        RUST_LOG=codex_core=trace,codex_api=trace codex exec
      --skip-git-repo-check --color never -s read-only -m
      gpt-5.6-sol -c model_reasoning_effort=low $arg -- "Reply OK"
      >/dev/null 2>/tmp/trace-$tier.log
        echo "== tier=$tier:"
        grep -io "service_tier[\":= ]*[a-z_]*"
      /tmp/trace-$tier.log | sort | uniq -c | head -5
      done'
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain

  5 tasks (0 done, 5 open)
  ◻ Pin latest codex + codex-yolo in Dockerfile
  ◻ Default model gpt-5.6-sol + ultra effort + fast ti…
  ◻ Run tests and rebuild image
  ◻ Update running containers (gateway + workers)
  ◻ Commit and push to main
PANE
)"

assert_ok "Long don't-ask-again: Yes option above tail window is detected" \
    detect_prompt "$_long_dontask_prompt"

_out="$(detect_prompt "$_long_dontask_prompt")"
assert_contains "Long don't-ask-again: pattern includes +context" "$_out" "+context"

assert_eq "Long don't-ask-again: marker on Yes → Enter" \
    "Enter" "$(prompt_approval_key "$_long_dontask_prompt")"

# Same shape but even the header scrolled off — context comes from
# "requires approval" alone
assert_ok "Long don't-ask-again: 'requires approval' as only context" \
    detect_prompt "$(cat <<'PANE'
 This command requires approval
 ❯ 1. Yes
   2. Yes, and don't ask again for: some-very-long-obscure-utility
      --with --many --flags
   3. No
PANE
)"

# A stale menu-looking numbered list without any secondary signal must not fire
assert_fail "Long don't-ask-again FP: menu shape without secondary signal" \
    detect_prompt "$(cat <<'PANE'
 ❯ 1. Yes
   2. No
 some unrelated pane content
PANE
)"

# Numbered prose starting with Yes*/No* words must not count as menu options
assert_fail "Long don't-ask-again FP: 'Yesterday/Nothing' prose list" \
    detect_prompt "$(cat <<'PANE'
 Status summary:
 1. Yesterday the daemon was running fine
 2. Nothing is blocking the release
 I will start by running the existing suite.
PANE
)"

# Quoted menu strings in code output must not count as option lines
assert_fail "Long don't-ask-again FP: quoted Yes/No in code, wide window" \
    detect_prompt "$(cat <<'PANE'
  options = {
    "1. Yes": handle_yes,
    "2. No": handle_no,
  }
  print("Do you want to proceed?")
  more output here
PANE
)"

# A menu merely *displayed* high on screen (cat/diff of fixtures) with an idle
# shell at the bottom must not fire: the No option is not near the pane bottom.
assert_fail "Long don't-ask-again FP: displayed menu with 25+ lines below" \
    detect_prompt "$(cat <<'PANE'
$ sed -n '380,400p' test_approver.sh
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: git push
   3. No
line6
line7
line8
line9
line10
line11
line12
line13
line14
line15
line16
line17
line18
line19
line20
line21
line22
line23
line24
line25
line26
line27
line28
line29
line30
$
PANE
)"

###############################################################################
#                 PROMPT APPROVAL KEY — TARGETING THE YES OPTION              #
###############################################################################

section "prompt_approval_key — always lands on Yes"

assert_eq "Approval key: marker on '1. Yes' → Enter" \
    "Enter" "$(prompt_approval_key "$(cat <<'PANE'
 Do you want to proceed?
 ❯ 1. Yes
   2. No
PANE
)")"

assert_eq "Approval key: marker on 'Yes, and don't ask again' → Enter" \
    "Enter" "$(prompt_approval_key "$(cat <<'PANE'
 Do you want to proceed?
   1. Yes
 ❯ 2. Yes, and don't ask again for: git push
   3. No
PANE
)")"

assert_eq "Approval key: marker moved to No → send Yes option number" \
    "1" "$(prompt_approval_key "$(cat <<'PANE'
 Do you want to proceed?
   1. Yes
   2. Yes, and don't ask again for: git push
 ❯ 3. No
PANE
)")"

assert_eq "Approval key: trust folder marker on Yes → Enter" \
    "Enter" "$(prompt_approval_key "$(cat <<'PANE'
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
PANE
)")"

assert_eq "Approval key: Style A buttons (no marker) → Enter" \
    "Enter" "$(prompt_approval_key "$(cat <<'PANE'
  Claude wants to execute Bash
  ls -la /tmp
  Allow              Deny
PANE
)")"

###############################################################################
#            ASKUSERQUESTION DIALOGS — RECOMMENDED OPTION AUTO-ANSWER         #
###############################################################################

section "detect_question_prompt — AskUserQuestion recommended options"

_question_marker_on_recommended="$(cat <<'PANE'
 Which auth method should we use?

 ❯ 1. JWT tokens (Recommended)
      Stateless, no session store needed
   2. Session cookies
      Server-side session store
   3. Other
      Provide your own answer
PANE
)"

_question_marker_elsewhere="$(cat <<'PANE'
 Which auth method should we use?

 ❯ 1. Session cookies
      Server-side session store
   2. JWT tokens (Recommended)
      Stateless, no session store needed
   3. Other
      Provide your own answer
PANE
)"

_question_marker_on_other="$(cat <<'PANE'
 Which auth method should we use?

   1. JWT tokens (Recommended)
      Stateless, no session store needed
   2. Session cookies
      Server-side session store
 ❯ 3. Other
      Provide your own answer
PANE
)"

assert_ok "Question: recommended option with marker detected" \
    detect_question_prompt "$_question_marker_on_recommended"

assert_ok "Question: recommended option, marker elsewhere, detected" \
    detect_question_prompt "$_question_marker_on_other"

_out="$(detect_question_prompt "$_question_marker_on_recommended")"
assert_eq "Question: pattern is question+recommended" \
    "question+recommended" "$_out"

# Boxed rendering with │ borders
assert_ok "Question: boxed rendering with borders detected" \
    detect_question_prompt "$(cat <<'PANE'
 ╭──────────────────────────────────────────────╮
 │ Which library should we use?                 │
 │                                              │
 │ ❯ 1. requests (Recommended)                  │
 │   2. httpx                                   │
 │   3. Other                                   │
 ╰──────────────────────────────────────────────╯
PANE
)"

# No recommended label → leave for the user
assert_fail "Question FP: menu without a recommended option is left alone" \
    detect_question_prompt "$(cat <<'PANE'
 Which auth method should we use?
 ❯ 1. JWT tokens
   2. Session cookies
   3. Other
PANE
)"

# Recommended mentioned in prose, no active menu → no detection
assert_fail "Question FP: prose mentioning (Recommended) without a menu" \
    detect_question_prompt "$(cat <<'PANE'
 The config guide says:
 Use option 1. The JWT approach is the one labelled (Recommended) in
 the docs, so let's go with that.
PANE
)"

# Single option is not a menu
assert_fail "Question FP: single numbered line is not a menu" \
    detect_question_prompt "$(cat <<'PANE'
 ❯ 1. JWT tokens (Recommended)
PANE
)"

# Yes/No permission prompt has no recommended label → not a question
assert_fail "Question FP: permission prompt is not a question" \
    detect_question_prompt "$(make_yesno_prompt "Bash" "ls /tmp")"

# Claude Code's own /model picker uses lowercase "(recommended)" — that's a
# user-driven menu the daemon must not fight. Only AskUserQuestion's
# capital-R "(Recommended)" convention triggers.
assert_fail "Question FP: /model picker with lowercase (recommended)" \
    detect_question_prompt "$(cat <<'PANE'
 Select model

 ❯ 1. Default (recommended)     Opus 4.8 · best for daily use
   2. Opus                      Most capable for complex work
   3. Haiku                     Fastest for simple tasks
PANE
)"

# multiSelect question rendering: checkboxes need toggling before Enter —
# blindly confirming would submit nothing. Leave for the user.
assert_fail "Question FP: multiSelect checkboxes are left alone" \
    detect_question_prompt "$(cat <<'PANE'
 Which features do you want to enable?

 ❯ 1. [ ] Retry logic (Recommended)
   2. [ ] Metrics export
   3. [ ] Debug logging
PANE
)"

# A markdown blockquote "> 1. ..." is not an active selection marker
assert_fail "Question FP: markdown blockquote is not a menu marker" \
    detect_question_prompt "$(cat <<'PANE'
 The setup guide says:
 > 1. Install the CLI first (Recommended)
 > 2. Then authenticate
 Follow those steps in order.
PANE
)"

# A question dialog merely *displayed* high on screen (cat of a fixture) with
# an idle shell at the bottom must not fire: no option line near the bottom.
assert_fail "Question FP: displayed question menu with 25+ lines below" \
    detect_question_prompt "$(cat <<'PANE'
$ cat question-fixture.txt
 Which auth method should we use?
 ❯ 1. JWT tokens (Recommended)
   2. Session cookies
   3. Other
line6
line7
line8
line9
line10
line11
line12
line13
line14
line15
line16
line17
line18
line19
line20
line21
line22
line23
line24
line25
line26
line27
line28
line29
line30
$
PANE
)"

section "question_approval_key — recommended option targeting"

assert_eq "Question key: marker on recommended → Enter" \
    "Enter" "$(question_approval_key "$_question_marker_on_recommended")"

assert_eq "Question key: marker on option 1, recommended is 2 → send 2" \
    "2" "$(question_approval_key "$_question_marker_elsewhere")"

assert_eq "Question key: marker on Other, recommended is 1 → send 1" \
    "1" "$(question_approval_key "$_question_marker_on_other")"

###############################################################################
#                 COLLAPSED TRANSCRIPT VIEW (ctrl+o to expand)                #
###############################################################################

section "detect_collapsed — Collapsed transcript detection"

assert_ok "Collapsed: Bash pending" \
    detect_collapsed "$(cat <<'PANE'
● I'll check the project structure first.

● Bash(ls /home/user/git/claude_yolo/)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

assert_ok "Collapsed: Bash(rm:*) pending" \
    detect_collapsed "$(cat <<'PANE'
● Cleaning up build artifacts.

● Bash(rm -rf dist/ build/)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

assert_ok "Collapsed: WebFetch pending" \
    detect_collapsed "$(cat <<'PANE'
● Let me check the API docs.

● WebFetch(https://docs.example.com/api)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

assert_ok "Collapsed: Read pending" \
    detect_collapsed "$(cat <<'PANE'
● Read(src/main.py)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

assert_ok "Collapsed: Write pending" \
    detect_collapsed "$(cat <<'PANE'
● Write(src/new_file.py)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

assert_ok "Collapsed: Edit pending" \
    detect_collapsed "$(cat <<'PANE'
● Edit(src/config.json)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

# Exact reproduction of the stuck session from the bug report
assert_ok "Collapsed: exact stuck session capture" \
    detect_collapsed "$(cat <<'PANE'
● I'll start by planning and then implementing a Snake game with comprehensive unit tests. Let me create the project structure.

● Bash(ls /home/user/git/claude_yolo/)

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

# Pattern output should contain tool name
_out="$(detect_collapsed "$(cat <<'PANE'
● Bash(ls /tmp)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)")"
assert_contains "Collapsed: pattern includes tool name" "$_out" "collapsed+Bash"

_out="$(detect_collapsed "$(cat <<'PANE'
● WebFetch(https://example.com)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)")"
assert_contains "Collapsed: WebFetch pattern" "$_out" "collapsed+WebFetch"

# A subagent's fetch renders under the shorter "Fetch" header
_out="$(detect_collapsed "$(cat <<'PANE'
● Fetch(https://sw.kovidgoyal.net/kitty/graphics-protocol/)

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)")"
assert_contains "Collapsed: Fetch pattern" "$_out" "collapsed+Fetch"

section "detect_collapsed — False positive resistance"

# Normal working output, no ● ToolName(...)
assert_fail "Collapsed FP: normal agent output with transcript line" \
    detect_collapsed "$(cat <<'PANE'
● I'll help you with that task.

  Some working output here.

──────────────────────────────────────────────────────────────────────────────
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

# Has "Showing detailed transcript" but no ● ToolName(
assert_fail "Collapsed FP: no tool indicator" \
    detect_collapsed "$(cat <<'PANE'
  Claude is working...
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

# Has ● Bash(...) but NOT "Showing detailed transcript"
assert_fail "Collapsed FP: tool indicator but expanded view" \
    detect_collapsed "$(cat <<'PANE'
● Bash(ls /tmp)

 Bash command
   ls /tmp
 Do you want to proceed?
 ❯ 1. Yes
   2. No
PANE
)"

# Text mentions "Bash(" but without ● prefix
assert_fail "Collapsed FP: Bash( without bullet" \
    detect_collapsed "$(cat <<'PANE'
  Running Bash(ls /tmp) command...
  Showing detailed transcript · ctrl+o to toggle · ctrl+e to show all
PANE
)"

###############################################################################
#              SLASH COMMAND PICKER DETECTION (detect_slash_picker)            #
###############################################################################

section "detect_slash_picker — positive detection"

# /p prefix: shows /plan, /permissions, /plugin etc.
assert_ok "Slash picker: /p prefix autocomplete" \
    detect_slash_picker "$(cat <<'PANE'
  Some conversation text above...
  Claude is working on the task.

  ❯ /permissions    View or update permissions
    /plan           Enter plan mode
    /plugin         Manage plugins
PANE
)"

# /c prefix: shows /commit, /clear, /config etc.
assert_ok "Slash picker: /c prefix autocomplete" \
    detect_slash_picker "$(cat <<'PANE'
  Previous output here.

    /clear          Clear conversation
    /commit         Create a git commit
    /config         View or update config
PANE
)"

# Highlighted ❯ selection marker on a different item
assert_ok "Slash picker: highlighted selection marker" \
    detect_slash_picker "$(cat <<'PANE'
  Working on your request...

    /bug            Report a bug
  ❯ /help           Get help with using Claude Code
    /init           Initialize project
PANE
)"

# Full command list (many items)
assert_ok "Slash picker: full command list" \
    detect_slash_picker "$(cat <<'PANE'
    /bug              Report a bug
    /clear            Clear conversation
    /commit           Create a git commit
    /config           View or update config
    /help             Get help with using Claude Code
    /init             Initialize project
    /permissions      View or update permissions
    /plan             Enter plan mode
    /terminal-setup   Setup terminal integration
PANE
)"

# Picker visible with stale conversation context above (the real false-positive scenario)
assert_ok "Slash picker: picker with stale context above" \
    detect_slash_picker "$(cat <<'PANE'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
  (approved earlier)

  ❯ /permissions    View or update permissions
    /plan           Enter plan mode
    /plugin         Manage plugins
PANE
)"

section "detect_slash_picker — false positive resistance"

# Normal permission prompt — no slash picker
assert_fail "Slash picker FP: normal permission prompt" \
    detect_slash_picker "$(cat <<'PANE'
  Claude wants to execute Bash
  ls -la /tmp
  Allow              Deny
PANE
)"

# File paths that start with / but aren't slash commands
assert_fail "Slash picker FP: file paths with slashes" \
    detect_slash_picker "$(cat <<'PANE'
  Reading /home/user/project/src/main.rs
  Writing /tmp/output.log
  /var/log/syslog checked
PANE
)"

# Single slash command mention in conversation (below threshold of 2)
assert_fail "Slash picker FP: single slash mention" \
    detect_slash_picker "$(cat <<'PANE'
  You can use /help to get more information.
  Let me know if you need anything else.
PANE
)"

# Code output with /path patterns
assert_fail "Slash picker FP: code with path patterns" \
    detect_slash_picker "$(cat <<'PANE'
  import { readFile } from 'fs';
  const path = '/api/users/list';
  fetch('/api/data/query');
PANE
)"

# Inline discussion mentioning commands without picker format (no 2+ space gap)
assert_fail "Slash picker FP: inline discussion of commands" \
    detect_slash_picker "$(cat <<'PANE'
  Try using /plan to enter plan mode. The /commit command
  will create a git commit. You can also use /help.
PANE
)"

# Empty content
assert_fail "Slash picker FP: empty content" \
    detect_slash_picker ""

# Yes/No prompt without picker
assert_fail "Slash picker FP: Yes/No prompt" \
    detect_slash_picker "$(cat <<'PANE'
 Bash command
   ls /home/user/git/claude_yolo/
 Do you want to proceed?
 > 1. Yes
   2. No
PANE
)"

section "detect_slash_picker — combined veto scenarios"

# Slash picker should veto even when stale Allow/Deny is in the window
_test_picker_vetoes_stale_allow_deny() {
    local content
    content="$(cat <<'PANE'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny

  ❯ /permissions    View or update permissions
    /plan           Enter plan mode
    /plugin         Manage plugins
PANE
)"
    # Picker is detected (would veto)
    detect_slash_picker "$content" || return 1
    # Prompt is also detected (stale signal)
    detect_prompt "$content" >/dev/null || true
    return 0
}
assert_ok "Combined: slash picker vetoes stale Allow/Deny" _test_picker_vetoes_stale_allow_deny

# Real prompt without picker should still work
_test_real_prompt_no_picker() {
    local content
    content="$(cat <<'PANE'
  Claude wants to execute Bash
  git status
  Allow              Deny
PANE
)"
    # No picker detected
    if detect_slash_picker "$content"; then
        return 1
    fi
    # Prompt is detected
    detect_prompt "$content" >/dev/null
}
assert_ok "Combined: real prompt without picker still detected" _test_real_prompt_no_picker

# Slash picker should veto even when stale Yes/No is in the window
_test_picker_vetoes_stale_yesno() {
    local content
    content="$(cat <<'PANE'
 Bash command
   ls /tmp
 Do you want to proceed?
 > 1. Yes
   2. No

    /permissions    View or update permissions
    /plan           Enter plan mode
PANE
)"
    detect_slash_picker "$content" || return 1
    return 0
}
assert_ok "Combined: slash picker vetoes stale Yes/No" _test_picker_vetoes_stale_yesno

###############################################################################
#                   ALLOW/DENY STYLE — BASH PERMISSION PROMPTS                #
###############################################################################

section "detect_prompt — Bash permission prompts"

assert_ok "Bash: simple ls command" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash" \
        "ls -la /tmp")"

assert_ok "Bash: git status" \
    detect_prompt "$(make_prompt \
        "Claude wants to run Bash" \
        "git status")"

assert_ok "Bash: piped command" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash" \
        "cat /etc/hosts | grep localhost")"

assert_ok "Bash: npm install" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash" \
        "npm install --save-dev jest")"

assert_ok "Bash: multi-line command" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash" \
        "cd /project && make build && make test")"

assert_ok "Bash: with allow once context" \
    detect_prompt "$(cat <<'PANE'
  Claude wants to execute a command

    python3 -m pytest tests/

  Allow once    Allow for this session    Deny
PANE
)"

assert_ok "Bash: minimal — just Allow/Deny + Bash keyword" \
    detect_prompt "$(printf 'Bash command:\n  Allow    Deny')"

# Verify the pattern output includes +tool
_out="$(detect_prompt "$(make_prompt "Claude wants to execute Bash" "ls")")"
assert_contains "Bash: pattern output includes +tool" "$_out" "+tool"

###############################################################################
#                    BASH(rm:*) PERMISSION PROMPTS                            #
###############################################################################

section "detect_prompt — Bash(rm:*) permission prompts"

assert_ok "Bash(rm:*): rm -rf" \
    detect_prompt "$(make_prompt \
        "Claude wants to run Bash(rm:*)" \
        "rm -rf /tmp/test-dir")"

assert_ok "Bash(rm:*): rm single file" \
    detect_prompt "$(make_prompt \
        "Claude wants to run Bash(rm:*)" \
        "rm /tmp/obsolete.log")"

assert_ok "Bash(rm:*): rm with glob" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash(rm:*)" \
        "rm -f /tmp/*.bak")"

assert_ok "Bash(rm:*): rm -r directory tree" \
    detect_prompt "$(make_prompt \
        "Claude wants to run Bash(rm:*)" \
        "rm -r ./node_modules")"

assert_ok "Bash(rm:*): combined with other commands" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute Bash(rm:*)" \
        "rm -rf dist/ && mkdir dist")"

assert_ok "Bash(rm:*): with allow-once buttons" \
    detect_prompt "$(cat <<'PANE'
  Claude wants to run Bash(rm:*)

    rm -rf /tmp/build-artifacts

  Allow once    Deny
PANE
)"

# The parenthesized rm:* part contains special chars — verify detection still works
assert_ok "Bash(rm:*): pattern with parens and colon" \
    detect_prompt "$(cat <<'PANE'
  ╭────────────────────────────────╮
  │ Bash(rm:*)                     │
  │   rm -rf /tmp/cache            │
  │   Allow           Deny         │
  ╰────────────────────────────────╯
PANE
)"

# Verify pattern output
_out="$(detect_prompt "$(make_prompt "Claude wants to run Bash(rm:*)" "rm -rf /tmp/x")")"
assert_contains "Bash(rm:*): pattern includes +tool" "$_out" "+tool"
assert_contains "Bash(rm:*): pattern includes +context" "$_out" "+context"

###############################################################################
#                     WEBFETCH PERMISSION PROMPTS                             #
###############################################################################

section "detect_prompt — WebFetch permission prompts"

assert_ok "WebFetch: simple URL" \
    detect_prompt "$(make_prompt \
        "Claude wants to use WebFetch" \
        "url: https://example.com")"

assert_ok "WebFetch: API endpoint" \
    detect_prompt "$(make_prompt \
        "Claude wants to execute WebFetch" \
        "url: https://api.github.com/repos/anthropics/claude-code")"

assert_ok "WebFetch: with prompt parameter" \
    detect_prompt "$(make_prompt \
        "Claude wants to run WebFetch" \
        "url: https://docs.python.org/3/library/json.html" \
        "  │   prompt: Extract the main API functions")"

assert_ok "WebFetch: HTTP URL (auto-upgrade)" \
    detect_prompt "$(make_prompt \
        "Claude wants to use WebFetch" \
        "url: http://localhost:3000/health")"

assert_ok "WebFetch: URL with query params" \
    detect_prompt "$(make_prompt \
        "Claude wants to use WebFetch" \
        "url: https://search.example.com/q?term=bash&page=1")"

assert_ok "WebFetch: allow-once variant" \
    detect_prompt "$(cat <<'PANE'
  Claude wants to use WebFetch

    https://raw.githubusercontent.com/user/repo/main/README.md

  Allow once    Allow for this session    Deny
PANE
)"

assert_ok "WebFetch: minimal — just keyword + Allow/Deny" \
    detect_prompt "$(printf 'WebFetch request:\n  Allow    Deny')"

# Verify pattern — "wants to use" does NOT match the context regex (only
# "wants to execute" and "wants to run" do), so only +tool fires here.
_out="$(detect_prompt "$(make_prompt "Claude wants to use WebFetch" "url: https://example.com")")"
assert_contains "WebFetch: pattern includes +tool" "$_out" "+tool"

# With "wants to run" phrasing, both tool + context fire
_out="$(detect_prompt "$(make_prompt "Claude wants to run WebFetch" "url: https://example.com")")"
assert_contains "WebFetch: 'wants to run' triggers +context" "$_out" "+context"

###############################################################################
#                     MIXED/OTHER TOOL PROMPTS                                #
###############################################################################

section "detect_prompt — Other tool prompts (Read, Write, Edit)"

assert_ok "Read tool prompt" \
    detect_prompt "$(make_prompt \
        "Claude wants to use Read" \
        "file: /home/user/project/src/main.py")"

assert_ok "Write tool prompt" \
    detect_prompt "$(make_prompt \
        "Claude wants to use Write" \
        "file: /home/user/project/new_file.py")"

assert_ok "Edit tool prompt" \
    detect_prompt "$(make_prompt \
        "Claude wants to use Edit" \
        "file: /home/user/project/config.json")"

assert_ok "execute keyword is enough as tool signal" \
    detect_prompt "$(printf 'wants to execute a command\n  Allow    Deny')"

###############################################################################
#                        FALSE POSITIVES                                      #
###############################################################################

section "detect_prompt — False positive resistance"

# Only Allow, no Deny
assert_fail "FP: Allow without Deny" \
    detect_prompt "$(cat <<'PANE'
  Claude is working...
  Allow the process to continue
  Bash command completed.
PANE
)"

# Only Deny, no Allow
assert_fail "FP: Deny without Allow" \
    detect_prompt "$(cat <<'PANE'
  Request denied by policy.
  Deny all future requests.
  Bash completed.
PANE
)"

# Allow + Deny but no tool or context keyword
assert_fail "FP: Yes+No but no secondary signal" \
    detect_prompt "$(cat <<'PANE'
  The system will Allow or Deny
  based on the configuration.
PANE
)"

# Code output that mentions Allow and Deny as variable names
assert_fail "FP: code with Allow/Deny variables" \
    detect_prompt "$(cat <<'PANE'
  const Allow = true;
  const Deny = false;
  if (Allow && !Deny) { proceed(); }
PANE
)"

# Markdown documentation about permissions — the word "Permission" matches
# the context regex, so this IS detected. Documented as a known limitation
# (same class as the code-discussing-prompts case below).
assert_ok "Known limitation: markdown with 'Permission' + Allow/Deny triggers detection" \
    detect_prompt "$(cat <<'PANE'
  ## Permission System
  The user can Allow or Deny each request.
  This is handled by the approval dialog.
PANE
)"

# Markdown WITHOUT the word "permission" should not trigger
assert_fail "FP: markdown doc without permission keyword" \
    detect_prompt "$(cat <<'PANE'
  ## Access Control
  The user can Allow or Deny each request.
  This is handled by the approval dialog.
PANE
)"

# Code that outputs "Bash" and "Allow" + "Deny" in a test assertion
# This one has all three signals in *code output* — the key question is
# whether the multi-signal approach still catches it. It WILL match because
# the detection is pattern-based. This is a known limitation documented below.
# We test it here to document expected behavior.
_code_output="$(cat <<'PANE'
  Running test_permission_dialog...
  assert response.tool == "Bash"
  assert "Allow" in buttons
  assert "Deny" in buttons
  PASSED
PANE
)"
# This WILL match (expected — documented known limitation)
assert_ok "Known limitation: code discussing prompts triggers detection" \
    detect_prompt "$_code_output"

# Empty content
assert_fail "FP: empty string" \
    detect_prompt ""

# Just whitespace
assert_fail "FP: whitespace only" \
    detect_prompt "$(printf '   \n  \n   ')"

# Normal claude output — no permission prompt
assert_fail "FP: normal agent work output" \
    detect_prompt "$(cat <<'PANE'
  I'll help you fix the authentication bug.
  Let me read the relevant files first.

  Reading src/auth/login.ts...
  The issue is on line 42 where the token validation
  skips the expiry check.
PANE
)"

# Output with "Bash" keyword but no Allow/Deny
assert_fail "FP: Bash keyword without Allow/Deny" \
    detect_prompt "$(cat <<'PANE'
  I'll run a Bash command to check the file.
  The Bash script completed successfully.
  WebFetch returned the expected data.
PANE
)"

# Output with rm command in normal text, no prompt
assert_fail "FP: rm command in normal output" \
    detect_prompt "$(cat <<'PANE'
  Removing temporary files...
  $ rm -rf /tmp/build
  Done. Build artifacts cleaned up.
PANE
)"

# Prompt-like text more than 20 lines from bottom
assert_fail "FP: prompt beyond 20-line detection window" \
    detect_prompt "$(cat <<'PANE'
  Claude wants to execute Bash
  rm -rf /tmp/old
  Allow    Deny
line4
line5
line6
line7
line8
line9
line10
line11
line12
line13
line14
line15
line16
line17
line18
line19
line20
line21
line22
line23
Agent is now working on a different task...
PANE
)"

###############################################################################
#                    REALISTIC TERMINAL CAPTURES                              #
###############################################################################

section "detect_prompt — Realistic full-pane captures"

# Simulates a real tmux pane with scrollback + Bash prompt at bottom
assert_ok "Realistic: Bash after scrollback" \
    detect_prompt "$(cat <<'PANE'

  ● claude
  ╭────────────────────────────────────────────────────────────────────────╮
  │ I'll check the project structure first.                               │
  │                                                                        │
  │ Let me look at the files in the current directory.                    │
  ╰────────────────────────────────────────────────────────────────────────╯

  ✻ Bash ls -la

  total 48
  drwxr-xr-x  5 user user  4096 Feb 15 10:00 .
  drwxr-xr-x  3 user user  4096 Feb 15 09:00 ..
  -rw-r--r--  1 user user  1234 Feb 15 10:00 main.py

  ╭────────────────────────────────────────────────────────────────────────╮
  │ Now let me run the tests to see what's failing.                       │
  ╰────────────────────────────────────────────────────────────────────────╯

  ✻ Bash python3 -m pytest tests/ -v

  ╭─────────────────────────────────────────╮
  │ Claude wants to execute Bash            │
  │                                         │
  │   python3 -m pytest tests/ -v           │
  │                                         │
  │   Allow              Deny               │
  ╰─────────────────────────────────────────╯
PANE
)"

# Realistic Bash(rm:*) after file operations
assert_ok "Realistic: Bash(rm:*) cleanup operation" \
    detect_prompt "$(cat <<'PANE'

  ● claude --model opus
  ╭────────────────────────────────────────────────────────────────────────╮
  │ The build artifacts are stale. Let me clean them up and rebuild.      │
  ╰────────────────────────────────────────────────────────────────────────╯

  ✻ Bash(rm:*) rm -rf dist/ build/ *.egg-info

  ╭─────────────────────────────────────────╮
  │ Claude wants to run Bash(rm:*)          │
  │                                         │
  │   rm -rf dist/ build/ *.egg-info        │
  │                                         │
  │   Allow              Deny               │
  ╰─────────────────────────────────────────╯
PANE
)"

# Realistic WebFetch during research
assert_ok "Realistic: WebFetch during documentation lookup" \
    detect_prompt "$(cat <<'PANE'

  ● claude
  ╭────────────────────────────────────────────────────────────────────────╮
  │ Let me check the latest API documentation for this library.           │
  ╰────────────────────────────────────────────────────────────────────────╯

  ✻ WebFetch https://docs.rs/tokio/latest/tokio/

  ╭─────────────────────────────────────────────────────╮
  │ Claude wants to use WebFetch                         │
  │                                                       │
  │   url: https://docs.rs/tokio/latest/tokio/           │
  │   prompt: Extract the main runtime configuration...  │
  │                                                       │
  │   Allow              Deny                             │
  ╰─────────────────────────────────────────────────────╯
PANE
)"

# Realistic: two prompts shown (one old approved, one new pending)
# The daemon should detect the new one at the bottom
assert_ok "Realistic: second prompt after first was approved" \
    detect_prompt "$(cat <<'PANE'
  ✻ Bash ls -la
  (approved)

  total 12
  -rw-r--r-- 1 user user 500 Feb 15 10:00 main.py

  ╭────────────────────────────────────────────────────────────────────────╮
  │ Good, now let me run the linter.                                      │
  ╰────────────────────────────────────────────────────────────────────────╯

  ✻ Bash python3 -m ruff check .

  ╭─────────────────────────────────────────╮
  │ Claude wants to execute Bash            │
  │                                         │
  │   python3 -m ruff check .              │
  │                                         │
  │   Allow              Deny               │
  ╰─────────────────────────────────────────╯
PANE
)"

###############################################################################
#                      PATTERN OUTPUT VALUES                                  #
###############################################################################

section "detect_prompt — Pattern output correctness"

# Bash: has tool (Bash) + context (wants to execute) → both flags
_out="$(detect_prompt "$(make_prompt "Claude wants to execute Bash" "ls")")"
assert_eq "Pattern: Bash execute → Yes+No+tool+context" \
    "Yes+No+tool+context" "$_out"

# WebFetch: has tool (WebFetch) + context (wants to use → no, 'use' not in context list)
# Actually 'wants to run' IS in context list but 'wants to use' is NOT. Let's check...
# Context patterns: want to proceed|wants to execute|wants to run|permission|allow once|allow always
# "Claude wants to use WebFetch" — 'wants to use' doesn't match context. But WebFetch matches tool.
_out="$(detect_prompt "$(printf 'WebFetch request:\n  Allow    Deny')")"
assert_eq "Pattern: WebFetch minimal → Yes+No+tool (no context)" \
    "Yes+No+tool" "$_out"

# Allow once in buttons → context signal fires too
_out="$(detect_prompt "$(printf 'WebFetch\n  Allow once    Deny')")"
assert_eq "Pattern: WebFetch + allow once → Yes+No+tool+context" \
    "Yes+No+tool+context" "$_out"

# Tool only (Bash keyword, no context phrases)
_out="$(detect_prompt "$(printf 'Bash:\n  Allow    Deny')")"
assert_eq "Pattern: Bash keyword only → Yes+No+tool" \
    "Yes+No+tool" "$_out"

# Context only (no tool keyword, but has context phrase)
# Use "want to proceed" which doesn't overlap with tool keywords
_out="$(detect_prompt "$(printf 'Do you want to proceed?\n  Allow    Deny')")"
assert_eq "Pattern: context only → Yes+No+context" \
    "Yes+No+context" "$_out"

###############################################################################
#                         COOLDOWN LOGIC                                      #
###############################################################################

section "in_cooldown — Pane cooldown logic"

# Fresh pane — never approved, should NOT be in cooldown
LAST_APPROVED=()
assert_fail "Cooldown: fresh pane is not in cooldown" \
    in_cooldown "%1"

# Just approved — should be in cooldown
LAST_APPROVED=(["%1"]="$(date +%s)")
assert_ok "Cooldown: just-approved pane is in cooldown" \
    in_cooldown "%1"

# Approved 10 seconds ago — should NOT be in cooldown (> 2s)
LAST_APPROVED=(["%1"]="$(($(date +%s) - 10))")
assert_fail "Cooldown: pane approved 10s ago is not in cooldown" \
    in_cooldown "%1"

# Approved exactly at threshold
LAST_APPROVED=(["%1"]="$(($(date +%s) - 2))")
assert_fail "Cooldown: pane at exactly 2s is not in cooldown" \
    in_cooldown "%1"

# Approved 1 second ago — should be in cooldown
LAST_APPROVED=(["%1"]="$(($(date +%s) - 1))")
assert_ok "Cooldown: pane approved 1s ago is in cooldown" \
    in_cooldown "%1"

# Different panes have independent cooldowns
LAST_APPROVED=(["%1"]="$(date +%s)" ["%2"]="$(($(date +%s) - 10))")
assert_ok "Cooldown: pane %1 just approved, in cooldown" \
    in_cooldown "%1"
assert_fail "Cooldown: pane %2 approved 10s ago, not in cooldown" \
    in_cooldown "%2"

###############################################################################
#                       BUILD_AGENT_CMD                                       #
###############################################################################

section "build_agent_cmd — Command construction"

_out="$(build_agent_cmd "" "fix the bug")"
assert_eq "build_agent_cmd: no model" \
    "claude 'fix the bug'" "$_out"

_out="$(build_agent_cmd "opus" "fix the bug")"
assert_eq "build_agent_cmd: with model" \
    "claude --model opus 'fix the bug'" "$_out"

_out="$(build_agent_cmd "sonnet" "it's a test")"
assert_eq "build_agent_cmd: single-quote escaping" \
    "claude --model sonnet 'it'\\''s a test'" "$_out"

_out="$(build_agent_cmd "" "simple task")"
assert_contains "build_agent_cmd: starts with claude" "$_out" "claude"

_out="$(build_agent_cmd "haiku" "task")"
assert_contains "build_agent_cmd: model flag present" "$_out" "--model haiku"

_out="$(build_agent_cmd "" "task with \"double quotes\"")"
assert_eq "build_agent_cmd: double quotes preserved" \
    "claude 'task with \"double quotes\"'" "$_out"

_out="$(build_agent_cmd "" "fix the bug" "/tmp/cy.hooks.json")"
assert_eq "build_agent_cmd: settings file flag" \
    "claude --settings '/tmp/cy.hooks.json' 'fix the bug'" "$_out"

_out="$(build_agent_cmd "opus" "fix the bug" "/tmp/cy.hooks.json")"
assert_eq "build_agent_cmd: settings before model" \
    "claude --settings '/tmp/cy.hooks.json' --model opus 'fix the bug'" "$_out"

_out="$(build_agent_cmd "" "" "/tmp/cy.hooks.json")"
assert_eq "build_agent_cmd: settings in interactive mode" \
    "claude --settings '/tmp/cy.hooks.json'" "$_out"

_out="$(build_agent_cmd "" "it's a task" "/tmp/o'brien.hooks.json")"
assert_eq "build_agent_cmd: single quotes in settings path escaped" \
    "claude --settings '/tmp/o'\\''brien.hooks.json' 'it'\\''s a task'" "$_out"

_out="$(build_agent_cmd "" "$(printf 'line one\nline two')" "/tmp/cy.hooks.json")"
assert_contains "build_agent_cmd: multiline task keeps settings flag" \
    "$_out" "--settings '/tmp/cy.hooks.json'"

_out="$(build_agent_cmd "opus" "fix the bug" "" "xhigh")"
assert_eq "build_agent_cmd: effort after model" \
    "claude --model opus --effort xhigh 'fix the bug'" "$_out"

_out="$(build_agent_cmd "" "task" "" "max")"
assert_eq "build_agent_cmd: effort without model" \
    "claude --effort max 'task'" "$_out"

_out="$(build_agent_cmd "claude-fable-5" "" "/tmp/cy.hooks.json" "xhigh")"
assert_eq "build_agent_cmd: settings + model + effort, interactive" \
    "claude --settings '/tmp/cy.hooks.json' --model claude-fable-5 --effort xhigh" "$_out"

_out="$(build_agent_cmd "opus" "fix the bug" "" "")"
assert_eq "build_agent_cmd: empty effort omits flag" \
    "claude --model opus 'fix the bug'" "$_out"

###############################################################################
#                RESOLVE_BEST_MODEL — BEST-MODEL AUTO-SELECTION               #
###############################################################################

section "resolve_best_model — best-model auto-selection"

_rbm_tmp="$(mktemp -d)"
# Pin the knobs this section asserts against (a user-exported
# CLAUDE_YOLO_MODEL_CANDIDATES would otherwise change candidate order and
# fail correct code); restored after the section.
_rbm_prev_candidates="$CLAUDE_YOLO_MODEL_CANDIDATES"
_rbm_prev_ttl="$CLAUDE_YOLO_MODEL_CACHE_TTL"

# The shipped default: latest opus first, sonnet behind it. Read from a clean
# environment so an exported override in the caller's shell cannot mask it.
assert_eq "resolve_best_model: default candidates are opus then sonnet" \
    "opus sonnet" \
    "$(env -u CLAUDE_YOLO_MODEL_CANDIDATES bash -c 'source "$1/lib/common.sh"; printf "%s" "$CLAUDE_YOLO_MODEL_CANDIDATES"' _ "$SCRIPT_DIR")"

CLAUDE_YOLO_MODEL_CANDIDATES="claude-fable-5 opus sonnet"
CLAUDE_YOLO_MODEL_CACHE_TTL=86400
model_cache_file() { echo "$_rbm_tmp/model-cache"; }

# Probe stub: a model is "available" iff listed in _RBM_AVAILABLE
claude_yolo_probe_model() {
    [[ " $_RBM_AVAILABLE " == *" $1 "* ]]
}

_RBM_AVAILABLE="claude-fable-5 opus sonnet"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: picks fable when available" "claude-fable-5" "$_out"

assert_eq "resolve_best_model: caches the winner" \
    "claude-fable-5" "$(head -1 "$_rbm_tmp/model-cache")"

_RBM_AVAILABLE="sonnet"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: fresh cache short-circuits probing" \
    "claude-fable-5" "$_out"

rm -f "$_rbm_tmp/model-cache"
_RBM_AVAILABLE="opus sonnet"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: falls back to opus when fable unavailable" "opus" "$_out"

rm -f "$_rbm_tmp/model-cache"
_RBM_AVAILABLE="sonnet"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: falls back to sonnet" "sonnet" "$_out"

rm -f "$_rbm_tmp/model-cache"
_RBM_AVAILABLE=""
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: empty when no candidate works" "" "$_out"

assert_ok "resolve_best_model: returns 0 even when no candidate works" \
    resolve_best_model 2>/dev/null

# An expired cache is re-probed
rm -f "$_rbm_tmp/model-cache"
_RBM_AVAILABLE="sonnet"
resolve_best_model >/dev/null 2>&1   # caches sonnet
CLAUDE_YOLO_MODEL_CACHE_TTL=0
_RBM_AVAILABLE="claude-fable-5"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: expired cache re-probes" "claude-fable-5" "$_out"
CLAUDE_YOLO_MODEL_CACHE_TTL=86400

# A cached model that is no longer in the candidate list is discarded —
# changing CLAUDE_YOLO_MODEL_CANDIDATES takes effect immediately
rm -f "$_rbm_tmp/model-cache"
_RBM_AVAILABLE="claude-fable-5 opus sonnet"
resolve_best_model >/dev/null 2>&1   # caches claude-fable-5
CLAUDE_YOLO_MODEL_CANDIDATES="opus sonnet"
_out="$(resolve_best_model 2>/dev/null)"
assert_eq "resolve_best_model: cached model outside candidates re-probes" "opus" "$_out"
CLAUDE_YOLO_MODEL_CANDIDATES="claude-fable-5 opus sonnet"

rm -rf "$_rbm_tmp"
unset _RBM_AVAILABLE
CLAUDE_YOLO_MODEL_CANDIDATES="$_rbm_prev_candidates"
CLAUDE_YOLO_MODEL_CACHE_TTL="$_rbm_prev_ttl"

###############################################################################
#          NOTIFY HOOK SETTINGS — OFF-SCREEN PERMISSION PROMPT MARKERS        #
###############################################################################

section "write_notify_hook_settings — per-session notify hook"

_hook_tmp="$(mktemp -d)"
_hook_audit="$_hook_tmp/claude-yolo-hooktest.log"
_hook_file="$(write_notify_hook_settings "$_hook_audit")"

assert_eq "notify hook: prints settings path" \
    "$_hook_audit.hooks.json" "$_hook_file"
assert_ok "notify hook: settings file exists" test -f "$_hook_audit.hooks.json"
assert_ok "notify hook: waiting dir created" test -d "$_hook_audit.waiting"
assert_contains "notify hook: permission_prompt matcher" \
    "$(cat "$_hook_audit.hooks.json")" '"matcher": "permission_prompt"'

# Extract the embedded hook command with whatever JSON parser is available
# (python3 preferred, node fallback) and exercise it exactly like Claude Code
# would: JSON payload on stdin, TMUX_PANE in the environment. When neither
# parser exists the block would be untestable, so emit a visible skip rather
# than silently pass.
_hook_cmd=""
if command -v python3 &>/dev/null; then
    assert_ok "notify hook: settings file is valid JSON" \
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$_hook_audit.hooks.json"
    _hook_cmd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Notification"][0]["hooks"][0]["command"])' "$_hook_audit.hooks.json")"
elif command -v node &>/dev/null; then
    assert_ok "notify hook: settings file is valid JSON" \
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$_hook_audit.hooks.json"
    _hook_cmd="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.Notification[0].hooks[0].command)' "$_hook_audit.hooks.json")"
fi

if [[ -n "$_hook_cmd" ]]; then
    _run_hook_cmd() {  # $1 = stdin payload, $2 = TMUX_PANE value
        printf '%s' "$1" | TMUX_PANE="$2" sh -c "$_hook_cmd"
    }

    rm -f "$_hook_audit.waiting"/* 2>/dev/null
    assert_ok "notify hook cmd: permission_prompt payload exits 0" \
        _run_hook_cmd '{"hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}' '%7'
    assert_ok "notify hook cmd: writes marker named after pane" \
        test -f "$_hook_audit.waiting/%7"
    assert_ok "notify hook cmd: marker line 1 holds an epoch timestamp" \
        bash -c "head -n1 '$_hook_audit.waiting/%7' | grep -qE '^[0-9]+\$'"
    assert_ok "notify hook cmd: marker line 2 holds the payload message" \
        grep -q '"message":"Claude needs your permission"' "$_hook_audit.waiting/%7"
    # No temp file is left behind by the atomic write
    assert_eq "notify hook cmd: atomic write leaves only the pane marker" \
        "%7" "$(ls "$_hook_audit.waiting")"

    # Plan notifications also carry permission_prompt, so they DO get a marker
    # (so the daemon can nudge to reveal them) — the daemon's message gate,
    # tested separately, is what keeps them from being blind-answered.
    rm -f "$_hook_audit.waiting"/* 2>/dev/null
    assert_ok "notify hook cmd: plan approval payload writes a marker" \
        _run_hook_cmd '{"hook_event_name":"Notification","message":"Claude Code needs your approval for the plan","notification_type":"permission_prompt"}' '%8'
    assert_ok "notify hook cmd: plan marker present" \
        test -f "$_hook_audit.waiting/%8"

    # Older Claude Code versions have no notification_type field (and may
    # ignore the matcher) — the message text alone must still qualify.
    rm -f "$_hook_audit.waiting"/* 2>/dev/null
    assert_ok "notify hook cmd: legacy payload matches on message text" \
        _run_hook_cmd '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' '%3'
    assert_ok "notify hook cmd: legacy payload writes marker" \
        test -f "$_hook_audit.waiting/%3"

    # Non-permission notifications must not leave markers even if an old
    # version routes them past the matcher.
    rm -f "$_hook_audit.waiting"/* 2>/dev/null
    assert_ok "notify hook cmd: idle payload exits 0" \
        _run_hook_cmd '{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' '%7'
    assert_fail "notify hook cmd: idle payload writes no marker" \
        test -f "$_hook_audit.waiting/%7"

    # Outside tmux there is no pane to mark — still exits 0 (hooks must not
    # surface errors into the Claude session).
    rm -f "$_hook_audit.waiting"/* 2>/dev/null
    assert_ok "notify hook cmd: no TMUX_PANE exits 0" \
        _run_hook_cmd '{"notification_type":"permission_prompt","message":"Claude needs your permission"}' ''
    assert_eq "notify hook cmd: no TMUX_PANE writes nothing" \
        "" "$(ls "$_hook_audit.waiting" 2>/dev/null)"
else
    echo "  ${_yellow}SKIP${_reset} notify hook cmd tests: no python3 or node to extract the embedded command"
fi

# Regenerating for the same session clears stale markers from a previous run
mkdir -p "$_hook_audit.waiting"
echo "12345" > "$_hook_audit.waiting/%9"
write_notify_hook_settings "$_hook_audit" >/dev/null
assert_fail "notify hook: regeneration clears stale markers" \
    test -f "$_hook_audit.waiting/%9"

# Ultracode rides along in the same settings file (it has no CLI flag)
assert_fail "notify hook: no ultracode key by default" \
    grep -q 'ultracode' "$_hook_audit.hooks.json"

write_notify_hook_settings "$_hook_audit" 1 >/dev/null
assert_ok "notify hook: ultracode key written when requested" \
    grep -q '"ultracode": true' "$_hook_audit.hooks.json"
assert_contains "notify hook: ultracode keeps the notify hook" \
    "$(cat "$_hook_audit.hooks.json")" '"matcher": "permission_prompt"'
if command -v python3 &>/dev/null; then
    assert_ok "notify hook: ultracode settings file is valid JSON" \
        python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["ultracode"] is True' \
        "$_hook_audit.hooks.json"
elif command -v node &>/dev/null; then
    assert_ok "notify hook: ultracode settings file is valid JSON" \
        node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if (s.ultracode !== true) process.exit(1)' \
        "$_hook_audit.hooks.json"
fi

rm -rf "$_hook_tmp"

###############################################################################
#                    RESOLVE_EFFORT — EFFORT LEVEL MAPPING                    #
###############################################################################

section "resolve_effort — --effort value and ultracode setting"

# Prints "<ultracode> <effort>"; ultracode has no CLI flag, so it resolves to
# xhigh on the flag plus the settings key — which is also the level it
# degrades to where ultracode is unavailable.
assert_eq "resolve_effort: ultracode → xhigh + setting" \
    "1 xhigh" "$(resolve_effort ultracode)"
assert_eq "resolve_effort: 'ultra' is an alias for ultracode" \
    "1 xhigh" "$(resolve_effort ultra)"
assert_eq "resolve_effort: xhigh alone does not enable ultracode" \
    "0 xhigh" "$(resolve_effort xhigh)"
assert_eq "resolve_effort: max passes through" \
    "0 max" "$(resolve_effort max)"
assert_eq "resolve_effort: low passes through" \
    "0 low" "$(resolve_effort low)"
assert_eq "resolve_effort: none drops the flag" \
    "0" "$(resolve_effort none)"
assert_eq "resolve_effort: empty drops the flag" \
    "0" "$(resolve_effort '')"
assert_eq "resolve_effort: unknown level passes through" \
    "0 turbo" "$(resolve_effort turbo 2>/dev/null)"

# The launcher parses the two fields with `read`; an empty effort must not
# shift ultracode into the effort variable.
_re_ultracode="" _re_effort="unset"
read -r _re_ultracode _re_effort <<< "$(resolve_effort none)"
assert_eq "resolve_effort: read keeps ultracode=0 when effort is empty" \
    "0" "$_re_ultracode"
assert_eq "resolve_effort: read leaves effort empty for none" \
    "" "$_re_effort"

read -r _re_ultracode _re_effort <<< "$(resolve_effort ultracode)"
assert_eq "resolve_effort: read gets ultracode=1" "1" "$_re_ultracode"
assert_eq "resolve_effort: read gets effort=xhigh" "xhigh" "$_re_effort"

# The launcher's shipped default
assert_ok "claude-yolo: default effort is ultracode" \
    grep -q 'effort="ultracode"' "$SCRIPT_DIR/claude-yolo"

section "notify_marker_fresh — hidden-prompt marker validity"

_marker_dir="$(mktemp -d)"

_notify_fresh() {  # $1 = pane
    CLAUDE_YOLO_WAITING_DIR="$_marker_dir" notify_marker_fresh "$1"
}
_notify_clear() {  # $1 = pane
    CLAUDE_YOLO_WAITING_DIR="$_marker_dir" clear_notify_marker "$1"
}

assert_fail "notify marker: missing marker is not fresh" _notify_fresh '%1'

date +%s > "$_marker_dir/%1"
assert_ok "notify marker: current timestamp is fresh" _notify_fresh '%1'

echo "$(( $(date +%s) - NOTIFY_MARKER_TTL - 10 ))" > "$_marker_dir/%2"
assert_fail "notify marker: expired marker is not fresh" _notify_fresh '%2'
assert_fail "notify marker: expired marker is removed" test -f "$_marker_dir/%2"

echo "not-a-timestamp" > "$_marker_dir/%3"
assert_fail "notify marker: malformed marker is not fresh" _notify_fresh '%3'
assert_fail "notify marker: malformed marker is removed" test -f "$_marker_dir/%3"

: > "$_marker_dir/%4"
assert_fail "notify marker: empty marker is not fresh" _notify_fresh '%4'

date +%s > "$_marker_dir/%5"
_notify_clear '%5'
assert_fail "notify marker: clear_notify_marker removes it" test -f "$_marker_dir/%5"

# Without an override or AUDIT_LOG the helpers refuse quietly
assert_fail "notify marker: no waiting dir configured" \
    env -u CLAUDE_YOLO_WAITING_DIR -u AUDIT_LOG bash -c '
        source "'"$SCRIPT_DIR"'/lib/common.sh"
        eval "$(sed -n "/^NOTIFY_MARKER_TTL=/p; /^notify_waiting_dir()/,/^}/p; /^notify_marker_fresh()/,/^}/p" "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
        notify_marker_fresh "%1"
    '

# Two-line markers (timestamp + payload) as the real hook writes them: the
# freshness check still reads the timestamp from line 1.
_write_marker() {  # $1 = pane, $2 = message
    printf '%s\n{"hook_event_name":"Notification","message":"%s","notification_type":"permission_prompt"}\n' \
        "$(date +%s)" "$2" > "$_marker_dir/$1"
}

_notify_msg() { CLAUDE_YOLO_WAITING_DIR="$_marker_dir" notify_marker_msg "$1"; }
_notify_ts() { CLAUDE_YOLO_WAITING_DIR="$_marker_dir" notify_marker_ts "$1"; }
_notify_blindable() { CLAUDE_YOLO_WAITING_DIR="$_marker_dir" notify_marker_blindable "$1"; }

_write_marker '%6' 'Claude needs your permission'
assert_ok "notify marker: two-line marker is fresh" _notify_fresh '%6'
_ts6="$(_notify_ts '%6')"
assert_ok "notify marker: two-line ts is numeric" bash -c "[[ '$_ts6' =~ ^[0-9]+\$ ]]"
assert_contains "notify marker: message extracted from line 2" \
    "$(_notify_msg '%6')" 'Claude needs your permission'

section "notify_marker_blindable — plain-tool vs reserved dialogs"

# Plain tool-permission dialog (Bash/Edit/…) → blind-answerable
_write_marker '%20' 'Claude needs your permission'
assert_ok "blindable: plain tool-permission message" _notify_blindable '%20'

# Plan-exit dialog → reserved for the user (message names the plan)
_write_marker '%21' 'Claude Code needs your approval for the plan'
assert_fail "blindable: plan-exit message is gated" _notify_blindable '%21'

# A cwd/path containing 'plan' must NOT gate a plain tool dialog — only the
# message field is inspected
printf '%s\n{"cwd":"/home/user/plan-app","message":"Claude needs your permission","notification_type":"permission_prompt"}\n' \
    "$(date +%s)" > "$_marker_dir/%22"
assert_ok "blindable: 'plan' in cwd does not gate (message-only)" _notify_blindable '%22'

# Missing message (older Claude Code) fails closed — no blind answer
printf '%s\n' "$(date +%s)" > "$_marker_dir/%23"
assert_fail "blindable: missing message fails closed" _notify_blindable '%23'

# A hypothetical question dialog naming 'question' is gated too
_write_marker '%24' 'Claude has a question for you'
assert_fail "blindable: question message is gated" _notify_blindable '%24'

rm -rf "$_marker_dir"

section "hidden_candidate — blind-Enter eligibility"

# The off-screen-dialog state: raw diff text at the pane bottom, no box chrome
assert_ok "hidden candidate: diff-filled pane qualifies" \
    hidden_candidate "$(cat <<'PANE'
 118 +    galleryIosAlts: [
 119 +      "Verbindungsformular von Mobile SSH auf einem iPhone",
 120 +      "Gespeicherte Server auf einem iPhone, organisiert",
 132       compareHead: "Sein Platz neben Termux und Termius",
 135       compareGuideTitle: "Vergleichsleitfaden",
 69   ],
 71   multiP1:d: "…",
PANE
)"

# Idle input box draws its ╰ bottom border — never type into it blindly
assert_fail "hidden candidate: idle input box is excluded" \
    hidden_candidate "$(cat <<'PANE'
 Some earlier output.

 ╭──────────────────────────────────────────────╮
 │ >                                            │
 ╰──────────────────────────────────────────────╯
   ? for shortcuts
PANE
)"

# A fully rendered boxed dialog is handled by the visual detectors instead
assert_fail "hidden candidate: rendered boxed dialog is excluded" \
    hidden_candidate "$(cat <<'PANE'
 ╭────────────────────────────────╮
 │ Bash(rm:*)                     │
 │   rm -rf /tmp/cache            │
 │   Allow           Deny         │
 ╰────────────────────────────────╯
PANE
)"

# Box chrome far above the tail window does not disqualify the pane
assert_ok "hidden candidate: old box chrome above tail window ignored" \
    hidden_candidate "$(printf '╰──────╯\n%s\n' "$(seq 1 20 | sed 's/^/+ diff line /')")"

section "audit_event — non-approval audit lines"

_audit_tmp="$(mktemp)"
AUDIT_LOG="$_audit_tmp" audit_event '%5' 'HIDDEN-PROMPT nudge 1/2'
assert_contains "audit_event: line lands in audit log" \
    "$(cat "$_audit_tmp")" "HIDDEN-PROMPT nudge 1/2 pane=%5"
rm -f "$_audit_tmp"

section "control-pane — Slash command parsing"

_out="$(control_parse_interval "1h")"
assert_eq "control_parse_interval: 1h" "3600" "$_out"

_out="$(control_parse_interval "30m")"
assert_eq "control_parse_interval: 30m" "1800" "$_out"

_out="$(control_parse_interval "90s")"
assert_eq "control_parse_interval: 90s" "90" "$_out"

_out="$(control_parse_interval "1d")"
assert_eq "control_parse_interval: 1d" "86400" "$_out"

assert_fail "control_parse_interval: rejects missing amount" \
    control_parse_interval "h"

assert_fail "control_parse_interval: rejects unknown unit" \
    control_parse_interval "1x"

assert_fail "control_parse_interval: rejects zero interval" \
    control_parse_interval "0m"

_test_control_parse_loop_command() {
    local parsed
    parsed="$(control_parse_loop_command "/loop 1h Continue experiments and push best submission")" || return 1
    [[ "$parsed" == $'1h\t3600\tContinue experiments and push best submission' ]]
}
assert_ok "control_parse_loop_command: parses interval and prompt" _test_control_parse_loop_command

_test_control_parse_loop_preserves_prompt_spacing() {
    local parsed
    parsed="$(control_parse_loop_command "/loop 30m   Run tests, commit, and push if green")" || return 1
    [[ "$parsed" == $'30m\t1800\tRun tests, commit, and push if green' ]]
}
assert_ok "control_parse_loop_command: trims separator spaces" _test_control_parse_loop_preserves_prompt_spacing

assert_fail "control_parse_loop_command: rejects missing prompt" \
    control_parse_loop_command "/loop 1h"

assert_fail "control_parse_loop_command: rejects invalid interval" \
    control_parse_loop_command "/loop 1x retry"

###############################################################################
#                       CONTROL PANE TMUX DISPATCH                            #
###############################################################################

section "control-pane — Tmux dispatch"

_CONTROL_SESSION="control-pane-test-$$"
_CONTROL_AUDIT="/tmp/claude-yolo-control-pane-test-$$.log"

_control_cleanup() {
    tmux kill-session -t "$_CONTROL_SESSION" 2>/dev/null || true
    rm -f "$_CONTROL_AUDIT" 2>/dev/null || true
}

_control_start_read_agent() {
    tmux new-session -d -s "$_CONTROL_SESSION" -n "agent-1" \
        "bash -lc 'while IFS= read -r line; do printf \"READ:%s\\n\" \"\$line\"; done'"
}

_test_control_send_prompt_uses_enter_key() {
    (
        local calls audit log
        calls="$(mktemp)"
        audit="$(mktemp)"

        tmux() {
            case "$1" in
                list-windows)
                    printf 'agent-1\n'
                    ;;
                send-keys)
                    printf '%s\n' "$*" >> "$calls"
                    ;;
            esac
        }

        CONTROL_SUBMIT_DELAY=0
        control_send_prompt "sess" "$audit" "agent-1" "hello world" 9 >/dev/null || exit 1
        log="$(cat "$calls")"
        rm -f "$calls" "$audit"

        [[ "$log" == *"send-keys -t sess:agent-1 -l hello world"* ]] && \
        [[ "$log" == *"send-keys -t sess:agent-1 Enter"* ]]
    )
}
assert_ok "control_send_prompt: submits with Enter key" _test_control_send_prompt_uses_enter_key

_test_control_send_prompt_to_agent() {
    _control_cleanup
    : > "$_CONTROL_AUDIT"
    _control_start_read_agent || return 1
    sleep 0.2

    local old_delay="$CONTROL_SUBMIT_DELAY"
    CONTROL_SUBMIT_DELAY=0.05
    control_send_prompt "$_CONTROL_SESSION" "$_CONTROL_AUDIT" "agent-1" "control dispatch test" 1 || return 1
    CONTROL_SUBMIT_DELAY="$old_delay"
    sleep 0.3

    local capture
    capture="$(tmux capture-pane -pt "$_CONTROL_SESSION:agent-1" -S -100 2>/dev/null)"
    _control_cleanup
    [[ "$capture" == *"READ:control dispatch test"* ]]
}
assert_ok "control_send_prompt: sends prompt to agent-1" _test_control_send_prompt_to_agent

_test_control_loop_dispatches_immediately() {
    _control_cleanup
    : > "$_CONTROL_AUDIT"
    _control_start_read_agent || return 1
    sleep 0.2

    SESSION_NAME="$_CONTROL_SESSION"
    AUDIT_LOG="$_CONTROL_AUDIT"
    SESSION_MODE="standard"
    LOOP_PIDS=()
    LOOP_INTERVALS=()
    LOOP_SECONDS=()
    LOOP_PROMPTS=()
    LOOP_TARGETS=()
    NEXT_LOOP_ID=1

    local old_delay="$CONTROL_SUBMIT_DELAY"
    CONTROL_SUBMIT_DELAY=0.05
    control_start_loop "5s" "5" "immediate loop dispatch test" || return 1
    sleep 0.4
    control_cancel_loop 1 >/dev/null 2>&1 || true
    CONTROL_SUBMIT_DELAY="$old_delay"

    local capture
    capture="$(tmux capture-pane -pt "$_CONTROL_SESSION:agent-1" -S -100 2>/dev/null)"
    _control_cleanup
    [[ "$capture" == *"READ:immediate loop dispatch test"* ]]
}
assert_ok "control-pane: /loop dispatches immediately" _test_control_loop_dispatches_immediately

_test_control_loop_dispatches_prompt() {
    _control_cleanup
    : > "$_CONTROL_AUDIT"
    _control_start_read_agent || return 1
    sleep 0.2

    {
        printf '/loop 2s loop dispatch test\n'
        sleep 0.5
        printf '/loops cancel 1\n'
    } | CLAUDE_YOLO_CONTROL_SUBMIT_DELAY=0.05 timeout 4 bash "$SCRIPT_DIR/lib/control-pane.sh" "$_CONTROL_SESSION" "$_CONTROL_AUDIT" standard >/dev/null 2>&1 || true

    local capture
    capture="$(tmux capture-pane -pt "$_CONTROL_SESSION:agent-1" -S -100 2>/dev/null)"
    _control_cleanup
    [[ "$capture" == *"READ:loop dispatch test"* ]]
}
assert_ok "control-pane: /loop dispatches on interval" _test_control_loop_dispatches_prompt

_control_cleanup

###############################################################################
#                       ENSURE_TRUSTED                                        #
###############################################################################

section "ensure_trusted — Auto-trust directories"

_trust_settings_tmp=""

_trust_setup() {
    _trust_settings_tmp="$(mktemp)"
    # Override HOME so ensure_trusted writes to our temp file
    export _REAL_HOME="$HOME"
}

_trust_teardown() {
    rm -f "$_trust_settings_tmp"
    export HOME="$_REAL_HOME"
}

# Test: adds new directory to empty settings
_test_trust_new_dir() {
    _trust_setup
    local fake_home
    fake_home="$(mktemp -d)"
    cat > "$fake_home/.claude.json" <<'EOF'
{
  "projects": {}
}
EOF
    HOME="$fake_home" ensure_trusted "/home/user/git/my-project" 2>/dev/null

    local result
    result="$(cat "$fake_home/.claude.json")"
    rm -rf "$fake_home"
    export HOME="$_REAL_HOME"

    [[ "$result" == *"/home/user/git/my-project"* ]] && \
    [[ "$result" == *"hasTrustDialogAccepted"* ]]
}

# Test: idempotent — running twice doesn't duplicate
_test_trust_idempotent() {
    _trust_setup
    local fake_home
    fake_home="$(mktemp -d)"
    cat > "$fake_home/.claude.json" <<'EOF'
{
  "projects": {}
}
EOF
    HOME="$fake_home" ensure_trusted "/home/user/git/my-project" 2>/dev/null
    HOME="$fake_home" ensure_trusted "/home/user/git/my-project" 2>/dev/null

    local count
    count="$(grep -c 'my-project' "$fake_home/.claude.json")"
    rm -rf "$fake_home"
    export HOME="$_REAL_HOME"

    # Should appear exactly once: as the projects key
    [[ "$count" -eq 1 ]]
}

# Test: preserves existing settings
_test_trust_preserves_existing() {
    _trust_setup
    local fake_home
    fake_home="$(mktemp -d)"
    cat > "$fake_home/.claude.json" <<'EOF'
{
  "numStartups": 5,
  "projects": {
    "/home/user/git/existing": {
      "hasTrustDialogAccepted": true,
      "allowedTools": []
    }
  }
}
EOF
    HOME="$fake_home" ensure_trusted "/home/user/git/new-project" 2>/dev/null

    local result
    result="$(cat "$fake_home/.claude.json")"
    rm -rf "$fake_home"
    export HOME="$_REAL_HOME"

    [[ "$result" == *"/home/user/git/existing"* ]] && \
    [[ "$result" == *"/home/user/git/new-project"* ]] && \
    [[ "$result" == *'"numStartups"'* ]]
}

# Test: creates .claude.json if it doesn't exist
_test_trust_creates_settings() {
    _trust_setup
    local fake_home
    fake_home="$(mktemp -d)"
    # No .claude.json at all
    HOME="$fake_home" ensure_trusted "/home/user/git/brand-new" 2>/dev/null

    local result=""
    [[ -f "$fake_home/.claude.json" ]] && \
        result="$(cat "$fake_home/.claude.json")"
    rm -rf "$fake_home"
    export HOME="$_REAL_HOME"

    [[ "$result" == *"/home/user/git/brand-new"* ]] && \
    [[ "$result" == *"hasTrustDialogAccepted"* ]]
}

# Test: skips if already trusted
_test_trust_already_trusted() {
    _trust_setup
    local fake_home
    fake_home="$(mktemp -d)"
    cat > "$fake_home/.claude.json" <<'EOF'
{
  "projects": {
    "/home/user/git/trusted": {
      "hasTrustDialogAccepted": true,
      "allowedTools": []
    }
  }
}
EOF
    # Get mtime before
    local before after
    before="$(stat -c %Y "$fake_home/.claude.json")"
    sleep 1
    HOME="$fake_home" ensure_trusted "/home/user/git/trusted" 2>/dev/null
    after="$(stat -c %Y "$fake_home/.claude.json")"
    rm -rf "$fake_home"
    export HOME="$_REAL_HOME"

    # File should not have been modified
    [[ "$before" -eq "$after" ]]
}

assert_ok "ensure_trusted: adds new directory" _test_trust_new_dir
assert_ok "ensure_trusted: idempotent (no duplicates)" _test_trust_idempotent
assert_ok "ensure_trusted: preserves existing settings" _test_trust_preserves_existing
assert_ok "ensure_trusted: creates .claude.json if missing" _test_trust_creates_settings
assert_ok "ensure_trusted: skips if already trusted" _test_trust_already_trusted

###############################################################################

section "ensure_bell — Auto-configure terminal bell notifications"

# Test: creates settings.json with both bell mechanisms if it doesn't exist
_test_bell_creates_settings() {
    local fake_home
    fake_home="$(mktemp -d)"
    HOME="$fake_home" ensure_bell 2>/dev/null

    local result=""
    [[ -f "$fake_home/.claude/settings.json" ]] && \
        result="$(cat "$fake_home/.claude/settings.json")"
    rm -rf "$fake_home"

    [[ "$result" == *'"preferredNotifChannel": "terminal_bell"'* ]] && \
    [[ "$result" == *'"Stop"'* ]] && \
    [[ "$result" == *'printf'* ]]
}

# Test: adds bell config to an empty/minimal settings object
_test_bell_adds_to_existing() {
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.claude"
    cat > "$fake_home/.claude/settings.json" <<'EOF'
{
  "model": "opus"
}
EOF
    HOME="$fake_home" ensure_bell 2>/dev/null

    local result
    result="$(cat "$fake_home/.claude/settings.json")"
    rm -rf "$fake_home"

    # New bell settings added, existing settings preserved
    [[ "$result" == *'"preferredNotifChannel": "terminal_bell"'* ]] && \
    [[ "$result" == *'"Stop"'* ]] && \
    [[ "$result" == *'"model"'* ]]
}

# Test: idempotent — running twice doesn't duplicate the channel
_test_bell_idempotent() {
    local fake_home
    fake_home="$(mktemp -d)"
    HOME="$fake_home" ensure_bell 2>/dev/null
    HOME="$fake_home" ensure_bell 2>/dev/null

    local count
    count="$(grep -c 'preferredNotifChannel' "$fake_home/.claude/settings.json")"
    rm -rf "$fake_home"

    [[ "$count" -eq 1 ]]
}

# Test: respects an explicit prior channel choice (does not override)
_test_bell_respects_existing_channel() {
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.claude"
    cat > "$fake_home/.claude/settings.json" <<'EOF'
{
  "preferredNotifChannel": "notifications_disabled"
}
EOF
    HOME="$fake_home" ensure_bell 2>/dev/null

    local result
    result="$(cat "$fake_home/.claude/settings.json")"
    rm -rf "$fake_home"

    # User silenced notifications — leave it fully alone (no bell forced in)
    [[ "$result" == *'notifications_disabled'* ]] && \
    [[ "$result" != *'terminal_bell'* ]] && \
    [[ "$result" != *'"Stop"'* ]]
}

# Test: does not touch settings that already have a Stop hook (bell considered
# "previously configured")
_test_bell_respects_existing_stop_hook() {
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.claude"
    cat > "$fake_home/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "my-custom-stop-hook" } ] }
    ]
  }
}
EOF
    HOME="$fake_home" ensure_bell 2>/dev/null

    local result count
    result="$(cat "$fake_home/.claude/settings.json")"
    count="$(grep -c '"Stop"' "$fake_home/.claude/settings.json")"
    rm -rf "$fake_home"

    # Existing Stop hook preserved, no second Stop added, channel NOT forced in
    [[ "$result" == *'my-custom-stop-hook'* ]] && \
    [[ "$count" -eq 1 ]] && \
    [[ "$result" != *'terminal_bell'* ]]
}

assert_ok "ensure_bell: creates settings.json if missing" _test_bell_creates_settings
assert_ok "ensure_bell: adds to existing settings, preserves them" _test_bell_adds_to_existing
assert_ok "ensure_bell: idempotent (no duplicates)" _test_bell_idempotent
assert_ok "ensure_bell: respects existing channel choice" _test_bell_respects_existing_channel
assert_ok "ensure_bell: respects existing Stop hook" _test_bell_respects_existing_stop_hook

###############################################################################
#                         AUDIT FUNCTION                                      #
###############################################################################

section "audit — Logging"

_audit_tmp="$(mktemp)"
AUDIT_LOG="$_audit_tmp"

audit "%99" "Yes+No+tool"
_content="$(cat "$_audit_tmp")"
assert_contains "audit: writes pane ID" "$_content" "pane=%99"
assert_contains "audit: writes pattern" "$_content" 'pattern="Yes+No+tool"'
assert_contains "audit: writes APPROVED" "$_content" "APPROVED"
assert_contains "audit: writes timestamp" "$_content" "[20"

rm -f "$_audit_tmp"

###############################################################################
#                     COMMON.SH UTILITIES                                     #
###############################################################################

section "common.sh — Logging and prereqs"

# log functions write to stderr
_out="$(log_info "test message" 2>&1)"
assert_contains "log_info: contains INFO" "$_out" "INFO"
assert_contains "log_info: contains message" "$_out" "test message"

_out="$(log_warn "warning msg" 2>&1)"
assert_contains "log_warn: contains WARN" "$_out" "WARN"

_out="$(log_error "error msg" 2>&1)"
assert_contains "log_error: contains ERROR" "$_out" "ERROR"

# check_prereqs — tmux should be available in test environment
assert_ok "check_prereqs: passes when tmux is available" check_prereqs

# log_dir — returns a writable directory
_test_log_dir_returns_path() {
    local d
    d="$(log_dir)"
    [[ -n "$d" ]] && [[ -d "$d" ]]
}
assert_ok "log_dir: returns an existing directory" _test_log_dir_returns_path

_test_log_dir_writable() {
    local d
    d="$(log_dir)"
    touch "$d/.claude-yolo-test-probe" 2>/dev/null && rm -f "$d/.claude-yolo-test-probe"
}
assert_ok "log_dir: returned directory is writable" _test_log_dir_writable

# log_dir fallback — when /tmp is not writable, uses ~/.claude-yolo/logs
_test_log_dir_fallback() {
    local fake_home
    fake_home="$(mktemp -d)"
    local result
    result="$(HOME="$fake_home" bash -c '
        touch() { return 1; }
        export -f touch
        source "'"$SCRIPT_DIR"'/lib/common.sh"
        log_dir
    ' 2>/dev/null)"
    rm -rf "$fake_home"
    [[ "$result" == *"/.claude-yolo/logs" ]]
}
assert_ok "log_dir: falls back to ~/.claude-yolo/logs when /tmp is not writable" _test_log_dir_fallback

###############################################################################
#                  LAUNCHER ARGUMENT PARSING                                  #
###############################################################################

section "claude-yolo — Argument parsing and validation"

# Help flag exits 0
assert_ok "launcher: --help exits successfully" \
    bash "$SCRIPT_DIR/claude-yolo" --help

assert_ok "launcher: -h exits successfully" \
    bash "$SCRIPT_DIR/claude-yolo" -h

# Short flags that mirror long flags
assert_ok "launcher: -s is alias for --session (help still works)" \
    bash "$SCRIPT_DIR/claude-yolo" -h

assert_fail "launcher: -d nonexistent path fails" \
    bash "$SCRIPT_DIR/claude-yolo" -d /nonexistent/path/xyz "task"

assert_fail "launcher: -f nonexistent file fails" \
    bash "$SCRIPT_DIR/claude-yolo" -f /nonexistent/file.txt

# No args = interactive mode (creates a tmux session, so we need cleanup).
# The launcher's final step is "tmux attach" which requires a real TTY.
# In CI (no TTY) this fails with "open terminal failed: not a terminal".
# So instead of checking the exit code, verify the session was actually created.
_test_no_args() {
    local before
    # The launcher runs with TMUX unset (see below), so it talks to the
    # *default-socket* tmux server — which is a different server when this
    # test itself runs inside tmux on a named socket. Every tmux call here
    # must also drop TMUX so the checks and cleanup hit the same server the
    # launcher used; otherwise the test looks for the session on the wrong
    # server and leaks it (plus a live claude agent) on the default one.
    before="$(env -u TMUX tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
    # Isolate HOME with a pre-seeded fresh model cache: the launcher's
    # resolve_best_model then cache-hits instantly instead of issuing real
    # (billed) `claude -p` probes and writing the user's real
    # ~/.claude-yolo/model-cache; ensure_trusted/ensure_bell config writes
    # land in the throwaway HOME too.
    local fake_home
    fake_home="$(mktemp -d)"
    mkdir -p "$fake_home/.claude-yolo"
    echo "sonnet" > "$fake_home/.claude-yolo/model-cache"
    # Unset TMUX so the launcher uses "tmux attach" (which harmlessly fails
    # when stdout is redirected) instead of "tmux switch-client" (which would
    # yank the user's current tmux client to the new session).
    env -u TMUX HOME="$fake_home" bash "$SCRIPT_DIR/claude-yolo" >/dev/null 2>&1 || true
    rm -rf "$fake_home"
    # Check that a new claude-yolo-* session was created
    local after found=0
    after="$(env -u TMUX tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
    local s
    for s in $(comm -13 <(echo "$before") <(echo "$after") | grep '^claude-yolo-' || true); do
        found=1
        env -u TMUX tmux kill-session -t "$s" 2>/dev/null || true
    done
    # Also clean up any stragglers
    for s in $(env -u TMUX tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-yolo-' || true); do
        echo "$before" | grep -qxF "$s" || env -u TMUX tmux kill-session -t "$s" 2>/dev/null || true
    done
    (( found ))
}
assert_ok "launcher: no arguments launches interactive mode" _test_no_args

# Unknown option exits non-zero
assert_fail "launcher: unknown --flag fails" \
    bash "$SCRIPT_DIR/claude-yolo" --bogus

# --dir with nonexistent path (we avoid actually launching tmux by expecting
# prereq check to pass but dir validation to fail)
assert_fail "launcher: --dir nonexistent path fails" \
    bash "$SCRIPT_DIR/claude-yolo" --dir /nonexistent/path/xyz "task"

# Short flags match long flags for --dir and --file
assert_fail "launcher: -d matches --dir behavior" \
    bash "$SCRIPT_DIR/claude-yolo" -d /nonexistent/path/xyz "task"

assert_fail "launcher: -f matches --file behavior" \
    bash "$SCRIPT_DIR/claude-yolo" -f /nonexistent/file.txt

###############################################################################
#                  INTEGRATION: DAEMON + TMUX                                 #
###############################################################################

section "Integration — Daemon with real tmux"

_INTEG_SESSION="claude-yolo-test-$$"
_integ_cleanup() {
    tmux kill-session -t "$_INTEG_SESSION" 2>/dev/null || true
    sleep 0.2
}

# Create a tmux session with a pane, inject a fake permission prompt,
# verify the daemon detects and approves it
_run_integ_bash() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    # Create session with a cat process (keeps pane alive and accepts input)
    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # Inject a Bash permission prompt into the pane
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls -la /tmp
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    # Run daemon for a short burst
    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_rm() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to run Bash(rm:*)
  rm -rf /tmp/test-dir
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_webfetch() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to use WebFetch
  url: https://example.com
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_no_false_positive() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # Send normal output — no permission prompt
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'OUTPUT'
  Working on the task...
  Reading files and analyzing code.
  No permission needed here.
OUTPUT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 1.5 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    # Should NOT contain any approvals
    [[ "$result" != *"APPROVED"* ]]
}

assert_ok  "Integration Allow/Deny: Bash prompt detected and approved" _run_integ_bash
assert_ok  "Integration Allow/Deny: Bash(rm:*) prompt detected and approved" _run_integ_rm
assert_ok  "Integration Allow/Deny: WebFetch prompt detected and approved" _run_integ_webfetch
assert_ok  "Integration: no false positive on normal output" _run_integ_no_false_positive

# ── Integration: hidden-prompt markers (Notification hook path) ──────────────

# Write a two-line marker exactly as the real Notification hook does:
# line 1 epoch timestamp, line 2 the payload JSON.
_write_hidden_marker() {  # $1 = dir, $2 = pane_id, $3 = message
    mkdir -p "$1"
    printf '%s\n{"hook_event_name":"Notification","message":"%s","notification_type":"permission_prompt"}\n' \
        "$(date +%s)" "$3" > "$1/$2"
}

# Shared daemon runner for the hidden-prompt tests: starts main_loop with the
# full detector cascade extracted (so branch ordering matches production) and
# CLAUDE_YOLO_WAITING_DIR pointed at $2.
_integ_hidden_daemon() {
    local audit_tmp="$1" waiting_dir="$2" run_secs="$3"
    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" \
        timeout "$run_secs" bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            CLAUDE_YOLO_WAITING_DIR="'"$waiting_dir"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED LAST_SENT_HASH SEND_STREAK HIDDEN_NUDGES HIDDEN_PREV_HASH HIDDEN_CHANGES HIDDEN_MARK_TS HIDDEN_GATED_LOGGED
            main_loop
        ' 2>/dev/null || true
}

# A frozen pane full of diff text, no visible dialog, fresh marker → the
# daemon must nudge, then land a blind Enter (proven by the pane's `read`
# completing and touching the proof file).
_run_integ_hidden_blind() {
    _integ_cleanup
    local audit_tmp waiting_dir proof pane_script pane_id
    audit_tmp="$(mktemp)"
    waiting_dir="$audit_tmp.waiting"
    proof="$audit_tmp.proof"
    pane_script="$audit_tmp.pane.sh"

    cat > "$pane_script" <<SCRIPT
#!/bin/sh
seq 1 30 | sed 's/^/+ translated diff line /'
read _line
touch '$proof'
sleep 5
SCRIPT
    chmod +x "$pane_script"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "$pane_script"
    sleep 0.4

    pane_id="$(tmux display-message -p -t "$_INTEG_SESSION:test" '#{pane_id}')"
    _write_hidden_marker "$waiting_dir" "$pane_id" 'Claude needs your permission'

    _integ_hidden_daemon "$audit_tmp" "$waiting_dir" 4

    local result marker_gone=0 proved=0
    result="$(cat "$audit_tmp")"
    [[ -f "$waiting_dir/$pane_id" ]] || marker_gone=1
    [[ -f "$proof" ]] && proved=1
    rm -rf "$audit_tmp" "$waiting_dir" "$proof" "$pane_script"
    _integ_cleanup

    [[ "$result" == *"HIDDEN-PROMPT nudge"* ]] \
        && [[ "$result" == *"hidden-blind+Enter"* ]] \
        && (( marker_gone )) && (( proved ))
}

# A hidden PLAN dialog (marker message names the plan) must be nudged (to try
# to reveal it) but never blind-answered — plan approval is reserved for the
# user. The marker is left in place for the visible path / user.
_run_integ_hidden_plan() {
    _integ_cleanup
    local audit_tmp waiting_dir proof pane_script pane_id
    audit_tmp="$(mktemp)"
    waiting_dir="$audit_tmp.waiting"
    proof="$audit_tmp.proof"
    pane_script="$audit_tmp.pane.sh"

    cat > "$pane_script" <<SCRIPT
#!/bin/sh
seq 1 30 | sed 's/^/  plan step /'
read _line
touch '$proof'
sleep 5
SCRIPT
    chmod +x "$pane_script"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "$pane_script"
    sleep 0.4

    pane_id="$(tmux display-message -p -t "$_INTEG_SESSION:test" '#{pane_id}')"
    _write_hidden_marker "$waiting_dir" "$pane_id" 'Claude Code needs your approval for the plan'

    _integ_hidden_daemon "$audit_tmp" "$waiting_dir" 4

    local result marker_present=0 proved=0
    result="$(cat "$audit_tmp")"
    [[ -f "$waiting_dir/$pane_id" ]] && marker_present=1
    [[ -f "$proof" ]] && proved=1
    rm -rf "$audit_tmp" "$waiting_dir" "$proof" "$pane_script"
    _integ_cleanup

    # Nudged, but NOT blind-answered; marker kept; the pane's read never fired.
    [[ "$result" == *"HIDDEN-PROMPT nudge"* ]] \
        && [[ "$result" == *"left for user"* ]] \
        && [[ "$result" != *"hidden-blind"* ]] \
        && (( marker_present )) && (( ! proved ))
}

# A fresh blind-answerable marker on a pane the user has scrolled into
# copy-mode must get no nudges and no keys, and keep its marker — Enter in
# copy-mode would destroy the user's scroll position/selection.
_run_integ_hidden_copymode() {
    _integ_cleanup
    local audit_tmp waiting_dir proof pane_script pane_id
    audit_tmp="$(mktemp)"
    waiting_dir="$audit_tmp.waiting"
    proof="$audit_tmp.proof"
    pane_script="$audit_tmp.pane.sh"

    cat > "$pane_script" <<SCRIPT
#!/bin/sh
seq 1 30 | sed 's/^/+ diff line /'
read _line
touch '$proof'
sleep 5
SCRIPT
    chmod +x "$pane_script"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "$pane_script"
    sleep 0.4

    pane_id="$(tmux display-message -p -t "$_INTEG_SESSION:test" '#{pane_id}')"
    _write_hidden_marker "$waiting_dir" "$pane_id" 'Claude needs your permission'
    tmux copy-mode -t "$_INTEG_SESSION:test"
    sleep 0.2

    _integ_hidden_daemon "$audit_tmp" "$waiting_dir" 2

    local result marker_present=0 proved=0
    result="$(cat "$audit_tmp")"
    [[ -f "$waiting_dir/$pane_id" ]] && marker_present=1
    [[ -f "$proof" ]] && proved=1
    rm -rf "$audit_tmp" "$waiting_dir" "$proof" "$pane_script"
    _integ_cleanup

    [[ "$result" != *"HIDDEN-PROMPT nudge"* ]] \
        && [[ "$result" != *"hidden-blind"* ]] \
        && (( marker_present )) && (( ! proved ))
}

# A marker on a pane that keeps producing output (a working agent) is stale —
# the daemon must consume it without sending any key.
_run_integ_hidden_stale() {
    _integ_cleanup
    local audit_tmp waiting_dir pane_script pane_id
    audit_tmp="$(mktemp)"
    waiting_dir="$audit_tmp.waiting"
    pane_script="$audit_tmp.pane.sh"

    cat > "$pane_script" <<'SCRIPT'
#!/bin/sh
while :; do date +%s%N; sleep 0.05; done
SCRIPT
    chmod +x "$pane_script"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "$pane_script"
    sleep 0.4

    pane_id="$(tmux display-message -p -t "$_INTEG_SESSION:test" '#{pane_id}')"
    _write_hidden_marker "$waiting_dir" "$pane_id" 'Claude needs your permission'

    _integ_hidden_daemon "$audit_tmp" "$waiting_dir" 2

    local result marker_gone=0
    result="$(cat "$audit_tmp")"
    [[ -f "$waiting_dir/$pane_id" ]] || marker_gone=1
    rm -rf "$audit_tmp" "$waiting_dir" "$pane_script"
    _integ_cleanup

    [[ "$result" != *"hidden-blind"* ]] \
        && [[ "$result" != *"APPROVED"* ]] \
        && (( marker_gone ))
}

# A frozen pane whose bottom shows input-box chrome (╰) must be nudged at
# most, never blind-typed into — the proof file must stay absent.
_run_integ_hidden_idle_box() {
    _integ_cleanup
    local audit_tmp waiting_dir proof pane_script pane_id
    audit_tmp="$(mktemp)"
    waiting_dir="$audit_tmp.waiting"
    proof="$audit_tmp.proof"
    pane_script="$audit_tmp.pane.sh"

    cat > "$pane_script" <<SCRIPT
#!/bin/sh
seq 1 10 | sed 's/^/  output line /'
printf '%s\n' ' ╭──────────────────────────╮' ' │ >                        │' ' ╰──────────────────────────╯'
read _line
touch '$proof'
sleep 5
SCRIPT
    chmod +x "$pane_script"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "$pane_script"
    sleep 0.4

    pane_id="$(tmux display-message -p -t "$_INTEG_SESSION:test" '#{pane_id}')"
    _write_hidden_marker "$waiting_dir" "$pane_id" 'Claude needs your permission'

    _integ_hidden_daemon "$audit_tmp" "$waiting_dir" 2.5

    local result proved=0
    result="$(cat "$audit_tmp")"
    [[ -f "$proof" ]] && proved=1
    rm -rf "$audit_tmp" "$waiting_dir" "$proof" "$pane_script"
    _integ_cleanup

    [[ "$result" != *"hidden-blind"* ]] && (( ! proved ))
}

assert_ok  "Integration Hidden: frozen diff pane gets nudges then blind Enter" _run_integ_hidden_blind
assert_ok  "Integration Hidden: hidden plan dialog nudged but never blind-answered" _run_integ_hidden_plan
assert_ok  "Integration Hidden: copy-mode pane gets no nudges or keys, marker kept" _run_integ_hidden_copymode
assert_ok  "Integration Hidden: stale marker on working pane consumed, no keys" _run_integ_hidden_stale
assert_ok  "Integration Hidden: input-box chrome blocks blind Enter" _run_integ_hidden_idle_box

# ── Integration: Yes/No style (real v2.x prompts) ────────────────────────────

_run_integ_yesno_bash() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 Bash command
   ls /home/user/git/claude_yolo/
 Permission rule Bash requires confirmation for this command.
 Do you want to proceed?
 > 1. Yes
   2. No
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_yesno_rm() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 Bash(rm:*) command
   rm -rf dist/ build/
 Permission rule Bash(rm:*) requires confirmation for this command.
 Do you want to proceed?
 > 1. Yes
   2. No
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_yesno_webfetch() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 WebFetch
   url: https://example.com
 Permission rule WebFetch requires confirmation for this command.
 Do you want to proceed?
 > 1. Yes
   2. No
PROMPT
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

assert_ok  "Integration Yes/No: Bash prompt detected and approved" _run_integ_yesno_bash
assert_ok  "Integration Yes/No: Bash(rm:*) prompt detected and approved" _run_integ_yesno_rm
assert_ok  "Integration Yes/No: WebFetch prompt detected and approved" _run_integ_yesno_webfetch

# ── Integration: long don't-ask-again menus and question dialogs ─────────────

# Shared sed extraction for the daemon functions used by these tests,
# including the key-selection helpers and the question detector.
_INTEG_FULL_EXTRACT='/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'

_run_integ_daemon_burst() {
    # $1 = audit log path. Runs main_loop against $_INTEG_SESSION for 2s with
    # the full extraction list (key helpers + question detector included).
    AUDIT_LOG="$1" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 2 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"''"$_INTEG_FULL_EXTRACT"''"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$1"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true
}

_run_integ_yesno_long_dontask() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" -x 80 -y 40 "cat"
    sleep 0.3

    # Long multi-line command inside the don't-ask-again option pushes
    # "> 1. Yes" above the 20-line tail window.
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 This command requires approval
 Do you want to proceed?
 > 1. Yes
   2. Yes, and don't ask again for: timeout 120 some-utility
      --flag-one
      --flag-two
      --flag-three
      --flag-four
      --flag-five
      --flag-six
      --flag-seven
      --flag-eight
      --flag-nine
      --flag-ten
      --flag-eleven
      --flag-twelve
      --flag-thirteen
      --flag-fourteen
      --flag-fifteen
      --flag-sixteen
      --flag-seventeen
   3. No
 Esc to cancel
PROMPT
)" ""
    sleep 0.2

    _run_integ_daemon_burst "$audit_tmp"

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

_run_integ_question_recommended() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 Which auth method should we use?
 ❯ 1. JWT tokens (Recommended)
      Stateless, no session store needed
   2. Session cookies
      Server-side session store
   3. Other
      Provide your own answer
PROMPT
)" ""
    sleep 0.2

    _run_integ_daemon_burst "$audit_tmp"

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"question+recommended"* ]]
}

_run_integ_question_without_recommended_ignored() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
 Which auth method should we use?
 ❯ 1. JWT tokens
   2. Session cookies
   3. Other
PROMPT
)" ""
    sleep 0.2

    _run_integ_daemon_burst "$audit_tmp"

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    # No recommended option — the question must be left for the user
    [[ "$result" != *"APPROVED"* ]]
}

_run_integ_static_send_cap() {
    _integ_cleanup
    local audit_tmp fixture_tmp
    audit_tmp="$(mktemp)"
    fixture_tmp="$(mktemp)"

    # A prompt-shaped pane that never reacts to keys (echo disabled, input
    # swallowed by sleep) — the daemon must stop keying it after the cap.
    cat > "$fixture_tmp" <<'PROMPT'
 Bash command
   ls /tmp
 Permission rule Bash requires confirmation for this command.
 Do you want to proceed?
 ❯ 1. Yes
   2. No
PROMPT

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" \
        "bash -c 'stty -echo 2>/dev/null; cat $fixture_tmp; exec sleep 30'"
    sleep 0.5

    # COOLDOWN_SECS=0 so only the send cap limits repeat sends
    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=0 \
        timeout 4 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"''"$_INTEG_FULL_EXTRACT"''"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=0
            main_loop
        ' 2>/dev/null || true

    local approved suppressed
    approved="$(grep -c 'APPROVED' "$audit_tmp" 2>/dev/null)" || approved=0
    suppressed="$(grep -c 'suppressed-static' "$audit_tmp" 2>/dev/null)" || suppressed=0
    rm -f "$audit_tmp" "$fixture_tmp"
    _integ_cleanup

    # 5 sends (the cap), then exactly one suppressed-static audit line.
    # The suppressed line itself contains "suppressed-static+<pattern>" and is
    # logged via audit(), so subtract it from the APPROVED count.
    (( approved - suppressed == 5 )) && (( suppressed == 1 ))
}

_run_integ_duplicate_daemon_refused() {
    command -v flock >/dev/null 2>&1 || return 0
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # First daemon runs the real script and holds the lock
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" "$_INTEG_SESSION" 0.2 "$audit_tmp" >/dev/null 2>&1 &
    local first_pid=$!
    sleep 0.7

    # Second daemon for the same session must refuse and exit promptly
    timeout 3 bash "$SCRIPT_DIR/lib/approver-daemon.sh" "$_INTEG_SESSION" 0.2 "$audit_tmp" >/dev/null 2>&1
    local rc=$?

    kill "$first_pid" 2>/dev/null
    wait "$first_pid" 2>/dev/null
    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp" "${audit_tmp}.lock"
    _integ_cleanup

    [[ "$result" == *"Duplicate daemon refused"* ]] && (( rc == 0 ))
}

assert_ok  "Integration Long menu: don't-ask-again prompt approved" _run_integ_yesno_long_dontask
assert_ok  "Integration Question: recommended option auto-answered" _run_integ_question_recommended
assert_ok  "Integration Question: no recommended option → left for user" _run_integ_question_without_recommended_ignored
assert_ok  "Integration Send cap: static pane keyed at most 5 times" _run_integ_static_send_cap
assert_ok  "Integration Lock: duplicate daemon for same session refused" _run_integ_duplicate_daemon_refused

# ── Integration: Collapsed transcript view ────────────────────────────────────

# Collapsed view integration tests need longer sleeps because the ● character
# and long dash lines can cause terminal rendering delays in tmux.
_run_integ_collapsed_bash() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.5

    tmux send-keys -t "$_INTEG_SESSION:test" "● Bash(ls /tmp)" Enter
    sleep 0.2
    tmux send-keys -t "$_INTEG_SESSION:test" "  Showing detailed transcript" Enter
    sleep 0.5

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 3 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"*"collapsed"* ]]
}

_run_integ_collapsed_webfetch() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.5

    tmux send-keys -t "$_INTEG_SESSION:test" "● WebFetch(https://example.com)" Enter
    sleep 0.2
    tmux send-keys -t "$_INTEG_SESSION:test" "  Showing detailed transcript" Enter
    sleep 0.5

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 3 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"*"collapsed"* ]]
}

assert_ok  "Integration Collapsed: Bash detected, ctrl+o sent" _run_integ_collapsed_bash
assert_ok  "Integration Collapsed: WebFetch detected, ctrl+o sent" _run_integ_collapsed_webfetch

# ── Integration: Slash picker veto ────────────────────────────────────────────

# Stale Allow/Deny context + slash picker visible → daemon must NOT approve.
_run_integ_slash_picker_veto() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    # Inject stale Allow/Deny from earlier conversation + slash picker at bottom
    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PANE'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny

  ❯ /permissions    View or update permissions
    /plan           Enter plan mode
    /plugin         Manage plugins
PANE
)" ""
    sleep 0.2

    AUDIT_LOG="$audit_tmp" SESSION_NAME="$_INTEG_SESSION" POLL_INTERVAL=0.2 COOLDOWN_SECS=2 \
        timeout 1.5 bash -c '
            source "'"$SCRIPT_DIR"'/lib/common.sh"
            eval "$(sed -n '"'"'/^declare -A /p; /^SEND_STREAK_CAP=/p; /^COOLDOWN_SECS=/p; /^PLAN_APPROVAL_TTL=/p; /^SLASH_APPROVAL_TTL=/p; /^NOTIFY_MARKER_TTL=/p; /^HIDDEN_NUDGE_MAX=/p; /^HIDDEN_BLIND_WINDOW=/p; /^[a-z][a-z_0-9]*()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
            AUDIT_LOG="'"$audit_tmp"'"
            SESSION_NAME="'"$_INTEG_SESSION"'"
            POLL_INTERVAL=0.2
            COOLDOWN_SECS=2
            declare -A LAST_APPROVED
            main_loop
        ' 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    # Must NOT contain any approvals — the slash picker should veto
    [[ "$result" != *"APPROVED"* ]]
}

assert_ok "Integration Slash Picker: veto prevents approval when picker visible" _run_integ_slash_picker_veto

# ── Per-session audit log ────────────────────────────────────────────────────

section "Per-session audit log"

# Verify the daemon uses session-specific log when invoked with 3rd arg
_run_integ_audit_log_arg() {
    _integ_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    # Run daemon with explicit audit log path (3rd arg)
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION" 0.2 "$audit_tmp" 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _integ_cleanup

    [[ "$result" == *"APPROVED"* ]]
}

assert_ok "Per-session audit: daemon uses 3rd arg as log path" _run_integ_audit_log_arg

# Verify default audit log includes session name and uses log_dir
_check_default_audit_path() {
    local path
    path="$(source "$SCRIPT_DIR/lib/common.sh"; echo "$(log_dir)/claude-yolo-claude-yolo-test-123.log")"
    [[ "$path" == *"claude-yolo-claude-yolo-test-123.log" ]]
}

assert_ok "Per-session audit: default path includes session name" _check_default_audit_path

# Verify launcher generates per-session log path using log_dir
_check_launcher_audit_path() {
    grep -q 'AUDIT_LOG="$(log_dir)/claude-yolo-${SESSION_NAME}.log"' "$SCRIPT_DIR/claude-yolo"
}

assert_ok "Per-session audit: launcher sets AUDIT_LOG from SESSION_NAME" _check_launcher_audit_path

# ── Integration: Concurrent daemons with isolated logs ────────────────────────

section "Integration — Concurrent daemons"

_INTEG_SESSION_A="claude-yolo-test-A-$$"
_INTEG_SESSION_B="claude-yolo-test-B-$$"

_concurrent_cleanup() {
    tmux kill-session -t "$_INTEG_SESSION_A" 2>/dev/null || true
    tmux kill-session -t "$_INTEG_SESSION_B" 2>/dev/null || true
    sleep 0.2
}

# Two daemons running concurrently must write to their own audit logs
_run_integ_concurrent_isolated_logs() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    # Create two independent sessions
    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    # Inject different prompts into each session
    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /home/project-a
  Allow              Deny
PROMPT
)" ""

    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'PROMPT'
  Claude wants to run Bash(rm:*)
  rm -rf /tmp/project-b
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    # Run two daemons concurrently with separate audit logs
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    # Wait for both daemons to finish
    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Each log must have its own APPROVED entry
    [[ "$result_a" == *"APPROVED"* ]] && [[ "$result_b" == *"APPROVED"* ]]
}

_run_integ_concurrent_no_crosstalk() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    # Create two sessions — only session A gets a prompt
    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    # Session A: real prompt
    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
PROMPT
)" ""

    # Session B: normal output, no prompt
    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'OUTPUT'
  Working on the task...
  Reading files and analyzing code.
OUTPUT
)" ""
    sleep 0.2

    # Run two daemons concurrently
    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 1.5 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Session A should be approved, session B should NOT
    [[ "$result_a" == *"APPROVED"* ]] && [[ "$result_b" != *"APPROVED"* ]]
}

_run_integ_concurrent_both_yesno() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    # Both sessions get Yes/No style prompts
    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
 Bash command
   git status
 Permission rule Bash requires confirmation for this command.
 Do you want to proceed?
 > 1. Yes
   2. No
PROMPT
)" ""

    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'PROMPT'
 WebFetch
   url: https://example.com
 Permission rule WebFetch requires confirmation for this command.
 Do you want to proceed?
 > 1. Yes
   2. No
PROMPT
)" ""
    sleep 0.2

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Both should be approved in their own log
    [[ "$result_a" == *"APPROVED"* ]] && [[ "$result_b" == *"APPROVED"* ]]
}

_run_integ_concurrent_session_in_log() {
    _concurrent_cleanup
    local audit_a audit_b
    audit_a="$(mktemp)"
    audit_b="$(mktemp)"

    tmux new-session -d -s "$_INTEG_SESSION_A" -n "test" "cat"
    tmux new-session -d -s "$_INTEG_SESSION_B" -n "test" "cat"
    sleep 0.3

    tmux send-keys -t "$_INTEG_SESSION_A:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
PROMPT
)" ""

    tmux send-keys -t "$_INTEG_SESSION_B:test" "$(cat <<'PROMPT'
  Claude wants to run Bash
  pwd
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_A" 0.2 "$audit_a" 2>/dev/null &
    local pid_a=$!

    timeout 2 bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_INTEG_SESSION_B" 0.2 "$audit_b" 2>/dev/null &
    local pid_b=$!

    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true

    local result_a result_b
    result_a="$(cat "$audit_a")"
    result_b="$(cat "$audit_b")"
    rm -f "$audit_a" "$audit_b"
    _concurrent_cleanup

    # Log A must reference session A's panes, log B must reference session B's panes
    # Neither log should contain the other session's name
    [[ "$result_a" == *"session=$_INTEG_SESSION_A"* ]] && \
    [[ "$result_b" == *"session=$_INTEG_SESSION_B"* ]] && \
    [[ "$result_a" != *"session=$_INTEG_SESSION_B"* ]] && \
    [[ "$result_b" != *"session=$_INTEG_SESSION_A"* ]]
}

assert_ok  "Concurrent: both daemons approve their own prompts" _run_integ_concurrent_isolated_logs
assert_ok  "Concurrent: no crosstalk — daemon B ignores session A prompt" _run_integ_concurrent_no_crosstalk
assert_ok  "Concurrent: both Yes/No prompts approved independently" _run_integ_concurrent_both_yesno
assert_ok  "Concurrent: each log only references its own session" _run_integ_concurrent_session_in_log

###############################################################################
#              DAEMON RESILIENCE — survives transient errors                  #
###############################################################################

section "Daemon resilience — survives errors and keeps approving"

# The daemon must survive transient errors (unwritable audit log, disappearing
# panes, etc.) and continue approving prompts. Previously it used set -euo
# pipefail which killed it silently on any unhandled error.

_RESIL_SESSION="claude-yolo-resil-$$"
_resil_cleanup() {
    tmux kill-session -t "$_RESIL_SESSION" 2>/dev/null || true
    sleep 0.2
}

# Test: daemon survives when audit log becomes unwritable mid-run, then
# still approves prompts once log is writable again.
_run_resil_unwritable_log() {
    _resil_cleanup
    local audit_tmp audit_dir
    audit_dir="$(mktemp -d)"
    audit_tmp="$audit_dir/audit.log"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # First prompt — daemon writes to writable log
    tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    # Start daemon in background
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 1

    # Daemon should have approved first prompt
    local first_result
    first_result="$(cat "$audit_tmp" 2>/dev/null)"

    # Make log unwritable
    chmod 000 "$audit_dir" 2>/dev/null || true

    # Inject a second prompt — daemon must survive the log write failure
    tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  git status
  Allow              Deny
PROMPT
)" ""
    sleep 1.5

    # Check daemon is still alive
    local daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1

    # Restore permissions and clean up
    chmod 755 "$audit_dir" 2>/dev/null || true
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -rf "$audit_dir"
    _resil_cleanup

    # Both conditions must hold:
    # 1. First prompt was approved (log has APPROVED)
    # 2. Daemon was still alive after log write failure
    [[ "$first_result" == *"APPROVED"* ]] && (( daemon_alive ))
}

# Test: daemon survives when a pane disappears mid-iteration.
_run_resil_pane_disappears() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    # Create session with two windows
    tmux new-session -d -s "$_RESIL_SESSION" -n "test1" "cat"
    tmux new-window -t "$_RESIL_SESSION" -n "test2" "cat"
    sleep 0.3

    # Inject prompt in window 1
    tmux send-keys -t "$_RESIL_SESSION:test1" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  ls /tmp
  Allow              Deny
PROMPT
)" ""
    sleep 0.2

    # Start daemon
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 1

    # Kill window 2 (pane disappears while daemon is iterating over panes)
    tmux kill-window -t "$_RESIL_SESSION:test2" 2>/dev/null || true
    sleep 0.5

    # Inject another prompt in window 1
    tmux send-keys -t "$_RESIL_SESSION:test1" "$(cat <<'PROMPT'
  Claude wants to execute Bash
  git diff
  Allow              Deny
PROMPT
)" ""
    sleep 1.5

    local result daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1
    result="$(cat "$audit_tmp")"

    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -f "$audit_tmp"
    _resil_cleanup

    # Daemon must still be alive and have approved prompts
    (( daemon_alive )) && [[ "$result" == *"APPROVED"* ]]
}

# Test: daemon logs its own exit (EXIT trap works).
_run_resil_exit_logged() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # Run daemon briefly, then kill it
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.2 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!
    sleep 0.5
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true

    local result
    result="$(cat "$audit_tmp")"
    rm -f "$audit_tmp"
    _resil_cleanup

    # The EXIT trap should have logged the daemon exit
    [[ "$result" == *"Daemon exited"* ]]
}

# Test: daemon keeps approving after many rapid iterations without crashing.
_run_resil_rapid_prompts() {
    _resil_cleanup
    local audit_tmp
    audit_tmp="$(mktemp)"

    tmux new-session -d -s "$_RESIL_SESSION" -n "test" "cat"
    sleep 0.3

    # Start daemon with very fast poll
    bash "$SCRIPT_DIR/lib/approver-daemon.sh" \
        "$_RESIL_SESSION" 0.1 "$audit_tmp" 2>/dev/null &
    local daemon_pid=$!

    # Inject 3 prompts rapidly
    local i
    for i in 1 2 3; do
        tmux send-keys -t "$_RESIL_SESSION:test" "$(cat <<PROMPT
  Claude wants to execute Bash
  command-$i
  Allow              Deny
PROMPT
)" ""
        sleep 1
    done

    local daemon_alive=0
    kill -0 "$daemon_pid" 2>/dev/null && daemon_alive=1
    local result
    result="$(cat "$audit_tmp")"

    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -f "$audit_tmp"
    _resil_cleanup

    # Count APPROVED lines — should have at least 2
    local count
    count="$(echo "$result" | grep -c "APPROVED" || true)"
    (( daemon_alive )) && (( count >= 2 ))
}

assert_ok "Resilience: daemon survives unwritable audit log" _run_resil_unwritable_log
assert_ok "Resilience: daemon survives disappearing pane" _run_resil_pane_disappears
assert_ok "Resilience: daemon logs its own exit via EXIT trap" _run_resil_exit_logged
assert_ok "Resilience: daemon handles rapid sequential prompts" _run_resil_rapid_prompts

###############################################################################
#                  WORKTREE MANAGER                                           #
###############################################################################

section "worktree-manager.sh — Git helpers"

# ── test repo scaffold ──────────────────────────────────────────────────────
# All worktree tests share a disposable git repo in /tmp.
# Save SCRIPT_DIR — sourcing worktree-manager.sh overwrites it to lib/.

_SAVED_SCRIPT_DIR="$SCRIPT_DIR"

# Ensure git user is configured (CI runners often lack this)
git config user.name >/dev/null 2>&1 || git config --global user.name "test"
git config user.email >/dev/null 2>&1 || git config --global user.email "test@test"

source "$SCRIPT_DIR/lib/worktree-manager.sh"

# Extract check_pair from conflict-daemon.sh without running main_loop.
eval "$(sed -n '/^check_pair()/,/^}/p' "$_SAVED_SCRIPT_DIR/lib/conflict-daemon.sh")"

SCRIPT_DIR="$_SAVED_SCRIPT_DIR"

_WT_REPO="/tmp/claude-yolo-test-repo-$$"
_WT_SESSION="wt-test-$$"

_wt_setup_repo() {
    rm -rf "$_WT_REPO" "${_WT_REPO}-worktrees"
    mkdir -p "$_WT_REPO"
    git -C "$_WT_REPO" init -b main >/dev/null 2>&1
    git -C "$_WT_REPO" commit --allow-empty -m "initial" >/dev/null 2>&1
    echo "hello" > "$_WT_REPO/file.txt"
    git -C "$_WT_REPO" add file.txt >/dev/null 2>&1
    git -C "$_WT_REPO" commit -m "add file" >/dev/null 2>&1
}

_wt_teardown() {
    wt_cleanup "$_WT_SESSION" >/dev/null 2>&1 || true
    rm -rf "$_WT_REPO" "${_WT_REPO}-worktrees"
    rm -f "$(wt_state_file "$_WT_SESSION")" 2>/dev/null
}

# ── wt_validate_repo ────────────────────────────────────────────────────────

_wt_setup_repo

assert_ok "wt_validate_repo: valid git repo succeeds" \
    wt_validate_repo "$_WT_REPO"

assert_fail "wt_validate_repo: non-repo fails" \
    wt_validate_repo "/tmp"

# ── wt_current_branch / wt_repo_root ────────────────────────────────────────

_test_current_branch() {
    local branch
    branch="$(wt_current_branch "$_WT_REPO")"
    [[ "$branch" == "main" ]]
}
assert_ok "wt_current_branch: returns 'main'" _test_current_branch

_test_repo_root() {
    local root
    root="$(wt_repo_root "$_WT_REPO")"
    [[ "$root" == "$_WT_REPO" ]]
}
assert_ok "wt_repo_root: returns correct path" _test_repo_root

# ── path helpers ─────────────────────────────────────────────────────────────

_test_state_file_path() {
    local sf
    sf="$(wt_state_file "my-session")"
    [[ "$sf" == *"claude-yolo-wt-my-session.state" ]]
}
assert_ok "wt_state_file: returns expected path" _test_state_file_path

_test_done_marker_path() {
    local dm
    dm="$(wt_done_marker "my-session" 3)"
    [[ "$dm" == *"claude-yolo-done-my-session-3" ]]
}
assert_ok "wt_done_marker: returns expected path" _test_done_marker_path

_test_base_dir() {
    local bd
    bd="$(wt_base_dir "/tmp/repo" "sess")"
    [[ "$bd" == "/tmp/repo-worktrees/sess" ]]
}
assert_ok "wt_base_dir: returns sibling directory" _test_base_dir

# ── wt_create_all ────────────────────────────────────────────────────────────

section "worktree-manager.sh — Create and list"

_test_create_all() {
    _wt_teardown; _wt_setup_repo
    wt_create_all "$_WT_REPO" "$_WT_SESSION" "main" 3 >/dev/null 2>&1
}
assert_ok "wt_create_all: creates 3 worktrees without error" _test_create_all

_test_state_file_header() {
    local sf
    sf="$(wt_state_file "$_WT_SESSION")"
    [[ -f "$sf" ]] || return 1
    local line1 line2
    line1="$(head -1 "$sf")"
    line2="$(sed -n '2p' "$sf")"
    [[ "$line1" == "$_WT_REPO" && "$line2" == "main" ]]
}
assert_ok "wt_create_all: state file has correct repo + base branch" _test_state_file_header

_test_state_file_entries() {
    local sf
    sf="$(wt_state_file "$_WT_SESSION")"
    local count
    count="$(tail -n +3 "$sf" | wc -l)"
    (( count == 3 ))
}
assert_ok "wt_create_all: state file has 3 worktree entries" _test_state_file_entries

_test_wt_dirs_exist() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    [[ -d "${base}/${_WT_SESSION}-1" ]] && \
    [[ -d "${base}/${_WT_SESSION}-2" ]] && \
    [[ -d "${base}/${_WT_SESSION}-3" ]]
}
assert_ok "wt_create_all: worktree directories exist on disk" _test_wt_dirs_exist

_test_wt_file_in_worktree() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    [[ -f "${base}/${_WT_SESSION}-1/file.txt" ]]
}
assert_ok "wt_create_all: worktree contains repo files" _test_wt_file_in_worktree

_test_branches_exist() {
    git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-1" >/dev/null 2>&1 && \
    git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-2" >/dev/null 2>&1 && \
    git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-3" >/dev/null 2>&1
}
assert_ok "wt_create_all: branches exist in git" _test_branches_exist

# ── state readers ────────────────────────────────────────────────────────────

section "worktree-manager.sh — State readers"

_test_read_repo_dir() {
    local rd
    rd="$(wt_read_repo_dir "$_WT_SESSION")"
    [[ "$rd" == "$_WT_REPO" ]]
}
assert_ok "wt_read_repo_dir: returns repo path" _test_read_repo_dir

_test_read_base_branch() {
    local bb
    bb="$(wt_read_base_branch "$_WT_SESSION")"
    [[ "$bb" == "main" ]]
}
assert_ok "wt_read_base_branch: returns 'main'" _test_read_base_branch

_test_list_count() {
    local count
    count="$(wt_list "$_WT_SESSION" | wc -l)"
    (( count == 3 ))
}
assert_ok "wt_list: returns 3 entries" _test_list_count

_test_list_format() {
    local first
    first="$(wt_list "$_WT_SESSION" | head -1)"
    [[ "$first" == "${_WT_SESSION}-1 "* ]]
}
assert_ok "wt_list: entries are 'branch path' format" _test_list_format

_test_path_for() {
    local p
    p="$(wt_path_for "$_WT_SESSION" 2)"
    [[ "$p" == *"${_WT_SESSION}-2" ]]
}
assert_ok "wt_path_for: index 2 returns correct path" _test_path_for

_test_branch_for() {
    local b
    b="$(wt_branch_for "$_WT_SESSION" 2)"
    [[ "$b" == "${_WT_SESSION}-2" ]]
}
assert_ok "wt_branch_for: index 2 returns correct branch" _test_branch_for

assert_fail "wt_list: nonexistent session fails" \
    wt_list "nonexistent-session-xyz"

# ── duplicate branch guard ──────────────────────────────────────────────────

section "worktree-manager.sh — Error handling"

_test_duplicate_branch() {
    # Worktrees already exist from prior test — creating again should fail
    wt_create_all "$_WT_REPO" "$_WT_SESSION" "main" 3 >/dev/null 2>&1
}
assert_fail "wt_create_all: fails when branches already exist" _test_duplicate_branch

assert_fail "wt_validate_repo: non-repo path fails" \
    wt_validate_repo "/tmp/definitely-not-a-git-repo-$$"

# ── wt_cleanup ──────────────────────────────────────────────────────────────

section "worktree-manager.sh — Cleanup"

# Re-create worktrees fresh (the duplicate-branch test above triggered internal cleanup)
_wt_teardown; _wt_setup_repo
wt_create_all "$_WT_REPO" "$_WT_SESSION" "main" 3 >/dev/null 2>&1

_test_cleanup() {
    wt_cleanup "$_WT_SESSION" >/dev/null 2>&1
    local sf
    sf="$(wt_state_file "$_WT_SESSION")"
    # State file should be gone
    [[ ! -f "$sf" ]]
}
assert_ok "wt_cleanup: removes state file" _test_cleanup

_test_cleanup_branches_gone() {
    ! git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-1" >/dev/null 2>&1 && \
    ! git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-2" >/dev/null 2>&1 && \
    ! git -C "$_WT_REPO" rev-parse --verify "${_WT_SESSION}-3" >/dev/null 2>&1
}
assert_ok "wt_cleanup: branches are deleted" _test_cleanup_branches_gone

_test_cleanup_dirs_gone() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    [[ ! -d "${base}/${_WT_SESSION}-1" ]] && \
    [[ ! -d "${base}/${_WT_SESSION}-2" ]]
}
assert_ok "wt_cleanup: worktree directories are removed" _test_cleanup_dirs_gone

_test_cleanup_noop() {
    wt_cleanup "nonexistent-session-xyz" >/dev/null 2>&1
}
assert_ok "wt_cleanup: no-op for nonexistent session" _test_cleanup_noop

_test_cleanup_done_markers() {
    # Create worktrees, add done markers, cleanup
    wt_create_all "$_WT_REPO" "$_WT_SESSION" "main" 2 >/dev/null 2>&1
    touch "$(wt_done_marker "$_WT_SESSION" 1)"
    touch "$(wt_done_marker "$_WT_SESSION" 2)"
    wt_cleanup "$_WT_SESSION" >/dev/null 2>&1
    [[ ! -f "$(wt_done_marker "$_WT_SESSION" 1)" ]] && \
    [[ ! -f "$(wt_done_marker "$_WT_SESSION" 2)" ]]
}
assert_ok "wt_cleanup: removes done markers" _test_cleanup_done_markers

###############################################################################
#                  CONFLICT DETECTION                                         #
###############################################################################

section "conflict-daemon.sh — check_pair"

# Re-create repo + worktrees for conflict tests
_wt_teardown; _wt_setup_repo
wt_create_all "$_WT_REPO" "$_WT_SESSION" "main" 3 >/dev/null 2>&1

# check_pair was extracted above via eval/sed; set REPO_DIR for it
REPO_DIR="$_WT_REPO"

# Make conflicting changes in worktree 1 and 2 (same file, different content)
_wt_make_conflicts() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    echo "change from agent 1" > "${base}/${_WT_SESSION}-1/file.txt"
    git -C "${base}/${_WT_SESSION}-1" add file.txt >/dev/null 2>&1
    git -C "${base}/${_WT_SESSION}-1" commit -m "agent 1 edit" >/dev/null 2>&1

    echo "change from agent 2" > "${base}/${_WT_SESSION}-2/file.txt"
    git -C "${base}/${_WT_SESSION}-2" add file.txt >/dev/null 2>&1
    git -C "${base}/${_WT_SESSION}-2" commit -m "agent 2 edit" >/dev/null 2>&1
}
_wt_make_conflicts

_test_conflict_detected() {
    local details
    details="$(check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-2")"
}
assert_ok "check_pair: detects conflict between divergent branches" _test_conflict_detected

_test_conflict_output() {
    local details
    details="$(check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-2")"
    [[ "$details" == *"CONFLICT"* ]]
}
assert_ok "check_pair: output contains CONFLICT" _test_conflict_output

_test_conflict_filename() {
    local details
    details="$(check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-2")"
    [[ "$details" == *"file.txt"* ]]
}
assert_ok "check_pair: output includes conflicting filename" _test_conflict_filename

_test_clean_merge() {
    # worktree 3 has no changes — should merge cleanly with either 1 or 2
    check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-3"
}
assert_fail "check_pair: clean merge when no overlap (returns 1)" _test_clean_merge

# Add non-conflicting change to worktree 3 (different file)
_test_no_conflict_different_files() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    echo "new file from agent 3" > "${base}/${_WT_SESSION}-3/other.txt"
    git -C "${base}/${_WT_SESSION}-3" add other.txt >/dev/null 2>&1
    git -C "${base}/${_WT_SESSION}-3" commit -m "agent 3 adds other file" >/dev/null 2>&1
    # Different files = clean merge
    check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-3"
}
assert_fail "check_pair: no conflict when agents edit different files" _test_no_conflict_different_files

# Test multiple conflicting files
_test_multi_file_conflict() {
    local base="${_WT_REPO}-worktrees/${_WT_SESSION}"
    # Add same new file in worktree 1 and 3
    echo "version A" > "${base}/${_WT_SESSION}-1/shared.txt"
    git -C "${base}/${_WT_SESSION}-1" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_SESSION}-1" commit -m "agent 1 adds shared" >/dev/null 2>&1

    echo "version B" > "${base}/${_WT_SESSION}-3/shared.txt"
    git -C "${base}/${_WT_SESSION}-3" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_SESSION}-3" commit -m "agent 3 adds shared" >/dev/null 2>&1

    local details
    details="$(check_pair "${_WT_SESSION}-1" "${_WT_SESSION}-3")"
    [[ "$details" == *"shared.txt"* ]]
}
assert_ok "check_pair: detects add/add conflict on new file" _test_multi_file_conflict

###############################################################################
#                  MERGE RESOLUTION                                           #
###############################################################################

section "merge-resolver.sh — merge_branch"

# Extract merge_branch and audit_merge from merge-resolver without running main.
# We set up the needed variables manually.
_MR_REPO="/tmp/claude-yolo-test-merge-$$"
_MR_SESSION="mr-test-$$"
_MR_AUDIT="$(mktemp)"

_mr_setup() {
    rm -rf "$_MR_REPO"
    mkdir -p "$_MR_REPO"
    git -C "$_MR_REPO" init -b main >/dev/null 2>&1
    echo "base content" > "$_MR_REPO/file.txt"
    git -C "$_MR_REPO" add file.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "initial" >/dev/null 2>&1
}

_mr_cleanup() {
    rm -rf "$_MR_REPO" "$_MR_AUDIT"
}

# Re-define audit_merge and merge_branch locally
REPO_DIR_saved="$REPO_DIR"
AUDIT_LOG_saved="${AUDIT_LOG:-}"
BASE_BRANCH_saved="${BASE_BRANCH:-}"

_mr_setup

REPO_DIR="$_MR_REPO"
AUDIT_LOG="$_MR_AUDIT"
BASE_BRANCH="main"

audit_merge() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MERGE $msg" >> "$AUDIT_LOG" 2>/dev/null
}

merge_branch() {
    local branch="$1"
    audit_merge "Merging $branch into $BASE_BRANCH"
    local merge_output
    if merge_output="$(git -C "$REPO_DIR" merge --no-edit "$branch" 2>&1)"; then
        audit_merge "OK $branch merged cleanly"
        return 0
    fi
    audit_merge "CONFLICTS in $branch"
    return 1
}

# Test: fast-forward merge
_test_ff_merge() {
    git -C "$_MR_REPO" checkout -b "ff-branch" main >/dev/null 2>&1
    echo "new content" > "$_MR_REPO/new.txt"
    git -C "$_MR_REPO" add new.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "ff commit" >/dev/null 2>&1
    git -C "$_MR_REPO" checkout main >/dev/null 2>&1
    merge_branch "ff-branch" >/dev/null 2>&1
}
assert_ok "merge_branch: fast-forward merge succeeds" _test_ff_merge

_test_ff_audit() {
    local log
    log="$(cat "$_MR_AUDIT")"
    [[ "$log" == *"OK ff-branch merged cleanly"* ]]
}
assert_ok "merge_branch: audit logs clean merge" _test_ff_audit

# Test: clean divergent merge
_test_divergent_clean() {
    # Reset for new test
    : > "$_MR_AUDIT"
    git -C "$_MR_REPO" checkout -b "div-branch" main >/dev/null 2>&1
    echo "divergent" > "$_MR_REPO/div.txt"
    git -C "$_MR_REPO" add div.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "divergent commit" >/dev/null 2>&1
    git -C "$_MR_REPO" checkout main >/dev/null 2>&1
    echo "main change" > "$_MR_REPO/main-only.txt"
    git -C "$_MR_REPO" add main-only.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "main commit" >/dev/null 2>&1
    merge_branch "div-branch" >/dev/null 2>&1
}
assert_ok "merge_branch: divergent non-conflicting merge succeeds" _test_divergent_clean

# Test: conflicting merge fails
_test_conflict_merge() {
    : > "$_MR_AUDIT"
    git -C "$_MR_REPO" checkout -b "conflict-branch" main >/dev/null 2>&1
    echo "conflict version A" > "$_MR_REPO/file.txt"
    git -C "$_MR_REPO" add file.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "conflict A" >/dev/null 2>&1
    git -C "$_MR_REPO" checkout main >/dev/null 2>&1
    echo "conflict version B" > "$_MR_REPO/file.txt"
    git -C "$_MR_REPO" add file.txt >/dev/null 2>&1
    git -C "$_MR_REPO" commit -m "conflict B" >/dev/null 2>&1
    merge_branch "conflict-branch" >/dev/null 2>&1
}
assert_fail "merge_branch: conflicting merge returns failure" _test_conflict_merge

_test_conflict_audit() {
    local log
    log="$(cat "$_MR_AUDIT")"
    [[ "$log" == *"CONFLICTS in conflict-branch"* ]]
}
assert_ok "merge_branch: audit logs conflict" _test_conflict_audit

# Clean up conflicting state for subsequent tests
git -C "$_MR_REPO" merge --abort 2>/dev/null || true

# Verify conflicting files are detectable after failed merge
_test_unmerged_files() {
    git -C "$_MR_REPO" merge --no-edit "conflict-branch" >/dev/null 2>&1 || true
    local unmerged
    unmerged="$(git -C "$_MR_REPO" diff --name-only --diff-filter=U 2>/dev/null)"
    git -C "$_MR_REPO" merge --abort 2>/dev/null || true
    [[ "$unmerged" == *"file.txt"* ]]
}
assert_ok "merge_branch: git reports unmerged files after conflict" _test_unmerged_files

# Restore saved variables
REPO_DIR="$REPO_DIR_saved"
AUDIT_LOG="${AUDIT_LOG_saved}"
BASE_BRANCH="${BASE_BRANCH_saved}"
_mr_cleanup

###############################################################################
#                  COMMON.SH — GIT HELPERS                                    #
###############################################################################

section "common.sh — Git merge-tree version check"

assert_ok "check_git_merge_tree: passes on git 2.43+" check_git_merge_tree

###############################################################################
#                  LAUNCHER — WORKTREE FLAGS                                  #
###############################################################################

section "claude-yolo — Worktree flag parsing"

_test_help_worktree() {
    local output
    output="$(bash "$_SAVED_SCRIPT_DIR/claude-yolo" --help 2>&1)"
    [[ "$output" == *"--worktree"* ]] && \
    [[ "$output" == *"--base-branch"* ]] && \
    [[ "$output" == *"--no-merge"* ]] && \
    [[ "$output" == *"--no-cleanup"* ]] && \
    [[ "$output" == *"--conflict-poll"* ]]
}
assert_ok "launcher: --help shows all worktree options" _test_help_worktree

assert_fail "launcher: --worktree with 1 task fails (needs >=2)" \
    bash "$_SAVED_SCRIPT_DIR/claude-yolo" --worktree -d /tmp "single task"

assert_fail "launcher: --worktree on non-git dir fails" \
    bash "$_SAVED_SCRIPT_DIR/claude-yolo" --worktree -d /tmp "task1" "task2"

_test_worktree_short_flag() {
    local output
    output="$(bash "$_SAVED_SCRIPT_DIR/claude-yolo" -w -d /tmp "task1" "task2" 2>&1)" || true
    # Should fail on non-git-repo, not on flag parsing
    [[ "$output" == *"Not a git repository"* ]]
}
assert_ok "launcher: -w is alias for --worktree" _test_worktree_short_flag

###############################################################################
#                  INTEGRATION — WORKTREE LIFECYCLE                           #
###############################################################################

section "Integration — Worktree lifecycle"

# Full lifecycle: create worktrees, commit to them, detect conflicts, merge cleanly, cleanup

_WT_INTEG_REPO="/tmp/claude-yolo-test-integ-$$"
_WT_INTEG_SESSION="wt-integ-$$"

_wt_integ_cleanup() {
    wt_cleanup "$_WT_INTEG_SESSION" >/dev/null 2>&1 || true
    rm -rf "$_WT_INTEG_REPO" "${_WT_INTEG_REPO}-worktrees"
}

_test_full_lifecycle_no_conflict() {
    _wt_integ_cleanup
    mkdir -p "$_WT_INTEG_REPO"
    git -C "$_WT_INTEG_REPO" init -b main >/dev/null 2>&1
    echo "base" > "$_WT_INTEG_REPO/base.txt"
    git -C "$_WT_INTEG_REPO" add base.txt >/dev/null 2>&1
    git -C "$_WT_INTEG_REPO" commit -m "initial" >/dev/null 2>&1

    # Create 2 worktrees
    wt_create_all "$_WT_INTEG_REPO" "$_WT_INTEG_SESSION" "main" 2 >/dev/null 2>&1 || return 1

    local base="${_WT_INTEG_REPO}-worktrees/${_WT_INTEG_SESSION}"

    # Agent 1 edits file-a, agent 2 edits file-b (no conflict)
    echo "agent1" > "${base}/${_WT_INTEG_SESSION}-1/file-a.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-1" add file-a.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-1" commit -m "agent 1" >/dev/null 2>&1

    echo "agent2" > "${base}/${_WT_INTEG_SESSION}-2/file-b.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-2" add file-b.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-2" commit -m "agent 2" >/dev/null 2>&1

    # No conflicts expected
    local REPO_DIR="$_WT_INTEG_REPO"
    local rc=0
    git -C "$_WT_INTEG_REPO" merge-tree --write-tree "${_WT_INTEG_SESSION}-1" "${_WT_INTEG_SESSION}-2" >/dev/null 2>&1 || rc=$?
    (( rc == 0 )) || return 1

    # Sequential merge
    git -C "$_WT_INTEG_REPO" checkout main >/dev/null 2>&1
    git -C "$_WT_INTEG_REPO" merge --no-edit "${_WT_INTEG_SESSION}-1" >/dev/null 2>&1 || return 1
    git -C "$_WT_INTEG_REPO" merge --no-edit "${_WT_INTEG_SESSION}-2" >/dev/null 2>&1 || return 1

    # Verify both files exist on main
    [[ -f "$_WT_INTEG_REPO/file-a.txt" ]] && [[ -f "$_WT_INTEG_REPO/file-b.txt" ]] || return 1

    # Cleanup
    wt_cleanup "$_WT_INTEG_SESSION" >/dev/null 2>&1

    # Verify cleanup
    [[ ! -f "$(wt_state_file "$_WT_INTEG_SESSION")" ]] && \
    ! git -C "$_WT_INTEG_REPO" rev-parse --verify "${_WT_INTEG_SESSION}-1" >/dev/null 2>&1
}
assert_ok "lifecycle: create → commit (no conflict) → merge → cleanup" _test_full_lifecycle_no_conflict

_test_full_lifecycle_with_conflict() {
    _wt_integ_cleanup
    mkdir -p "$_WT_INTEG_REPO"
    git -C "$_WT_INTEG_REPO" init -b main >/dev/null 2>&1
    echo "original" > "$_WT_INTEG_REPO/shared.txt"
    git -C "$_WT_INTEG_REPO" add shared.txt >/dev/null 2>&1
    git -C "$_WT_INTEG_REPO" commit -m "initial" >/dev/null 2>&1

    # Create 2 worktrees
    wt_create_all "$_WT_INTEG_REPO" "$_WT_INTEG_SESSION" "main" 2 >/dev/null 2>&1 || return 1

    local base="${_WT_INTEG_REPO}-worktrees/${_WT_INTEG_SESSION}"

    # Both agents edit the same file
    echo "agent1 version" > "${base}/${_WT_INTEG_SESSION}-1/shared.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-1" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-1" commit -m "agent 1 edit" >/dev/null 2>&1

    echo "agent2 version" > "${base}/${_WT_INTEG_SESSION}-2/shared.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-2" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-2" commit -m "agent 2 edit" >/dev/null 2>&1

    # Conflict detected by merge-tree
    local rc=0
    git -C "$_WT_INTEG_REPO" merge-tree --write-tree "${_WT_INTEG_SESSION}-1" "${_WT_INTEG_SESSION}-2" >/dev/null 2>&1 || rc=$?
    (( rc == 1 )) || return 1  # rc=1 means conflicts

    # First merge succeeds, second hits conflict
    git -C "$_WT_INTEG_REPO" checkout main >/dev/null 2>&1
    git -C "$_WT_INTEG_REPO" merge --no-edit "${_WT_INTEG_SESSION}-1" >/dev/null 2>&1 || return 1

    local merge_rc=0
    git -C "$_WT_INTEG_REPO" merge --no-edit "${_WT_INTEG_SESSION}-2" >/dev/null 2>&1 || merge_rc=$?
    (( merge_rc != 0 )) || return 1  # Should fail

    # Verify conflict markers present
    local unmerged
    unmerged="$(git -C "$_WT_INTEG_REPO" diff --name-only --diff-filter=U 2>/dev/null)"
    [[ "$unmerged" == *"shared.txt"* ]] || return 1

    git -C "$_WT_INTEG_REPO" merge --abort 2>/dev/null || true

    # Cleanup
    wt_cleanup "$_WT_INTEG_SESSION" >/dev/null 2>&1
    _wt_integ_cleanup
}
assert_ok "lifecycle: create → commit (with conflict) → detect → abort → cleanup" _test_full_lifecycle_with_conflict

_test_three_way_partial_conflict() {
    _wt_integ_cleanup
    mkdir -p "$_WT_INTEG_REPO"
    git -C "$_WT_INTEG_REPO" init -b main >/dev/null 2>&1
    echo "original" > "$_WT_INTEG_REPO/shared.txt"
    echo "untouched" > "$_WT_INTEG_REPO/safe.txt"
    git -C "$_WT_INTEG_REPO" add . >/dev/null 2>&1
    git -C "$_WT_INTEG_REPO" commit -m "initial" >/dev/null 2>&1

    wt_create_all "$_WT_INTEG_REPO" "$_WT_INTEG_SESSION" "main" 3 >/dev/null 2>&1 || return 1
    local base="${_WT_INTEG_REPO}-worktrees/${_WT_INTEG_SESSION}"

    # Agent 1: edit shared.txt
    echo "agent1" > "${base}/${_WT_INTEG_SESSION}-1/shared.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-1" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-1" commit -m "a1" >/dev/null 2>&1

    # Agent 2: edit shared.txt (conflict with 1)
    echo "agent2" > "${base}/${_WT_INTEG_SESSION}-2/shared.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-2" add shared.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-2" commit -m "a2" >/dev/null 2>&1

    # Agent 3: edit safe.txt only (no conflict with anyone)
    echo "agent3" > "${base}/${_WT_INTEG_SESSION}-3/safe.txt"
    git -C "${base}/${_WT_INTEG_SESSION}-3" add safe.txt >/dev/null 2>&1
    git -C "${base}/${_WT_INTEG_SESSION}-3" commit -m "a3" >/dev/null 2>&1

    # 1 vs 2: conflict. 1 vs 3: clean. 2 vs 3: clean.
    local rc12=0 rc13=0 rc23=0
    git -C "$_WT_INTEG_REPO" merge-tree --write-tree "${_WT_INTEG_SESSION}-1" "${_WT_INTEG_SESSION}-2" >/dev/null 2>&1 || rc12=$?
    git -C "$_WT_INTEG_REPO" merge-tree --write-tree "${_WT_INTEG_SESSION}-1" "${_WT_INTEG_SESSION}-3" >/dev/null 2>&1 || rc13=$?
    git -C "$_WT_INTEG_REPO" merge-tree --write-tree "${_WT_INTEG_SESSION}-2" "${_WT_INTEG_SESSION}-3" >/dev/null 2>&1 || rc23=$?

    (( rc12 == 1 )) && (( rc13 == 0 )) && (( rc23 == 0 )) || return 1

    wt_cleanup "$_WT_INTEG_SESSION" >/dev/null 2>&1
    _wt_integ_cleanup
}
assert_ok "lifecycle: 3 worktrees — only overlapping pair conflicts" _test_three_way_partial_conflict

# Final cleanup for all worktree tests
_wt_teardown
_wt_integ_cleanup 2>/dev/null || true

###############################################################################
#               PLAN-EXIT PROMPT DETECTION                                    #
###############################################################################

section "detect_plan_prompt — Claude Code ExitPlanMode prompts"

# Realistic ExitPlanMode prompt from Claude Code TUI
make_plan_exit_prompt() {
    cat <<'PANE'
  ⏵⏵ ready to exit plan mode and start implementing
  ⎿ User must approve the plan before tools can run

 Would you like to proceed with this plan?
 ❯ 1. Yes, and auto-accept edits
   2. Yes, and manually approve edits
   3. No, keep planning

 Esc to cancel
PANE
}

assert_ok "Plan: ExitPlanMode auto-accept variant" \
    detect_plan_prompt "$(make_plan_exit_prompt)"

assert_ok "Plan: numbered list with proceed-with-plan question" \
    detect_plan_prompt "$(cat <<'PANE'
 The agent is in plan mode.

 Proceed with this plan?
 ❯ 1. Yes, and auto-accept edits
   2. No, keep planning
PANE
)"

assert_ok "Plan: ExitPlanMode keyword present" \
    detect_plan_prompt "$(cat <<'PANE'
 ● ExitPlanMode(plan: refactor the parser)
   Implement this plan?

 ❯ 1. Yes, proceed
   2. No, keep planning
PANE
)"

# Negative: missing approval option text
assert_fail "Plan: missing approval option" \
    detect_plan_prompt "$(cat <<'PANE'
 Would you like to proceed with this plan?
 No options listed
PANE
)"

# Negative: missing "no/keep planning" context
assert_fail "Plan: missing keep-planning context" \
    detect_plan_prompt "$(cat <<'PANE'
 Would you like to proceed with this plan?
 ❯ 1. Yes, proceed
PANE
)"

# Negative: generic Yes/No prompt without plan context
assert_fail "Plan: generic permission prompt is not a plan prompt" \
    detect_plan_prompt "$(cat <<'PANE'
 Bash command

   ls /tmp
   List current directory contents

 Do you want to proceed?
 > 1. Yes
   2. No
PANE
)"

# detect_slash_picker still vetoes in the daemon, but detect_plan_prompt itself
# should not match a slash picker because the ExitPlanMode keywords are absent.
assert_fail "Plan: slash picker is not a plan prompt" \
    detect_plan_prompt "$(cat <<'PANE'
   /plan          Enter plan mode
 ❯ /permissions   Modify allowed tools
   /clear         Clear conversation
PANE
)"

###############################################################################
#               PLAN-APPROVAL MARKER FILE VALIDATION                          #
###############################################################################

section "plan_approval_marker_valid — pane and TTL scoping"

_marker_setup() {
    AUDIT_LOG="$(mktemp)"
    : > "$AUDIT_LOG"
    PLAN_APPROVAL_TTL=3600
    SLASH_APPROVAL_TTL=60
}

_marker_teardown() {
    [[ -n "${AUDIT_LOG:-}" ]] && rm -f "$AUDIT_LOG" "$AUDIT_LOG.plan-approval" "$AUDIT_LOG.slash-approval" 2>/dev/null
    AUDIT_LOG=""
}

_marker_setup
_test_plan_marker_present_matching_pane() {
    local f
    f="$(plan_approval_file)"
    printf '%%5\t%s\n' "$(date +%s)" > "$f"
    plan_approval_marker_valid "%5"
}
assert_ok "plan marker: valid for matching pane" _test_plan_marker_present_matching_pane

_test_plan_marker_present_other_pane() {
    local f
    f="$(plan_approval_file)"
    printf '%%5\t%s\n' "$(date +%s)" > "$f"
    plan_approval_marker_valid "%9"
}
assert_fail "plan marker: rejects mismatched pane" _test_plan_marker_present_other_pane

_test_plan_marker_missing() {
    rm -f "$(plan_approval_file)" 2>/dev/null
    plan_approval_marker_valid "%5"
}
assert_fail "plan marker: missing marker is invalid" _test_plan_marker_missing

_test_plan_marker_expired() {
    local f stale
    f="$(plan_approval_file)"
    stale="$(($(date +%s) - PLAN_APPROVAL_TTL - 60))"
    printf '%%5\t%s\n' "$stale" > "$f"
    plan_approval_marker_valid "%5"
}
assert_fail "plan marker: expired TTL is invalid" _test_plan_marker_expired

_test_plan_marker_expired_self_cleans() {
    local f stale
    f="$(plan_approval_file)"
    stale="$(($(date +%s) - PLAN_APPROVAL_TTL - 60))"
    printf '%%5\t%s\n' "$stale" > "$f"
    plan_approval_marker_valid "%5" >/dev/null 2>&1
    [[ ! -f "$f" ]]
}
assert_ok "plan marker: expired marker is removed" _test_plan_marker_expired_self_cleans

_test_plan_marker_malformed() {
    local f
    f="$(plan_approval_file)"
    printf 'garbage\n' > "$f"
    plan_approval_marker_valid "%5"
}
assert_fail "plan marker: malformed marker is invalid" _test_plan_marker_malformed

_test_clear_plan_marker() {
    local f
    f="$(plan_approval_file)"
    printf '%%5\t%s\n' "$(date +%s)" > "$f"
    clear_plan_approval_marker
    [[ ! -f "$f" ]]
}
assert_ok "plan marker: clear_plan_approval_marker removes file" _test_clear_plan_marker

# Slash marker uses 60s TTL by default
_test_slash_marker_within_ttl() {
    local f
    f="$(slash_approval_file)"
    printf '%%5\t%s\n' "$(date +%s)" > "$f"
    slash_approval_marker_valid "%5"
}
assert_ok "slash marker: valid for matching pane" _test_slash_marker_within_ttl

_test_slash_marker_expired() {
    local f stale
    f="$(slash_approval_file)"
    stale="$(($(date +%s) - SLASH_APPROVAL_TTL - 5))"
    printf '%%5\t%s\n' "$stale" > "$f"
    slash_approval_marker_valid "%5"
}
assert_fail "slash marker: expired TTL is invalid" _test_slash_marker_expired

_test_slash_marker_pane_mismatch() {
    local f
    f="$(slash_approval_file)"
    printf '%%5\t%s\n' "$(date +%s)" > "$f"
    slash_approval_marker_valid "%9"
}
assert_fail "slash marker: rejects mismatched pane" _test_slash_marker_pane_mismatch

_marker_teardown

###############################################################################
#               CONTROL PANE — RECOGNIZERS                                    #
###############################################################################

section "control-pane — /plan and /queue recognizers"

assert_ok "control_is_plan_command: bare /plan" \
    control_is_plan_command "/plan"

assert_ok "control_is_plan_command: /plan with prompt" \
    control_is_plan_command "/plan refactor the parser"

assert_fail "control_is_plan_command: /planet is not /plan" \
    control_is_plan_command "/planet earth"

assert_fail "control_is_plan_command: /loop is not /plan" \
    control_is_plan_command "/loop 1h test"

assert_ok "control_is_queue_command: bare /queue" \
    control_is_queue_command "/queue"

assert_ok "control_is_queue_command: /queue with array" \
    control_is_queue_command '/queue ["one", "two"]'

assert_fail "control_is_queue_command: /queues plural is not /queue" \
    control_is_queue_command "/queues"

###############################################################################
#               CONTROL PANE — QUEUE ARRAY PARSING                            #
###############################################################################

section "control-pane — /queue array parsing"

_test_queue_parse_simple() {
    control_parse_queue_items '["one", "two"]' || return 1
    [[ "${#CONTROL_QUEUE_PARSED_ITEMS[@]}" -eq 2 ]] || return 1
    [[ "${CONTROL_QUEUE_PARSED_ITEMS[0]}" == "one" && "${CONTROL_QUEUE_PARSED_ITEMS[1]}" == "two" ]]
}
assert_ok "queue parse: two double-quoted strings" _test_queue_parse_simple

_test_queue_parse_single_quoted() {
    control_parse_queue_items "['alpha', 'beta']" || return 1
    [[ "${#CONTROL_QUEUE_PARSED_ITEMS[@]}" -eq 2 ]] || return 1
    [[ "${CONTROL_QUEUE_PARSED_ITEMS[0]}" == "alpha" && "${CONTROL_QUEUE_PARSED_ITEMS[1]}" == "beta" ]]
}
assert_ok "queue parse: single-quoted strings" _test_queue_parse_single_quoted

_test_queue_parse_triple_quoted() {
    local input
    input='["""line one
line two""", "single"]'
    control_parse_queue_items "$input" || return 1
    [[ "${#CONTROL_QUEUE_PARSED_ITEMS[@]}" -eq 2 ]] || return 1
    [[ "${CONTROL_QUEUE_PARSED_ITEMS[0]}" == $'line one\nline two' ]] || return 1
    [[ "${CONTROL_QUEUE_PARSED_ITEMS[1]}" == "single" ]]
}
assert_ok "queue parse: triple-quoted multi-line strings" _test_queue_parse_triple_quoted

assert_fail "queue parse: rejects empty []" \
    control_parse_queue_items '[]'

assert_fail "queue parse: rejects trailing comma" \
    control_parse_queue_items '["one",]'

assert_fail "queue parse: rejects unquoted item" \
    control_parse_queue_items '[one]'

assert_fail "queue parse: rejects bare text" \
    control_parse_queue_items 'just text'

# control_queue_array_needs_more: true when the [ has no matching ]
_test_queue_array_needs_more_open() {
    control_queue_array_needs_more '["start without end'
}
assert_ok "queue array_needs_more: bracket open" _test_queue_array_needs_more_open

_test_queue_array_needs_more_closed() {
    control_queue_array_needs_more '["complete"]'
}
assert_fail "queue array_needs_more: bracket already closed" _test_queue_array_needs_more_closed

###############################################################################
#               CONTROL PANE — QUEUE STATE ROUND-TRIP                         #
###############################################################################

section "control-pane — queue state on disk"

_test_queue_init_round_trip() {
    local dir
    dir="$(mktemp -d)"
    local items=("first" "second" "third")
    control_queue_init_state "$dir" items || { rm -rf "$dir"; return 1; }
    [[ "$(cat "$dir/status")" == "pending" ]] || { rm -rf "$dir"; return 1; }
    [[ "$(cat "$dir/next_pos")" == "1" ]] || { rm -rf "$dir"; return 1; }

    local order=()
    control_queue_read_order "$dir" order || { rm -rf "$dir"; return 1; }
    [[ "${#order[@]}" -eq 3 ]] || { rm -rf "$dir"; return 1; }

    [[ "$(cat "$dir/items/${order[0]}")" == "first" ]] || { rm -rf "$dir"; return 1; }
    [[ "$(cat "$dir/items/${order[2]}")" == "third" ]] || { rm -rf "$dir"; return 1; }

    rm -rf "$dir"
}
assert_ok "queue state: init writes order, items, status" _test_queue_init_round_trip

_test_queue_remove_position() {
    local dir
    dir="$(mktemp -d)"
    local items=("a" "b" "c" "d")
    control_queue_init_state "$dir" items || { rm -rf "$dir"; return 1; }
    control_queue_remove_positions_unlocked "$dir" 2 3 || { rm -rf "$dir"; return 1; }

    local order=()
    control_queue_read_order "$dir" order || { rm -rf "$dir"; return 1; }
    [[ "${#order[@]}" -eq 2 ]] || { rm -rf "$dir"; return 1; }
    [[ "$(cat "$dir/items/${order[0]}")" == "a" ]] || { rm -rf "$dir"; return 1; }
    [[ "$(cat "$dir/items/${order[1]}")" == "d" ]] || { rm -rf "$dir"; return 1; }

    rm -rf "$dir"
}
assert_ok "queue state: remove positions 2-3 leaves a, d" _test_queue_remove_position

_test_queue_remove_running_item_blocked() {
    local dir
    dir="$(mktemp -d)"
    local items=("a" "b" "c")
    control_queue_init_state "$dir" items || { rm -rf "$dir"; return 1; }
    # Mark item 2 as the one currently running.
    printf '2\n' > "$dir/current_pos"
    printf '3\n' > "$dir/next_pos"

    # Removing position 2 (the running item) must fail with rc=2.
    control_queue_remove_positions_unlocked "$dir" 2 2
    local rc=$?
    rm -rf "$dir"
    (( rc == 2 ))
}
assert_ok "queue state: cannot remove the running item" _test_queue_remove_running_item_blocked

_test_queue_pending_index_allowed() {
    local dir
    dir="$(mktemp -d)"
    local items=("a" "b" "c")
    control_queue_init_state "$dir" items || { rm -rf "$dir"; return 1; }

    control_queue_pending_index_allowed_unlocked "$dir" 1 || { rm -rf "$dir"; return 1; }

    # After the queue is "done", no index is allowed
    printf 'done\n' > "$dir/status"
    local rc=0
    control_queue_pending_index_allowed_unlocked "$dir" 1 || rc=$?
    rm -rf "$dir"
    (( rc != 0 ))
}
assert_ok "queue state: pending index allowed before done" _test_queue_pending_index_allowed

###############################################################################
#               CONTROL PANE — /loop /queue and /loop /plan ROUTING            #
###############################################################################

section "control-pane — /loop /queue and /loop /plan dispatch"

_LOOP_ROUTE_AUDIT="/tmp/claude-yolo-loop-route-test-$$.log"

_test_start_loop_routes_queue() {
    local audit calls captured_args
    audit="$(mktemp)"
    calls="$(mktemp)"

    SESSION_NAME="route-test"
    AUDIT_LOG="$audit"
    SESSION_MODE="standard"
    LOOP_PIDS=(); LOOP_INTERVALS=(); LOOP_SECONDS=(); LOOP_PROMPTS=(); LOOP_TARGETS=(); LOOP_TYPES=(); LOOP_QUEUE_IDS=()
    QUEUE_PIDS=(); QUEUE_INTERVALS=(); QUEUE_SECONDS=(); QUEUE_TARGETS=(); QUEUE_TYPES=(); QUEUE_STATE_DIRS=(); QUEUE_LOOP_IDS=()
    NEXT_LOOP_ID=1; NEXT_QUEUE_ID=1

    # Stub control_agent_exists / control_start_queue / control_loop_worker
    control_agent_exists() { return 0; }
    control_start_queue() {
        printf 'start_queue type=%s items_var=%s interval=%s seconds=%s loop_id=%s display=%s\n' \
            "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}" >> "$calls"
    }
    control_loop_worker() {
        printf 'loop_worker type=%s\n' "${8:-prompt}" >> "$calls"
    }

    control_start_loop "30s" "30" '/queue ["alpha", "beta"]' >/dev/null
    captured_args="$(cat "$calls")"
    rm -f "$audit" "$calls"
    [[ "$captured_args" == *"start_queue type=loop items_var=CONTROL_QUEUE_PARSED_ITEMS"* ]] || return 1
    [[ "$captured_args" != *"loop_worker"* ]]
}
assert_ok "control-pane: /loop /queue routes to control_start_queue" _test_start_loop_routes_queue

_test_start_loop_routes_plan_loop_type() {
    local audit calls captured_args pid
    audit="$(mktemp)"
    calls="$(mktemp)"

    SESSION_NAME="route-test"
    AUDIT_LOG="$audit"
    SESSION_MODE="standard"
    LOOP_PIDS=(); LOOP_INTERVALS=(); LOOP_SECONDS=(); LOOP_PROMPTS=(); LOOP_TARGETS=(); LOOP_TYPES=(); LOOP_QUEUE_IDS=()
    NEXT_LOOP_ID=1

    control_agent_exists() { return 0; }
    control_loop_worker() {
        printf 'loop_worker type=%s prompt=%s\n' "${8:-prompt}" "${7:-}" >> "$calls"
    }

    control_start_loop "1h" "3600" "/plan refactor the parser" >/dev/null
    captured_args="$(cat "$calls")"
    rm -f "$audit" "$calls"

    [[ "$captured_args" == *"loop_worker type=plan prompt=/plan refactor the parser"* ]] || return 1
    [[ "${LOOP_TYPES[1]:-}" == "plan" ]]
}
assert_ok "control-pane: /loop /plan sets loop_type=plan" _test_start_loop_routes_plan_loop_type

_test_start_loop_routes_plain_prompt() {
    local audit calls captured_args
    audit="$(mktemp)"
    calls="$(mktemp)"

    SESSION_NAME="route-test"
    AUDIT_LOG="$audit"
    SESSION_MODE="standard"
    LOOP_PIDS=(); LOOP_INTERVALS=(); LOOP_SECONDS=(); LOOP_PROMPTS=(); LOOP_TARGETS=(); LOOP_TYPES=(); LOOP_QUEUE_IDS=()
    NEXT_LOOP_ID=1

    control_agent_exists() { return 0; }
    control_loop_worker() {
        printf 'loop_worker type=%s\n' "${8:-prompt}" >> "$calls"
    }

    control_start_loop "5s" "5" "Continue experiments" >/dev/null
    captured_args="$(cat "$calls")"
    rm -f "$audit" "$calls"

    [[ "$captured_args" == *"loop_worker type=prompt"* ]] || return 1
    [[ "${LOOP_TYPES[1]:-}" == "prompt" ]]
}
assert_ok "control-pane: /loop with bare prompt uses loop_type=prompt" _test_start_loop_routes_plain_prompt

# Restore real implementations so later tests are unaffected
unset -f control_agent_exists control_start_queue control_loop_worker 2>/dev/null
source "$SCRIPT_DIR/lib/control-pane.sh" "" "" "standard"
rm -f "$_LOOP_ROUTE_AUDIT"

###############################################################################
#                          SUMMARY                                            #
###############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if (( FAIL == 0 )); then
    echo "${_green}All $PASS tests passed${_reset} ($TOTAL total, $SKIP skipped)"
else
    echo "${_red}Failed tests:${_reset}"
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure"
    done
    echo ""
    echo "${_red}$FAIL failed${_reset}, $PASS passed ($TOTAL total, $SKIP skipped)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAIL
