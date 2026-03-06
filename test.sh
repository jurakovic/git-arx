#!/usr/bin/env bash
set -euo pipefail

# test.sh — Integration test suite for git-arx
# Runs ./git-arx directly; no install required.
# Usage: bash test.sh

ARX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-arx"
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

set_storage() {
    case "$1" in
        file) git config arx.storefile true  && git config arx.storerefs false ;;
        refs) git config arx.storerefs true  && git config arx.storefile false ;;
        both) git config arx.storerefs true  && git config arx.storefile true  ;;
    esac
}

reset_archive() {
    cd "$REPO"
    rm -f .gitarchive
    git for-each-ref --format='%(refname)' 'refs/arx/' | while read -r ref; do
        git update-ref -d "$ref"
    done
    set_storage file
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
    set_storage file
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
    assert_ok  "help exits 0"        "$ARX" help
    assert_out "help shows USAGE"    "USAGE"    "$ARX" help
    assert_out "help shows COMMANDS" "COMMANDS" "$ARX" help
    assert_ok  "--help exits 0"      "$ARX" --help
    assert_ok  "-h exits 0"          "$ARX" -h
}

test_add() {
    section "add"
    reset_archive

    assert_out   "add: archives a branch"       "Archived: feature/alpha"   "$ARX" add feature/alpha
    assert_out   "add: shows short SHA"         "at "                       "$ARX" add feature/beta
    assert_out   "add: nonexistent: error msg"  "not found in local"        "$ARX" add no-such-branch
    assert_fails "add: nonexistent: nonzero"                                "$ARX" add no-such-branch
    assert_out   "add: no arg: usage"           "Usage:"                    "$ARX" add
    assert_fails "add: no arg: nonzero"                                     "$ARX" add

    # same SHA: idempotent
    assert_out   "add: same SHA: already archived"  "Already archived"  "$ARX" add feature/alpha
    assert_ok    "add: same SHA: exits 0"                               "$ARX" add feature/alpha

    # conflict: different SHA already in archive
    reset_archive
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive

    assert_out   "add: conflict: error message"      "conflict"            "$ARX" add feature/alpha
    assert_out   "add: conflict: shows old SHA"      "${SHA_BETA:0:8}"     "$ARX" add feature/alpha
    assert_out   "add: conflict: hints --force"      "force"               "$ARX" add feature/alpha
    assert_fails "add: conflict: nonzero"                                  "$ARX" add feature/alpha

    # --force: overwrites conflict
    assert_out   "add: --force: archived"            "Archived"            "$ARX" add feature/alpha --force
    local stored
    stored=$(grep "^feature/alpha " .gitarchive | awk '{print $2}')
    if [[ "$stored" == "$SHA_ALPHA" ]]; then
        pass "add: --force: stored correct SHA"
    else
        fail "add: --force: wrong SHA (got ${stored:0:8}, want ${SHA_ALPHA:0:8})"
    fi

    # archive name: archive under a different name
    reset_archive
    assert_out   "add: archive name: archived with archive name label"  "Archived: feature/alpha (as alpha-saved)"  \
        "$ARX" add feature/alpha alpha-saved
    assert_out   "add: archive name: name in archive"            "alpha-saved"      "$ARX" list

    # archive name conflict
    assert_out   "add: archive name conflict: error"             "conflict"         "$ARX" add feature/beta alpha-saved
    assert_fails "add: archive name conflict: nonzero"                              "$ARX" add feature/beta alpha-saved

    # SHA already archived under a different name: note shown, still archives
    reset_archive
    "$ARX" add feature/alpha alpha-saved > /dev/null
    local dup_out
    dup_out=$("$ARX" add feature/alpha 2>&1)
    if printf '%s' "$dup_out" | grep -qF "Note:"; then
        pass "add: SHA duplicate: shows note"
    else
        fail "add: SHA duplicate: should show note"
        printf '      got: %s\n' "$dup_out"
    fi
    if printf '%s' "$dup_out" | grep -qF "alpha-saved"; then
        pass "add: SHA duplicate: note names existing entry"
    else
        fail "add: SHA duplicate: note should name existing entry"
        printf '      got: %s\n' "$dup_out"
    fi
    if printf '%s' "$dup_out" | grep -qF "Archived: feature/alpha"; then
        pass "add: SHA duplicate: still archives"
    else
        fail "add: SHA duplicate: should still archive"
        printf '      got: %s\n' "$dup_out"
    fi
}

