# git-bx — Internals & Design

Implementation details, design decisions, and architectural notes for contributors and maintainers.

For end-user documentation, see [README.md](README.md).

---

## Overview

`git-bx` is a single self-contained bash script (~330 lines). There are no dependencies beyond git and bash 4+. The script is structured in six sections separated by comment headers:

```
# --- CONFIG HELPERS ---
# --- BACKEND: FILE ---
# --- BACKEND: REFS ---
# --- ABSTRACTION LAYER ---
# --- COMMANDS ---
# --- ENTRY POINT ---
```

All commands go through an internal abstraction layer and never touch storage directly. This makes adding a new storage backend a matter of implementing three functions and wiring them into the layer — no commands need to change.

---

## File Structure

```
git-bx           Single executable bash script — the entire implementation
install.sh       Installs git-bx to PATH and sets the git alias
test.sh          Test suite
.gitattributes   Enforces LF line endings for git-bx and install.sh on Windows checkout
README.md        End-user documentation
INTERNALS.md     This file
LICENSE          MIT License
```

---

## Why a Bash Script

- No install dependencies — bash and git are already present everywhere this tool would be used
- Git aliases with `!` prefix (`git config alias.bx '!git-bx'`) invoke external scripts on `$PATH` natively
- The logic is simple enough that bash's limitations (no proper data structures, string-heavy) are acceptable
- A Go binary would be the right choice if distribution to non-developers were a goal; it's not

The one meaningful bash requirement is associative arrays (`declare -A`), which need bash 4+. Git for Windows ships bash 4.4+. macOS ships bash 3.2 (due to GPL licensing), but `/usr/bin/env bash` on modern macOS with Homebrew resolves to bash 5.x. This is a known trade-off.

---

## Safety Flags

```bash
set -euo pipefail
```

- `-e`: exit immediately on any command error
- `-u`: treat unset variables as errors
- `-o pipefail`: propagate errors through pipes (e.g. `false | true` fails)

This is important for a tool that writes to storage — silent failures would corrupt the archive or leave it in a partial state.

**Caveat:** Commands that are expected to return non-zero must be wrapped. Examples:
- `git cat-file -e "$sha"` — used for existence checks, returns 1 if the object is missing. Wrapped in `if ! ...`.
- `git update-ref -d` — used when deleting refs that may not exist. Followed by `|| true`.
- `(( counter++ ))` — arithmetic `(( expr ))` returns 1 when the expression evaluates to 0. Use `counter=$(( counter + 1 ))` instead.
- `[[ $dry_run -eq 1 ]] && printf '...\n'` — when `dry_run=0`, `[[ ]]` returns 1, which is the exit code of the whole `&&` expression, triggering `set -e`. Always append `|| true`: `[[ $dry_run -eq 1 ]] && printf '...\n' || true`.

**Implementing `--dry-run` on a command:**

1. Add a `local dry_run=0` variable and a `--dry-run)  dry_run=1 ;;` case in the option parser.
2. Keep all output (`printf`) statements identical to the non-dry-run path — the user sees the same output either way.
3. Guard every write/delete with `[[ $dry_run -eq 0 ]] && ...` or wrap in `if [[ $dry_run -eq 0 ]]; then ... fi`.
4. Append a single trailing line after the normal summary:
   ```bash
   [[ $dry_run -eq 1 ]] && printf '(dry run — no changes written)\n' || true
   ```
   The `|| true` is mandatory — see the caveat above.

---

## Entry Point and Dispatch

```bash
main() {
    _bx_require_git
    BX_GIT_ROOT=$(_bx_git_root)
    ...
}
```

`BX_GIT_ROOT` is set once at startup and used by `_bx_config_file()` to resolve the archive path relative to the repo root rather than the current working directory. This means `git bx list` works correctly regardless of which subdirectory the user is in when they run it.

Commands that don't apply to the configured storage call `_bx_require_storage` at the top of their function, which prints a descriptive error and exits:

```
git-bx: this command requires refs storage (set: git config bx.storerefs true)
```

Unknown commands print an error referencing `git bx help`.

---

## Abstraction Layer

The core of the architecture is three functions that all commands call exclusively:

### `_bx_read_all()`

Reads from configured backend(s) and emits normalized records to stdout, one per line:

```
<branch-name> <full-sha> <ISO-8601-date>
```

This is a streaming interface — callers pipe or redirect it with `while read`. No temporary files are needed for reads.

