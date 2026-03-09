#!/usr/bin/env bash
# install.sh — Install claude-yolo from source
# Usage: source <(curl -fsSL https://<url>/install.sh)
#   or:  curl -fsSL https://<url>/install.sh | bash && source ~/.bashrc

# Wrap in a function so `source <(curl ...)` won't exit the user's shell on error
__claude_yolo_install() {
    set -euo pipefail

    local REPO="https://github.com/claude-yolo/claude-yolo.git"
    local INSTALL_DIR="${CLAUDE_YOLO_HOME:-$HOME/.claude-yolo}"
    local BIN_DIR="$HOME/.local/bin"

    # Colors (disabled if not a terminal)
    local RED GREEN YELLOW BOLD RESET
    if [[ -t 1 ]]; then
        RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BOLD='\033[1m' RESET='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BOLD='' RESET=''
    fi

    info()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
    warn()  { printf "${YELLOW}WARNING:${RESET} %s\n" "$*"; }
    error() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; return 1; }

    # Detect Termux (Android) — no sudo, uses pkg
    local IS_TERMUX=0
    if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
        IS_TERMUX=1
    fi

    # Install a package using the appropriate package manager
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
                sudo apt-get update && sudo apt-get install -y "$pkg"
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y "$pkg"
            elif command -v yum &>/dev/null; then
                sudo yum install -y "$pkg"
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm "$pkg"
            elif command -v apk &>/dev/null; then
                sudo apk add "$pkg"
            else
                error "$pkg is required but no supported package manager found. Install $pkg manually."
            fi
        else
            error "$pkg is required. Install it manually for your platform."
        fi
    }

    # ---------------------------------------------------------------
    # Pre-flight checks
    # ---------------------------------------------------------------
    if ! command -v git &>/dev/null; then
        info "git is not installed — attempting to install"
        install_pkg git
        command -v git &>/dev/null || { error "git installation failed — install it manually and re-run"; return 1; }
        info "git installed successfully"
    fi

    # ---------------------------------------------------------------
    # Detect OS
    # ---------------------------------------------------------------
    local OS IS_WSL=0
    OS="$(uname -s)"
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

    # ---------------------------------------------------------------
    # Install tmux if missing
    # ---------------------------------------------------------------
    if ! command -v tmux &>/dev/null; then
        info "tmux is not installed — attempting to install"
        install_pkg tmux
        command -v tmux &>/dev/null || { error "tmux installation failed — install it manually and re-run"; return 1; }
        info "tmux installed successfully"
    fi

    # ---------------------------------------------------------------
    # Install Claude Code CLI if missing
    # ---------------------------------------------------------------
    if ! command -v claude &>/dev/null; then
        info "Claude Code CLI is not installed — installing"
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            # Termux: the official installer downloads a native binary that fails
            # under Android's linker. Install via npm instead.
            if ! command -v npm &>/dev/null; then
                info "npm is not installed — installing via pkg"
                pkg install -y nodejs
            fi
            npm install -g @anthropic-ai/claude-code
        else
            curl -fsSL https://claude.ai/install.sh | bash
            # Source shell config to pick up newly installed binary
            local SHELL_NAME
            SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
            case "$SHELL_NAME" in
                zsh)  [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc" 2>/dev/null || true ;;
                bash) [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" 2>/dev/null || true ;;
                *)    [[ -f "$HOME/.profile" ]] && source "$HOME/.profile" 2>/dev/null || true ;;
            esac
            # Also check common install locations directly
            local p
            for p in "$HOME/.claude/local/bin/claude" "$HOME/.local/bin/claude" "/usr/local/bin/claude"; do
                if [[ -x "$p" ]]; then
                    export PATH="$(dirname "$p"):$PATH"
                    break
                fi
            done
        fi
        command -v claude &>/dev/null || warn "Claude Code CLI installed but not found in PATH — you may need to restart your shell"
    fi

    # ---------------------------------------------------------------
    # Install / update
    # ---------------------------------------------------------------
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Updating existing installation in $INSTALL_DIR"
        git -C "$INSTALL_DIR" checkout . 2>/dev/null
        git -C "$INSTALL_DIR" pull --ff-only || { error "Failed to update. Resolve manually in $INSTALL_DIR"; return 1; }
    else
        if [[ -d "$INSTALL_DIR" ]]; then
            error "$INSTALL_DIR already exists but is not a git repo. Remove it first and re-run."
            return 1
        fi
        info "Cloning claude-yolo into $INSTALL_DIR"
        git clone "$REPO" "$INSTALL_DIR" || { error "Failed to clone repository"; return 1; }
    fi

    chmod +x "$INSTALL_DIR/claude-yolo"

    # ---------------------------------------------------------------
    # Symlink into PATH
    # ---------------------------------------------------------------
    mkdir -p "$BIN_DIR"

    ln -sf "$INSTALL_DIR/claude-yolo" "$BIN_DIR/claude-yolo"
    info "Linked claude-yolo → $BIN_DIR/claude-yolo"

    # ---------------------------------------------------------------
    # Ensure ~/.local/bin is in PATH
    # ---------------------------------------------------------------
    local SHELL_NAME RC_FILE
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        bash) RC_FILE="$HOME/.bashrc" ;;
        fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
        *)    RC_FILE="$HOME/.profile" ;;
    esac

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        warn "$BIN_DIR is not in your PATH"

        local EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
        if [[ "$SHELL_NAME" == "fish" ]]; then
            EXPORT_LINE='fish_add_path $HOME/.local/bin'
        fi

        if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
            info "PATH entry already exists in $RC_FILE"
        else
            printf '\n# Added by claude-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
            info "Added $BIN_DIR to PATH in $RC_FILE"
        fi

        # Apply PATH now so claude-yolo is available immediately
        export PATH="$BIN_DIR:$PATH"
        info "PATH updated for current session"
    fi

    # ---------------------------------------------------------------
    # Done
    # ---------------------------------------------------------------
    printf "\n${BOLD}${GREEN}claude-yolo installed successfully!${RESET}\n"
    printf "\n  Usage:\n"
    printf "    cd /path/to/your/project\n"
    printf "    claude-yolo \"fix the tests\" \"update docs\"\n\n"
}

# Run the installer, then clean up the function
__claude_yolo_install
__claude_yolo_install_ret=$?
unset -f __claude_yolo_install
return $__claude_yolo_install_ret 2>/dev/null || exit $__claude_yolo_install_ret