test_remove() {
    section "remove"
    reset_archive
    "$ARX" add feature/alpha > /dev/null

    assert_out   "remove: removes branch"       "Removed: feature/alpha" "$ARX" remove feature/alpha
    assert_out   "remove: missing: error msg"   "not found in archive"   "$ARX" remove feature/alpha
    assert_fails "remove: missing: nonzero"                              "$ARX" remove feature/alpha
    assert_out   "remove: no arg: usage"        "Usage:"                 "$ARX" remove
    assert_fails "remove: no arg: nonzero"                               "$ARX" remove
}

test_list() {
    section "list"
    reset_archive

    assert_out "list: empty archive message" "No archived branches" "$ARX" list

    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/beta  > /dev/null
    "$ARX" add fix/gamma     > /dev/null

    assert_out   "list: shows header"              "BRANCH"           "$ARX" list
    assert_out   "list: shows archived branch"     "feature/alpha"    "$ARX" list
    assert_out   "list: shows all branches"        "fix/gamma"        "$ARX" list
    assert_out   "list: --author shows header"     "AUTHOR"           "$ARX" list --author
    assert_out   "list: --author shows name"       "Test"             "$ARX" list --author
    assert_ok    "list: --sort=name"               "$ARX" list --sort=name
    assert_ok    "list: --sort=date"               "$ARX" list --sort=date
    assert_ok    "list: --order=asc"               "$ARX" list --order=asc
    assert_ok    "list: --order=desc"              "$ARX" list --order=desc
    assert_ok    "list: --storage=file"            "$ARX" list --storage=file
    assert_fails "list: --storage=refs (file-only)" "$ARX" list --storage=refs
    assert_out   "list: --storage=bogus: error"   "invalid --storage value" "$ARX" list --storage=bogus
    assert_out   "list: --storage=both: error"    "invalid --storage value" "$ARX" list --storage=both
    assert_fails "list: --storage=both: nonzero"                            "$ARX" list --storage=both
    assert_fails "list: unknown option: nonzero"  "$ARX" list --bogus
}

test_rename() {
    section "rename"
    reset_archive
    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/beta  > /dev/null

    assert_out   "rename: succeeds"              "Renamed: feature/alpha -> alpha-old"  "$ARX" rename feature/alpha alpha-old
    assert_out   "rename: no arg: usage"         "Usage:"                               "$ARX" rename
    assert_fails "rename: no arg: nonzero"                                              "$ARX" rename
    assert_out   "rename: missing: error"        "not found in archive"                 "$ARX" rename no-such x
    assert_fails "rename: missing: nonzero"                                             "$ARX" rename no-such x
    assert_out   "rename: same name: error"      "identical"                            "$ARX" rename feature/beta feature/beta
    assert_fails "rename: same name: nonzero"                                           "$ARX" rename feature/beta feature/beta
    assert_out   "rename: target exists: error"  "already exists"                       "$ARX" rename feature/beta alpha-old
    assert_fails "rename: target exists: nonzero"                                       "$ARX" rename feature/beta alpha-old

    local list_out
    list_out=$("$ARX" list 2>&1)
    if printf '%s' "$list_out" | grep -qF "alpha-old"; then
        pass "rename: new name appears in list"
    else
        fail "rename: new name should appear in list"
    fi
    if ! printf '%s' "$list_out" | grep -qF "feature/alpha "; then
        pass "rename: old name gone from list"
    else
        fail "rename: old name should be gone"
    fi

    # refs backend
    set_storage refs
    reset_archive
    set_storage refs
    "$ARX" add feature/alpha > /dev/null
    "$ARX" rename feature/alpha alpha-renamed > /dev/null
    if git rev-parse --verify refs/arx/alpha-renamed > /dev/null 2>&1; then
        pass "rename refs: new ref exists"
    else
        fail "rename refs: new ref should exist"
    fi
    if ! git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "rename refs: old ref gone"
    else
        fail "rename refs: old ref should be gone"
    fi

    set_storage file
}

