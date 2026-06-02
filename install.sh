#!/usr/bin/env bash
# install.sh — Install claude-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash && export PATH="${CLAUDE_YOLO_BIN_DIR:-$HOME/.local/bin}:${CLAUDE_YOLO_HOME:-$HOME/.claude-yolo}/bin:$PATH"
#        ./install.sh --local   # install from the current local repo
set -euo pipefail

LOCAL_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL_INSTALL=1 ;;
        *) ;;
    esac
done

REPO="https://github.com/claude-yolo/claude-yolo.git"
INSTALL_DIR="${CLAUDE_YOLO_HOME:-$HOME/.claude-yolo}"
DEFAULT_BIN_DIR="$HOME/.local/bin"
REQUESTED_BIN_DIR="${CLAUDE_YOLO_BIN_DIR:-$DEFAULT_BIN_DIR}"
BIN_DIR="$REQUESTED_BIN_DIR"
NPM_PREFIX="${CLAUDE_YOLO_NPM_PREFIX:-$HOME/.local}"
NPM_BIN_DIR="$NPM_PREFIX/bin"
ORIGINAL_PATH="${PATH:-}"

# Make user-prefix npm installs visible during this script, not just after it.
export PATH="$BIN_DIR:$NPM_BIN_DIR:$ORIGINAL_PATH"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}WARNING:${RESET} %s\n" "$*"; }
error() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

# Detect Termux (Android) — no sudo, uses pkg
IS_TERMUX=0
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
    IS_TERMUX=1
fi

# Use sudo only if it is actually usable. Some locked-down systems have sudo
# installed even though the current user is not allowed to run it.
SUDO=""
CAN_INSTALL_SYSTEM_PACKAGES=0
if [[ "$IS_TERMUX" -eq 1 ]]; then
    :
elif [[ "$(id -u)" -eq 0 ]]; then
    CAN_INSTALL_SYSTEM_PACKAGES=1
elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    SUDO="sudo"
    CAN_INSTALL_SYSTEM_PACKAGES=1
else
    warn "sudo is not available or not allowed — using user-space installs only"
fi

require_system_pkg_install() {
    local pkg="$1"
    if [[ "$CAN_INSTALL_SYSTEM_PACKAGES" -ne 1 ]]; then
        error "$pkg is required, but this user cannot install system packages without sudo. Install $pkg manually and re-run."
    fi
}

