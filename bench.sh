#!/usr/bin/env bash
# Benchmark git-arx's subprocess-heavy commands against a synthetic repo
# with many branches, optionally comparing two versions side by side.
#
# Usage:
#   bash bench.sh                  # time the working-tree git-arx
#   bash bench.sh <rev>            # compare <rev> against the working tree
#   bash bench.sh <rev-a> <rev-b>  # compare two versions
#
# Each argument is a git revision (git-arx is extracted from it via git show)
# or a path to a git-arx executable, e.g. an installed copy:
#   bash bench.sh ~/bin/git-arx
# N=<count> overrides the branch count (default: 80):
#   N=200 bash bench.sh 3e11639 HEAD
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
N="${N:-80}"

TMP=$(mktemp -d)
trap 'cd /; rm -rf "$TMP"' EXIT

# Resolve an argument to an executable: an existing file is used as-is
# (made absolute – the benchmark runs from a temp directory), anything else
# is treated as a git revision to extract git-arx from.
resolve() {
    local arg="$1" out="$2"
    if [[ -f "$arg" ]]; then
        printf '%s/%s' "$(cd "$(dirname "$arg")" && pwd)" "$(basename "$arg")"
    else
        git -C "$SCRIPT_DIR" show "${arg}:git-arx" > "$out"
        printf '%s' "$out"
    fi
}

declare -a BINS=() LABELS=()
case $# in
    0)  BINS=("$SCRIPT_DIR/git-arx")
        LABELS=("worktree") ;;
    1)  BINS=("$(resolve "$1" "$TMP/arx-a")" "$SCRIPT_DIR/git-arx")
        LABELS=("$1" "worktree") ;;
    2)  BINS=("$(resolve "$1" "$TMP/arx-a")" "$(resolve "$2" "$TMP/arx-b")")
        LABELS=("$1" "$2") ;;
    *)  printf 'Usage: bash bench.sh [rev-or-path [rev-or-path]]\n' >&2
        exit 1 ;;
esac

# --- synthetic repo: N branches at distinct commits (update dedups identical
# SHAs), each with an upstream whose tracking ref is gone (remote-deleted) ---
cd "$TMP"
git init -q -b master bench && cd bench
git config user.name "Bench" && git config user.email "bench@example.com"
printf 'x\n' > f.txt && git add f.txt && git commit -qm init
git remote add origin .  # %(upstream) resolves only if the remote is configured

tree=$(git rev-parse 'HEAD^{tree}') head=$(git rev-parse HEAD)
for i in $(seq 1 "$N"); do
    sha=$(git commit-tree -m "c$i" "$tree" -p "$head")
    git branch "feat/b$i" "$sha"
    git config "branch.feat/b$i.remote" origin
    git config "branch.feat/b$i.merge" "refs/heads/feat/b$i"
done

reset_arx() {
    git for-each-ref --format='%(refname)' refs/arx/ \
        | while read -r r; do git update-ref -d "$r"; done
    rm -f .gitarchive
}

ms() {  # ms <bin> <args...> – run and print elapsed wall-clock ms
    local bin="$1" t0 t1
    shift
    t0=$(date +%s%N)
    bash "$bin" "$@" > /dev/null 2>&1 || true
    t1=$(date +%s%N)
    printf '%d' $(( (t1 - t0) / 1000000 ))
}

row() {  # row <label> <args...> – one table row, timing every bin
    local label="$1"
    shift
    printf '%-22s' "$label"
    local bin
    for bin in "${BINS[@]}"; do
        printf ' %12s' "$(ms "$bin" "$@")"
    done
    printf '\n'
}

printf '%-22s' "COMMAND (N=$N)"
for l in "${LABELS[@]}"; do printf ' %12s' "${l:0:12}"; done
printf '\n%-22s' "-------"
for l in "${LABELS[@]}"; do printf ' %12s' "------"; done
printf '\n'

row "status" status
row "status --all" status --all

# update writes – reset the archive before each version's run
printf '%-22s' "update (archive $N)"
for bin in "${BINS[@]}"; do
    reset_arx
    printf ' %12s' "$(ms "$bin" update)"
done
printf '\n'

# archive is now populated; list and prune read the same state for every bin
row "list" list
row "prune --dry-run" prune --dry-run