test_update() {
    section "update"
    reset_archive

    # status: shows candidates without writing
    local dry_out
    dry_out=$("$ARX" status 2>&1)
    if printf '%s' "$dry_out" | grep -qF "feature/alpha"; then
        pass "status: shows branch with no upstream"
    else
        fail "status: shows branch with no upstream"
    fi
    if printf '%s' "$dry_out" | grep -qF "STATUS"; then
        pass "status: shows STATUS column header"
    else
        fail "status: shows STATUS column header"
        printf '      got: %s\n' "$dry_out"
    fi
    if printf '%s' "$dry_out" | grep -qF "SHA"; then
        pass "status: shows SHA column header"
    else
        fail "status: shows SHA column header"
    fi
    if printf '%s' "$dry_out" | grep -qF "Not archived"; then
        pass "status: shows Not archived for unarchived branch"
    else
        fail "status: shows Not archived for unarchived branch"
        printf '      got: %s\n' "$dry_out"
    fi
    if [[ ! -f .gitarchive ]]; then
        pass "status: does not write archive"
    else
        fail "status: does not write archive"
    fi
    assert_out "status: shows author" "Test" "$ARX" status

    local out
    out=$("$ARX" update 2>&1)
    if printf '%s' "$out" | grep -qF "Archived: feature/alpha"; then
        pass "update: archives branch with no upstream"
    else
        fail "update: archives branch with no upstream"
    fi
    # After archiving, status should show "Archived" for those branches
    local status_after
    status_after=$("$ARX" status 2>&1)
    if printf '%s' "$status_after" | grep -qF "Archived"; then
        pass "status: shows Archived for already-archived branch"
    else
        fail "status: shows Archived for already-archived branch"
        printf '      got: %s\n' "$status_after"
    fi
    assert_out   "status: shows author (2nd call)"    "Test" "$ARX" status
    assert_ok    "status: --sort=name"               "$ARX" status --sort=name
    assert_ok    "status: --sort=date"               "$ARX" status --sort=date
    assert_ok    "status: --order=asc"               "$ARX" status --order=asc
    assert_ok    "status: --order=desc"              "$ARX" status --order=desc
    assert_fails "status: unknown option: nonzero"   "$ARX" status --bogus
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
    out=$("$ARX" update 2>&1)
    if ! printf '%s' "$out" | grep -qF "Archived: feature/alpha"; then
        pass "update: skips branch with live upstream"
    else
        fail "update: skips branch with live upstream"
    fi

    # Restore: remove tracking so later tests are not affected
    git branch --unset-upstream feature/alpha 2>/dev/null || true
    git update-ref -d refs/remotes/origin/feature/alpha 2>/dev/null || true

    # --dry-run: shows same output without writing
    reset_archive
    out=$("$ARX" update --dry-run 2>&1)
    if printf '%s' "$out" | grep -qF "Archived: feature/alpha"; then
        pass "update --dry-run: shows archived message"
    else
        fail "update --dry-run: should show archived message"
        printf '      got: %s\n' "$out"
    fi
    if printf '%s' "$out" | grep -qF "(dry run — no changes written)"; then
        pass "update --dry-run: appends dry-run line"
    else
        fail "update --dry-run: should append dry-run line"
        printf '      got: %s\n' "$out"
    fi
    if [[ ! -f .gitarchive ]]; then
        pass "update --dry-run: does not write archive"
    else
        fail "update --dry-run: should not write archive"
    fi

    assert_fails "update: unknown option: nonzero" "$ARX" update --bogus

    # conflict: already archived with a different SHA
    reset_archive
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive

    local conflict_out
    conflict_out=$("$ARX" update 2>&1) || true
    if printf '%s' "$conflict_out" | grep -qF "Conflict: feature/alpha"; then
        pass "update: reports conflict for different SHA"
    else
        fail "update: should report conflict"
        printf '      got: %s\n' "$conflict_out"
    fi
    if printf '%s' "$conflict_out" | grep -qF "1 conflict(s) skipped"; then
        pass "update: reports conflict count in summary"
    else
        fail "update: should report conflict count"
        printf '      got: %s\n' "$conflict_out"
    fi
    # file should still have the old (conflicting) SHA
    if grep -qF "$SHA_BETA" .gitarchive; then
        pass "update: does not overwrite conflict without --force"
    else
        fail "update: should not overwrite conflict"
    fi

    # --force: overwrites conflicts
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive
    local force_out
    force_out=$("$ARX" update --force 2>&1)
    if printf '%s' "$force_out" | grep -qF "Updated: feature/alpha"; then
        pass "update --force: overwrites conflict"
    else
        fail "update --force: should overwrite conflict"
        printf '      got: %s\n' "$force_out"
    fi
    if grep -qF "$SHA_ALPHA" .gitarchive; then
        pass "update --force: stored correct SHA"
    else
        fail "update --force: wrong SHA in archive"
    fi

    # already up to date: silently skipped
    reset_archive
    "$ARX" add feature/alpha > /dev/null
    local skip_out
    skip_out=$("$ARX" update 2>&1)
    if ! printf '%s' "$skip_out" | grep -qF "feature/alpha"; then
        pass "update: silently skips already up-to-date branch"
    else
        fail "update: should skip already up-to-date branch silently"
        printf '      got: %s\n' "$skip_out"
    fi

    # SHA already archived under a different name: skipped with note
    reset_archive
    "$ARX" add feature/alpha alpha-saved > /dev/null
    local safe_out
    safe_out=$("$ARX" update 2>&1)
    if printf '%s' "$safe_out" | grep -qF "Already safe: feature/alpha"; then
        pass "update: SHA duplicate: reports already safe"
    else
        fail "update: SHA duplicate: should report already safe"
        printf '      got: %s\n' "$safe_out"
    fi
    if printf '%s' "$safe_out" | grep -qF "alpha-saved"; then
        pass "update: SHA duplicate: names the existing entry"
    else
        fail "update: SHA duplicate: should name existing entry"
        printf '      got: %s\n' "$safe_out"
    fi
    if printf '%s' "$safe_out" | grep -qF "already safe (SHA archived under different name)"; then
        pass "update: SHA duplicate: summary notes count"
    else
        fail "update: SHA duplicate: summary should note count"
        printf '      got: %s\n' "$safe_out"
    fi
    if ! grep -qF "feature/alpha " .gitarchive 2>/dev/null; then
        pass "update: SHA duplicate: not archived under natural name"
    else
        fail "update: SHA duplicate: should not be archived under natural name"
    fi

    # status: shows "Archived as" for SHA archived under different name
    local status_as_out
    status_as_out=$("$ARX" status 2>&1)
    if printf '%s' "$status_as_out" | grep -qF 'Archived as'; then
        pass "status: shows Archived as for SHA archived under different name"
    else
        fail "status: shows Archived as for SHA archived under different name"
        printf '      got: %s\n' "$status_as_out"
    fi
    if printf '%s' "$status_as_out" | grep -qF "alpha-saved"; then
        pass "status: Archived as names the existing entry"
    else
        fail "status: Archived as should name the existing entry"
        printf '      got: %s\n' "$status_as_out"
    fi

    # combined: stale entry for branch (different SHA) AND current SHA archived elsewhere
    # feature/alpha is at SHA_ALPHA; archive has feature/alpha->SHA_BETA (old) and alpha-saved->SHA_ALPHA
    printf '# git-arx archive\nalpha-saved %s 2025-01-01T00:00:00+00:00\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' \
        "$SHA_ALPHA" "$SHA_BETA" > .gitarchive

    local combined_update_out
    combined_update_out=$("$ARX" update 2>&1)
    if printf '%s' "$combined_update_out" | grep -qF "Already safe: feature/alpha"; then
        pass "update: conflict+SHA duplicate: reports already safe"
    else
        fail "update: conflict+SHA duplicate: should report already safe, not conflict"
        printf '      got: %s\n' "$combined_update_out"
    fi
    if ! printf '%s' "$combined_update_out" | grep -qF "Conflict: feature/alpha"; then
        pass "update: conflict+SHA duplicate: does not report as conflict"
    else
        fail "update: conflict+SHA duplicate: should not report as conflict"
        printf '      got: %s\n' "$combined_update_out"
    fi

    local combined_status_out
    combined_status_out=$("$ARX" status 2>&1)
    if printf '%s' "$combined_status_out" | grep -qF 'Archived as'; then
        pass "status: conflict+SHA duplicate: shows Archived as"
    else
        fail "status: conflict+SHA duplicate: should show Archived as, not Conflict"
        printf '      got: %s\n' "$combined_status_out"
    fi
    if ! printf '%s' "$combined_status_out" | grep -qF "Conflict"; then
        pass "status: conflict+SHA duplicate: does not show Conflict"
    else
        fail "status: conflict+SHA duplicate: should not show Conflict"
        printf '      got: %s\n' "$combined_status_out"
    fi
}

