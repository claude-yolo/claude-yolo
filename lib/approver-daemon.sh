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

# Log daemon exit for debugging (catches crashes, signals, etc.)
trap '_exit_code=$?; echo "[$(date "+%Y-%m-%d %H:%M:%S")] Daemon exited (code=$_exit_code, session=$SESSION_NAME)" >> "$AUDIT_LOG" 2>/dev/null; log_warn "Approver daemon exiting (code=$_exit_code)" 2>/dev/null' EXIT

audit() {
    local pane="$1" pattern="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] APPROVED pane=$pane pattern=\"$pattern\"" >> "$AUDIT_LOG" 2>/dev/null || true
    log_info "Auto-approved: pane=$pane pattern=\"$pattern\"" 2>/dev/null || true
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
detect_prompt() {
    local content="$1"

    local tail_content
    tail_content="$(echo "$content" | tail -n 20)"

    local has_yes=0 has_no=0 has_tool=0 has_context=0

    # Primary signal — Style A: Allow/Deny buttons
    if echo "$tail_content" | grep -qi 'Allow'; then
        if echo "$tail_content" | grep -qi 'Deny'; then
            has_yes=1; has_no=1
        fi
    fi

    # Primary signal — Style B: numbered Yes/No menu
    #   "❯ 1. Yes" / "2. No" — require the digit+dot prefix to avoid
    #   matching random "Yes"/"No" in code output.
    if echo "$tail_content" | grep -qE '[0-9]+\.\s*Yes'; then
        if echo "$tail_content" | grep -qE '[0-9]+\.\s*No'; then
            has_yes=1; has_no=1
        fi
    fi

    # Secondary signal 1: Tool-related keywords near the prompt
    if echo "$tail_content" | grep -qiE '(Bash|WebFetch|Read|Write|Edit|execute|run)'; then
        has_tool=1
    fi

    # Secondary signal 2: Contextual phrases
    if echo "$tail_content" | grep -qiE '(want to proceed|wants to execute|wants to run|permission|allow once|allow always|trust this folder|trust this project|safety check)'; then
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

            # Detect permission prompt (expanded view)
            if pattern="$(detect_prompt "$content")"; then
                # Send Enter to confirm the pre-selected option
                # (Style A: "Allow" is focused, Style B: "❯ 1. Yes" is focused)
                tmux send-keys -t "$pane" Enter 2>/dev/null || continue
                LAST_APPROVED["$pane"]="$(date +%s)"
                audit "$pane" "$pattern"
            elif pattern="$(detect_collapsed "$content")"; then
                # Collapsed transcript — prompt is hidden. Send ctrl+o to expand,
                # then the next poll cycle will detect and approve the prompt.
                tmux send-keys -t "$pane" C-o 2>/dev/null || continue
                audit "$pane" "$pattern"
                # Don't set cooldown — we need the next cycle to approve
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

main_loop
