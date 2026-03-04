#!/usr/bin/env bash
set -euo pipefail

# test.sh — Integration test suite for git-bx
# Runs ./git-bx directly; no install required.
# Usage: bash test.sh

BX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-bx"
PASS=0
FAIL=0
TMPROOT=""
REPO=""
REMOTE=""
SHA_ALPHA="" SHA_BETA="" SHA_GAMMA=""
DEFAULT_BRANCH=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { printf '  PASS  %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

assert_ok() {       # label cmd...
    local label="$1"; shift
    if "$@" > /dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

assert_fails() {    # label cmd...
    local label="$1"; shift
    if ! "$@" > /dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

assert_out() {      # label pattern cmd...
    local label="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1) || true
    if printf '%s' "$out" | grep -qF "$pattern"; then
        pass "$label"
    else
        fail "$label"
        printf '      expected: %s\n' "$pattern"
        printf '      got:      %s\n' "$out"
    fi
}

section() { printf '\n=== %s ===\n' "$1"; }

reset_archive() {
    cd "$REPO"
    rm -f .gitarchive
    git for-each-ref --format='%(refname)' 'refs/bx/' | while read -r ref; do
        git update-ref -d "$ref"
    done
    git config bx.storage file
}

recreate_branches() {
    git rev-parse --verify refs/heads/feature/alpha > /dev/null 2>&1 \
        || git branch feature/alpha "$SHA_ALPHA"
    git rev-parse --verify refs/heads/feature/beta > /dev/null 2>&1 \
        || git branch feature/beta "$SHA_BETA"
    git rev-parse --verify refs/heads/fix/gamma > /dev/null 2>&1 \
        || git branch fix/gamma "$SHA_GAMMA"
}

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
    TMPROOT=$(mktemp -d)
    REMOTE="$TMPROOT/remote.git"
    git init --bare "$REMOTE" -q

    REPO="$TMPROOT/repo"
    git clone "$REMOTE" "$REPO" -q
    cd "$REPO"
    git config user.email "test@example.com"
    git config user.name "Test"

    git commit --allow-empty -m "initial" -q
    git push origin HEAD -q 2>/dev/null
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)

    git checkout -b feature/alpha -q && git commit --allow-empty -m "alpha" -q
    git checkout -b feature/beta  -q && git commit --allow-empty -m "beta"  -q
    git checkout -b fix/gamma     -q && git commit --allow-empty -m "gamma" -q

    SHA_ALPHA=$(git rev-parse refs/heads/feature/alpha)
    SHA_BETA=$(git rev-parse refs/heads/feature/beta)
    SHA_GAMMA=$(git rev-parse refs/heads/fix/gamma)

    git checkout "$DEFAULT_BRANCH" -q
    git config bx.storage file
}

teardown() {
    cd "$HOME"
    rm -rf "$TMPROOT"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_help() {
    section "help"
    assert_ok  "help exits 0"        "$BX" help
    assert_out "help shows USAGE"    "USAGE"    "$BX" help
    assert_out "help shows COMMANDS" "COMMANDS" "$BX" help
    assert_ok  "--help exits 0"      "$BX" --help
    assert_ok  "-h exits 0"          "$BX" -h
}

test_add() {
    section "add"
    reset_archive

    assert_out   "add: archives a branch"       "Archived: feature/alpha"   "$BX" add feature/alpha
    assert_out   "add: shows short SHA"         "at "                       "$BX" add feature/beta
    assert_out   "add: nonexistent: error msg"  "not found in local"        "$BX" add no-such-branch
    assert_fails "add: nonexistent: nonzero"                                "$BX" add no-such-branch
    assert_out   "add: no arg: usage"           "Usage:"                    "$BX" add
    assert_fails "add: no arg: nonzero"                                     "$BX" add
}

test_remove() {
    section "remove"
    reset_archive
    "$BX" add feature/alpha > /dev/null

    assert_out   "remove: removes branch"       "Removed: feature/alpha" "$BX" remove feature/alpha
    assert_out   "remove: missing: error msg"   "not found in archive"   "$BX" remove feature/alpha
    assert_fails "remove: missing: nonzero"                              "$BX" remove feature/alpha
    assert_out   "remove: no arg: usage"        "Usage:"                 "$BX" remove
    assert_fails "remove: no arg: nonzero"                               "$BX" remove
}

test_list() {
    section "list"
    reset_archive

    assert_out "list: empty archive message" "No archived branches" "$BX" list

    "$BX" add feature/alpha > /dev/null
    "$BX" add feature/beta  > /dev/null
    "$BX" add fix/gamma     > /dev/null

    assert_out   "list: shows header"              "BRANCH"           "$BX" list
    assert_out   "list: shows archived branch"     "feature/alpha"    "$BX" list
    assert_out   "list: shows all branches"        "fix/gamma"        "$BX" list
    assert_ok    "list: --sort=name"               "$BX" list --sort=name
    assert_ok    "list: --sort=date"               "$BX" list --sort=date
    assert_ok    "list: --order=asc"               "$BX" list --order=asc
    assert_ok    "list: --order=desc"              "$BX" list --order=desc
    assert_ok    "list: --storage=file"            "$BX" list --storage=file
    assert_fails "list: --storage=refs (file-only)" "$BX" list --storage=refs
    assert_out   "list: --storage=bogus: error"   "invalid --storage value" "$BX" list --storage=bogus
    assert_fails "list: unknown option: nonzero"  "$BX" list --bogus
}

test_update() {
    section "update"
    reset_archive

    local out
    out=$("$BX" update 2>&1)
    if printf '%s' "$out" | grep -qF "Archived: feature/alpha"; then
        pass "update: archives branch with no upstream"
    else
        fail "update: archives branch with no upstream"
    fi
    if printf '%s' "$out" | grep -qF "Archived 3 branch(es)"; then
        pass "update: reports correct count"
    else
        fail "update: reports correct count"
        printf '      got: %s\n' "$out"
    fi

    # Give feature/alpha a live upstream so it should be skipped
    git checkout feature/alpha -q
    git push origin feature/alpha -q 2>/dev/null
    git branch --set-upstream-to=origin/feature/alpha 2>/dev/null || true
    git checkout "$DEFAULT_BRANCH" -q

    reset_archive
    out=$("$BX" update 2>&1)
    if ! printf '%s' "$out" | grep -qF "Archived: feature/alpha"; then
        pass "update: skips branch with live upstream"
    else
        fail "update: skips branch with live upstream"
    fi

    # Restore: remove tracking so later tests are not affected
    git branch --unset-upstream feature/alpha 2>/dev/null || true
    git update-ref -d refs/remotes/origin/feature/alpha 2>/dev/null || true
}

test_log() {
    section "log"
    reset_archive
    "$BX" add feature/alpha > /dev/null

    assert_ok    "log: shows history"      "$BX" log feature/alpha
    assert_ok    "log: passes --oneline"   "$BX" log feature/alpha --oneline
    assert_ok    "log: passes -n 1"        "$BX" log feature/alpha -n 1
    assert_out   "log: missing: error"     "not found in archive" "$BX" log no-such-branch
    assert_fails "log: missing: nonzero"                          "$BX" log no-such-branch
    assert_out   "log: no arg: usage"      "Usage:"               "$BX" log
    assert_fails "log: no arg: nonzero"                           "$BX" log
}

test_checkout() {
    section "checkout"
    reset_archive
    "$BX" add feature/alpha > /dev/null
    git branch -D feature/alpha  # delete locally so we can restore it

    assert_out   "checkout: restores branch"       "Restored branch: feature/alpha" "$BX" checkout feature/alpha
    assert_out   "checkout: branch exists: error"  "already exists"                 "$BX" checkout feature/alpha
    assert_fails "checkout: branch exists: nonzero"                                 "$BX" checkout feature/alpha
    assert_out   "checkout: missing: error"        "not found in archive"           "$BX" checkout no-such-branch
    assert_fails "checkout: missing: nonzero"                                       "$BX" checkout no-such-branch
    assert_out   "checkout: no arg: usage"         "Usage:"                         "$BX" checkout
    git checkout "$DEFAULT_BRANCH" -q
}

test_prune() {
    section "prune"
    reset_archive
    recreate_branches

    "$BX" add feature/alpha > /dev/null
    "$BX" add feature/beta  > /dev/null

    local out
    out=$("$BX" prune --force 2>&1)
    if printf '%s' "$out" | grep -qF "Deleted 2 branch(es)"; then
        pass "prune: deletes archived branches with --force"
    else
        fail "prune: deletes archived branches with --force"
        printf '      got: %s\n' "$out"
    fi
    if ! git rev-parse --verify refs/heads/feature/alpha > /dev/null 2>&1; then
        pass "prune: feature/alpha is deleted locally"
    else
        fail "prune: feature/alpha should be deleted"
    fi

    assert_out "prune: nothing to delete" "No archived branches found" "$BX" prune --force

    # Currently checked-out branch should be skipped
    recreate_branches
    "$BX" add fix/gamma > /dev/null
    git checkout fix/gamma -q
    out=$("$BX" prune --force 2>&1)
    if printf '%s' "$out" | grep -qF "Skipped (currently checked out)"; then
        pass "prune: skips checked-out branch"
    else
        fail "prune: skips checked-out branch"
        printf '      got: %s\n' "$out"
    fi
    git checkout "$DEFAULT_BRANCH" -q

    assert_fails "prune: unknown option: nonzero" "$BX" prune --bogus

    recreate_branches  # restore for subsequent tests
}

test_merge() {
    section "merge"
    reset_archive

    local f1="$TMPROOT/a1.txt" f2="$TMPROOT/a2.txt" fo="$TMPROOT/out.txt"

    printf '# archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\nfeature/beta %s 2025-01-02T00:00:00+00:00\n' \
        "$SHA_ALPHA" "$SHA_BETA" > "$f1"
    printf '# archive\nfeature/beta %s 2025-01-02T00:00:00+00:00\nfix/gamma %s 2025-01-03T00:00:00+00:00\n' \
        "$SHA_BETA" "$SHA_GAMMA" > "$f2"

    assert_ok  "merge: succeeds"         "$BX" merge "$f1" "$f2" -o "$fo"
    assert_out "merge: alpha in output"  "feature/alpha" cat "$fo"
    assert_out "merge: gamma in output"  "fix/gamma"     cat "$fo"
    assert_out "merge: reports count"    "Merged"        "$BX" merge "$f1" "$f2" -o "$fo"

    local beta_count
    beta_count=$(grep -c "^feature/beta " "$fo" 2>/dev/null || true)
    if [[ "$beta_count" -eq 1 ]]; then
        pass "merge: deduplicates identical entries"
    else
        fail "merge: expected 1 beta entry, got $beta_count"
    fi

    # SHA conflict: f2 has feature/alpha with a different SHA
    printf '# archive\nfeature/alpha %s 2025-01-04T00:00:00+00:00\n' "$SHA_BETA" > "$f2"
    local out
    out=$("$BX" merge "$f1" "$f2" -o "$fo" 2>&1) || true
    if printf '%s' "$out" | grep -qF "CONFLICT"; then
        pass "merge: reports SHA conflict"
    else
        fail "merge: should report SHA conflict"
    fi
    if ! grep -qF "feature/alpha" "$fo" 2>/dev/null; then
        pass "merge: conflict entry excluded from output"
    else
        fail "merge: conflict entry should be excluded"
    fi

    # Wrong backend
    git config bx.storage refs
    assert_out   "merge: requires file storage" "requires file storage" "$BX" merge "$f1" "$f2" -o "$fo"
    assert_fails "merge: nonzero when refs-only"                        "$BX" merge "$f1" "$f2" -o "$fo"
    git config bx.storage file
}

test_refs_backend() {
    section "refs backend"
    reset_archive
    git config bx.storage refs

    assert_out "refs add: archives" "Archived: feature/alpha" "$BX" add feature/alpha

    if git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "refs: ref exists under refs/bx/"
    else
        fail "refs: ref should exist under refs/bx/"
    fi

    assert_out "refs list: shows branch"  "feature/alpha"          "$BX" list
    assert_out "refs remove: removes"     "Removed: feature/alpha" "$BX" remove feature/alpha

    if ! git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "refs: ref removed"
    else
        fail "refs: ref should be removed"
    fi

    git config bx.storage file
}

test_both_backend() {
    section "both backend (write fan-out)"
    reset_archive
    git config bx.storage both

    "$BX" add feature/alpha > /dev/null

    if grep -qF "feature/alpha" .gitarchive 2>/dev/null; then
        pass "both: written to file"
    else
        fail "both: should write to file"
    fi
    if git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "both: written to refs"
    else
        fail "both: should write to refs"
    fi

    "$BX" remove feature/alpha > /dev/null

    if ! grep -qF "feature/alpha" .gitarchive 2>/dev/null; then
        pass "both: deleted from file"
    else
        fail "both: should delete from file"
    fi
    if ! git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "both: deleted from refs"
    else
        fail "both: should delete from refs"
    fi

    git config bx.storage file
}

test_push_pull() {
    section "push / pull (refs backend)"
    reset_archive
    git config bx.storage refs

    "$BX" add feature/alpha > /dev/null
    "$BX" add feature/beta  > /dev/null

    assert_ok    "push: succeeds"            "$BX" push
    assert_ok    "push: --dry-run"           "$BX" push --dry-run
    assert_fails "push: unknown option"      "$BX" push --bogus

    if git ls-remote "$REMOTE" 'refs/bx/*' | grep -q 'refs/bx/feature/alpha'; then
        pass "push: ref visible on remote"
    else
        fail "push: ref should be on remote"
    fi

    # Fresh clone — test pull
    local repo2="$TMPROOT/repo2"
    git clone "$REMOTE" "$repo2" -q
    cd "$repo2"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config bx.storage refs

    assert_ok "pull: succeeds in fresh clone" "$BX" pull

    if git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "pull: ref present after pull"
    else
        fail "pull: ref should be present after pull"
    fi

    # pull with both storage → also syncs to .gitarchive
    git config bx.storage both
    "$BX" pull > /dev/null 2>&1 || true
    if [[ -f .gitarchive ]] && grep -qF "feature/alpha" .gitarchive; then
        pass "pull (both): syncs to .gitarchive"
    else
        fail "pull (both): should sync to .gitarchive"
    fi

    cd "$REPO"
    git config bx.storage file
}

test_sync() {
    section "sync (both backend)"
    reset_archive
    git config bx.storage both

    # File-only drift
    printf '# git-bx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive

    local out
    out=$("$BX" sync --check 2>&1)
    if printf '%s' "$out" | grep -qF "file-only: feature/alpha"; then
        pass "sync --check: reports file-only entry"
    else
        fail "sync --check: should report file-only"
        printf '      got: %s\n' "$out"
    fi

    "$BX" sync > /dev/null
    if git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "sync: copies file-only entry to refs"
    else
        fail "sync: should copy file-only to refs"
    fi

    # Refs-only drift
    reset_archive
    git config bx.storage both
    git update-ref "refs/bx/feature/beta" "$SHA_BETA"

    out=$("$BX" sync --check 2>&1)
    if printf '%s' "$out" | grep -qF "refs-only: feature/beta"; then
        pass "sync --check: reports refs-only entry"
    else
        fail "sync --check: should report refs-only"
        printf '      got: %s\n' "$out"
    fi

    "$BX" sync > /dev/null
    if [[ -f .gitarchive ]] && grep -qF "feature/beta" .gitarchive; then
        pass "sync: copies refs-only entry to file"
    else
        fail "sync: should copy refs-only to file"
    fi

    # SHA conflict
    reset_archive
    git config bx.storage both
    printf '# git-bx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/bx/feature/alpha" "$SHA_BETA"  # intentionally different

    out=$("$BX" sync 2>&1) || true
    if printf '%s' "$out" | grep -qF "CONFLICT"; then
        pass "sync: reports SHA conflict"
    else
        fail "sync: should report SHA conflict"
    fi

    # --force-file: refs should be overwritten with file's SHA
    "$BX" sync --force-file > /dev/null
    local resolved
    resolved=$(git rev-parse refs/bx/feature/alpha)
    if [[ "$resolved" == "$SHA_ALPHA" ]]; then
        pass "sync --force-file: refs updated to file's SHA"
    else
        fail "sync --force-file: wrong SHA (got ${resolved:0:8}, want ${SHA_ALPHA:0:8})"
    fi

    # --force-refs: file should be overwritten with refs' SHA
    reset_archive
    git config bx.storage both
    printf '# git-bx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/bx/feature/alpha" "$SHA_BETA"
    "$BX" sync --force-refs > /dev/null
    if grep -qF "$SHA_BETA" .gitarchive; then
        pass "sync --force-refs: file updated to refs' SHA"
    else
        fail "sync --force-refs: file should have refs' SHA"
    fi

    # sync requires both
    git config bx.storage file
    assert_out   "sync: error when file-only" "requires both storage" "$BX" sync
    assert_fails "sync: nonzero when file-only"                       "$BX" sync

    git config bx.storage refs
    assert_out   "sync: error when refs-only" "requires both storage" "$BX" sync
    assert_fails "sync: nonzero when refs-only"                       "$BX" sync

    git config bx.storage file
}

test_slashed_branches() {
    section "branch names with slashes"
    reset_archive

    "$BX" add feature/alpha > /dev/null
    assert_out "slash: in file list" "feature/alpha" "$BX" list

    git config bx.storage refs
    "$BX" add feature/alpha > /dev/null
    if git rev-parse --verify refs/bx/feature/alpha > /dev/null 2>&1; then
        pass "slash: correct ref path refs/bx/feature/alpha"
    else
        fail "slash: should be at refs/bx/feature/alpha"
    fi

    git config bx.storage file
}

test_double_add() {
    section "double add (idempotent)"
    reset_archive

    "$BX" add feature/alpha > /dev/null
    "$BX" add feature/alpha > /dev/null  # second add — should update, not duplicate

    local count
    count=$(grep -c "^feature/alpha " .gitarchive 2>/dev/null || true)
    if [[ "$count" -eq 1 ]]; then
        pass "double add: no duplicate in file"
    else
        fail "double add: expected 1 entry, got $count"
    fi
}

test_error_cases() {
    section "error cases"
    reset_archive

    assert_out   "unknown cmd: error message" "unknown command"    "$BX" bogus
    assert_fails "unknown cmd: nonzero"                            "$BX" bogus

    local notrepo="$TMPROOT/notrepo"
    mkdir -p "$notrepo"
    assert_out   "not-in-repo: error"   "not inside a git repository" \
        bash -c "cd '$notrepo' && '$BX' list"
    assert_fails "not-in-repo: nonzero" \
        bash -c "cd '$notrepo' && '$BX' list"

    git config bx.storage file
    assert_out   "push: requires refs" "requires refs storage" "$BX" push
    assert_out   "pull: requires refs" "requires refs storage" "$BX" pull
    assert_out   "sync: requires both" "requires both storage" "$BX" sync

    git config bx.storage refs
    assert_out   "merge: requires file" "requires file storage" \
        "$BX" merge /dev/null /dev/null -o /dev/null

    git config bx.storage file
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    printf 'git-bx integration test suite\n'
    printf 'Script: %s\n\n' "$BX"

    if [[ ! -x "$BX" ]]; then
        printf 'ERROR: git-bx not found or not executable at %s\n' "$BX" >&2
        exit 1
    fi

    setup

    test_help
    test_add
    test_remove
    test_list
    test_update
    test_log
    test_checkout
    test_prune
    test_merge
    test_refs_backend
    test_both_backend
    test_push_pull
    test_sync
    test_slashed_branches
    test_double_add
    test_error_cases

    teardown

    printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
    [[ $FAIL -eq 0 ]]
}

main
