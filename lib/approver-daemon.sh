#!/usr/bin/env bash
# approver-daemon.sh — Background monitor that auto-approves Claude Code permission prompts
#
# Usage: approver-daemon.sh <session-name> [poll-interval]
# Reads pane list from stdin or discovers all panes in the given tmux session.

set -u  # Catch unset variables, but NO set -e (daemon must survive transient errors)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SESSION_NAME="${1:?Usage: approver-daemon.sh <session-name> [poll-interval] [audit-log]}"
POLL_INTERVAL="${2:-0.3}"
AUDIT_LOG="${3:-$(log_dir)/claude-yolo-${SESSION_NAME}.log}"
COOLDOWN_SECS=2
PLAN_APPROVAL_TTL="${CLAUDE_YOLO_PLAN_APPROVAL_TTL:-3600}"
SLASH_APPROVAL_TTL="${CLAUDE_YOLO_SLASH_APPROVAL_TTL:-60}"

# Associative array tracking last-approval timestamp per pane
declare -A LAST_APPROVED

# Static-pane send cap: if a pane's content is byte-identical across repeated
# key sends, the "prompt" is not reacting — almost certainly a false positive
# (a menu merely displayed on an idle pane). Stop after SEND_STREAK_CAP sends
# instead of typing into it every cooldown forever. Any content change resets
# the streak, so real prompts (which disappear or redraw once answered) are
# unaffected.
declare -A LAST_SENT_HASH
declare -A SEND_STREAK
SEND_STREAK_CAP="${CLAUDE_YOLO_SEND_STREAK_CAP:-5}"

# Log daemon exit for debugging (catches crashes, signals, etc.)
trap '_exit_code=$?; echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon exited (code=$_exit_code, session=$SESSION_NAME)" >> "$AUDIT_LOG" 2>/dev/null; log_warn "Approver daemon exiting (code=$_exit_code)" 2>/dev/null' EXIT

audit() {
    local pane="$1" pattern="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] APPROVED pane=$pane pattern=\"$pattern\"" >> "$AUDIT_LOG" 2>/dev/null || true
    log_info "Auto-approved: pane=$pane pattern=\"$pattern\"" 2>/dev/null || true
}

# Returns 0 (skip) when this exact pane content has already been keyed
# SEND_STREAK_CAP times without changing. Callers must treat a non-zero
# return as "go ahead and send" so a missing function (old test extractions)
# fails open to the pre-cap behavior.
send_should_skip() {
    local pane="$1" content_hash="$2"
    [[ -n "$content_hash" ]] || return 1
    [[ "${LAST_SENT_HASH[$pane]:-}" == "$content_hash" ]] || return 1
    (( ${SEND_STREAK[$pane]:-0} >= SEND_STREAK_CAP ))
}

# Record that a key was sent for this pane content, growing the streak when
# the content is unchanged and resetting it otherwise.
note_key_sent() {
    local pane="$1" content_hash="$2"
    [[ -n "$content_hash" ]] || return 0
    if [[ "${LAST_SENT_HASH[$pane]:-}" == "$content_hash" ]]; then
        SEND_STREAK["$pane"]="$(( ${SEND_STREAK[$pane]:-0} + 1 ))"
    else
        LAST_SENT_HASH["$pane"]="$content_hash"
        SEND_STREAK["$pane"]=1
    fi
}

# Check if a pane is in cooldown
in_cooldown() {
    local pane="$1"
    local last="${LAST_APPROVED[$pane]:-0}"
    local now
    now="$(date +%s)"
    (( now - last < COOLDOWN_SECS ))
}