test_log() {
    section "log"
    reset_archive
    "$ARX" add feature/alpha > /dev/null

    assert_ok    "log: shows history"      "$ARX" log feature/alpha
    assert_ok    "log: passes --oneline"   "$ARX" log feature/alpha --oneline
    assert_ok    "log: passes -n 1"        "$ARX" log feature/alpha -n 1
    assert_out   "log: missing: error"     "not found in archive" "$ARX" log no-such-branch
    assert_fails "log: missing: nonzero"                          "$ARX" log no-such-branch
    assert_out   "log: no arg: usage"      "Usage:"               "$ARX" log
    assert_fails "log: no arg: nonzero"                           "$ARX" log
}

test_checkout() {
    section "checkout"
    reset_archive
    "$ARX" add feature/alpha > /dev/null
    git branch -D feature/alpha  # delete locally so we can restore it

    assert_out   "checkout: restores branch"       "Restored branch: feature/alpha" "$ARX" checkout feature/alpha
    assert_out   "checkout: branch exists: error"  "already exists"                 "$ARX" checkout feature/alpha
    assert_fails "checkout: branch exists: nonzero"                                 "$ARX" checkout feature/alpha
    assert_out   "checkout: missing: error"        "not found in archive"           "$ARX" checkout no-such-branch
    assert_fails "checkout: missing: nonzero"                                       "$ARX" checkout no-such-branch
    assert_out   "checkout: no arg: usage"         "Usage:"                         "$ARX" checkout
    git checkout "$DEFAULT_BRANCH" -q
}

