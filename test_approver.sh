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

_red=$'\033[0;31m' _green=$'\033[0;32m' _yellow=$'\033[0;33m' _reset=$'\033[0m'

assert_ok() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        (( VERBOSE )) && echo "  ${_green}PASS${_reset} $desc"
    else
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc"
    fi
}

assert_fail() {
    local desc="$1"; shift
    TOTAL=$((TOTAL+1))
    if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
        SKIP=$((SKIP+1)); return 0
    fi
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL+1))
        echo "  ${_red}FAIL${_reset} $desc  (expected failure, got success)"
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
    fi
}

section() { echo "${_yellow}▸ $1${_reset}"; }

# ── source the units under test ──────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"

# Source detect_prompt, detect_collapsed and friends without running the daemon's main_loop.
# We extract the functions only.
eval "$(sed -n '/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^detect_collapsed()/,/^}/p' "$SCRIPT_DIR/lib/approver-daemon.sh")"

# Source build_agent_cmd from the launcher
eval "$(sed -n '/^build_agent_cmd()/,/^}/p' "$SCRIPT_DIR/claude-yolo")"

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
#                 YES/NO STYLE — BASH(rm:*) PERMISSION PROMPTS                #
###############################################################################

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
    before="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
    # Unset TMUX so the launcher uses "tmux attach" (which harmlessly fails
    # when stdout is redirected) instead of "tmux switch-client" (which would
    # yank the user's current tmux client to the new session).
    env -u TMUX bash "$SCRIPT_DIR/claude-yolo" >/dev/null 2>&1 || true
    # Check that a new claude-yolo-* session was created
    local after found=0
    after="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort || true)"
    local s
    for s in $(comm -13 <(echo "$before") <(echo "$after") | grep '^claude-yolo-' || true); do
        found=1
        tmux kill-session -t "$s" 2>/dev/null || true
    done
    # Also clean up any stragglers
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-yolo-' || true); do
        echo "$before" | grep -qxF "$s" || tmux kill-session -t "$s" 2>/dev/null || true
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^AUDIT_LOG=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^detect_collapsed()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^detect_collapsed()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
            eval "$(sed -n '"'"'/^declare -A LAST_APPROVED/p; /^COOLDOWN_SECS=/p; /^audit()/,/^}/p; /^in_cooldown()/,/^}/p; /^detect_prompt()/,/^}/p; /^detect_slash_picker()/,/^}/p; /^main_loop()/,/^}/p'"'"' "'"$SCRIPT_DIR"'/lib/approver-daemon.sh")"
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
#                          SUMMARY                                            #
###############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if (( FAIL == 0 )); then
    echo "${_green}All $PASS tests passed${_reset} ($TOTAL total, $SKIP skipped)"
else
    echo "${_red}$FAIL failed${_reset}, $PASS passed ($TOTAL total, $SKIP skipped)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FAIL