# Detect permission prompt in captured pane content.
# Requires multiple signals to avoid false positives.
#
# Claude Code prompt styles:
#   Style A (buttons):  "Allow  Deny" or "Allow once  Deny"
#   Style B (numbered): "❯ 1. Yes  2. No" with "Do you want to proceed?"
#   Style C (collapsed): "● Bash(...)" with "Showing detailed transcript"
#     — the prompt is hidden behind the collapsed view; needs ctrl+o to expand
#
# Styles A and B require a secondary signal (tool keyword or context phrase).
# Style C (collapsed) is detected separately — it means a tool call is pending
# but the prompt is not visible, so we send ctrl+o to expand it first.
#
# Style B menus can grow far taller than the 20-line tail window: a
# "2. Yes, and don't ask again for: <command>" option echoes the full command,
# pushing "❯ 1. Yes" (and the "Do you want to proceed?" header) well above the
# bottom of the pane. So Style B option lines — and the secondary signals when
# such a menu is found — are matched against the whole visible capture, but
# anchored to the start of the line (after an optional │ box border and ❯/›/>
# selection marker) so quoted strings in code output ("1. Yes": ...) don't count.
detect_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 20)"

    local has_yes=0 has_no=0 has_tool=0 has_context=0
    # Window the secondary signals are matched against. Stays the tail window
    # for Style A; widens to the whole visible capture for Style B menus.
    local signal_window="$tail_content"

    # Primary signal — Style A: Allow/Deny buttons
    if echo "$tail_content" | grep -qi 'Allow'; then
        if echo "$tail_content" | grep -qi 'Deny'; then
            has_yes=1; has_no=1
        fi
    fi

    # Primary signal — Style B: numbered Yes/No menu option lines
    #   "❯ 1. Yes" / "2. No" — require the line-anchored digit+dot prefix and
    #   a word boundary (so "1. Yesterday"/"2. Nothing" prose lists don't
    #   count) to avoid matching random "Yes"/"No" in output. The Yes option
    #   may sit anywhere on screen, but the No option (the menu's last item)
    #   must be near the pane bottom: a live dialog always renders its tail
    #   just above the footer/status area, so this keeps menus that are
    #   merely *displayed* higher up (cat/diff of test fixtures, quoted menus
    #   in prose) from firing.
    local yes_option_re='^[[:space:]]*(│[[:space:]]*)?((❯|›|>)[[:space:]]*)?[0-9]+[.)][[:space:]]*Yes\b'
    local no_option_re='^[[:space:]]*(│[[:space:]]*)?((❯|›|>)[[:space:]]*)?[0-9]+[.)][[:space:]]*No\b'
    if (( ! has_yes )); then
        if echo "$content" | grep -qE "$yes_option_re"; then
            if echo "$content" | tail -n 25 | grep -qE "$no_option_re"; then
                has_yes=1; has_no=1
                # Scope the secondary signals to the menu region — from just
                # above the first Yes option (the "Do you want to proceed?"
                # header sits 1-3 lines above it) to the pane bottom. Using
                # the whole screen would let an unrelated "run"/"read" word
                # in some other message satisfy the two-signal requirement.
                local menu_start
                menu_start="$(echo "$content" | grep -nE "$yes_option_re" | head -n 1 | cut -d: -f1)"
                if [[ "$menu_start" =~ ^[0-9]+$ ]] && (( menu_start > 4 )); then
                    signal_window="$(echo "$content" | tail -n "+$((menu_start - 4))")"
                else
                    signal_window="$content"
                fi
            fi
        fi
    fi

    # Secondary signal 1: Tool-related keywords near the prompt
    if echo "$signal_window" | grep -qiE '(Bash|WebFetch|Read|Write|Edit|execute|run)'; then
        has_tool=1
    fi

    # Secondary signal 2: Contextual phrases
    if echo "$signal_window" | grep -qiE '(want to proceed|wants to execute|wants to run|permission|allow once|allow always|trust this folder|trust this project|safety check|requires approval|requires confirmation)'; then
        has_context=1
    fi

    # Require primary signal plus at least one secondary signal
    if (( has_yes && has_no && (has_tool || has_context) )); then
        local pattern="Yes+No"
        (( has_tool )) && pattern="$pattern+tool"
        (( has_context )) && pattern="$pattern+context"
        echo "$pattern"
        return 0
    fi

    return 1
}