test_prune() {
    section "prune"
    reset_archive
    recreate_branches

    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/beta  > /dev/null

    local out
    out=$("$ARX" prune --force 2>&1)
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

    assert_out "prune: nothing to delete" "No archived branches found" "$ARX" prune --force

    # Currently checked-out branch should be skipped
    recreate_branches
    "$ARX" add fix/gamma > /dev/null
    git checkout fix/gamma -q
    out=$("$ARX" prune --force 2>&1)
    if printf '%s' "$out" | grep -qF "Skipped (currently checked out)"; then
        pass "prune: skips checked-out branch"
    else
        fail "prune: skips checked-out branch"
        printf '      got: %s\n' "$out"
    fi
    git checkout "$DEFAULT_BRANCH" -q

    # --dry-run: shows branch list without deleting
    recreate_branches
    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/beta  > /dev/null
    out=$("$ARX" prune --dry-run 2>&1)
    if printf '%s' "$out" | grep -qF "(dry run — no changes written)"; then
        pass "prune --dry-run: appends dry-run line"
    else
        fail "prune --dry-run: should append dry-run line"
        printf '      got: %s\n' "$out"
    fi
    if printf '%s' "$out" | grep -qF "feature/alpha"; then
        pass "prune --dry-run: lists branch that would be deleted"
    else
        fail "prune --dry-run: should list branch"
        printf '      got: %s\n' "$out"
    fi
    if git rev-parse --verify refs/heads/feature/alpha > /dev/null 2>&1; then
        pass "prune --dry-run: branch still exists locally"
    else
        fail "prune --dry-run: branch should not be deleted"
    fi

    assert_fails "prune: unknown option: nonzero" "$ARX" prune --bogus

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

    assert_ok  "merge: succeeds"         "$ARX" merge "$f1" "$f2" -o "$fo"
    assert_out "merge: alpha in output"  "feature/alpha" cat "$fo"
    assert_out "merge: gamma in output"  "fix/gamma"     cat "$fo"
    assert_out "merge: reports count"    "Merged"        "$ARX" merge "$f1" "$f2" -o "$fo"

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
    out=$("$ARX" merge "$f1" "$f2" -o "$fo" 2>&1) || true
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
    set_storage refs
    assert_out   "merge: requires file storage" "requires file storage" "$ARX" merge "$f1" "$f2" -o "$fo"
    assert_fails "merge: nonzero when refs-only"                        "$ARX" merge "$f1" "$f2" -o "$fo"
    set_storage file
}