run_as_root() {
    if [[ -n "$SUDO" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

run_noninteractive_as_root() {
    if [[ -n "$SUDO" ]]; then
        sudo env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC "$@"
    else
        DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC "$@"
    fi
}

run_apt_get() {
    run_noninteractive_as_root apt-get "$@"
}

choose_bin_dir() {
    local requested="$1"
    local fallback="$INSTALL_DIR/bin"

    if mkdir -p "$requested" 2>/dev/null && [[ -w "$requested" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi

    if [[ -n "${CLAUDE_YOLO_BIN_DIR:-}" ]]; then
        error "Cannot create or write CLAUDE_YOLO_BIN_DIR=$requested. Set CLAUDE_YOLO_BIN_DIR to a writable directory and re-run."
    fi

    warn "Cannot create or write $requested — falling back to $fallback" >&2
    mkdir -p "$fallback" || error "Cannot create fallback bin directory: $fallback"
    [[ -w "$fallback" ]] || error "Fallback bin directory is not writable: $fallback"
    printf '%s\n' "$fallback"
}

git_install_dir() {
    git -c "safe.directory=$INSTALL_DIR" -C "$INSTALL_DIR" "$@"
}

# Verify a command both exists and actually runs (catches broken installs where
# a shim is on PATH but the underlying package is missing or corrupt).
command_runnable() {
    local cmd="$1"
    shift

    hash -r 2>/dev/null || true
    command -v "$cmd" &>/dev/null || return 1
    "$cmd" "$@" &>/dev/null
}

node_runtime_works() { command_runnable node --version; }
npm_runtime_works()  { command_runnable npm --version; }
claude_cli_works()   { command_runnable claude --version; }

claude_cli_needs_install() {
    command -v claude &>/dev/null || return 0
    ! claude_cli_works
}

claude_cli_failure_summary() {
    local path output
    path="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
        printf '%s\n' "claude was not found on PATH"
        return 0
    fi

    if output="$(claude --version 2>&1)"; then
        printf '%s\n' "claude works: $output"
        return 0
    fi

    output="${output//$'\n'/; }"
    [[ -n "$output" ]] || output="failed with no output"
    printf '%s\n' "claude path: $path; claude --version: $output"
}

# Install a package using the appropriate package manager
# Usage: install_pkg <package_name>
install_pkg() {
    local pkg="$1"
    local os="$(uname -s)"
    if [[ "$os" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install "$pkg"
        else
            error "$pkg is required. Install Homebrew (https://brew.sh) then run: brew install $pkg"
        fi
    elif [[ "$os" == Linux* ]]; then
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            pkg install -y "$pkg"
        elif command -v apt-get &>/dev/null; then
            require_system_pkg_install "$pkg"
            run_apt_get update && run_apt_get install -y "$pkg"
        elif command -v dnf &>/dev/null; then
            require_system_pkg_install "$pkg"
            run_as_root dnf install -y "$pkg"
        elif command -v yum &>/dev/null; then
            require_system_pkg_install "$pkg"
            run_as_root yum install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            require_system_pkg_install "$pkg"
            run_as_root pacman -S --noconfirm "$pkg"
        elif command -v apk &>/dev/null; then
            require_system_pkg_install "$pkg"
            run_as_root apk add "$pkg"
        else
            error "$pkg is required but no supported package manager found. Install $pkg manually."
        fi
    else
        error "$pkg is required. Install it manually for your platform."
    fi
}

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
if ! command -v curl &>/dev/null; then
    info "curl is not installed — attempting to install"
    install_pkg curl
    command -v curl &>/dev/null || error "curl installation failed — install it manually and re-run"
    info "curl installed successfully"
fi

if ! command -v git &>/dev/null; then
    info "git is not installed — attempting to install"
    install_pkg git
    command -v git &>/dev/null || error "git installation failed — install it manually and re-run"
    info "git installed successfully"
fi

# -------------------------------------------------------------------
# Detect OS
# -------------------------------------------------------------------
OS="$(uname -s)"
IS_WSL=0
case "$OS" in
    Linux*)
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            info "Detected platform: Termux (Android)"
        elif grep -qi microsoft /proc/version 2>/dev/null; then
            info "Detected platform: WSL (Windows Subsystem for Linux)"
            IS_WSL=1
        else
            info "Detected platform: Linux"
        fi
        ;;
    Darwin*)
        info "Detected platform: macOS"
        ;;
    *)
        warn "Unrecognized platform: $OS — proceeding anyway"
        ;;
esac

# -------------------------------------------------------------------
# Install tmux if missing
# -------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
    info "tmux is not installed — attempting to install"
    install_pkg tmux
    command -v tmux &>/dev/null || error "tmux installation failed — install it manually and re-run"
    info "tmux installed successfully"
fi

# -------------------------------------------------------------------
# Install Claude Code CLI if missing
# -------------------------------------------------------------------
if claude_cli_needs_install; then
    info "Claude Code CLI is not installed (or not runnable) — installing"
    CLAUDE_INSTALLED=0
    if [[ "$IS_TERMUX" -eq 1 ]]; then
        # Termux: the official installer downloads a native binary that fails
        # under Android's linker. Install via npm instead.
        if ! command -v npm &>/dev/null; then
            info "npm is not installed — installing via pkg"
            pkg install -y nodejs
        fi
        npm install -g @anthropic-ai/claude-code && CLAUDE_INSTALLED=1
    else
        # Ensure ~/.local/bin is in PATH before running Claude's installer —
        # otherwise it prints a warning asking the user to do this manually.
        if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
            export PATH="$HOME/.local/bin:$PATH"
            if [[ -f "$HOME/.bashrc" ]] && ! grep -qF '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
                printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
                info "Added ~/.local/bin to PATH in ~/.bashrc"
            fi
        fi
        # Try the official binary installer first
        if curl -fsSL https://claude.ai/install.sh | bash; then
            CLAUDE_INSTALLED=1
            # Check common install locations directly (sourcing shell rc files is
            # unreliable inside set -euo pipefail — bashrc may reference unset vars
            # or return non-zero from internal commands).
            for p in "$HOME/.claude/local/bin/claude" "$HOME/.local/bin/claude" "/usr/local/bin/claude"; do
                if [[ -x "$p" ]]; then
                    export PATH="$(dirname "$p"):$PATH"
                    break
                fi
            done
        fi
        # Fall back to npm if the binary installer failed (e.g., unsupported arch)
        if ! claude_cli_works && [[ "$CLAUDE_INSTALLED" -eq 0 ]]; then
            warn "Binary installer failed — falling back to npm install"

            # Install Node.js 22 from NodeSource (proper Node.js, not Bun).
            # Common need on aarch64 with 64KB pages where distro Node fails.
            _install_nodesource_nodejs() {
                command -v apt-get &>/dev/null || return 1
                [[ "$CAN_INSTALL_SYSTEM_PACKAGES" -eq 1 ]] || return 1
                command -v curl &>/dev/null || return 1

                warn "Trying Node.js 22 via NodeSource"
                run_apt_get remove -y nodejs libnode-dev libnode72 2>/dev/null || true
                run_apt_get autoremove -y 2>/dev/null || true
                if curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh 2>/dev/null; then
                    run_noninteractive_as_root bash /tmp/nodesource_setup.sh 2>/dev/null
                    # Use --force-overwrite in case distro libnode-dev wasn't fully removed
                    run_apt_get install -y -o Dpkg::Options::="--force-overwrite" nodejs 2>/dev/null
                    rm -f /tmp/nodesource_setup.sh
                fi
                node_runtime_works && npm_runtime_works
            }

            _ensure_npm() {
                if node_runtime_works && npm_runtime_works; then return 0; fi
                info "Node.js/npm not runnable — attempting to install Node.js"
                if [[ "$IS_TERMUX" -eq 1 ]]; then
                    pkg install -y nodejs
                elif command -v apt-get &>/dev/null; then
                    _install_nodesource_nodejs || {
                        node_runtime_works || install_pkg nodejs
                        npm_runtime_works  || install_pkg npm
                    }
                else
                    node_runtime_works || install_pkg nodejs
                    npm_runtime_works  || install_pkg npm
                fi
                node_runtime_works && npm_runtime_works
            }

            # Install the npm package into the global prefix, retrying under
            # $NPM_PREFIX when an unprefixed global install is not permitted.
            _npm_global_install() {
                local pkg="$1"
                if npm install -g "$pkg" 2>/dev/null; then
                    hash -r 2>/dev/null || true
                    return 0
                fi
                mkdir -p "$NPM_PREFIX"
                if npm install -g --prefix "$NPM_PREFIX" "$pkg" 2>/dev/null; then
                    hash -r 2>/dev/null || true
                    return 0
                fi
                return 1
            }

            if _ensure_npm; then
                _npm_global_install @anthropic-ai/claude-code && CLAUDE_INSTALLED=1
            else
                warn "npm is not available — cannot install Claude Code CLI"
            fi
        fi
    fi
    if ! claude_cli_works; then
        ARCH="$(uname -m)"
        warn "$(claude_cli_failure_summary)"
        error "Claude Code CLI could not be installed (platform: $OS, arch: $ARCH). Install it manually: https://docs.anthropic.com/en/docs/claude-code/getting-started"
    fi
fi

# -------------------------------------------------------------------
# Install / update
# -------------------------------------------------------------------
if [[ "$LOCAL_INSTALL" -eq 1 ]]; then
    LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info "Installing from local repo: $LOCAL_SRC"
    if [[ "$LOCAL_SRC" == "$INSTALL_DIR" ]]; then
        info "Local repo is already the install directory — skipping copy"
    else
        mkdir -p "$INSTALL_DIR"
        rsync -a --exclude='.git' "$LOCAL_SRC/" "$INSTALL_DIR/" 2>/dev/null \
            || cp -a "$LOCAL_SRC"/. "$INSTALL_DIR"/
        info "Copied local repo to $INSTALL_DIR"
    fi
elif [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation in $INSTALL_DIR"
    UPDATE_OK=1
    UPDATE_OUTPUT=""
    if ! UPDATE_OUTPUT="$(git_install_dir fetch origin 2>&1)"; then
        UPDATE_OK=0
        warn "Could not fetch the latest claude-yolo update:"
        printf '%s\n' "$UPDATE_OUTPUT" >&2
    elif ! UPDATE_OUTPUT="$(git_install_dir reset --hard origin/main 2>&1)"; then
        UPDATE_OK=0
        warn "Could not reset the existing claude-yolo checkout to origin/main:"
        printf '%s\n' "$UPDATE_OUTPUT" >&2
    fi

    if [[ "$UPDATE_OK" -ne 1 ]]; then
        if [[ -f "$INSTALL_DIR/claude-yolo" ]]; then
            warn "Using existing installation in $INSTALL_DIR"
        else
            error "Existing installation is incomplete and could not be updated. Remove $INSTALL_DIR and re-run."
        fi
    fi
else
    if [[ -d "$INSTALL_DIR" ]]; then
        error "$INSTALL_DIR already exists but is not a git repo. Remove it first and re-run."
    fi
    info "Cloning claude-yolo into $INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR" || error "Failed to clone repository"
fi

chmod +x "$INSTALL_DIR/claude-yolo"

# -------------------------------------------------------------------
# Symlink into PATH
# -------------------------------------------------------------------
BIN_DIR="$(choose_bin_dir "$REQUESTED_BIN_DIR")"
export PATH="$BIN_DIR:$NPM_BIN_DIR:$ORIGINAL_PATH"

ln -sf "$INSTALL_DIR/claude-yolo" "$BIN_DIR/claude-yolo"
info "Linked claude-yolo → $BIN_DIR/claude-yolo"

# -------------------------------------------------------------------
# Ensure ~/.local/bin is in PATH
# -------------------------------------------------------------------
# Detect the running shell reliably: $SHELL may be /bin/sh in Docker
# even when the user is actually running bash.
_detect_shell() {
    local sh_name
    sh_name="$(basename "${SHELL:-}")"
    # If $SHELL says sh, check if we're actually running bash/zsh
    if [[ "$sh_name" == "sh" ]] || [[ -z "$sh_name" ]]; then
        if [[ -n "${BASH_VERSION:-}" ]]; then
            sh_name="bash"
        elif [[ -n "${ZSH_VERSION:-}" ]]; then
            sh_name="zsh"
        fi
    fi
    echo "$sh_name"
}
SHELL_NAME="$(_detect_shell)"
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.profile" ;;
esac

if ! echo "$ORIGINAL_PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    if [[ "$BIN_DIR" == "$DEFAULT_BIN_DIR" ]]; then
        EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    else
        EXPORT_LINE="export PATH=\"$BIN_DIR:\$PATH\""
    fi
    if [[ "$SHELL_NAME" == "fish" ]]; then
        if [[ "$BIN_DIR" == "$DEFAULT_BIN_DIR" ]]; then
            EXPORT_LINE='fish_add_path $HOME/.local/bin'
        else
            EXPORT_LINE="fish_add_path $BIN_DIR"
        fi
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE"
    else
        touch "$RC_FILE"
        printf '\n# Added by claude-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}claude-yolo installed successfully!${RESET}\n"
printf "\n  Activate now (if claude-yolo is not yet available):\n\n"
printf "    source %s\n\n" "$RC_FILE"
printf "  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    claude-yolo \"fix the tests\" \"update docs\"\n\n"

# Export PATH in the current process so that when this script is sourced
# or when the caller does `source <rc_file>`, the binary is immediately available.
export PATH="$BIN_DIR:$PATH"