# Decide which key approves a permission prompt detected by detect_prompt.
# Enter activates the pre-selected option (Style A: "Allow" focused,
# Style B: "❯ 1. Yes" focused). But when the selection marker is visible on a
# non-Yes option (e.g. the selection was moved before the daemon started),
# Enter would pick the wrong option — so send the Yes option's number instead,
# which jumps the selection to Yes. If the number press only moves the
# selection without activating it, the next poll cycle sees the marker on
# "1. Yes" and finishes the approval with Enter.
prompt_approval_key() {
    local content="$1"

    # Only real ❯/› selection markers count here — a bare ">" is too common
    # in shell transcripts (PS2 continuation, markdown blockquotes) and would
    # route to the digit path, typing digits into an input box on a false
    # positive. Without a real marker we fall through to Enter, which is the
    # pre-selected-option default (and harmless on an empty input box).

    # Selection marker already on a Yes option ("Yes", "Yes, and don't ask
    # again", "Yes, I trust this folder", ...) → Enter confirms it.
    if echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(❯|›)[[:space:]]*[0-9]+[.)][[:space:]]*Yes\b'; then
        echo "Enter"
        return 0
    fi

    # Marker visible on some other numbered option → send the first Yes
    # option's number to move the selection to Yes.
    if echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(❯|›)[[:space:]]*[0-9]+[.)]'; then
        local digit
        digit="$(echo "$content" \
            | grep -E '^[[:space:]]*(│[[:space:]]*)?[0-9]+[.)][[:space:]]*Yes\b' \
            | head -n 1 | grep -oE '[0-9]+' | head -n 1)"
        if [[ -n "$digit" ]]; then
            echo "$digit"
            return 0
        fi
    fi

    # No selection marker (Style A buttons) — Enter activates the focused
    # Allow button.
    echo "Enter"
}

# Detect an AskUserQuestion dialog that offers a "(Recommended)" option.
# Claude Code renders the AskUserQuestion tool as a numbered option menu:
#
#   Which approach should we use?
#   ❯ 1. Fix the daemon in place (Recommended)
#        Patch the detection logic
#     2. Rewrite from scratch
#        Start over with a new design
#     3. Other
#        Provide your own answer
#
# Signals required:
#   - a numbered option line labelled "(Recommended)" — case-sensitive:
#     AskUserQuestion's convention is a capital R, while Claude Code's own
#     built-in pickers (/model: "Default (recommended)") use lowercase; those
#     are user-driven menus the daemon must not fight
#   - a ❯/› selection marker on a numbered option (an active menu, not prose;
#     a bare ">" is NOT accepted — markdown blockquotes and PS2 continuation
#     lines in ordinary output would satisfy it)
#   - at least two numbered option lines (a menu offers alternatives)
#   - no checkbox glyphs in the options (multiSelect questions need toggling
#     before Enter — blindly confirming would submit nothing)
#
# Questions without a recommended option are deliberately left for the user.
# Yes/No permission prompts and plan-exit prompts never carry "(Recommended)"
# labels and are handled by detect_prompt / detect_plan_prompt, which run
# first in the daemon loop.
detect_question_prompt() {
    local content="$1"

    # A numbered option labelled (Recommended)
    if ! echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*)?[0-9]+[.)].*\(Recommended\)'; then
        return 1
    fi

    # An active selection marker on a numbered option
    if ! echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?(❯|›)[[:space:]]*[0-9]+[.)]'; then
        return 1
    fi

    # At least two numbered option lines
    local option_count
    option_count="$(echo "$content" | grep -cE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*)?[0-9]+[.)][[:space:]]')" || option_count=0
    if (( option_count < 2 )); then
        return 1
    fi

    # multiSelect rendering — checkboxes need toggling, not a blind Enter
    if echo "$content" | grep -qE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*)?[0-9]+[.)][[:space:]]*(\[[ xX]\]|◻|☐|☑|◼|■)'; then
        return 1
    fi

    # Bottom anchor: a live dialog renders its options just above the
    # footer/status area, so at least one option line must be near the pane
    # bottom. Keeps question menus merely *displayed* higher up on screen
    # (cat/diff of fixtures, quoted menus in prose) from firing.
    if ! echo "$content" | tail -n 25 | grep -qE '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*)?[0-9]+[.)][[:space:]]'; then
        return 1
    fi

    echo "question+recommended"
    return 0
}