test_refs_backend() {
    section "refs backend"
    reset_archive
    set_storage refs

    assert_out "refs add: archives" "Archived: feature/alpha" "$ARX" add feature/alpha

    if git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "refs: ref exists under refs/arx/"
    else
        fail "refs: ref should exist under refs/arx/"
    fi

    assert_out "refs list: shows branch"  "feature/alpha"          "$ARX" list
    assert_out "refs remove: removes"     "Removed: feature/alpha" "$ARX" remove feature/alpha

    if ! git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "refs: ref removed"
    else
        fail "refs: ref should be removed"
    fi

    set_storage file
}

test_both_backend() {
    section "both backend (write fan-out)"
    reset_archive
    set_storage both

    "$ARX" add feature/alpha > /dev/null

    if grep -qF "feature/alpha" .gitarchive 2>/dev/null; then
        pass "both: written to file"
    else
        fail "both: should write to file"
    fi
    if git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "both: written to refs"
    else
        fail "both: should write to refs"
    fi

    "$ARX" remove feature/alpha > /dev/null

    if ! grep -qF "feature/alpha" .gitarchive 2>/dev/null; then
        pass "both: deleted from file"
    else
        fail "both: should delete from file"
    fi
    if ! git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "both: deleted from refs"
    else
        fail "both: should delete from refs"
    fi

    set_storage file
}

