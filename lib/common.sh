#!/usr/bin/env bash
# common.sh — Shared utilities for claude-yolo

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
    _RED='\033[0;31m'
    _YELLOW='\033[0;33m'
    _BLUE='\033[0;34m'
    _RESET='\033[0m'
else
    _RED='' _YELLOW='' _BLUE='' _RESET=''
fi

log_info() {
    printf "${_BLUE}[%s INFO]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_warn() {
    printf "${_YELLOW}[%s WARN]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

log_error() {
    printf "${_RED}[%s ERROR]${_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

# Verify a command both exists and actually runs (catches broken installs where
# a shim is on PATH but the underlying package is missing or corrupt).
claude_yolo_command_works() {
    local cmd="$1"
    shift

    hash -r 2>/dev/null || true
    command -v "$cmd" &>/dev/null || return 1
    "$cmd" "$@" &>/dev/null
}

claude_yolo_claude_cli_works() {
    claude_yolo_command_works claude --version
}

check_prereqs() {
    local missing=0
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is not installed"
        missing=1
    fi
    if ! command -v claude &>/dev/null; then
        log_error "claude (Claude Code CLI) is not installed"
        missing=1
    elif ! claude_yolo_claude_cli_works; then
        log_error "claude (Claude Code CLI) is installed but cannot run; 'claude --version' failed. Re-install Claude Code (npm i -g @anthropic-ai/claude-code) or check your Node.js install."
        missing=1
    fi
    return $missing
}

# ── best-model auto-selection ────────────────────────────────────────────────
# When no -m/--model is given, the launcher picks the most capable model the
# account can actually use: candidates are probed in order with a minimal
# one-shot print-mode call, and the winner is cached so later launches skip
# the probe. Claude Code's own `--fallback-model` can't do this for us — it
# only works with --print, and yolo agents run interactive sessions.
CLAUDE_YOLO_MODEL_CANDIDATES="${CLAUDE_YOLO_MODEL_CANDIDATES:-claude-fable-5 opus sonnet}"
CLAUDE_YOLO_MODEL_CACHE_TTL="${CLAUDE_YOLO_MODEL_CACHE_TTL:-86400}"
CLAUDE_YOLO_MODEL_PROBE_TIMEOUT="${CLAUDE_YOLO_MODEL_PROBE_TIMEOUT:-60}"

model_cache_file() {
    echo "$HOME/.claude-yolo/model-cache"
}

# Probe whether the account can use a model: one tiny print-mode request.
# Exit 0 = the model answered. Kept as its own function so tests can stub it.
claude_yolo_probe_model() {
    local m="$1"
    if command -v timeout &>/dev/null; then
        timeout "$CLAUDE_YOLO_MODEL_PROBE_TIMEOUT" \
            claude -p 'Reply with one word: ok' --model "$m" </dev/null &>/dev/null
    else
        claude -p 'Reply with one word: ok' --model "$m" </dev/null &>/dev/null
    fi
}

# Print the best available model from CLAUDE_YOLO_MODEL_CANDIDATES (probed in
# order, result cached for CLAUDE_YOLO_MODEL_CACHE_TTL seconds). Prints
# nothing when no candidate works (auth/network down, or none permitted) —
# the launcher then omits --model and Claude Code uses its own default.
# Always returns 0 so `set -e` callers survive a failed resolution.
resolve_best_model() {
    local cache now
    cache="$(model_cache_file)"
    now="$(date +%s)"

    if [[ -f "$cache" ]]; then
        local cached mtime age
        cached="$(head -1 "$cache" 2>/dev/null | tr -d '[:space:]')"
        mtime="$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)"
        age=$(( now - mtime ))
        # A cached winner is only valid while it is still one of the current
        # candidates — otherwise a changed CLAUDE_YOLO_MODEL_CANDIDATES would
        # be silently ignored until the TTL expires.
        if [[ -n "$cached" ]] && (( age >= 0 && age < CLAUDE_YOLO_MODEL_CACHE_TTL )) \
           && [[ " $CLAUDE_YOLO_MODEL_CANDIDATES " == *" $cached "* ]]; then
            echo "$cached"
            return 0
        fi
    fi

    local m
    for m in $CLAUDE_YOLO_MODEL_CANDIDATES; do
        log_info "Probing model availability: $m"
        if claude_yolo_probe_model "$m"; then
            mkdir -p "$(dirname "$cache")" 2>/dev/null || true
            printf '%s\n' "$m" > "$cache" 2>/dev/null || true
            echo "$m"
            return 0
        fi
        log_warn "Model unavailable: $m — trying next candidate"
    done

    log_warn "No candidate model available ($CLAUDE_YOLO_MODEL_CANDIDATES) — using Claude Code's default model"
    return 0
}

# Return a writable directory for audit logs.
# Prefers /tmp; falls back to ~/.claude-yolo/logs (e.g. Termux where /tmp is not writable).
log_dir() {
    if touch /tmp/.claude-yolo-probe 2>/dev/null; then
        rm -f /tmp/.claude-yolo-probe
        echo "/tmp"
    else
        local d="$HOME/.claude-yolo/logs"
        mkdir -p "$d" 2>/dev/null || true
        echo "$d"
    fi
}

resolve_script_dir() {
    local src="${BASH_SOURCE[1]:-$0}"
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    echo "$dir"
}

# Check if git supports merge-tree --write-tree (requires git 2.38+)
check_git_merge_tree() {
    local version
    version="$(git version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+')" || return 1
    local major minor
    IFS='.' read -r major minor <<< "$version"
    (( major > 2 || (major == 2 && minor >= 38) ))
}

# Ensure a directory is trusted by Claude Code so the "trust this folder" prompt is skipped.
# Adds the directory to ~/.claude.json under projects with hasTrustDialogAccepted: true.
# Uses python3 if available, falls back to node, falls back to sed-based JSON editing.
ensure_trusted() {
    local dir="$1"
    local settings="$HOME/.claude.json"

    # Create settings file if it doesn't exist
    if [[ ! -f "$settings" ]]; then
        cat > "$settings" <<EOJSON
{
  "projects": {}
}
EOJSON
    fi

    # Try python3 first, then node, then sed
    if command -v python3 &>/dev/null; then
        _ensure_trusted_python "$dir" "$settings" && return 0
    fi
    if command -v node &>/dev/null; then
        _ensure_trusted_node "$dir" "$settings" && return 0
    fi
    _ensure_trusted_sed "$dir" "$settings"
}

_ensure_trusted_python() {
    local dir="$1" settings="$2"
    python3 -c "
import json
with open('$settings') as f:
    s = json.load(f)
projects = s.setdefault('projects', {})
proj = projects.setdefault('$dir', {})
if proj.get('hasTrustDialogAccepted'):
    raise SystemExit(0)
proj['hasTrustDialogAccepted'] = True
proj.setdefault('allowedTools', [])
with open('$settings', 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
" 2>/dev/null && log_info "Auto-trusted directory: $dir"
}

_ensure_trusted_node() {
    local dir="$1" settings="$2"
    node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$settings', 'utf8'));
if (!s.projects) s.projects = {};
if (!s.projects['$dir']) s.projects['$dir'] = {};
if (s.projects['$dir'].hasTrustDialogAccepted) process.exit(0);
s.projects['$dir'].hasTrustDialogAccepted = true;
if (!s.projects['$dir'].allowedTools) s.projects['$dir'].allowedTools = [];
fs.writeFileSync('$settings', JSON.stringify(s, null, 2) + '\n');
" 2>/dev/null && log_info "Auto-trusted directory: $dir"
}

_ensure_trusted_sed() {
    local dir="$1" settings="$2"
    # Check if already trusted
    if grep -q "\"$dir\"" "$settings" 2>/dev/null && \
       grep -q 'hasTrustDialogAccepted.*true' "$settings" 2>/dev/null; then
        return 0
    fi
    # Insert project entry before the closing brace of "projects"
    local entry="    \"$dir\": {\"hasTrustDialogAccepted\": true, \"allowedTools\": []}"
    if grep -q '"projects": {}' "$settings" 2>/dev/null; then
        # Empty projects object — replace it
        sed -i "s|\"projects\": {}|\"projects\": {\n$entry\n  }|" "$settings" 2>/dev/null
    elif grep -q '"projects"' "$settings" 2>/dev/null; then
        # Non-empty projects — insert before closing brace
        sed -i "/\"projects\"/,/}/{s|^\(  \)}|$entry,\n\1}|}" "$settings" 2>/dev/null
    fi
    log_info "Auto-trusted directory: $dir"
}

# Write a per-session Claude Code settings file wiring a Notification hook
# that records permission prompts as per-pane marker files. The launcher
# passes it to each agent via `claude --settings <file>`, so the user's own
# settings and unrelated Claude sessions are untouched.
#
# The hook fires when Claude Code shows a permission dialog (notification
# type permission_prompt) and writes, to <audit-log>.waiting/<pane-id> (using
# the $TMUX_PANE the hook process inherits from its pane): line 1 an epoch
# timestamp, line 2 the payload JSON (newlines stripped). The write is atomic
# (temp file + mv) so the daemon never reads a half-written marker. The
# approver daemon uses these markers to recognize dialogs rendered off-screen
# (e.g. an Edit diff taller than the pane), which the capture-based detectors
# can never see; it reads the payload's message to tell a plain tool-permission
# dialog (blind-answerable) from a plan-exit dialog (left for the user). The
# hook is double-gated: the permission_prompt matcher restricts it on current
# Claude Code, and a payload check keeps older versions (which ignore
# Notification matchers) from writing markers for unrelated notifications like
# idle_prompt.
#
# $1 = session audit log path. Prints the settings file path on success.
write_notify_hook_settings() {
    local audit_log="$1"
    local settings_file="${audit_log}.hooks.json"
    local waiting_dir="${audit_log}.waiting"

    mkdir -p "$waiting_dir" 2>/dev/null || return 1
    rm -f "$waiting_dir"/* 2>/dev/null || true

    # The marker dir is embedded single-quoted inside a POSIX sh command that
    # is itself embedded in JSON — escape for sh first, then for JSON. The
    # command is a single line (semicolons, no literal newlines) so JSON
    # encoding only has to escape backslashes and double quotes.
    local dir_sh="${waiting_dir//\'/\'\\\'\'}"
    local hook_cmd
    hook_cmd="p=\$(cat 2>/dev/null); case \"\$p\" in *permission_prompt*|*'needs your permission'*|*'approval for the plan'*) [ -n \"\${TMUX_PANE:-}\" ] || exit 0; d='${dir_sh}'; mkdir -p \"\$d\" 2>/dev/null || exit 0; t=\"\$d/.tmp.\$\$.\$TMUX_PANE\"; { date +%s; printf '%s' \"\$p\" | tr -d '\\r\\n'; echo; } > \"\$t\" 2>/dev/null && mv \"\$t\" \"\$d/\$TMUX_PANE\" 2>/dev/null ;; esac; exit 0"

    local cmd_json="${hook_cmd//\\/\\\\}"
    cmd_json="${cmd_json//\"/\\\"}"

    printf '{\n  "hooks": {\n    "Notification": [\n      {\n        "matcher": "permission_prompt",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "%s"\n          }\n        ]\n      }\n    ]\n  }\n}\n' "$cmd_json" > "$settings_file" 2>/dev/null || return 1

    # A malformed settings file would make every agent error at startup —
    # verify it parses when a JSON parser is available.
    if command -v python3 &>/dev/null; then
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$settings_file" 2>/dev/null; then
            rm -f "$settings_file" 2>/dev/null
            return 1
        fi
    elif command -v node &>/dev/null; then
        if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$settings_file" 2>/dev/null; then
            rm -f "$settings_file" 2>/dev/null
            return 1
        fi
    fi

    printf '%s\n' "$settings_file"
}

# Ensure Claude Code rings the terminal bell when a task finishes and when it
# needs your input, by configuring ~/.claude/settings.json:
#   - preferredNotifChannel: "terminal_bell" → bell on input-needed notifications
#   - a Stop hook printing \a               → bell when a response/task finishes
# Only acts when the bell was "not previously configured" — i.e. neither a
# notification channel nor a Stop hook is already set. If the user has expressed
# any such preference (a different channel, disabled notifications, or their own
# Stop hook), everything is left untouched. Uses python3, falls back to node,
# falls back to a minimal sed path that handles the native channel only.
ensure_bell() {
    local settings_dir="$HOME/.claude"
    local settings="$settings_dir/settings.json"
    # Real backslash-a here (\\a collapses to \a under double quotes); python/node
    # re-escape it to \\a when serializing, matching what the heredoc writes verbatim.
    local bell_cmd="printf '\\a' > /dev/tty 2>/dev/null || printf '\\a'"

    mkdir -p "$settings_dir" 2>/dev/null || return 0

    if [[ ! -f "$settings" ]]; then
        cat > "$settings" <<'EOJSON'
{
  "preferredNotifChannel": "terminal_bell",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "printf '\\a' > /dev/tty 2>/dev/null || printf '\\a'"
          }
        ]
      }
    ]
  }
}
EOJSON
        log_info "Configured terminal bell notifications: $settings"
        return 0
    fi

    # `|| rc=$?` keeps the non-zero exit codes (1 = unparseable, 2 = already
    # configured) from tripping `set -e` in the calling launcher.
    local rc
    if command -v python3 &>/dev/null; then
        rc=0; _ensure_bell_python "$settings" "$bell_cmd" || rc=$?
        case $rc in
            0) log_info "Configured terminal bell notifications: $settings"; return 0 ;;
            2) return 0 ;;  # already configured — leave the user's choice alone
        esac
    fi
    if command -v node &>/dev/null; then
        rc=0; _ensure_bell_node "$settings" "$bell_cmd" || rc=$?
        case $rc in
            0) log_info "Configured terminal bell notifications: $settings"; return 0 ;;
            2) return 0 ;;
        esac
    fi
    _ensure_bell_sed "$settings"
}

# Exit codes for the python/node helpers: 0 = changed and wrote, 2 = nothing to
# change, 1 = unparseable JSON (caller falls through to the next backend).
_ensure_bell_python() {
    local settings="$1" bell_cmd="$2"
    CY_SETTINGS="$settings" CY_BELL_CMD="$bell_cmd" python3 - <<'PYEOF'
import json, os
settings = os.environ["CY_SETTINGS"]
bell_cmd = os.environ["CY_BELL_CMD"]
try:
    with open(settings) as f:
        s = json.load(f)
except Exception:
    raise SystemExit(1)
if not isinstance(s, dict):
    raise SystemExit(1)
hooks = s.get("hooks") if isinstance(s.get("hooks"), dict) else {}
if ("preferredNotifChannel" in s) or hooks.get("Stop"):
    raise SystemExit(2)  # already configured — leave the user's choice alone
s["preferredNotifChannel"] = "terminal_bell"
hooks["Stop"] = [{"hooks": [{"type": "command", "command": bell_cmd}]}]
s["hooks"] = hooks
with open(settings, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PYEOF
}

_ensure_bell_node() {
    local settings="$1" bell_cmd="$2"
    CY_SETTINGS="$settings" CY_BELL_CMD="$bell_cmd" node -e '
const fs = require("fs");
const settings = process.env.CY_SETTINGS;
const bellCmd = process.env.CY_BELL_CMD;
let s;
try { s = JSON.parse(fs.readFileSync(settings, "utf8")); } catch (e) { process.exit(1); }
if (typeof s !== "object" || s === null || Array.isArray(s)) process.exit(1);
let hooks = (typeof s.hooks === "object" && s.hooks !== null && !Array.isArray(s.hooks)) ? s.hooks : {};
if (("preferredNotifChannel" in s) || (hooks.Stop && hooks.Stop.length > 0)) process.exit(2);
s.preferredNotifChannel = "terminal_bell";
hooks.Stop = [{ hooks: [{ type: "command", command: bellCmd }] }];
s.hooks = hooks;
fs.writeFileSync(settings, JSON.stringify(s, null, 2) + "\n");
'
}

# Fallback with neither python3 nor node available. Editing a nested hooks array
# with sed is too fragile, so the fallback only sets the native channel (which
# alone rings on both events). Respects an existing channel choice.
_ensure_bell_sed() {
    local settings="$1"
    # Already configured? (a channel choice, or any existing Stop hook)
    grep -q '"preferredNotifChannel"' "$settings" 2>/dev/null && return 0
    grep -q '"Stop"' "$settings" 2>/dev/null && return 0
    local compact
    compact="$(tr -d '[:space:]' < "$settings" 2>/dev/null || true)"
    if [[ "$compact" == "{}" ]]; then
        printf '{\n  "preferredNotifChannel": "terminal_bell"\n}\n' > "$settings"
        log_info "Configured terminal bell notifications: $settings"
    elif [[ "$compact" == "{"* ]]; then
        # Insert as the first key after the opening brace (trailing comma is safe
        # because a non-empty object guarantees at least one following key).
        sed -i '0,/{/s//{\n  "preferredNotifChannel": "terminal_bell",/' "$settings" 2>/dev/null \
            && log_info "Configured terminal bell notifications: $settings"
    fi
}