# Decide which key answers a question dialog detected by detect_question_prompt.
# Enter when the selection marker already sits on the "(Recommended)" option;
# otherwise the recommended option's number, which jumps the selection there.
# If the number press only moves the selection without activating it, the next
# poll cycle sees the marker on the recommended option and finishes with Enter.
question_approval_key() {
    local content="$1"

    if echo "$content" | grep -E '^[[:space:]]*(│[[:space:]]*)?(❯|›)[[:space:]]*[0-9]+[.)]' \
        | grep -qF '(Recommended)'; then
        echo "Enter"
        return 0
    fi

    local digit
    digit="$(echo "$content" \
        | grep -E '^[[:space:]]*(│[[:space:]]*)?((❯|›)[[:space:]]*)?[0-9]+[.)].*\(Recommended\)' \
        | head -n 1 | grep -oE '[0-9]+' | head -n 1)"
    if [[ -n "$digit" ]]; then
        echo "$digit"
        return 0
    fi

    echo "Enter"
}

# Detect the ExitPlanMode approval prompt that Claude Code shows when an agent
# finishes plan mode. Pattern looks like:
#   ⏵⏵ Would you like to proceed with this plan?
#   ❯ 1. Yes, and auto-accept edits
#     2. Yes, and manually approve edits
#     3. No, keep planning
#
# Three signals required to distinguish a plan-exit prompt from a generic
# tool-permission prompt:
#   - plan-context phrase ("proceed with this plan", "ExitPlanMode", "plan mode" etc.)
#   - approval option ("Yes, and auto-accept", "Yes, and manually approve", ...)
#   - denial/keep-planning option ("No, keep planning", ...)
detect_plan_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 35)"

    local has_plan=0 has_approval_option=0 has_context=0

    if echo "$tail_content" | grep -qiE '(proceed with (this )?plan|exit plan mode|implement (this )?plan|approve (this )?plan|plan mode|ExitPlanMode|^ *plan:)'; then
        has_plan=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(Yes,? (and )?(auto-accept|manually approve|proceed|implement|clear context and implement)|Proceed|Implement|Approve|Continue)([[:space:]]|$)'; then
        has_approval_option=1
    fi

    if echo "$tail_content" | grep -qiE '^[[:space:]]*((❯|›)[[:space:]]*)?([0-9]+[.)][[:space:]]*)?(No,?[[:space:]]*keep planning|Keep planning|No,? but|Go back|Cancel|Revise|.*do differently)'; then
        has_context=1
    fi

    if (( has_plan && has_approval_option && has_context )); then
        echo "plan"
        return 0
    fi

    return 1
}

# Marker file used by control-pane.sh to scope plan-mode auto-approval to a
# specific pane. The daemon reads "<pane_id>\t<timestamp>" and only approves
# plan-exit prompts when (a) the pane matches and (b) the timestamp is within
# PLAN_APPROVAL_TTL.
plan_approval_file() {
    if [[ -n "${CLAUDE_YOLO_PLAN_APPROVAL_FILE:-}" ]]; then
        printf '%s\n' "$CLAUDE_YOLO_PLAN_APPROVAL_FILE"
        return 0
    fi

    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.plan-approval\n' "$AUDIT_LOG"
}

slash_approval_file() {
    if [[ -n "${CLAUDE_YOLO_SLASH_APPROVAL_FILE:-}" ]]; then
        printf '%s\n' "$CLAUDE_YOLO_SLASH_APPROVAL_FILE"
        return 0
    fi

    [[ -n "${AUDIT_LOG:-}" ]] || return 1
    printf '%s.slash-approval\n' "$AUDIT_LOG"
}

