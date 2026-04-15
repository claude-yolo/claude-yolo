#!/usr/bin/env bash
# merge-resolver.sh — Wait for agents, then merge worktree branches with auto conflict resolution
#
# Runs inside a tmux "merge" window. Waits for all agent done-markers,
# sequentially merges each worktree branch into the base branch, and
# spawns a Claude agent to resolve any conflicts.
#
# Usage: merge-resolver.sh <session-name> <audit-log> [--no-cleanup] [--model MODEL]

set -u

_MR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MR_LIB_DIR/common.sh"
source "$_MR_LIB_DIR/worktree-manager.sh"

SESSION_NAME="${1:?Usage: merge-resolver.sh <session-name> <audit-log> [options...]}"
AUDIT_LOG="${2:-$(log_dir)/claude-yolo-${SESSION_NAME}.log}"
shift 2

NO_CLEANUP=0
MODEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cleanup)  NO_CLEANUP=1; shift ;;
        --model)       MODEL="$2"; shift 2 ;;
        *)             shift ;;
    esac
done

REPO_DIR="$(wt_read_repo_dir "$SESSION_NAME")"
BASE_BRANCH="$(wt_read_base_branch "$SESSION_NAME")"

audit_merge() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MERGE $msg" >> "$AUDIT_LOG" 2>/dev/null
    echo "  $msg"
}

# ── wait for agents ──────────────────────────────────────────────────────────

# Detect if an agent pane is idle (Claude finished work, showing ❯ prompt).
# Returns 0 if idle, 1 otherwise.
# When idle, the pane shows a short line with ❯ (no typed text after it).
# The ❯ line uses a non-breaking space (\xc2\xa0) so we match by line
# length (<10 chars) rather than exact whitespace.
#
# IMPORTANT: Claude Code always shows the ❯ input prompt at the bottom of its
# TUI, even while the model is actively thinking. To avoid false positives, we
# also check for processing indicators — the thinking spinner shows patterns
# like "· Hullaballooing…" or "* Actioning…" while the model is working.
agent_is_idle() {
    local pane="$1"
    local content
    content="$(tmux capture-pane -t "$pane" -p 2>/dev/null)" || return 1

    # Veto: Claude Code thinking/processing spinner is visible.
    # During model processing the TUI shows lines like:
    #   · Hullaballooing…   * Actioning…   ✶ Envisioning… (23s · ↑ 327 tokens)
    # The spinner character varies (·, *, ✶, etc.) so we match the general
    # shape: 1-4 non-space chars, a space, a capitalized word, then …
    if echo "$content" | grep -qE '^\S{1,4} [A-Z][a-z]+.{0,5}…'; then
        return 1
    fi

    local tail20
    tail20="$(echo "$content" | tail -20)"

    # Veto: a permission prompt is visible (Allow/Deny or Yes/No).
    # The agent is waiting for tool approval — the approver daemon will handle it.
    if echo "$tail20" | grep -qi 'Allow' && echo "$tail20" | grep -qi 'Deny'; then
        return 1
    fi
    if echo "$tail20" | grep -qE '[0-9]+\.\s*Yes' && echo "$tail20" | grep -qE '[0-9]+\.\s*No'; then
        return 1
    fi

    local tail10
    tail10="$(echo "$content" | tail -10)"
    echo "$tail10" | awk '/❯/ && length < 10 { found=1 } END { exit !found }'
}

wait_for_agents() {
    local count="$1"
    local start_time
    start_time="$(date +%s)"

    # Grace period: don't check idle state until agents have had time to start
    # processing. Claude Code shows the ❯ prompt immediately on startup
    # (before the model responds), so checking too early causes false positives.
    local STARTUP_GRACE=15

    echo "Waiting for $count agent(s) to finish..."
    echo ""

    # Track which agents we've already sent /exit to
    local -A exit_sent=()

    while true; do
        local done_count=0
        local now
        now="$(date +%s)"

        for (( i=1; i<=count; i++ )); do
            # Already done (marker exists)
            if [[ -f "$(wt_done_marker "$SESSION_NAME" "$i")" ]]; then
                done_count=$((done_count + 1))
                continue
            fi

            # Skip idle detection during startup grace period
            if (( now - start_time < STARTUP_GRACE )); then
                continue
            fi

            # Detect idle agent and send /exit (once per agent)
            if [[ -z "${exit_sent[$i]:-}" ]] && agent_is_idle "$SESSION_NAME:agent-$i"; then
                tmux send-keys -t "$SESSION_NAME:agent-$i" "/exit" C-m 2>/dev/null || true
                exit_sent[$i]=1
                audit_merge "Agent $i finished, sent /exit"
            fi
        done

        if (( done_count >= count )); then
            echo ""
            echo "All $count agent(s) finished."
            return 0
        fi

        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "Session gone, aborting."
            return 1
        fi

        printf "\r  %d/%d agents done..." "$done_count" "$count"
        sleep 2
    done
}

