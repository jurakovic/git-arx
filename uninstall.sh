#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh — Remove git-arx, its completion script, and the git alias
#
# Usage:
#   bash uninstall.sh
#   curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/tags/latest/uninstall.sh | bash
#
#   bash uninstall.sh /usr/local/bin   # if installed to a custom path

# Determine install directory (must match what install.sh used)
if [[ "${MSYSTEM:-}" == "MINGW64" || "${MSYSTEM:-}" == "MINGW32" || "${OS:-}" == "Windows_NT" ]]; then
    INSTALL_DIR="$HOME/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
fi

if [[ -n "${1:-}" ]]; then
    INSTALL_DIR="$1"
fi

COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"

# Show what will be removed
printf 'The following will be removed:\n'
[[ -f "$INSTALL_DIR/git-arx" ]]     && printf '  %s/git-arx\n' "$INSTALL_DIR"     || printf '  %s/git-arx (not found)\n' "$INSTALL_DIR"
[[ -f "$COMPLETION_DIR/git-arx" ]]  && printf '  %s/git-arx\n' "$COMPLETION_DIR"  || printf '  %s/git-arx (not found)\n' "$COMPLETION_DIR"
printf '  git global alias: arx\n'
printf '\n'

read -r -p 'Continue? [y/N] ' answer </dev/tty
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    printf 'Aborted.\n'
    exit 1
fi

# Remove files
if [[ -f "$INSTALL_DIR/git-arx" ]]; then
    rm -f "$INSTALL_DIR/git-arx"
    printf 'Removed: %s/git-arx\n' "$INSTALL_DIR"
fi

if [[ -f "$COMPLETION_DIR/git-arx" ]]; then
    rm -f "$COMPLETION_DIR/git-arx"
    printf 'Removed: %s/git-arx\n' "$COMPLETION_DIR"
fi

# Remove git alias
if git config --global --get alias.arx > /dev/null 2>&1; then
    git config --global --unset alias.arx
    printf 'Removed git alias: arx\n'
fi

printf '\nDone.\n'