clear_plan_approval_marker() {
    local marker
    marker="$(plan_approval_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

clear_slash_approval_marker() {
    local marker
    marker="$(slash_approval_file 2>/dev/null)" || return 0
    rm -f "$marker" 2>/dev/null || true
}

plan_approval_marker_valid() {
    local pane="$1"
    local marker marker_pane marker_ts now ttl

    marker="$(plan_approval_file)" || return 1
    [[ -f "$marker" ]] || return 1

    IFS=$'\t ' read -r marker_pane marker_ts _ < "$marker" || return 1
    if [[ -z "$marker_pane" || ! "$marker_ts" =~ ^[0-9]+$ ]]; then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    ttl="$PLAN_APPROVAL_TTL"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=3600
    now="$(date +%s)"
    if (( now - marker_ts > ttl )); then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    [[ "$marker_pane" == "$pane" ]]
}

slash_approval_marker_valid() {
    local pane="$1"
    local marker marker_pane marker_ts now ttl

    marker="$(slash_approval_file)" || return 1
    [[ -f "$marker" ]] || return 1

    IFS=$'\t ' read -r marker_pane marker_ts _ < "$marker" || return 1
    if [[ -z "$marker_pane" || ! "$marker_ts" =~ ^[0-9]+$ ]]; then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    ttl="$SLASH_APPROVAL_TTL"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=60
    now="$(date +%s)"
    if (( now - marker_ts > ttl )); then
        rm -f "$marker" 2>/dev/null || true
        return 1
    fi

    [[ "$marker_pane" == "$pane" ]]
}

# Detect if the slash command autocomplete picker is visible.
# When the user types "/p" (or similar), Claude Code shows an autocomplete popup
# with lines like:  /plan    Enter plan mode
# This can contribute false secondary signals (e.g. "/permissions" contains "permission").
# If 2+ such lines appear in the tail, veto any approval to avoid selecting autocomplete items.
detect_slash_picker() {
    local content="$1"
    local tail_content
    tail_content="$(echo "$content" | tail -n 15)"

    # Count lines matching slash command autocomplete format:
    #   /command-name    Description text
    # Optional ❯ selection marker before the /command.
    local count
    count="$(echo "$tail_content" | grep -cE '^\s*(❯\s*)?/[a-z][-a-z]+\s{2,}' 2>/dev/null)" || count=0

    (( count >= 2 ))
}

# Detect if the pane shows a collapsed transcript hiding a pending permission prompt.
# Pattern: "● ToolName(...)" followed by "Showing detailed transcript"
# This means a tool call is waiting for approval but the prompt is collapsed.
detect_collapsed() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 10)"

    # Must have "Showing detailed transcript" (collapsed view indicator)
    if ! echo "$tail_content" | grep -q 'Showing detailed transcript'; then
        return 1
    fi

    # Must have "● ToolName(...)" — the filled circle indicates pending approval.
    # Check the broader tail for the tool indicator line.
    local tool_area
    tool_area="$(echo "$content" | tail -n 15)"
    if echo "$tool_area" | grep -qE '● (Bash|WebFetch|Read|Write|Edit)\('; then
        local tool
        tool="$(echo "$tool_area" | grep -oE '● (Bash|WebFetch|Read|Write|Edit)\(' | head -1 | sed 's/● //;s/(//')"
        echo "collapsed+$tool"
        return 0
    fi

    return 1
}

