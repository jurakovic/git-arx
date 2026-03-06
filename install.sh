#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install git-arx and configure the git alias
#
# Local install (after git clone):
#   bash install.sh
#
# Remote install (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/master/install.sh | bash
#
# Custom install path:
#   bash install.sh /usr/local/bin
#   curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/master/install.sh | bash -s -- /usr/local/bin

RAW_URL="https://raw.githubusercontent.com/jurakovic/git-arx/master/git-arx"

# Locate git-arx: check alongside this script first, then download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || pwd)"
SCRIPT_SRC="$SCRIPT_DIR/git-arx"
TMPFILE=""

if [[ ! -f "$SCRIPT_SRC" ]]; then
    printf 'Downloading git-arx...\n'
    TMPFILE="$(mktemp)"
    curl -fsSL "$RAW_URL" -o "$TMPFILE"
    SCRIPT_SRC="$TMPFILE"
fi

# Determine install directory
if [[ "${MSYSTEM:-}" == "MINGW64" || "${MSYSTEM:-}" == "MINGW32" || "${OS:-}" == "Windows_NT" ]]; then
    INSTALL_DIR="$HOME/bin"
else
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

# Install
cp "$SCRIPT_SRC" "$INSTALL_DIR/git-arx"
chmod +x "$INSTALL_DIR/git-arx"
printf 'Installed: %s/git-arx\n' "$INSTALL_DIR"

# Cleanup temp file if we downloaded
if [[ -n "$TMPFILE" ]]; then
    rm -f "$TMPFILE"
fi

# Check if install dir is on PATH
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qxF "$INSTALL_DIR"; then
    printf '\nNote: %s is not on your PATH.\n' "$INSTALL_DIR"
    printf 'Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n'
    printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
fi

# Set global git alias
git config --global alias.arx '!git-arx'
printf 'Git alias set: git arx -> git-arx\n'
printf '\nDone! Try: git arx help\n'
