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

check_prereqs() {
    local missing=0
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is not installed"
        missing=1
    fi
    if ! command -v claude &>/dev/null; then
        log_error "claude (Claude Code CLI) is not installed"
        missing=1
    fi
    return $missing
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
