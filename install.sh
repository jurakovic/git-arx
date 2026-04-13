#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install git-arx and configure the git alias
#
# Local install (after git clone):
#   bash install.sh
#
# Remote install (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/install.sh | bash
#
# Custom install path:
#   bash install.sh /usr/local/bin
#   curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/install.sh | bash -s -- /usr/local/bin

RAW_URL="https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/git-arx"
COMPLETION_RAW_URL="https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/git-arx-completion.bash"

# Locate files: check alongside this script first, then download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || pwd)"
SCRIPT_SRC="$SCRIPT_DIR/git-arx"
COMPLETION_SRC="$SCRIPT_DIR/git-arx-completion.bash"
TMPFILE=""
COMPLETION_TMPFILE=""

if [[ ! -f "$SCRIPT_SRC" ]]; then
    printf 'Downloading git-arx...\n'
    TMPFILE="$(mktemp)"
    curl -fsSL "$RAW_URL" -o "$TMPFILE"
    SCRIPT_SRC="$TMPFILE"
fi

if [[ ! -f "$COMPLETION_SRC" ]]; then
    COMPLETION_TMPFILE="$(mktemp)"
    curl -fsSL "$COMPLETION_RAW_URL" -o "$COMPLETION_TMPFILE"
    COMPLETION_SRC="$COMPLETION_TMPFILE"
fi

# Determine commit hash for version stamp
if [[ -n "$TMPFILE" ]]; then
    # Remote install: use git ls-remote to get the latest commit on master
    COMMIT=$(git ls-remote https://github.com/jurakovic/git-arx.git refs/heads/master 2>/dev/null | cut -f1 | cut -c1-7) || COMMIT="dev"
else
    # Local install: read from the git repo alongside this script
    COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null) || COMMIT="dev"
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

# Install and stamp version
cp "$SCRIPT_SRC" "$INSTALL_DIR/git-arx"
tmp=$(mktemp)
sed "s/VERSION=\"dev\"/VERSION=\"$COMMIT\"/" "$INSTALL_DIR/git-arx" > "$tmp"
mv "$tmp" "$INSTALL_DIR/git-arx"
chmod +x "$INSTALL_DIR/git-arx"
printf 'Installed: %s/git-arx (%s)\n' "$INSTALL_DIR" "$COMMIT"

# Cleanup temp files if we downloaded
if [[ -n "$TMPFILE" ]]; then
    rm -f "$TMPFILE"
fi

# Install bash completion
COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"
mkdir -p "$COMPLETION_DIR"
cp "$COMPLETION_SRC" "$COMPLETION_DIR/git-arx"
printf 'Installed completion: %s/git-arx\n' "$COMPLETION_DIR"

if [[ -n "$COMPLETION_TMPFILE" ]]; then
    rm -f "$COMPLETION_TMPFILE"
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
