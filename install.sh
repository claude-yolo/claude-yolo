#!/usr/bin/env bash
# install.sh — Install claude-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash
set -euo pipefail

REPO="https://github.com/claude-yolo/claude-yolo.git"
INSTALL_DIR="${CLAUDE_YOLO_HOME:-$HOME/.claude-yolo}"
BIN_DIR="$HOME/.local/bin"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}WARNING:${RESET} %s\n" "$*"; }
error() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
if ! command -v git &>/dev/null; then
    info "git is not installed — attempting to install"
    OS_PRE="$(uname -s)"
    if [[ "$OS_PRE" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install git
        else
            error "git is required. Install Homebrew (https://brew.sh) then run: brew install git"
        fi
    elif [[ "$OS_PRE" == Linux* ]]; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y git
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y git
        elif command -v yum &>/dev/null; then
            sudo yum install -y git
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm git
        elif command -v apk &>/dev/null; then
            sudo apk add git
        else
            error "git is required but no supported package manager found. Install git manually."
        fi
    else
        error "git is required. Install it manually for your platform."
    fi
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
        if grep -qi microsoft /proc/version 2>/dev/null; then
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
    if [[ "$OS" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install tmux
        else
            error "tmux is required. Install Homebrew (https://brew.sh) then run: brew install tmux"
        fi
    elif [[ "$OS" == Linux* ]]; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y tmux
        elif command -v yum &>/dev/null; then
            sudo yum install -y tmux
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm tmux
        elif command -v apk &>/dev/null; then
            sudo apk add tmux
        else
            error "tmux is required but no supported package manager found. Install tmux manually."
        fi
    else
        error "tmux is required. Install it manually for your platform."
    fi
    command -v tmux &>/dev/null || error "tmux installation failed — install it manually and re-run"
    info "tmux installed successfully"
fi

# -------------------------------------------------------------------
# Install Claude Code CLI if missing
# -------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
    info "Claude Code CLI is not installed — installing"
    curl -fsSL https://claude.ai/install.sh | bash
    # Source shell config to pick up newly installed binary
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        zsh)  [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc" 2>/dev/null || true ;;
        bash) [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" 2>/dev/null || true ;;
        *)    [[ -f "$HOME/.profile" ]] && source "$HOME/.profile" 2>/dev/null || true ;;
    esac
    # Also check common install locations directly
    for p in "$HOME/.claude/local/bin/claude" "$HOME/.local/bin/claude" "/usr/local/bin/claude"; do
        if [[ -x "$p" ]]; then
            export PATH="$(dirname "$p"):$PATH"
            break
        fi
    done
    command -v claude &>/dev/null || warn "Claude Code CLI installed but not found in PATH — you may need to restart your shell"
fi

# -------------------------------------------------------------------
# Install / update
# -------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation in $INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout . 2>/dev/null
    git -C "$INSTALL_DIR" pull --ff-only || error "Failed to update. Resolve manually in $INSTALL_DIR"
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
mkdir -p "$BIN_DIR"

ln -sf "$INSTALL_DIR/claude-yolo" "$BIN_DIR/claude-yolo"
info "Linked claude-yolo → $BIN_DIR/claude-yolo"

# -------------------------------------------------------------------
# Ensure ~/.local/bin is in PATH
# -------------------------------------------------------------------
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    warn "$BIN_DIR is not in your PATH"

    # Detect shell config file
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        bash) RC_FILE="$HOME/.bashrc" ;;
        fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
        *)    RC_FILE="$HOME/.profile" ;;
    esac

    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE='fish_add_path $HOME/.local/bin'
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE — you may need to restart your shell"
    else
        printf '\n# Added by claude-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
        warn "Restart your shell or run: source $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}claude-yolo installed successfully!${RESET}\n"
printf "\n  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    claude-yolo \"fix the tests\" \"update docs\"\n\n"