# ── merge one branch ─────────────────────────────────────────────────────────

merge_branch() {
    local branch="$1"

    audit_merge "Merging $branch into $BASE_BRANCH"

    local merge_output
    if merge_output="$(git -C "$REPO_DIR" merge --no-edit "$branch" 2>&1)"; then
        audit_merge "OK $branch merged cleanly"
        return 0
    fi

    echo "$merge_output"
    audit_merge "CONFLICTS in $branch — spawning resolver agent"
    return 1
}

# ── resolve conflicts via Claude ─────────────────────────────────────────────

resolve_conflicts() {
    local branch="$1"

    local conflicted
    conflicted="$(git -C "$REPO_DIR" diff --name-only --diff-filter=U 2>/dev/null)"

    if [[ -z "$conflicted" ]]; then
        audit_merge "No conflicted files found (merge may have failed for another reason)"
        return 1
    fi

    local branch_log
    branch_log="$(git -C "$REPO_DIR" log --oneline "${BASE_BRANCH}..${branch}" -- 2>/dev/null)" || true

    local prompt
    prompt="You are resolving git merge conflicts in this repository.

The merge of branch '${branch}' into '${BASE_BRANCH}' produced conflicts.

Conflicted files:
${conflicted}

Commits from ${branch}:
${branch_log:-  (no commits)}

Instructions:
1. Read each conflicted file listed above
2. Resolve every conflict marker (<<<<<<< ======= >>>>>>>) by preserving both sets of changes where possible
3. After resolving ALL conflicts, stage and commit:  git add -A && git commit --no-edit

Do NOT modify files that are not in the conflicted list above."

    audit_merge "Resolver agent for: $(echo "$conflicted" | tr '\n' ' ')"

    # Write prompt to temp file — avoids quoting issues with tmux send-keys
    local tmpfile="/tmp/claude-yolo-resolve-${SESSION_NAME}-${RANDOM}.txt"
    printf '%s' "$prompt" > "$tmpfile"

    # Run Claude in a new tmux window so the approver daemon handles permissions.
    # The resolver waits for the done-marker to appear.
    local resolve_win="resolve"
    local resolve_done="/tmp/claude-yolo-resolve-done-${SESSION_NAME}-${RANDOM}"

    tmux new-window -t "$SESSION_NAME" -n "$resolve_win" -c "$REPO_DIR" 2>/dev/null || true

    local cmd="cat '$tmpfile' | claude"
    [[ -n "$MODEL" ]] && cmd="cat '$tmpfile' | claude --model $MODEL"
    cmd="$cmd ; touch '$resolve_done'"

    tmux send-keys -t "$SESSION_NAME:$resolve_win" "$cmd" C-m

    # Wait for resolver to finish — detect idle prompt and send /exit.
    # Grace period: the resolver needs time to start processing before we
    # check idle state (same TUI false-positive issue as agent_is_idle).
    local resolve_exited=0
    local resolve_start
    resolve_start="$(date +%s)"
    local RESOLVE_GRACE=45

    while [[ ! -f "$resolve_done" ]]; do
        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            rm -f "$tmpfile"
            return 1
        fi
        local now
        now="$(date +%s)"
        if (( ! resolve_exited )) && (( now - resolve_start >= RESOLVE_GRACE )) && \
           agent_is_idle "$SESSION_NAME:$resolve_win"; then
            tmux send-keys -t "$SESSION_NAME:$resolve_win" "/exit" C-m 2>/dev/null || true
            resolve_exited=1
            audit_merge "Resolver finished, sent /exit"
        fi
        sleep 2
    done

    tmux kill-window -t "$SESSION_NAME:$resolve_win" 2>/dev/null || true
    rm -f "$tmpfile" "$resolve_done"

    # Auto-commit in case the resolver edited files but the commit failed or was skipped
    if [[ -n "$(git -C "$REPO_DIR" diff --name-only 2>/dev/null)" ]]; then
        audit_merge "Resolver left uncommitted changes — auto-committing"
        git -C "$REPO_DIR" add -A 2>/dev/null
        git -C "$REPO_DIR" commit --no-edit 2>/dev/null || true
    fi

    # Check if conflicts are resolved — both git-level and leftover markers
    local remaining
    remaining="$(git -C "$REPO_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
    if [[ -n "$remaining" ]]; then
        audit_merge "FAILED Unresolved conflicts remain: $(echo "$remaining" | tr '\n' ' ')"
        return 1
    fi

    # Also check for leftover conflict markers in tracked files.
    # After auto-commit, git considers the merge resolved even if markers remain.
    local marker_files
    marker_files="$(git -C "$REPO_DIR" grep -l '^<<<<<<<\|^=======$\|^>>>>>>>' HEAD -- 2>/dev/null | head -20)" || true
    if [[ -n "$marker_files" ]]; then
        audit_merge "WARN Conflict markers still present in: $(echo "$marker_files" | tr '\n' ' ')"
        audit_merge "FAILED Resolution incomplete for $branch — conflict markers remain"
        return 1
    fi

    audit_merge "OK Conflicts resolved for $branch"
    return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "  claude-yolo merge resolver"
    echo "  Session:     $SESSION_NAME"
    echo "  Base branch: $BASE_BRANCH"
    echo "  Repo:        $REPO_DIR"
    echo ""

    local count
    count="$(wt_list "$SESSION_NAME" | wc -l)"

    if ! wait_for_agents "$count"; then
        return 1
    fi

    # Auto-commit any uncommitted changes in each worktree.
    # Agents often edit files but don't commit — we commit on their behalf.
    echo ""
    echo "Committing agent changes..."
    echo ""

    while IFS=' ' read -r branch wt_path; do
        [[ -z "$branch" ]] && continue
        local status
        status="$(git -C "$wt_path" status --porcelain 2>/dev/null)" || continue
        if [[ -n "$status" ]]; then
            git -C "$wt_path" add -A 2>/dev/null
            git -C "$wt_path" commit -m "agent: work from $branch" 2>/dev/null || true
            audit_merge "Auto-committed changes in $branch"
        else
            audit_merge "No uncommitted changes in $branch"
        fi
    done < <(wt_list "$SESSION_NAME")

    echo ""
    echo "Starting sequential merge..."
    echo ""

    # Switch to base branch
    git -C "$REPO_DIR" checkout "$BASE_BRANCH" 2>&1

    local total=0 merged=0 failed=0

    while IFS=' ' read -r branch _path; do
        [[ -z "$branch" ]] && continue
        total=$((total + 1))
        echo "--- [$total] $branch ---"

        if merge_branch "$branch"; then
            merged=$((merged + 1))
        elif resolve_conflicts "$branch"; then
            merged=$((merged + 1))
        else
            failed=$((failed + 1))
            audit_merge "FAILED Could not resolve $branch — aborting merge"
            git -C "$REPO_DIR" merge --abort 2>/dev/null || true
            echo ""
            echo "Merge aborted for $branch. Remaining branches skipped."
            echo "Resolve manually:  cd $REPO_DIR && git merge $branch"
            break
        fi
        echo ""
    done < <(wt_list "$SESSION_NAME")

    echo "========================================"
    echo "  Results: $merged/$total merged, $failed failed"
    echo "========================================"
    audit_merge "Complete: $merged/$total merged, $failed failed"

    if (( NO_CLEANUP )); then
        echo ""
        echo "Worktrees preserved (--no-cleanup)."
        echo "Clean up manually:"
        echo "  source $_MR_LIB_DIR/worktree-manager.sh && wt_cleanup '$SESSION_NAME'"
    else
        echo ""
        echo "Cleaning up worktrees..."
        wt_cleanup "$SESSION_NAME"
    fi
}

main
