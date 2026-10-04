#!/usr/bin/env bash
set -euo pipefail

# test.sh – Integration test suite for git-arx
# Runs ./git-arx directly; no install required.
# Usage: bash test.sh [section...]
#   bash test.sh              # every section
#   bash test.sh prune sync   # only test_prune and test_sync
#
# Each section runs in a private copy of a pristine fixture (a repo and its
# bare remote), so sections are independent of each other and run in
# parallel. Their output is printed in section order.

ARX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-arx"
PASS=0
FAIL=0
TMPROOT=""
SANDBOX=""      # the running section's private directory
REPO=""
REMOTE=""
SHA_ALPHA="" SHA_BETA="" SHA_GAMMA=""
DEFAULT_BRANCH=""
OUT=""          # combined stdout+stderr of the last run
RC=0            # exit status of the last run

PASS_TAG=$'  \033[32mPASS\033[0m  '
FAIL_TAG=$'  \033[31mFAIL\033[0m  '

# Keep the user's global git config out of the fixtures: commit signing would
# sign (or prompt) for every fixture commit, and settings like
# branch.autoSetupMerge or fetch.prune change the very states under test.
export GIT_CONFIG_GLOBAL=/dev/null

SECTIONS=(
    help add remove rename list update sort_tiebreak sort_time log checkout prune merge
    refs_backend both_backend push_pull purge sync file_records slashed_branches
    double_add config_bool config error_cases overwrite_guard
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { printf '%s%s\n' "$PASS_TAG" "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '%s%s\n' "$FAIL_TAG" "$1"; FAIL=$(( FAIL + 1 )); }

section() { printf '\n=== %s ===\n' "$1"; }

# Through bash rather than the shebang: one process instead of two (env, then
# bash) – which adds up on Windows – and no dependence on the executable bit.
arx() { bash "$ARX" "$@"; }

in_dir() { local dir="$1"; shift; (cd "$dir" && "$@"); }   # dir cmd...

# Run a command once, keeping its output and exit status for the checks that
# follow – one invocation serves every assertion about it.
run() { OUT=$("$@" 2>&1) && RC=0 || RC=$?; }   # cmd...

# Assertions on the last run
got() { printf '      got:      %s\n' "$OUT"; }
ok()  { if (( RC == 0 )); then pass "$1"; else fail "$1"; printf '      status:   %d\n' "$RC"; got; fi; }
nok() { if (( RC != 0 )); then pass "$1"; else fail "$1"; got; fi; }

has() {     # label pattern... – output contains every pattern
    local label="$1" pattern
    shift
    for pattern in "$@"; do
        if [[ $OUT != *"$pattern"* ]]; then
            fail "$label"
            printf '      expected: %s\n' "$pattern"
            got
            return 0
        fi
    done
    pass "$label"
}

lacks() {   # label pattern – output does not contain pattern
    if [[ $OUT != *"$2"* ]]; then
        pass "$1"
    else
        fail "$1"
        printf '      unexpected: %s\n' "$2"
        got
    fi
}

# One-shot forms: run, then a single assertion
assert_ok()    { local label="$1"; shift; run "$@"; ok "$label"; }                            # label cmd...
assert_fails() { local label="$1"; shift; run "$@"; nok "$label"; }                           # label cmd...
assert_out()   { local label="$1" pattern="$2"; shift 2; run "$@"; has "$label" "$pattern"; } # label pattern cmd...

# Assert on state rather than output: pass if cmd succeeds – or, after "!",
# if it fails. cmd's own output is discarded.
check() {   # label [!] cmd...
    local label="$1" want=0 rc=0
    shift
    if [[ $1 == '!' ]]; then want=1; shift; fi
    "$@" > /dev/null 2>&1 || rc=1
    if (( rc == want )); then pass "$label"; else fail "$label"; fi
}

# State predicates for check
ref_exists() { git show-ref --verify -q "$@"; }                    # ref... – all exist
ref_is()     { [[ $(git rev-parse -q --verify "$1") == "$2" ]]; }  # ref sha
remote_has() { [[ -n $(git ls-remote "$REMOTE" "$1") ]]; }         # ref-pattern

file_has() {   # file pattern... – file exists and contains every pattern
    local content="" pattern
    [[ -f $1 ]] || return 1
    IFS= read -r -d '' content < "$1" || true
    shift
    for pattern in "$@"; do
        [[ $content == *"$pattern"* ]] || return 1
    done
}

set_storage() {
    case "$1" in
        file) git config arx.storefile true  && git config arx.storerefs false ;;
        refs) git config arx.storerefs true  && git config arx.storefile false ;;
        both) git config arx.storerefs true  && git config arx.storefile true  ;;
    esac
}

# Empty the archive in both backends, then select storage (default: file).
reset_archive() {   # [file|refs|both]
    cd "$REPO"
    rm -f .gitarchive
    local refs
    refs=$(git for-each-ref --format='delete %(refname)' 'refs/arx/')
    if [[ -n $refs ]]; then git update-ref --stdin <<< "$refs"; fi
    set_storage "${1:-file}"
}

# Put branches in the "remote branch was deleted" state: an upstream is
# configured but its tracking ref does not exist – what the repo looks like
# after the branch is deleted on the remote and `git fetch --prune` runs.
set_gone_upstream() {   # branch...
    local b
    for b in "$@"; do
        git config "branch.$b.remote" origin
        git config "branch.$b.merge" "refs/heads/$b"
    done
}

# Put the fixture branches back at their fixture commits, recreating any that
# a test deleted.
reset_branches() {
    git update-ref --stdin <<EOF
update refs/heads/feature/alpha $SHA_ALPHA
update refs/heads/feature/beta $SHA_BETA
update refs/heads/fix/gamma $SHA_GAMMA
EOF
}

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

