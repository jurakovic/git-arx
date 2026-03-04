#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install git-bx and configure the git alias

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SCRIPT_DIR/git-bx"

if [[ ! -f "$SCRIPT_SRC" ]]; then
    printf 'Error: git-bx script not found at %s\n' "$SCRIPT_SRC" >&2
    exit 1
fi

# Determine install directory
if [[ "${MSYSTEM:-}" == "MINGW64" || "${MSYSTEM:-}" == "MINGW32" || "${OS:-}" == "Windows_NT" ]]; then
    # MINGW64 / Git Bash on Windows
    INSTALL_DIR="$HOME/bin"
else
    # Linux / macOS
    INSTALL_DIR="$HOME/.local/bin"
fi

# Allow override via first argument
if [[ -n "${1:-}" ]]; then
    INSTALL_DIR="$1"
fi

# Create install directory if needed
if [[ ! -d "$INSTALL_DIR" ]]; then
    printf 'Creating %s\n' "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
fi

# Copy script
cp "$SCRIPT_SRC" "$INSTALL_DIR/git-bx"
chmod +x "$INSTALL_DIR/git-bx"
printf 'Installed: %s/git-bx\n' "$INSTALL_DIR"

# Check if install dir is on PATH
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qxF "$INSTALL_DIR"; then
    printf '\nNote: %s is not on your PATH.\n' "$INSTALL_DIR"
    printf 'Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n'
    printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
fi

# Set global git alias
git config --global alias.bx '!git-bx'
printf 'Git alias set: git bx -> git-bx\n'
printf '\nDone! Try: git bx help\n'