main_loop() {
    log_info "Approver daemon started for session '$SESSION_NAME' (poll=${POLL_INTERVAL}s, cooldown=${COOLDOWN_SECS}s)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Daemon started for session=$SESSION_NAME" >> "$AUDIT_LOG"

    while true; do
        # Check if session still exists
        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            log_warn "Session '$SESSION_NAME' no longer exists, exiting daemon"
            break
        fi

        # Get all panes in the session
        local panes
        panes="$(tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_id}' 2>/dev/null)" || continue

        for pane in $panes; do
            # Skip if in cooldown
            if in_cooldown "$pane"; then
                continue
            fi

            # Capture pane content
            local content
            content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)" || continue

            # Skip empty panes
            [[ -z "$content" ]] && continue

            # Veto: slash command autocomplete picker is visible — do not send any keys
            if detect_slash_picker "$content"; then
                continue
            fi

            # Plan-exit prompts are scoped to the control pane via the marker
            # file. Without a valid marker we deliberately leave the prompt for
            # the user, so user-initiated plan mode is not silently approved.
            local pattern
            if pattern="$(detect_plan_prompt "$content")"; then
                if plan_approval_marker_valid "$pane"; then
                    tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                    clear_plan_approval_marker
                    LAST_APPROVED["$pane"]="$(date +%s)"
                    audit "$pane" "plan-control"
                fi
                continue
            fi

            # Slash-command confirmation prompts (e.g. /clear) issued from the
            # control pane via /queue are auto-approved when the slash marker
            # is set; otherwise the prompt waits for the user.
            if slash_approval_marker_valid "$pane"; then
                if pattern="$(detect_prompt "$content")"; then
                    tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                    clear_slash_approval_marker
                    LAST_APPROVED["$pane"]="$(date +%s)"
                    audit "$pane" "slash-control+$pattern"
                    continue
                fi
            fi

            # Hash the capture for the static-pane send cap: identical content
            # across repeated sends means the pane is not reacting to our keys.
            local content_hash
            content_hash="$(printf '%s' "$content" | cksum 2>/dev/null)" || content_hash=""

            # Detect permission prompt (expanded view)
            if pattern="$(detect_prompt "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                # Confirm the Yes option: Enter when it is already selected
                # (Style A: "Allow" focused, Style B: "❯ 1. Yes" focused), or
                # its number when the selection marker sits on another option.
                local approve_key
                approve_key="$(prompt_approval_key "$content" 2>/dev/null)" || approve_key=""
                [[ -n "$approve_key" ]] || approve_key="Enter"
                tmux send-keys -t "$pane" "$approve_key" 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_question_prompt "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    if (( ${SEND_STREAK[$pane]:-0} == SEND_STREAK_CAP )); then
                        audit "$pane" "suppressed-static+$pattern"
                        SEND_STREAK["$pane"]="$(( SEND_STREAK_CAP + 1 ))"
                    fi
                    continue
                fi
                # AskUserQuestion dialog — answer with the recommended option.
                local question_key
                question_key="$(question_approval_key "$content" 2>/dev/null)" || question_key=""
                [[ -n "$question_key" ]] || question_key="Enter"
                tmux send-keys -t "$pane" "$question_key" 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_collapsed "$content")"; then
                if send_should_skip "$pane" "$content_hash" 2>/dev/null; then
                    continue
                fi
                # Collapsed transcript — prompt is hidden. Send ctrl+o to expand,
                # then the next poll cycle will detect and approve the prompt.
                tmux send-keys -t "$pane" C-o 2>/dev/null || continue
                note_key_sent "$pane" "$content_hash" 2>/dev/null || true
                audit "$pane" "$pattern"
                # Don't set cooldown — we need the next cycle to approve
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

# Refuse to run two daemons for the same session: duplicates double-send keys
# (a second Enter usually lands on an empty input box, but a second digit
# types text into the agent's input). The lock is keyed on the per-session
# audit log, so daemons for different sessions never contend. Fails open when
# flock is unavailable or the lock file cannot be created.
if command -v flock >/dev/null 2>&1 && exec 9>"${AUDIT_LOG}.lock" 2>/dev/null; then
    if ! flock -n 9; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Duplicate daemon refused (lock held) for session=$SESSION_NAME" >> "$AUDIT_LOG" 2>/dev/null || true
        trap - EXIT
        exit 0
    fi
fi

main_loop