test_push_pull() {
    section "push / pull (refs backend)"
    reset_archive
    set_storage refs

    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/beta  > /dev/null

    assert_ok    "push: succeeds"            "$ARX" push
    assert_ok    "push: --dry-run"           "$ARX" push --dry-run
    assert_fails "push: unknown option"      "$ARX" push --bogus

    if git ls-remote "$REMOTE" 'refs/arx/*' | grep -q 'refs/arx/feature/alpha'; then
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
    set_storage refs

    assert_ok "pull: succeeds in fresh clone" "$ARX" pull

    if git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "pull: ref present after pull"
    else
        fail "pull: ref should be present after pull"
    fi

    # pull with both storage → also syncs to .gitarchive
    set_storage both
    "$ARX" pull > /dev/null 2>&1 || true
    if [[ -f .gitarchive ]] && grep -qF "feature/alpha" .gitarchive; then
        pass "pull (both): syncs to .gitarchive"
    else
        fail "pull (both): should sync to .gitarchive"
    fi

    cd "$REPO"
    set_storage file
}

test_sync() {
    section "sync (both backend)"
    reset_archive
    set_storage both

    # File-only drift
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive

    local out
    out=$("$ARX" sync --dry-run 2>&1)
    if printf '%s' "$out" | grep -qF "Synced to refs: feature/alpha"; then
        pass "sync --dry-run: reports file-only entry"
    else
        fail "sync --dry-run: should report file-only"
        printf '      got: %s\n' "$out"
    fi
    if printf '%s' "$out" | grep -qF "(dry run — no changes written)"; then
        pass "sync --dry-run: appends dry-run line"
    else
        fail "sync --dry-run: should append dry-run line"
        printf '      got: %s\n' "$out"
    fi
    if ! git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "sync --dry-run: does not write to refs"
    else
        fail "sync --dry-run: should not write to refs"
    fi

    "$ARX" sync > /dev/null
    if git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "sync: copies file-only entry to refs"
    else
        fail "sync: should copy file-only to refs"
    fi

    # Refs-only drift
    reset_archive
    set_storage both
    git update-ref "refs/arx/feature/beta" "$SHA_BETA"

    out=$("$ARX" sync --dry-run 2>&1)
    if printf '%s' "$out" | grep -qF "Synced to file: feature/beta"; then
        pass "sync --dry-run: reports refs-only entry"
    else
        fail "sync --dry-run: should report refs-only"
        printf '      got: %s\n' "$out"
    fi

    "$ARX" sync > /dev/null
    if [[ -f .gitarchive ]] && grep -qF "feature/beta" .gitarchive; then
        pass "sync: copies refs-only entry to file"
    else
        fail "sync: should copy refs-only to file"
    fi

    # SHA conflict
    reset_archive
    set_storage both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"  # intentionally different

    out=$("$ARX" sync 2>&1) || true
    if printf '%s' "$out" | grep -qF "CONFLICT"; then
        pass "sync: reports SHA conflict"
    else
        fail "sync: should report SHA conflict"
    fi

    # --force-file: refs should be overwritten with file's SHA
    "$ARX" sync --force-file > /dev/null
    local resolved
    resolved=$(git rev-parse refs/arx/feature/alpha)
    if [[ "$resolved" == "$SHA_ALPHA" ]]; then
        pass "sync --force-file: refs updated to file's SHA"
    else
        fail "sync --force-file: wrong SHA (got ${resolved:0:8}, want ${SHA_ALPHA:0:8})"
    fi

    # --force-refs: file should be overwritten with refs' SHA
    reset_archive
    set_storage both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    "$ARX" sync --force-refs > /dev/null
    if grep -qF "$SHA_BETA" .gitarchive; then
        pass "sync --force-refs: file updated to refs' SHA"
    else
        fail "sync --force-refs: file should have refs' SHA"
    fi

    # --dry-run --force-file: shows what would happen without writing
    reset_archive
    set_storage both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    out=$("$ARX" sync --dry-run --force-file 2>&1)
    if printf '%s' "$out" | grep -qF "Resolved (force-file)"; then
        pass "sync --dry-run --force-file: shows resolved message"
    else
        fail "sync --dry-run --force-file: should show resolved message"
        printf '      got: %s\n' "$out"
    fi
    if printf '%s' "$out" | grep -qF "(dry run — no changes written)"; then
        pass "sync --dry-run --force-file: appends dry-run line"
    else
        fail "sync --dry-run --force-file: should append dry-run line"
        printf '      got: %s\n' "$out"
    fi
    # Verify no write happened: refs should still have SHA_BETA
    local still_beta
    still_beta=$(git rev-parse refs/arx/feature/alpha)
    if [[ "$still_beta" == "$SHA_BETA" ]]; then
        pass "sync --dry-run --force-file: does not write"
    else
        fail "sync --dry-run --force-file: should not write"
    fi

    # --dry-run --force-refs: shows what would happen without writing
    reset_archive
    set_storage both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    out=$("$ARX" sync --dry-run --force-refs 2>&1)
    if printf '%s' "$out" | grep -qF "Resolved (force-refs)"; then
        pass "sync --dry-run --force-refs: shows resolved message"
    else
        fail "sync --dry-run --force-refs: should show resolved message"
        printf '      got: %s\n' "$out"
    fi
    if printf '%s' "$out" | grep -qF "(dry run — no changes written)"; then
        pass "sync --dry-run --force-refs: appends dry-run line"
    else
        fail "sync --dry-run --force-refs: should append dry-run line"
        printf '      got: %s\n' "$out"
    fi
    # Verify no write happened: file should still have SHA_ALPHA
    if grep -qF "$SHA_ALPHA" .gitarchive; then
        pass "sync --dry-run --force-refs: does not write"
    else
        fail "sync --dry-run --force-refs: should not write"
    fi

    # sync requires both
    set_storage file
    assert_out   "sync: error when file-only" "requires both storage" "$ARX" sync
    assert_fails "sync: nonzero when file-only"                       "$ARX" sync

    set_storage refs
    assert_out   "sync: error when refs-only" "requires both storage" "$ARX" sync
    assert_fails "sync: nonzero when refs-only"                       "$ARX" sync

    set_storage file
}