# Built once; every section starts from its own copy (see run_section).
make_fixture() {
    local dir="$TMPROOT/fixture"
    git init --bare -q "$dir/remote.git"
    git clone -q "$dir/remote.git" "$dir/repo" 2> /dev/null   # "cloned an empty repository"
    cd "$dir/repo"
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

# Run test_<name> in a private copy of the fixture: REPO is the working repo,
# REMOTE its origin, SANDBOX the directory for anything else the test creates.
run_section() {   # name
    SANDBOX="$TMPROOT/$1"
    REPO="$SANDBOX/repo"
    REMOTE="$SANDBOX/remote.git"
    cp -R "$TMPROOT/fixture" "$SANDBOX"
    cd "$REPO"
    git config remote.origin.url "$REMOTE"
    "test_$1"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_help() {
    section "help"
    run arx help
    ok  "help exits 0"
    has "help shows USAGE"    "USAGE"
    has "help shows COMMANDS" "COMMANDS"
    assert_ok "-h exits 0" arx -h

    # Every command's -h, --help and "help <cmd>" print its help: the row the
    # overview shows, a blank line, then details. Run outside any repo – help
    # must not need one.
    local overview cmd summary
    overview=$(arx help)
    mkdir "$SANDBOX/norepo"
    for cmd in add remove rename status update list log checkout prune merge \
               push fetch pull purge sync config upgrade; do
        run in_dir "$SANDBOX/norepo" arx "$cmd" -h
        ok  "$cmd -h: exits 0 outside a repo"
        has "$cmd -h: has details" $'\n\n'
        summary="${OUT%%$'\n\n'*}"
        if [[ "$summary" == "  $cmd"[\ \|]* && "$overview" == *"$summary"* ]]; then
            pass "$cmd -h: starts with its overview row"
        else
            fail "$cmd -h: starts with its overview row"; got
        fi
        assert_out "$cmd --help" "$summary" in_dir "$SANDBOX/norepo" arx "$cmd" --help
        assert_out "help $cmd"   "$summary" in_dir "$SANDBOX/norepo" arx help "$cmd"
    done

    assert_out "help rm: alias resolves" "remove|rm <branch>" arx help rm
    assert_out "ls -h: alias resolves"   "list|ls"            arx ls -h

    run arx help nope
    has "help <unknown>: error" 'unknown command "nope"'
    nok "help <unknown>: nonzero"

    # Only the first argument asks for help: later ones go to the command
    run arx log feature/alpha -h
    lacks "log <branch> -h: passed to git log" "Runs git log on the archived"
}

test_add() {
    section "add"

    assert_out "add: archives a branch" "Archived: feature/alpha" arx add feature/alpha
    assert_out "add: shows short SHA"   "at "                     arx add feature/beta

    run arx add no-such-branch
    has "add: nonexistent: error msg" "not found in local"
    nok "add: nonexistent: nonzero"

    run arx add
    has "add: no arg: usage" "Usage:"
    nok "add: no arg: nonzero"

    # same SHA: idempotent
    run arx add feature/alpha
    has "add: same SHA: already archived" "Already archived"
    ok  "add: same SHA: exits 0"

    # conflict: different SHA already in archive
    reset_archive
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive

    run arx add feature/alpha
    has "add: conflict: error message" "conflict"
    has "add: conflict: shows old SHA" "${SHA_BETA:0:8}"
    has "add: conflict: hints --force" "force"
    nok "add: conflict: nonzero"

    # --force: overwrites conflict
    assert_out "add: --force: archived" "Archived" arx add feature/alpha --force
    check "add: --force: stored correct SHA" \
        [ "$(awk '$1 == "feature/alpha" { print $2 }' .gitarchive)" = "$SHA_ALPHA" ]

    # archive name: archive under a different name
    reset_archive
    assert_out "add: archive name: archived with archive name label" "Archived: feature/alpha (as alpha-saved)" \
        arx add feature/alpha alpha-saved
    assert_out "add: archive name: name in archive" "alpha-saved" arx list

    # archive name conflict
    run arx add feature/beta alpha-saved
    has "add: archive name conflict: error" "conflict"
    nok "add: archive name conflict: nonzero"

    # archive names must be valid branch names – a space would split the
    # file record, and the name becomes a ref and a branch on checkout
    run arx add feature/beta 'my old beta'
    has   "add: invalid archive name: error" "not a valid archive name"
    nok   "add: invalid archive name: nonzero"
    check "add: invalid archive name: nothing written" ! file_has .gitarchive "my old beta"
    assert_fails "add: archive name with leading dash: nonzero" arx add feature/beta -beta
    set_storage both
    assert_fails "add (both): invalid archive name: nonzero" arx add feature/beta 'bad name2'
    check "add (both): invalid archive name: file untouched" ! file_has .gitarchive "bad"
    set_storage file

    # SHA already archived under a different name: note shown, still archives
    reset_archive
    arx add feature/alpha alpha-saved > /dev/null
    run arx add feature/alpha
    has "add: SHA duplicate: shows note"                "Note:"
    has "add: SHA duplicate: note names existing entry" "alpha-saved"
    has "add: SHA duplicate: still archives"            "Archived: feature/alpha"
}

test_remove() {
    section "remove"
    arx add feature/alpha > /dev/null

    assert_out "remove: removes branch" "Removed: feature/alpha" arx remove feature/alpha

    run arx remove feature/alpha
    has "remove: missing: error msg" "not found in archive"
    nok "remove: missing: nonzero"

    run arx remove
    has "remove: no arg: usage" "Usage:"
    nok "remove: no arg: nonzero"

    # header-less archive whose only entry is being removed: the filtered
    # tmpfile is empty, but the replace must still work and the refs backend
    # delete must still run afterwards
    reset_archive both
    printf 'feature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref refs/arx/feature/alpha "$SHA_ALPHA"
    assert_ok "remove: header-less single-entry archive succeeds" arx remove feature/alpha
    check "remove: archive file survives emptying" test -f .gitarchive
    check "remove: refs entry also deleted" ! ref_exists refs/arx/feature/alpha
}

test_list() {
    section "list"

    assert_out "list: empty archive message" "No archived branches" arx list

    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null
    arx add fix/gamma     > /dev/null

    run arx list
    has "list: shows header"          "BRANCH"
    has "list: shows archived branch" "feature/alpha"
    has "list: shows all branches"    "fix/gamma"

    run arx list --author
    has "list: --author shows header" "AUTHOR"
    has "list: --author shows name"   "Test"

    assert_ok    "list: --sort=name"                arx list --sort=name
    assert_ok    "list: --sort=date"                arx list --sort=date
    assert_ok    "list: --order=asc"                arx list --order=asc
    assert_ok    "list: --order=desc"               arx list --order=desc
    assert_ok    "list: --storage=file"             arx list --storage=file
    assert_fails "list: --storage=refs (file-only)" arx list --storage=refs
    assert_out   "list: --storage=bogus: error" "invalid --storage value" arx list --storage=bogus

    run arx list --storage=both
    has "list: --storage=both: error" "invalid --storage value"
    nok "list: --storage=both: nonzero"

    assert_fails "list: unknown option: nonzero" arx list --bogus
}

test_rename() {
    section "rename"
    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null

    assert_out "rename: succeeds" "Renamed: feature/alpha -> alpha-old" arx rename feature/alpha alpha-old

    run arx rename
    has "rename: no arg: usage" "Usage:"
    nok "rename: no arg: nonzero"

    run arx rename no-such x
    has "rename: missing: error" "not found in archive"
    nok "rename: missing: nonzero"

    run arx rename feature/beta feature/beta
    has "rename: same name: error" "identical"
    nok "rename: same name: nonzero"

    run arx rename feature/beta alpha-old
    has "rename: target exists: error" "already exists"
    nok "rename: target exists: nonzero"

    run arx rename feature/beta 'beta two'
    has   "rename: invalid new name: error" "not a valid archive name"
    nok   "rename: invalid new name: nonzero"
    check "rename: invalid new name: entry unchanged" file_has .gitarchive "feature/beta "

    run arx list
    has   "rename: new name appears in list" "alpha-old"
    lacks "rename: old name gone from list"  "feature/alpha "

    # refs backend
    reset_archive refs
    arx add feature/alpha > /dev/null
    arx rename feature/alpha alpha-renamed > /dev/null
    check "rename refs: new ref exists"   ref_exists refs/arx/alpha-renamed
    check "rename refs: old ref gone"   ! ref_exists refs/arx/feature/alpha
}

test_update() {
    section "update"

    # --- Never-pushed branches (no upstream configured) ---
    # status --all shows them with "Local only"; status (no --all) hides them
    run arx status --all
    has "status --all: shows never-pushed branch" "feature/alpha"
    has "status --all: shows Local only for never-pushed unarchived branch" "Local only"
    has "status --all: shows STATUS column header" "STATUS"
    has "status --all: shows SHA column header" "SHA"
    check "status --all: does not write archive" ! test -f .gitarchive
    has "status --all: shows author" "Test"

    run arx status
    lacks "status: hides never-pushed branches without --all" "feature/alpha"

    # update skips never-pushed branches
    run arx update
    lacks "update: skips never-pushed branch" "Archived: feature/alpha"
    has   "update: reports 0 for never-pushed only" "Archived 0 branch(es)"

    # --- Simulate remote-deleted branches ---
    set_gone_upstream feature/alpha feature/beta fix/gamma
    reset_archive

    # status (no --all): shows remote-deleted branches with "Not archived"
    run arx status
    has "status: shows remote-deleted branch" "feature/alpha"
    has "status: shows STATUS column header" "STATUS"
    has "status: shows SHA column header" "SHA"
    has "status: shows Not archived for unarchived remote-deleted branch" "Not archived"
    check "status: does not write archive" ! test -f .gitarchive
    has "status: shows author" "Test"

    run arx update
    has "update: archives remote-deleted branch" "Archived: feature/alpha"
    has "update: reports correct count" "Archived 3 branch(es)"

    # After archiving, status should show "Archived" for those branches
    run arx status
    has "status: shows Archived for already-archived branch" "Archived"
    has "status: shows author (2nd call)" "Test"
    assert_ok    "status: --sort=name"             arx status --sort=name
    assert_ok    "status: --sort=date"             arx status --sort=date
    assert_ok    "status: --order=asc"             arx status --order=asc
    assert_ok    "status: --order=desc"            arx status --order=desc
    assert_fails "status: unknown option: nonzero" arx status --bogus

    # Restore the tracking ref for feature/alpha to simulate a live upstream
    git update-ref "refs/remotes/origin/feature/alpha" "$SHA_ALPHA"
    reset_archive
    run arx update
    lacks "update: skips branch with live upstream" "Archived: feature/alpha"
    # Remove it again to restore remote-deleted state
    git update-ref -d refs/remotes/origin/feature/alpha

    # Branch whose upstream is a local branch (branch.<name>.remote=.) counts
    # as a live upstream – update must skip it, status must not list it
    git branch --track local-tracker feature/beta > /dev/null 2>&1
    reset_archive
    run arx update
    lacks "update: skips branch tracking a local branch" "Archived: local-tracker"
    run arx status --all
    lacks "status --all: hides branch tracking a local branch" "local-tracker"
    git branch -D local-tracker > /dev/null 2>&1

    # --dry-run: shows same output without writing
    reset_archive
    run arx update --dry-run
    has "update --dry-run: shows archived message" "Archived: feature/alpha"
    has "update --dry-run: appends dry-run line" "(dry run – no changes written)"
    check "update --dry-run: does not write archive" ! test -f .gitarchive

    assert_fails "update: unknown option: nonzero" arx update --bogus

    # conflict: already archived with a different SHA
    reset_archive
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive

    run arx update
    has "update: reports conflict for different SHA" "Conflict: feature/alpha"
    has "update: reports conflict count in summary" "1 conflict(s) skipped"
    # file should still have the old (conflicting) SHA
    check "update: does not overwrite conflict without --force" file_has .gitarchive "$SHA_BETA"

    # --force: overwrites conflicts
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_BETA" > .gitarchive
    run arx update --force
    has "update --force: overwrites conflict" "Updated: feature/alpha"
    check "update --force: stored correct SHA" file_has .gitarchive "$SHA_ALPHA"

    # already up to date: silently skipped
    reset_archive
    arx add feature/alpha > /dev/null
    run arx update
    lacks "update: silently skips already up-to-date branch" "feature/alpha"

    # SHA already archived under a different name: skipped with note
    reset_archive
    arx add feature/alpha alpha-saved > /dev/null
    run arx update
    has "update: SHA duplicate: reports already safe" "Already safe: feature/alpha"
    has "update: SHA duplicate: names the existing entry" "alpha-saved"
    has "update: SHA duplicate: summary notes count" "already safe (SHA archived under different name)"
    check "update: SHA duplicate: not archived under natural name" ! file_has .gitarchive "feature/alpha "

    # status: shows "Archived as" for SHA archived under different name
    run arx status
    has "status: shows Archived as for SHA archived under different name" "Archived as"
    has "status: Archived as names the existing entry" "alpha-saved"

    # combined: stale entry for branch (different SHA) AND current SHA archived elsewhere
    # feature/alpha is at SHA_ALPHA; archive has feature/alpha->SHA_BETA (old) and alpha-saved->SHA_ALPHA
    printf '# git-arx archive\nalpha-saved %s 2025-01-01T00:00:00+00:00\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' \
        "$SHA_ALPHA" "$SHA_BETA" > .gitarchive

    run arx update
    has   "update: conflict+SHA duplicate: reports already safe" "Already safe: feature/alpha"
    lacks "update: conflict+SHA duplicate: does not report as conflict" "Conflict: feature/alpha"

    run arx status
    has   "status: conflict+SHA duplicate: shows Archived as" "Archived as"
    lacks "status: conflict+SHA duplicate: does not show Conflict" "Conflict"
}

test_sort_tiebreak() {
    section "sort tiebreaker"

    # Two branches, same commit date, with author order contradicting name
    # order: the documented tiebreaker for --sort=date is the branch name,
    # not whatever column happens to follow the date.
    local sha_x sha_y
    sha_x=$(GIT_AUTHOR_NAME="Zed" GIT_AUTHOR_EMAIL="z@example.com" GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00" \
        git commit-tree -m "tie-x" "HEAD^{tree}")
    sha_y=$(GIT_AUTHOR_NAME="Ann" GIT_AUTHOR_EMAIL="a@example.com" GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00" \
        git commit-tree -m "tie-y" "HEAD^{tree}")
    git branch aaa-tie "$sha_x"   # author Zed
    git branch zzz-tie "$sha_y"   # author Ann

    run arx status --all --sort=date --order=asc
    if [[ $OUT == *aaa-tie*zzz-tie* ]]; then
        pass "status --sort=date: equal dates tiebreak by branch name"
    else
        fail "status --sort=date: equal dates tiebreak by branch name"
        got
    fi
}

test_sort_time() {
    section "date sorting across UTC offsets"

    # tokyo happened at 01:00 UTC, london at 02:00 UTC – but as text,
    # tokyo's local 10:00 sorts after london's 02:00. --sort=date must order
    # by when they happened.
    printf '# git-arx archive\nlondon %s 2025-06-01T02:00:00+00:00\ntokyo %s 2025-06-01T10:00:00+09:00\n' \
        "$SHA_ALPHA" "$SHA_BETA" > .gitarchive
    run arx list --sort=date --order=asc
    if [[ $OUT == *tokyo*london* ]]; then
        pass "list --sort=date: orders by actual time across offsets"
    else
        fail "list --sort=date: orders by actual time across offsets"
        got
    fi

    local sha_t sha_l
    sha_t=$(GIT_AUTHOR_DATE="2025-06-01T10:00:00+09:00" git commit-tree -m "tokyo" "HEAD^{tree}")
    sha_l=$(GIT_AUTHOR_DATE="2025-06-01T02:00:00+00:00" git commit-tree -m "london" "HEAD^{tree}")
    git branch tz-tokyo "$sha_t"
    git branch tz-london "$sha_l"
    run arx status --all --sort=date --order=asc
    if [[ $OUT == *tz-tokyo*tz-london* ]]; then
        pass "status --sort=date: orders by actual time across offsets"
    else
        fail "status --sort=date: orders by actual time across offsets"
        got
    fi
}

test_log() {
    section "log"
    arx add feature/alpha > /dev/null

    assert_ok "log: shows history"    arx log feature/alpha
    assert_ok "log: passes --oneline" arx log feature/alpha --oneline
    assert_ok "log: passes -n 1"      arx log feature/alpha -n 1

    run arx log no-such-branch
    has "log: missing: error" "not found in archive"
    nok "log: missing: nonzero"

    run arx log
    has "log: no arg: usage" "Usage:"
    nok "log: no arg: nonzero"
}

test_checkout() {
    section "checkout"
    arx add feature/alpha > /dev/null
    git branch -D -q feature/alpha  # delete locally so we can restore it

    assert_out "checkout: restores branch" "Restored branch: feature/alpha" arx checkout feature/alpha

    run arx checkout feature/alpha
    has "checkout: branch exists: error" "already exists"
    nok "checkout: branch exists: nonzero"

    run arx checkout no-such-branch
    has "checkout: missing: error" "not found in archive"
    nok "checkout: missing: nonzero"

    assert_out "checkout: no arg: usage" "Usage:" arx checkout
}

test_prune() {
    section "prune"

    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null

    run arx prune --force
    has "prune: deletes archived branches with --force" "Deleted 2 branch(es)"
    has "prune: prints per-branch deleted lines" "Deleted branch feature/alpha" "Deleted branch feature/beta"
    check "prune: feature/alpha is deleted locally" ! ref_exists refs/heads/feature/alpha

    assert_out "prune: nothing to delete" "No archived branches found" arx prune --force

    # Currently checked-out branch should be skipped
    reset_branches
    arx add fix/gamma > /dev/null
    git checkout fix/gamma -q
    run arx prune --force
    has "prune: skips checked-out branch" "Skipped (currently checked out)"
    git checkout "$DEFAULT_BRANCH" -q

    # --dry-run: shows branch list without deleting
    reset_branches
    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null
    run arx prune --dry-run
    has "prune --dry-run: appends dry-run line" "(dry run – no changes written)"
    has "prune --dry-run: lists branch that would be deleted" "feature/alpha"
    check "prune --dry-run: branch still exists locally" ref_exists refs/heads/feature/alpha

    # SHA archived under a different name, remote branch gone – still safe to
    # delete, but the name change is surfaced so it is visible before
    # confirming.
    reset_archive
    reset_branches
    set_gone_upstream feature/alpha
    arx add feature/alpha alpha-renamed > /dev/null
    run arx prune --dry-run
    has "prune: labels branch archived under a different name" 'feature/alpha (archived as "alpha-renamed")'
    run arx prune --force
    check "prune: deletes branch archived under a different name" ! ref_exists refs/heads/feature/alpha

    # Name archived at a different SHA – the current commit is in no archive
    # entry, so deleting would lose it. Must be skipped as a conflict.
    reset_archive
    reset_branches
    arx add feature/beta > /dev/null
    git checkout feature/beta -q
    git commit --allow-empty -m "beta moved" -q
    git checkout "$DEFAULT_BRANCH" -q

    run arx prune --force
    has "prune: reports conflict for branch archived at a different SHA" "Skipped (archived at a different SHA"
    check "prune: does not delete conflicting branch" ref_exists refs/heads/feature/beta
    nok "prune: conflict exits nonzero"
    run arx prune --dry-run
    nok "prune --dry-run: conflict exits nonzero"
    has "prune --dry-run: conflicts-only run still prints dry-run marker" "(dry run – no changes written)"

    # A branch with a live remote is out of prune's scope even when its name
    # is in the archive at an older SHA: its commits are on the remote, so it
    # is neither deleted nor reported as a conflict.
    reset_archive
    reset_branches
    arx add feature/alpha > /dev/null
    git branch -f feature/alpha "$SHA_BETA"
    git update-ref refs/remotes/origin/feature/alpha "$SHA_BETA"
    git branch --set-upstream-to=origin/feature/alpha feature/alpha > /dev/null 2>&1
    run arx prune --force
    lacks "prune: branch with a live remote is not a conflict" "archived at a different SHA"
    ok    "prune: live-remote branch exits 0"
    git branch --unset-upstream feature/alpha > /dev/null 2>&1
    git update-ref -d refs/remotes/origin/feature/alpha

    # A branch that merely shares a tip with an archived branch – the default
    # branch after a fast-forward merge, say – was never archived itself and
    # must survive.
    reset_archive
    reset_branches
    git branch shares-tip feature/alpha
    arx add feature/alpha > /dev/null
    run arx prune --force
    check "prune: keeps unarchived branch sharing a tip with an archived one" ref_exists refs/heads/shares-tip
    git branch -D shares-tip > /dev/null 2>&1

    # Checked-out branch that has moved past its archived SHA: reported as the
    # checked-out skip, not as a conflict, and still exits 0.
    reset_archive
    reset_branches
    arx add fix/gamma > /dev/null
    git checkout fix/gamma -q
    git commit --allow-empty -m "gamma moved" -q
    run arx prune --force
    if [[ $OUT == *"Skipped (currently checked out)"* && $OUT != *"archived at a different SHA"* ]]; then
        pass "prune: moved checked-out branch is skipped, not a conflict"
    else
        fail "prune: moved checked-out branch is skipped, not a conflict"
        got
    fi
    ok "prune: moved checked-out branch exits 0"
    git checkout "$DEFAULT_BRANCH" -q

    # Name archived at a stale SHA while the *current* commit is archived
    # under another name: the commit is safe, so this is a delete, not a
    # conflict – the same call `status` makes.
    reset_archive
    reset_branches
    arx add feature/alpha > /dev/null
    git branch -f feature/alpha "$SHA_BETA"
    arx add feature/alpha beta-copy > /dev/null
    run arx prune --dry-run
    has "prune: stale name whose commit is archived elsewhere is a delete" 'feature/alpha (archived as "beta-copy")'
    ok  "prune: stale name whose commit is archived elsewhere exits 0"
    git branch -f feature/alpha "$SHA_ALPHA"

    # A tag sharing a branch's name makes the shortened refname ambiguous
    # ("heads/ambiguous"); every branch loop must use the plain branch name.
    reset_archive
    git checkout -qb ambiguous
    git commit --allow-empty -m "ambiguous" -q
    git checkout -q "$DEFAULT_BRANCH"
    git tag ambiguous refs/heads/ambiguous
    set_gone_upstream ambiguous

    run arx update
    if [[ $OUT == *"Archived: ambiguous"* && $OUT != *"heads/ambiguous"* ]]; then
        pass "update: archives tag-shadowed branch under its plain name"
    else
        fail "update: archives tag-shadowed branch under its plain name"
        got
    fi
    run arx status --all
    lacks "status: shows tag-shadowed branch under its plain name" "heads/ambiguous"
    run arx prune --force
    check "prune: deletes branch whose name is also a tag" ! ref_exists refs/heads/ambiguous

    # A branch checked out in another worktree can't be deleted either – it
    # must be skipped like the current branch, not break the batch delete
    reset_archive
    reset_branches
    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null
    git worktree add -q "$SANDBOX/wt" feature/beta
    run arx prune --force
    ok    "prune: branch in another worktree: exits 0"
    has   "prune: branch in another worktree: skipped and located" "Skipped (currently checked out)" "feature/beta (in "
    check "prune: branch in another worktree: kept" ref_exists refs/heads/feature/beta
    check "prune: rest of the batch still deleted" ! ref_exists refs/heads/feature/alpha

    assert_fails "prune: unknown option: nonzero" arx prune --bogus
}

test_merge() {
    section "merge"

    local f1="$SANDBOX/a1.txt" f2="$SANDBOX/a2.txt" fo="$SANDBOX/out.txt"

    printf '# archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\nfeature/beta %s 2025-01-02T00:00:00+00:00\n' \
        "$SHA_ALPHA" "$SHA_BETA" > "$f1"
    printf '# archive\nfeature/beta %s 2025-01-02T00:00:00+00:00\nfix/gamma %s 2025-01-03T00:00:00+00:00\n' \
        "$SHA_BETA" "$SHA_GAMMA" > "$f2"

    run arx merge "$f1" "$f2" -o "$fo"
    ok    "merge: succeeds"
    check "merge: alpha in output" file_has "$fo" "feature/alpha"
    check "merge: gamma in output" file_has "$fo" "fix/gamma"
    has   "merge: reports count" "Merged"
    check "merge: deduplicates identical entries" [ "$(grep -c '^feature/beta ' "$fo" 2> /dev/null)" = 1 ]

    # A last line without a trailing newline is still an entry
    printf '# archive\nfix/gamma %s 2025-01-03T00:00:00+00:00' "$SHA_GAMMA" > "$f2"
    run arx merge "$f1" "$f2" -o "$fo"
    check "merge: keeps a last line without trailing newline" file_has "$fo" "fix/gamma"

    # SHA conflict: f2 has feature/alpha with a different SHA
    printf '# archive\nfeature/alpha %s 2025-01-04T00:00:00+00:00\n' "$SHA_BETA" > "$f2"
    run arx merge "$f1" "$f2" -o "$fo"
    has   "merge: reports SHA conflict" "CONFLICT"
    nok   "merge: conflict exits nonzero"
    check "merge: conflict entry excluded from output" ! file_has "$fo" "feature/alpha"

    # Wrong backend
    set_storage refs
    run arx merge "$f1" "$f2" -o "$fo"
    has "merge: requires file storage" "requires file storage"
    nok "merge: nonzero when refs-only"
}

test_refs_backend() {
    section "refs backend"
    set_storage refs

    assert_out "refs add: archives" "Archived: feature/alpha" arx add feature/alpha
    check "refs: ref exists under refs/arx/" ref_exists refs/arx/feature/alpha

    assert_out "refs list: shows branch" "feature/alpha"          arx list
    assert_out "refs remove: removes"    "Removed: feature/alpha" arx remove feature/alpha
    check "refs: ref removed" ! ref_exists refs/arx/feature/alpha

    # refs backend must report the author date (what the file backend stores),
    # not the committer date – these differ after rebase/amend/cherry-pick
    local dated_sha
    dated_sha=$(GIT_AUTHOR_DATE="2020-01-02T03:04:05+00:00" GIT_COMMITTER_DATE="2021-06-07T08:09:10+00:00" \
        git commit-tree -m "dated" "HEAD^{tree}")
    git branch dated-branch "$dated_sha"
    arx add dated-branch > /dev/null
    run arx list
    has "refs list: shows author date, not committer date" "2020-01-02"
    # DATE column renders date and time to the second, offset stripped
    has "list: DATE shows time to the second" "2020-01-02 03:04:05"
    assert_out "status: DATE shows time to the second" "2020-01-02 03:04:05" arx status --all
}

test_both_backend() {
    section "both backend (write fan-out)"
    set_storage both

    arx add feature/alpha > /dev/null
    check "both: written to file" file_has .gitarchive "feature/alpha"
    check "both: written to refs" ref_exists refs/arx/feature/alpha

    arx remove feature/alpha > /dev/null
    check "both: deleted from file" ! file_has .gitarchive "feature/alpha"
    check "both: deleted from refs" ! ref_exists refs/arx/feature/alpha

    # update flushes all entries in one bulk write per backend – verify the
    # batch lands in both the file and refs/arx/*
    set_gone_upstream feature/beta fix/gamma
    arx update > /dev/null
    check "both: update bulk-writes all branches to file" file_has .gitarchive "feature/beta" "fix/gamma"
    check "both: update bulk-writes all branches to refs" ref_exists refs/arx/feature/beta refs/arx/fix/gamma

    # Refs are written first: when git refuses the refs update – here
    # refs/arx/collide/next can't coexist with the archived refs/arx/collide –
    # nothing from the batch may reach the file, or prune would take a
    # file-only entry as proof the branch is safe to delete
    reset_archive both
    arx add feature/alpha collide > /dev/null
    git branch collide/next "$(git commit-tree -m next "HEAD^{tree}")"
    set_gone_upstream collide/next
    run arx update
    nok "both: failed refs write: update exits nonzero"
    has "both: failed refs write: says nothing was archived" "nothing was archived"
    check "both: failed refs write: colliding entry not in file"      ! file_has .gitarchive "collide/next"
    check "both: failed refs write: rest of the batch not in file"    ! file_has .gitarchive "feature/beta"

    # prune deletes on refs alone: an entry only the file holds (drift, or a
    # teammate's committed archive) is reported until sync backs it with a ref
    reset_archive both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    run arx prune --force
    nok   "prune (both): file-only entry exits nonzero"
    has   "prune (both): reports the file-only entry" "archived in the file only" "feature/alpha"
    check "prune (both): keeps the branch" ref_exists refs/heads/feature/alpha
    arx sync > /dev/null
    arx prune --force > /dev/null
    check "prune (both): deletes it once sync wrote the ref" ! ref_exists refs/heads/feature/alpha
}

test_push_pull() {
    section "push / pull (refs backend)"
    set_storage refs

    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null

    assert_ok    "push: succeeds"       arx push
    assert_ok    "push: --dry-run"      arx push --dry-run
    assert_fails "push: unknown option" arx push --bogus
    check "push: ref visible on remote" remote_has refs/arx/feature/alpha

    # fetch – after push both branches should be up to date
    assert_out   "fetch: shows up to date after push" "up to date" arx fetch
    assert_fails "fetch: unknown option"                           arx fetch --bogus

    # Locally re-archive one branch at a different SHA: fetch shows it as
    # "ahead", and pull must keep it – the remote's copy is the older one,
    # and refs/arx/* keeps no reflog to recover an overwritten commit from
    git update-ref refs/arx/feature/alpha "$SHA_BETA"
    assert_out "fetch: shows ahead when re-archived locally" "ahead" arx fetch
    assert_ok  "pull: succeeds with a local re-archive"           arx pull
    check "pull: keeps an entry re-archived locally" ref_is refs/arx/feature/alpha "$SHA_BETA"
    git update-ref refs/arx/feature/alpha "$SHA_ALPHA"  # restore

    # Fresh clone – test pull
    local repo2="$SANDBOX/repo2"
    git clone "$REMOTE" "$repo2" -q
    cd "$repo2"
    git config user.email "test@example.com"
    git config user.name "Test"
    git config fetch.prune false  # don't let machine-global config mask the explicit --prune in arx pull
    set_storage refs

    assert_out "fetch: shows new in fresh clone" "new" arx fetch
    assert_ok  "pull: succeeds in fresh clone"         arx pull
    check "pull: ref present after pull" ref_exists refs/arx/feature/alpha

    # pull with both storage → also syncs to .gitarchive
    set_storage both
    arx pull > /dev/null 2>&1 || true
    check "pull (both): syncs to .gitarchive" file_has .gitarchive "feature/alpha"

    # pull (both): file-only entries must survive the sync
    printf 'file-only-entry %s 2025-01-01T00:00:00+00:00\n' "$SHA_GAMMA" >> .gitarchive
    arx pull > /dev/null 2>&1 || true
    check "pull (both): preserves file-only entries" file_has .gitarchive "file-only-entry" "feature/alpha"

    cd "$REPO"   # still refs storage

    # push --delete: remove a single ref from remote
    arx push > /dev/null  # ensure both refs are on remote
    assert_ok "push --delete: succeeds" arx push --delete feature/alpha
    check "push --delete: ref removed from remote"         ! remote_has refs/arx/feature/alpha
    check "push --delete: remote tracking ref cleaned up"  ! ref_exists refs/arx-remote/origin/feature/alpha
    assert_ok    "push --delete: --dry-run succeeds"  arx push --dry-run --delete feature/beta
    assert_fails "push --delete: missing branch name" arx push --delete

    # push --prune: delete remote refs that no longer exist locally
    arx push > /dev/null  # re-push feature/alpha and feature/beta
    arx remove feature/beta > /dev/null
    assert_ok "push --prune: succeeds" arx push --prune
    check "push --prune: removed ref from remote"            ! remote_has refs/arx/feature/beta
    check "push --prune: kept ref that still exists locally"   remote_has refs/arx/feature/alpha
    assert_ok "push --prune: --dry-run succeeds" arx push --prune --dry-run

    # pull after remote force-push: non-fast-forward tracking update must succeed
    local sha_initial
    sha_initial=$(git rev-parse "refs/heads/$DEFAULT_BRANCH")
    git update-ref refs/arx/feature/alpha "$sha_initial"  # ancestor of SHA_ALPHA → non-FF
    arx push --force > /dev/null
    cd "$repo2"
    set_storage refs
    assert_out "fetch: shows changed when only the remote moved" "changed" arx fetch
    assert_ok "pull: succeeds after remote force-push" arx pull
    check "pull: local ref updated to force-pushed SHA" ref_is refs/arx/feature/alpha "$sha_initial"

    # Both sides re-archived since the last sync: neither copy may be lost,
    # so pull keeps the local one and says so
    git update-ref refs/arx/feature/alpha "$SHA_BETA"    # an object repo2 has
    cd "$REPO"
    git update-ref refs/arx/feature/alpha "$SHA_GAMMA"
    arx push --force > /dev/null
    cd "$repo2"
    assert_out "fetch: shows conflict when both sides changed" "conflict" arx fetch
    run arx pull
    nok "pull: both sides changed: nonzero"
    has "pull: both sides changed: reports the kept entry" "Kept local" "feature/alpha"
    check "pull: both sides changed: keeps the local copy" ref_is refs/arx/feature/alpha "$SHA_BETA"

    # pull prunes tracking refs for refs deleted on the remote
    # (feature/beta was removed from the remote by push --prune above,
    # but repo2 still has its tracking ref from the earlier pull)
    check "pull: prunes tracking ref for remotely deleted ref" ! ref_exists refs/arx-remote/origin/feature/beta

    # A push that is partly rejected – feature/alpha moved back to an
    # ancestor of the remote's copy, so not a fast-forward – must still
    # record the refs the remote did accept
    cd "$REPO"
    git update-ref refs/arx/feature/alpha "$SHA_BETA"
    git update-ref refs/arx/newone "$SHA_ALPHA"
    run arx push
    nok   "push: partial rejection exits nonzero"
    has   "push: partial rejection reports both" "Rejected: feature/alpha" "Pushed: newone (new)"
    check "push: accepted ref tracked despite a rejection" ref_is refs/arx-remote/origin/newone "$SHA_ALPHA"
    check "push: rejected ref keeps its tracking value"    ref_is refs/arx-remote/origin/feature/alpha "$SHA_GAMMA"
}

test_purge() {
    section "purge (refs backend)"
    set_storage refs

    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null
    arx push > /dev/null  # both refs now on remote

    assert_fails "purge: unknown option" arx purge --bogus

    # --dry-run lists refs but deletes nothing
    assert_out "purge: --dry-run lists remote refs" "feature/alpha" arx purge --dry-run
    check "purge: --dry-run leaves remote refs intact" remote_has refs/arx/feature/alpha

    # --force deletes all remote refs regardless of local archive
    assert_ok "purge: --force succeeds" arx purge --force
    check "purge: all remote refs removed"         ! remote_has 'refs/arx/*'
    check "purge: remote tracking refs cleaned up" ! ref_exists refs/arx-remote/origin/feature/alpha

    # local archive is untouched
    run arx list
    has "purge: local archive left intact" "feature/alpha" "feature/beta"

    # purge on an empty remote is a clean no-op
    assert_out "purge: no-op when remote empty" "No archived refs on the remote." arx purge
}

test_sync() {
    section "sync (both backend)"
    set_storage both

    # File-only drift
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive

    run arx sync --dry-run
    has "sync --dry-run: reports file-only entry" "Synced to refs: feature/alpha"
    has "sync --dry-run: appends dry-run line" "(dry run – no changes written)"
    check "sync --dry-run: does not write to refs" ! ref_exists refs/arx/feature/alpha

    arx sync > /dev/null
    check "sync: copies file-only entry to refs" ref_exists refs/arx/feature/alpha

    # Refs-only drift
    reset_archive both
    git update-ref "refs/arx/feature/beta" "$SHA_BETA"

    run arx sync --dry-run
    has "sync --dry-run: reports refs-only entry" "Synced to file: feature/beta"

    arx sync > /dev/null
    check "sync: copies refs-only entry to file" file_has .gitarchive "feature/beta"

    # SHA conflict
    reset_archive both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"  # intentionally different

    run arx sync
    has "sync: reports SHA conflict" "CONFLICT"

    # --force-file: refs should be overwritten with file's SHA
    arx sync --force-file > /dev/null
    check "sync --force-file: refs updated to file's SHA" ref_is refs/arx/feature/alpha "$SHA_ALPHA"

    # --force-refs: file should be overwritten with refs' SHA
    reset_archive both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    arx sync --force-refs > /dev/null
    check "sync --force-refs: file updated to refs' SHA" file_has .gitarchive "$SHA_BETA"

    # --dry-run --force-file: shows what would happen without writing
    reset_archive both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    run arx sync --dry-run --force-file
    has "sync --dry-run --force-file: shows resolved message" "Resolved (force-file)"
    has "sync --dry-run --force-file: appends dry-run line" "(dry run – no changes written)"
    # Verify no write happened: refs should still have SHA_BETA
    check "sync --dry-run --force-file: does not write" ref_is refs/arx/feature/alpha "$SHA_BETA"

    # --dry-run --force-refs: shows what would happen without writing
    reset_archive both
    printf '# git-arx archive\nfeature/alpha %s 2025-01-01T00:00:00+00:00\n' "$SHA_ALPHA" > .gitarchive
    git update-ref "refs/arx/feature/alpha" "$SHA_BETA"
    run arx sync --dry-run --force-refs
    has "sync --dry-run --force-refs: shows resolved message" "Resolved (force-refs)"
    has "sync --dry-run --force-refs: appends dry-run line" "(dry run – no changes written)"
    # Verify no write happened: file should still have SHA_ALPHA
    check "sync --dry-run --force-refs: does not write" file_has .gitarchive "$SHA_ALPHA"

    # A file entry whose commit isn't in this repository (a teammate's
    # never-pushed branch, say) can't become a ref: it is skipped and
    # reported, and the entries around it are still synced
    reset_archive both
    printf '# git-arx archive\naaa-first %s 2025-01-01T00:00:00+00:00\nmissing %s 2025-01-01T00:00:00+00:00\nzzz-last %s 2025-01-01T00:00:00+00:00\n' \
        "$SHA_ALPHA" 1111111111111111111111111111111111111111 "$SHA_BETA" > .gitarchive
    run arx sync
    nok   "sync: missing object exits nonzero"
    has   "sync: missing object is reported" "Skipped: missing"
    check "sync: entries around a missing object still synced" ref_exists refs/arx/aaa-first refs/arx/zzz-last
    check "sync: no ref for the missing object" ! ref_exists refs/arx/missing

    # sync requires both
    set_storage file
    run arx sync
    has "sync: error when file-only" "requires both storage"
    nok "sync: nonzero when file-only"

    set_storage refs
    run arx sync
    has "sync: error when refs-only" "requires both storage"
    nok "sync: nonzero when refs-only"
}

test_file_records() {
    section "archive file records"
    arx add feature/alpha > /dev/null

    # The archive file is meant to be committed and shared, so its contents
    # are untrusted: a SHA field shaped like a git option must never reach
    # git, where --output=<path> would overwrite any file the user can write
    printf 'evil --output=%s 2025-01-01T00:00:00+00:00\n' "$SANDBOX/pwned" >> .gitarchive
    run arx list --author
    has   "records: malformed line is reported" "not an archive record"
    has   "records: valid entries still listed" "feature/alpha"
    lacks "records: malformed entry not listed" "evil"
    check "records: list --author passes nothing to git as an option"   ! test -e "$SANDBOX/pwned"
    arx status --all > /dev/null 2>&1
    check "records: status --all passes nothing to git as an option"    ! test -e "$SANDBOX/pwned"

    # git allows branch names starting with "#": such a record must read
    # back as an entry, not be skipped as a comment
    reset_archive
    git branch '#hotfix' "$SHA_BETA"
    arx add '#hotfix' > /dev/null
    assert_out "records: #-named branch is listed" "#hotfix" arx list
    assert_out "records: #-named branch re-add is idempotent" "Already archived" arx add '#hotfix'
    check "records: #-named branch stored once" [ "$(grep -c '^#hotfix ' .gitarchive)" = 1 ]
    assert_ok "records: #-named branch can be removed" arx remove '#hotfix'
    check "records: header comment survives" file_has .gitarchive "# git-arx archive"

    # A CRLF checkout (core.autocrlf on Windows) leaves \r on every line
    reset_archive
    printf '# git-arx archive\r\nfeature/alpha %s 2025-01-01T00:00:00+00:00\r\n' "$SHA_ALPHA" > .gitarchive
    run arx list
    has   "records: CRLF file is read" "feature/alpha"
    lacks "records: CRLF leaves no carriage return" $'\r'
    lacks "records: CRLF lines are not reported" "not an archive record"
}

test_slashed_branches() {
    section "branch names with slashes"

    arx add feature/alpha > /dev/null
    assert_out "slash: in file list" "feature/alpha" arx list

    set_storage refs
    arx add feature/alpha > /dev/null
    check "slash: correct ref path refs/arx/feature/alpha" ref_exists refs/arx/feature/alpha
}

test_double_add() {
    section "double add (idempotent)"

    arx add feature/alpha > /dev/null
    arx add feature/alpha > /dev/null  # second add – should update, not duplicate
    check "double add: no duplicate in file" [ "$(grep -c '^feature/alpha ' .gitarchive 2> /dev/null)" = 1 ]
}

test_config_bool() {
    section "git-style boolean config values"

    # 'yes' / 'off' are valid git booleans and must be honored
    git config arx.storefile yes
    git config arx.storerefs off
    arx add feature/alpha > /dev/null 2>&1 || true
    check "config: arx.storefile=yes enables file backend"    file_has .gitarchive "feature/alpha"
    check "config: arx.storerefs=off disables refs backend" ! ref_exists refs/arx/feature/alpha

    reset_archive
    git config arx.storefile 0
    git config arx.storerefs 1
    arx add feature/beta > /dev/null 2>&1 || true
    check "config: arx.storerefs=1 enables refs backend"    ref_exists refs/arx/feature/beta
    check "config: arx.storefile=0 disables file backend" ! test -f .gitarchive

    # numeric booleans, checked against git directly (see INTERNALS: Testing)
    local boolfn="$SANDBOX/arx-bool.sh"
    sed -n '/^_arx_bool()/,/^}/p' "$ARX" > "$boolfn"
    # shellcheck source=/dev/null
    source "$boolfn"
    if ! declare -F _arx_bool > /dev/null; then
        fail "config: could not extract _arx_bool from git-arx"
        return 0
    fi

    # git is the oracle. Both defaults are checked: with only one, "fell back
    # to the default" would pass as "parsed correctly".
    local probes="$SANDBOX/bool-probes.config"
    local -a bool_values=(
        2 -1 +5 00 000 -0 007 010 0777 0x10 0X10 0x0 1k 2m 0k 3g
        2147483647 2147483648 -2147483648 -2147483649 2097151k 2097152k
        0x10000000000000000 18446744073709551616 0777777777777777777777777
        9999999999g 08 notabool " 1" ""
    )
    printf '[probe]\n' > "$probes"
    local value verdict expected default i=0
    for value in "${bool_values[@]}"; do
        printf '\tp%d = "%s"\n' "$i" "$value" >> "$probes"
        i=$(( i + 1 ))
    done

    i=0
    for value in "${bool_values[@]}"; do
        if ! verdict=$(git config -f "$probes" --type=bool --get "probe.p$i" 2>/dev/null); then
            verdict=""      # git rejects it; git-arx must use the key's default
        fi
        # Before 2.50, git's range check was off by one for the most negative
        # int (parse.c: -max / factor, now (-max - 1) / factor), so the
        # oracle's answer for it depends on the installed version. git-arx
        # follows the fixed parser.
        if [[ "$value" == "-2147483648" ]]; then
            verdict="true"
        fi
        for default in true false; do
            REPLY=""
            _arx_bool "$value" false "$default"
            if [[ -n "$verdict" ]]; then expected="$verdict"; else expected="$default"; fi
            if [[ "$REPLY" == "$expected" ]]; then
                pass "config: bool [$value] default=$default -> $expected (matches git)"
            else
                fail "config: bool [$value] default=$default should be $expected, got $REPLY"
            fi
        done
        i=$(( i + 1 ))
    done
}

test_config() {
    section "config"
    arx_no()  { arx "$@" < /dev/null; }   # answer a prompt with EOF
    arx_yes() { arx "$@" <<< yes; }
    # A private global config, so --global has somewhere to write
    export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
    : > "$GIT_CONFIG_GLOBAL"

    # Listing: value in effect and its source (fixture: file storage)
    run arx config
    ok  "list: exits 0"
    has "list: shows every key" "storerefs" "storefile" "filepath" "refsprefix"
    has "list: local value"     "storefile   true"
    has "list: default source"  "default"
    assert_out "get: value"                   "true"        arx config storefile
    assert_out "get: arx. prefix, any case"   "true"        arx config ARX.StoreFile
    assert_out "get: default when unset"      ".gitarchive" arx config filepath

    # Usage and validation – nothing written on refusal
    assert_fails "unknown key refused"          arx config bogus
    assert_fails "unknown option refused"       arx config --bogus
    assert_fails "too many args refused"        arx config a b c
    assert_fails "--unset without key refused"  arx config --unset
    assert_fails "--global on get refused"      arx config --global storefile
    run arx config storefile maybe
    nok "non-boolean refused"
    has "non-boolean: explains" "must be a boolean"
    assert_fails "refsprefix outside refs/ refused"  arx config refsprefix arx
    assert_fails "refsprefix in refs/heads/ refused" arx config refsprefix refs/heads/
    assert_fails "absolute filepath refused"         arx config filepath /tmp/x
    assert_fails "empty filepath refused"            arx config filepath ""
    run arx config storefile false
    nok "disabling the last backend refused"
    has "last backend: explains" "refusing to disable both"
    check "refusals wrote nothing" ! git config arx.refsprefix

    # Values are stored normalized
    assert_ok "set boolean" arx config storerefs yes
    check "boolean stored as true"     test "$(git config --local arx.storerefs)" = true
    assert_ok "set refsprefix" arx config refsprefix refs/arxtest -f
    check "refsprefix stored with /"   test "$(git config --local arx.refsprefix)" = refs/arxtest/
    assert_ok "unset" arx config --unset refsprefix
    check "unset removes the key"      ! git config --local arx.refsprefix
    assert_out "unset again: nothing to do" "not set in local config" arx config --unset refsprefix

    # --global: written there; a local value overriding it is reported
    run arx config --global storerefs false
    ok  "--global set succeeds"
    has "--global: shadowed by local is noted" "overridden here by the local value"
    check "--global wrote the global config" test "$(git config --global arx.storerefs)" = false
    assert_ok "--global unset" arx config --global --unset storerefs
    git config --local arx.storerefs false     # back to the fixture: file only

    # Hidden entries: enabling a backend notes what sync would copy
    arx add feature/alpha > /dev/null
    arx add feature/beta  > /dev/null
    run arx config storerefs true
    has "enable refs: note points at sync" "2 archived entries found only in the file" "git arx sync"
    arx sync > /dev/null

    # Disabling a backend whose entries are all in the other: no prompt
    run arx_no config storefile false
    ok    "disable synced backend: no prompt"
    lacks "disable synced backend: no warning" "WARNING"
    arx config storefile true > /dev/null

    # Disabling a backend with entries the other lacks: prompt
    git update-ref -d refs/arx/feature/beta   # now only in the file
    run arx_no config storefile false
    nok "disable file: declined prompt aborts"
    has "disable file: warns with the count" "1 archived entry found only in .gitarchive" "Aborted."
    check "disable file: declined leaves config" test "$(git config --local arx.storefile)" = true
    run arx_yes config storefile false
    ok  "disable file: confirmed"
    check "disable file: written" test "$(git config --local arx.storefile)" = false
    arx config storefile true > /dev/null

    # Renaming the refs prefix or the file hides everything under the old one
    run arx_no config refsprefix refs/other
    nok "refsprefix: declined prompt aborts"
    has "refsprefix: warns with the count" "1 archived entry under refs/arx/"
    run arx config refsprefix refs/other --force
    ok    "refsprefix: --force skips the prompt"
    has   "refsprefix: --force still warns" "WARNING"
    lacks "refsprefix: --force does not prompt" "Type \"yes\""
    check "refsprefix: old refs left in place" ref_exists refs/arx/feature/alpha
    arx config --unset refsprefix > /dev/null
    run arx_no config filepath other.txt
    nok "filepath: declined prompt aborts"
    has "filepath: warns with the count" "2 archived entries in .gitarchive"

    # A broken config can still be inspected and repaired
    git config arx.storerefs false
    git config arx.storefile false
    git config arx.refsprefix refs/heads
    assert_fails "broken config: other commands refuse" arx list
    run arx config
    ok  "broken config: list still works"
    has "broken config: invalid prefix flagged" "local – invalid"
    has "broken config: no backend flagged" "no storage backend enabled"
    assert_ok "broken config: set storefile" arx config storefile true
    assert_ok "broken config: fix prefix"    arx config --unset refsprefix
    assert_ok "repaired config: list works"  arx list
}

test_error_cases() {
    section "error cases"

    run arx bogus
    has "unknown cmd: error message" "unknown command"
    nok "unknown cmd: nonzero"

    local notrepo="$SANDBOX/notrepo"
    mkdir -p "$notrepo"
    run in_dir "$notrepo" arx list
    has "not-in-repo: error" "not inside a git repository"
    nok "not-in-repo: nonzero"

    assert_out "push: requires refs" "requires refs storage" arx push
    assert_out "pull: requires refs" "requires refs storage" arx pull
    assert_out "sync: requires both" "requires both storage" arx sync

    set_storage refs
    assert_out "merge: requires file" "requires file storage" \
        arx merge /dev/null /dev/null -o /dev/null

    # A refs prefix inside one of git's own namespaces would turn prune and
    # purge into mass deletions of real branches
    git config arx.refsprefix refs/heads
    run arx prune --dry-run
    nok "refsprefix inside refs/heads/: rejected"
    has "refsprefix inside refs/heads/: explains why" "dedicated namespace"
    lacks "refsprefix inside refs/heads/: lists nothing to delete" "permanently deleted"
    git config --unset arx.refsprefix

    # Neither backend enabled: nothing can be stored, so commands must refuse
    # rather than report "Archived" having written nothing
    git config arx.storerefs false
    git config arx.storefile false
    run arx add feature/alpha
    has   "no backend: add reports it" "no storage backend enabled"
    nok   "no backend: add exits nonzero"
    lacks "no backend: add does not claim success" "Archived"
    assert_fails "no backend: update exits nonzero" arx update

    # A bare repo is a repo, but has no work tree to resolve the archive path
    # against – it must say so rather than fall through to a raw git error.
    local bare="$SANDBOX/bare.git"
    git init --bare "$bare" -q
    run in_dir "$bare" arx list
    has "bare-repo: error" "must run inside a work tree"
    nok "bare-repo: nonzero"
}

test_overwrite_guard() {
    section "self-overwrite guard"

    # The script must never execute bytes past the final { main; exit; } line –
    # that's what `upgrade` overwriting the running file would leave behind.
    local guarded="$SANDBOX/arx-guard-copy"
    cp "$ARX" "$guarded"
    printf 'echo GUARD-FAIL\n' >> "$guarded"
    run bash "$guarded" --version
    lacks "guard: bytes after main are never executed" "GUARD-FAIL"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    printf 'git-arx integration test suite\n'
    printf 'Script: %s\n' "$ARX"

    if [[ ! -f "$ARX" ]]; then
        printf 'ERROR: git-arx not found at %s\n' "$ARX" >&2
        exit 1
    fi

    if (( $# == 0 )); then set -- "${SECTIONS[@]}"; fi
    local name
    for name in "$@"; do
        if ! declare -F "test_$name" > /dev/null; then
            printf 'ERROR: unknown section "%s" – one of: %s\n' "$name" "${SECTIONS[*]}" >&2
            exit 1
        fi
    done

    TMPROOT=$(mktemp -d)
    # set -e still applies inside the trap: a bare kill with no jobs left
    # would abort it before the cleanup.
    trap 'kill $(jobs -p) 2> /dev/null || true; cd /; rm -rf "$TMPROOT"' EXIT
    make_fixture

    local -a names=("$@") pids=()
    for name in "${names[@]}"; do
        run_section "$name" > "$TMPROOT/$name.log" 2>&1 &
        pids+=("$!")
    done

    # Print each section's log in order, tallying its results. A section that
    # died part-way (set -e) counts as one more failure.
    local i rc line
    for i in "${!names[@]}"; do
        rc=0
        wait "${pids[i]}" || rc=$?
        while IFS= read -r line || [[ -n $line ]]; do
            case $line in
                "$PASS_TAG"*) PASS=$(( PASS + 1 )) ;;
                "$FAIL_TAG"*) FAIL=$(( FAIL + 1 )) ;;
            esac
            printf '%s\n' "$line"
        done < "$TMPROOT/${names[i]}.log"
        if (( rc != 0 )); then
            fail "test_${names[i]} aborted with exit status $rc"
        fi
    done

    printf '\n=== Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m ===\n' "$PASS" "$FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