When both `bx.storerefs` and `bx.storefile` are enabled, the function performs a union merge:
1. Emit everything from the refs backend, recording branch names in a `declare -A seen` associative array
2. Emit file-only entries (those whose branch name is not in `seen`)

Refs are treated as primary in the union merge. This reflects the refs backend's stronger guarantees (gc-safe, native git). The `sync` command surfaces conflicts between backends explicitly; `_bx_read_all` silently prefers refs to avoid making every command into a conflict reporter.

### `_bx_write(branch, sha, date)`

Writes to all enabled backends. When both are enabled, writes to file first, then refs. Order doesn't matter for correctness; file first means a crash between the two writes leaves the more portable copy updated.

### `_bx_delete(branch)`

Removes from all enabled backends. When both are enabled, removes from file first, then refs.

---

## File Backend

### Format

```
# git-bx archive — do not edit manually
feature/login a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 2025-11-15T10:30:00+01:00
fix/bug-42 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2025-10-01T08:00:00+00:00
```

- Space-delimited, three fields: `branch sha date`
- Full 40-character SHA (abbreviated SHAs become ambiguous as repos grow)
- ISO-8601 date with timezone offset from `git log -1 --format=%aI` (author date of HEAD commit)
- `#` lines are comments, skipped on read
- Blank lines are skipped on read

The format is intentionally simple. Since git branch names cannot contain spaces (git itself rejects them), space as delimiter is unambiguous and requires no quoting or escaping.

### Atomic Writes

The file is never modified in place. Every write uses a filter-then-append pattern:

1. Read the full archive into a temp file (`${archive}.tmp.$$`), skipping the entry being updated
2. Append the new entry to the temp file
3. Replace the archive with the temp file