test_slashed_branches() {
    section "branch names with slashes"
    reset_archive

    "$ARX" add feature/alpha > /dev/null
    assert_out "slash: in file list" "feature/alpha" "$ARX" list

    set_storage refs
    "$ARX" add feature/alpha > /dev/null
    if git rev-parse --verify refs/arx/feature/alpha > /dev/null 2>&1; then
        pass "slash: correct ref path refs/arx/feature/alpha"
    else
        fail "slash: should be at refs/arx/feature/alpha"
    fi

    set_storage file
}

test_double_add() {
    section "double add (idempotent)"
    reset_archive

    "$ARX" add feature/alpha > /dev/null
    "$ARX" add feature/alpha > /dev/null  # second add — should update, not duplicate

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

    assert_out   "unknown cmd: error message" "unknown command"    "$ARX" bogus
    assert_fails "unknown cmd: nonzero"                            "$ARX" bogus

    local notrepo="$TMPROOT/notrepo"
    mkdir -p "$notrepo"
    assert_out   "not-in-repo: error"   "not inside a git repository" \
        bash -c "cd '$notrepo' && '$ARX' list"
    assert_fails "not-in-repo: nonzero" \
        bash -c "cd '$notrepo' && '$ARX' list"

    set_storage file
    assert_out   "push: requires refs" "requires refs storage" "$ARX" push
    assert_out   "pull: requires refs" "requires refs storage" "$ARX" pull
    assert_out   "sync: requires both" "requires both storage" "$ARX" sync

    set_storage refs
    assert_out   "merge: requires file" "requires file storage" \
        "$ARX" merge /dev/null /dev/null -o /dev/null

    set_storage file
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    printf 'git-arx integration test suite\n'
    printf 'Script: %s\n\n' "$ARX"

    if [[ ! -x "$ARX" ]]; then
        printf 'ERROR: git-arx not found or not executable at %s\n' "$ARX" >&2
        exit 1
    fi

    setup

    test_help
    test_add
    test_remove
    test_rename
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