The temp file name uses `$$` (the shell's PID) to avoid collisions if multiple instances run simultaneously (unlikely for an interactive CLI, but safe practice).

The replace step on MINGW64/Windows requires an explicit `rm -f` before `mv`:

```bash
[[ -f "$archive" ]] && rm -f "$archive"
mv "$tmpfile" "$archive"
```

On Linux/macOS, `mv` over an existing file is atomic at the filesystem level. On Windows NTFS via Git Bash, `mv` can fail if the destination exists; the explicit remove makes it reliable.

### Remove = Filter Out

Deleted entries are removed from the file entirely, not marked with a prefix like `#archived`. Rationale:

- The git object itself still exists in the repository (until gc) — the SHA in the record is the real audit trail
- Keeping deleted entries would mean the file grows unboundedly
- `_bx_file_write` already implements filter-then-append, so delete is just filter-without-append — no new code path

---

## Refs Backend

### Namespace

Archived branches are stored as git refs under `refs/bx/`. For a branch named `feature/login`, the ref path is `refs/bx/feature/login`.

Git ref names allow forward slashes and use them to create directory structure. `refs/bx/feature/login` is stored as the file `.git/refs/bx/feature/login`. This is the same mechanism used by `refs/remotes/origin/feature/login` — no special handling is needed.

The only characters illegal in git ref names are: space, `~`, `^`, `:`, `?`, `*`, `[`, `\`, and the sequences `..` and `@{`. Since git itself rejects branch names with these characters, any valid local branch name is a valid ref name in our namespace.

### Why Refs Protect from gc

`git gc` prunes **unreachable** objects — commits, trees, and blobs that cannot be reached by following refs (branches, tags, stash, reflogs). When a local branch is deleted, its commits become unreachable unless something else references them. A `refs/bx/` ref is a real git ref, so any commit it points to (and all ancestors of that commit) remain reachable and will not be pruned.

### Reading Dates from Refs

The refs backend does not store dates explicitly — the date is read from the commit object at query time:

```bash
git for-each-ref \
    --format='%(refname:short) %(objectname) %(creatordate:iso-strict)' \
    'refs/bx/'
```

`%(refname:short)` strips the `refs/` prefix, giving `bx/feature/login`. The `bx/` prefix is then stripped in `_bx_refs_read` to recover the branch name.

`%(creatordate:iso-strict)` gives the ISO-8601 date of the commit the ref points to. This is the same date that would have been stored in the file backend, so the normalized output of both `_bx_file_read` and `_bx_refs_read` is identical in format.

### Remote Operations

Refs in `refs/bx/` are not pushed by default. Git only pushes `refs/heads/*` and `refs/tags/*` in a standard `git push`. The `push` command uses an explicit refspec:

```bash
git push origin 'refs/bx/*:refs/bx/*'
```

This pushes all `refs/bx/` refs to the same path on the remote. Supported by GitHub, GitLab, Gitea, and Bitbucket. The `pull` command uses the equivalent fetch refspec.

This is also how the `both` backend can achieve fully automatic remote sync without `git bx push/pull`: if `.gitarchive` is committed to the repository, it syncs as part of the normal git object graph.

---

## Command Notes

### `bx update` and `bx status`

Both commands use the same upstream-detection logic. Both also use the same performance optimisation — see below.

`%(upstream)` outputs the full ref path of the configured upstream (e.g. `refs/remotes/origin/main`). If no upstream is configured, the field is empty. A branch is a candidate for archiving if the upstream field is empty (never had a remote) or `git rev-parse --verify "$upstream_ref"` fails (upstream configured but the tracking ref no longer exists locally).

This approach is more robust than checking `%(upstream:track)` for the string `[gone]` because:
- `[gone]` can vary by git version or locale
- The ref-existence check is a direct, binary fact about the object store

Note: `git remote prune origin` removes the remote tracking ref (`refs/remotes/origin/branch`) but does **not** clear `branch.<name>.remote` or `branch.<name>.merge` from `.git/config`. So `%(upstream:short)` still outputs `origin/deleted-branch` for pruned branches. Using `%(upstream)` (the full ref) and checking whether that ref resolves correctly handles both the "never had a remote" and "remote was deleted" cases.

`bx update` writes the archive for each candidate. `bx status` runs the same detection and determines each branch's archive state (`Not archived`, `Archived`, `Archived as "<name>"`, or `Conflict`). Nothing is written.

### Performance (`bx update`, `bx status`, `bx list --author`)

For repos with many branches or archived entries, naive per-branch subprocess calls add up to tens of seconds. Three commands use bulk operations to avoid this.

**`bx update` and `bx status`** share the same two optimisations:

1. **Archive loaded once** — `_bx_read_all` is called once before the branch loop and its output is stored in two in-memory associative arrays: `arc_by_name[branch]=sha` and `arc_by_sha[sha]=name`. All per-branch archive lookups are then O(1) bash hash table reads instead of O(n) subprocess calls.

2. **Single `git for-each-ref` call** — a single call retrieves branch name, SHA, author date, and (for `status`) author name for every branch at once, replacing per-branch `git rev-parse` and `git log` calls:

```bash
# bx status (includes authorname for display)
git for-each-ref \
    --format='%(refname:short)%09%(objectname)%09%(authordate:iso-strict)%09%(authorname)%09%(upstream)' \
    refs/heads/

# bx update (authorname not needed)
git for-each-ref \
    --format='%(refname:short)%09%(objectname)%09%(authordate:iso-strict)%09%(upstream)' \
    refs/heads/
```

`bx update` also keeps the in-memory maps current after each write — `arc_by_name` and `arc_by_sha` are updated immediately after `_bx_write` — so that subsequent branches processed in the same run see the correct archive state.

**`%(upstream)` must be last.** Tab (`%09`) is an IFS whitespace character. When `%(upstream)` is empty, it produces two consecutive tabs. Because IFS whitespace collapses, `read` treats `<TAB><TAB>` as a single separator — the empty field disappears and all subsequent fields shift left. Placing `%(upstream)` last avoids this: the trailing tab is stripped cleanly, and `upstream_ref` is assigned an empty string, which is the correct behaviour.

**`set -u` and associative arrays.** Accessing a missing key in an associative array with `set -u` enabled triggers an "unbound variable" error in bash 4.x. All array reads use `${arr[key]:-}` to provide an explicit empty-string default and suppress the error.

**`bx list --author`** — archived SHAs are not local branch refs, so `git for-each-ref` does not apply. Instead, all SHAs are collected from the sorted entries and passed to a single `git log --no-walk` call, reducing N subprocess calls to one:

```bash
git log --no-walk --format='%H %an' sha1 sha2 sha3 ...
```

The result is stored in `author_by_sha[sha]=name` and looked up during rendering. gc'd commits are absent from the output and fall back to `(gc)` via `${author_by_sha[$sha]:-\(gc\)}`.

### `bx add` — Conflict Detection

Before writing, `add` calls `_bx_lookup_branch` against the target name (which may be a custom archive name). Four outcomes:

1. **Not archived** — write and report `Archived:`.
2. **Archived with same SHA** — exit 0 with `Already archived:`. Idempotent; safe to call repeatedly.
3. **Archived with different SHA** — conflict. Exit 1 with an error and hints. `--force` overwrites; an `archive-name` argument stores under a different name instead.
4. **Not archived by target name, but SHA already present under a different name** — `_bx_lookup_sha` finds the duplicate. Prints a `Note:` line, then writes anyway (the user explicitly requested this archive entry).

`bx update` applies the same conflict logic for every candidate branch, using the in-memory `arc_by_name` and `arc_by_sha` maps (see Performance section) rather than calling `_bx_lookup_branch` and `_bx_lookup_sha` per branch. If the current SHA is already stored under a different name, the branch is skipped with an `Already safe:` message and counted separately in the summary. This prevents silent duplicate SHA storage during automatic archiving. If the user wants the branch indexed under its natural name too, they can run `git bx add <branch>` explicitly.

### `bx rename`

Implemented as `_bx_write(new) + _bx_delete(old)` — the abstraction layer fans out to all enabled backends automatically. There is no dedicated rename primitive in either backend; write-then-delete is equivalent.

### `bx log` — Argument Passthrough

```bash
cmd_log() {
    local branch="$1"
    shift          # $@ now contains only the git log flags
    ...
    git log "$sha" "$@"
}
```

`shift` removes the branch name argument, leaving `"$@"` as whatever the user typed after the branch name. All git log flags, format strings, file path filters, and revision ranges work as expected.

`exec` is intentionally not used here. On Windows/MINGW64, `exec` does not properly transfer the pipe file descriptor to the replacement process, so git detects a terminal instead of a pipe, opens the pager, and the output never reaches the caller. A plain `git log` call avoids this and behaves correctly on all platforms.

### `bx checkout` — gc Detection

Before attempting to restore, the script checks whether the commit still exists:

```bash
if ! git cat-file -e "$sha"; then
    # commit was garbage collected
fi
```

`git cat-file -e <object>` exits 0 if the object exists in the object store, non-zero otherwise. It does not print anything. This is the correct low-level check — it works for any object type (commit, tree, blob) and does not require the object to be reachable.

### `bx sync` — Union Merge Algorithm

`sync` is only meaningful when both `bx.storerefs` and `bx.storefile` are enabled, since it reconciles two backends that can theoretically drift.

**When drift happens:**

In normal usage, drift should not occur — every write operation hits both backends atomically (within the script). Drift can arise from:

1. Someone manually edits `.gitarchive` with a text editor
2. Someone manually creates/deletes refs with raw git commands
3. A script crash between the file write and the ref write
4. `git bx pull` without `both` storage (updates refs but not file)

**Algorithm:**

```
for each branch in (refs ∪ file):
    refs-only → write to file
    file-only → write to refs
    both, same SHA → no-op
    both, different SHA → conflict
```

Non-conflicting entries are always processed. A conflict does not block other entries from being synced. After processing all entries, if any conflicts occurred, `sync` exits with status 1.

**`--dry-run`:** Runs the same comparison logic and prints the same output as a real sync, but skips all writes. A trailing `(dry run — no changes written)` line is appended. Works with or without `--force-file` / `--force-refs` — output shows exactly what would happen if the flag were run without `--dry-run`.

**`--force-file` / `--force-refs`:** When a SHA conflict is detected and a force flag is present, the designated backend is treated as the source of truth and the other is overwritten. This is an escape hatch for the rare case where the user knows which side is correct.

---

## Known Limitations

- **No locking.** The archive file has no write lock. Concurrent invocations (unlikely for an interactive tool) could corrupt it. Acceptable trade-off.
- **bash 4+ required.** Uses `declare -A` associative arrays. macOS ships bash 3.2; users need to install bash via Homebrew and ensure it's on their PATH.
- **`merge` does not resolve SHA conflicts.** When the same branch appears in two files with different SHAs, the conflict is reported and the entry is skipped. The user must manually decide which SHA is correct and edit the output file. There is no `--force-file` / `--force-refs` equivalent for `merge` (unlike `sync`) because `merge` has no concept of a "primary" source.
- **`push/pull` hardcodes `origin`.** The remote name is not configurable. This could be added via `bx.remote` config in a future version.
- **No autocomplete.** Branch name tab-completion for `add`, `remove`, `log`, `checkout` is not implemented. Shell completion scripts (bash/zsh/fish) would be a useful addition.
- **Ref namespace collisions.** Git ref names are hierarchical. Archiving a branch named `update` creates `refs/bx/update` as a file. Archiving `update/packages` needs `refs/bx/update/` to be a directory — the two cannot coexist. If this occurs, use `git bx rename update update-legacy` to free up the name before archiving the slashed branch.
