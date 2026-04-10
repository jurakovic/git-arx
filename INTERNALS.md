# git-arx – Internals & Design

Implementation details, design decisions, and architectural notes for contributors and maintainers.

For end-user documentation, see [README.md](README.md).

---

## Contents

- [Overview](#overview)
- [File Structure](#file-structure)
- [Why a Bash Script](#why-a-bash-script)
- [Safety Flags](#safety-flags)
- [Entry Point and Dispatch](#entry-point-and-dispatch)
- [Abstraction Layer](#abstraction-layer)
- [File Backend](#file-backend)
- [Refs Backend](#refs-backend)
- [Command Notes](#command-notes)
- [Shell Completion](#shell-completion)
- [Testing](#testing)
- [Versioning](#versioning)
- [Known Limitations](#known-limitations)

---

## Overview

`git-arx` is a single self-contained bash script. There are no dependencies beyond git and bash 4+. The script is structured in six sections separated by comment headers:

```
# --- CONFIG HELPERS ---
# --- BACKEND: FILE ---
# --- BACKEND: REFS ---
# --- ABSTRACTION LAYER ---
# --- COMMANDS ---
# --- ENTRY POINT ---
```

All commands go through an internal abstraction layer and never touch storage directly. This makes adding a new storage backend a matter of implementing three functions and wiring them into the layer – no commands need to change.

---

## File Structure

```
git-arx                    Single executable bash script – the entire implementation
install.sh                 Installs git-arx to PATH and sets the git alias
uninstall.sh               Removes installed files and the git alias
git-arx-completion.bash    Bash tab completion script
test.sh                    Test suite
README.md                  End-user documentation
INTERNALS.md               This file
LICENSE                    MIT License
```

---

## Why a Bash Script

- No install dependencies – bash and git are already present everywhere this tool would be used
- Git aliases with `!` prefix (`git config alias.arx '!git-arx'`) invoke external scripts on `$PATH` natively
- The logic is simple enough that bash's limitations (no proper data structures, string-heavy) are acceptable
- A compiled binary (Go, Rust, etc.) would be the right choice if distribution to non-developers were a goal; it's not

The one meaningful bash requirement is associative arrays (`declare -A`), which need bash 4+. Git for Windows ships bash 4.4+. macOS ships bash 3.2 (due to GPL licensing), but `/usr/bin/env bash` on modern macOS with Homebrew resolves to bash 5.x. This is a known trade-off.

---

## Safety Flags

```bash
set -euo pipefail
```

- `-e`: exit immediately on any command error
- `-u`: treat unset variables as errors
- `-o pipefail`: propagate errors through pipes (e.g. `false | true` fails)

This is important for a tool that writes to storage – silent failures would corrupt the archive or leave it in a partial state.

**Caveat:** Commands that are expected to return non-zero must be wrapped. Examples:
- `git cat-file -e "$sha"` – used for existence checks, returns 1 if the object is missing. Wrapped in `if ! ...`.
- `git update-ref -d` – used when deleting refs that may not exist. Followed by `|| true`.
- `(( counter++ ))` – arithmetic `(( expr ))` returns 1 when the expression evaluates to 0. Use `counter=$(( counter + 1 ))` instead.
- `[[ $dry_run -eq 1 ]] && printf '...\n'` – when `dry_run=0`, `[[ ]]` returns 1, which is the exit code of the whole `&&` expression, triggering `set -e`. Always append `|| true`: `[[ $dry_run -eq 1 ]] && printf '...\n' || true`.

**Implementing `--dry-run` on a command:**

1. Add a `local dry_run=0` variable and a `--dry-run)  dry_run=1 ;;` case in the option parser.
2. Keep all output (`printf`) statements identical to the non-dry-run path – the user sees the same output either way.
3. Guard every write/delete with `[[ $dry_run -eq 0 ]] && ...` or wrap in `if [[ $dry_run -eq 0 ]]; then ... fi`.
4. Append a single trailing line after the normal summary:
   ```bash
   [[ $dry_run -eq 1 ]] && printf '(dry run – no changes written)\n' || true
   ```
   The `|| true` is mandatory – see the caveat above.

---

## Entry Point and Dispatch

```bash
main() {
    _arx_require_git
    ARX_GIT_ROOT=$(_arx_git_root)
    ...
}
```

`ARX_GIT_ROOT` is set once at startup and used by `_arx_config_file()` to resolve the archive path relative to the repo root rather than the current working directory. This means `git arx list` works correctly regardless of which subdirectory the user is in when they run it.

Commands that don't apply to the configured storage call `_arx_require_storage` at the top of their function, which prints a descriptive error and exits:

```
git-arx: this command requires refs storage (set: git config arx.storerefs true)
```

Unknown commands print an error referencing `git arx help`.

---

## Abstraction Layer

The core of the architecture is three functions that all commands call exclusively:

### `_arx_read_all()`

Reads from configured backend(s) and emits normalized records to stdout, one per line:

```
<branch-name> <full-sha> <ISO-8601-date>
```

This is a streaming interface – callers pipe or redirect it with `while read`. No temporary files are needed for reads.

When both `arx.storerefs` and `arx.storefile` are enabled, the function performs a union merge:
1. Emit everything from the refs backend, recording branch names in a `declare -A seen` associative array
2. Emit file-only entries (those whose branch name is not in `seen`)

Refs are treated as primary in the union merge. This reflects the refs backend's stronger guarantees (gc-safe, native git). The `sync` command surfaces conflicts between backends explicitly; `_arx_read_all` silently prefers refs to avoid making every command into a conflict reporter.

### `_arx_write(branch, sha, date)`

Writes to all enabled backends. When both are enabled, writes to file first, then refs. Order doesn't matter for correctness; file first means a crash between the two writes leaves the more portable copy updated.

### `_arx_delete(branch)`

Removes from all enabled backends. When both are enabled, removes from file first, then refs.

### Helper Functions

Several helper functions are defined between the abstraction layer and the commands:

- `_arx_lookup_branch(branch)` – calls `_arx_read_all` and returns `sha date` for the named branch.
- `_arx_sha_exists(sha)` – checks object existence via `git cat-file -e`; used by `log` and `checkout` before operating on an archived SHA.
- `_arx_lookup_sha(sha)` – reverse-lookup: scans `_arx_read_all` output for all entries matching the target SHA. Used by `arx add` to detect when a commit is already archived under a different name. `arx update` uses the in-memory `arc_by_sha` map instead (see Performance section).

---

## File Backend

### Format

```
# git-arx archive – do not edit manually
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

The replace step on Windows/MINGW64 requires an explicit `rm -f` before `mv`:

```bash
[[ -f "$archive" ]] && rm -f "$archive"
mv "$tmpfile" "$archive"
```

On Linux/macOS, `mv` over an existing file is atomic at the filesystem level. On Windows NTFS via Git Bash, `mv` can fail if the destination exists; the explicit remove makes it reliable.

### Remove = Filter Out

Deleted entries are removed from the file entirely, not marked with a prefix like `#archived`. Rationale:

- The git object itself still exists in the repository (until gc) – the SHA in the record is the real audit trail
- Keeping deleted entries would mean the file grows unboundedly
- `_arx_file_write` already implements filter-then-append, so delete is just filter-without-append – no new code path

---

## Refs Backend

### Namespace

Archived branches are stored as git refs under a configurable prefix, defaulting to `refs/arx/`. For a branch named `feature/login`, the default ref path is `refs/arx/feature/login`. The prefix is read from `arx.refsprefix` via `_arx_config_refsprefix()`.

Git ref names allow forward slashes and use them to create directory structure. `refs/arx/feature/login` is stored as the file `.git/refs/arx/feature/login`. This is the same mechanism used by `refs/remotes/origin/feature/login` – no special handling is needed.

The only characters illegal in git ref names are: space, `~`, `^`, `:`, `?`, `*`, `[`, `\`, and the sequences `..` and `@{`. Since git itself rejects branch names with these characters, any valid local branch name is a valid ref name in our namespace.

### Why Refs Protect from gc

`git gc` prunes **unreachable** objects – commits, trees, and blobs that cannot be reached by following refs (branches, tags, stash, reflogs). When a local branch is deleted, its commits become unreachable unless something else references them. A ref under the arx prefix (e.g., `refs/arx/`) is a real git ref, so any commit it points to (and all ancestors of that commit) remain reachable and will not be pruned.

### Reading Dates from Refs

The refs backend does not store dates explicitly – the date is read from the commit object at query time:

```bash
git for-each-ref \
    --format='%(refname) %(objectname) %(creatordate:iso-strict)' \
    "$refsprefix"
```

`%(refname)` gives the full ref path (e.g., `refs/arx/feature/login`). The configured prefix is then stripped in `_arx_refs_read` to recover the branch name.

`%(creatordate:iso-strict)` gives the ISO-8601 date of the commit the ref points to. This is the same date that would have been stored in the file backend, so the normalized output of both `_arx_file_read` and `_arx_refs_read` is identical in format.

### Remote Operations

Refs under the arx prefix are not pushed by default. Git only pushes `refs/heads/*` and `refs/tags/*` in a standard `git push`. The `push` command uses an explicit refspec built from `arx.refsprefix` (default: `refs/arx/`):

```bash
git push origin 'refs/arx/*:refs/arx/*'
```

This pushes all refs under the prefix to the same path on the remote. Supported by GitHub, GitLab, Gitea, and Bitbucket.

After a successful push, `arx push` updates a local remote-tracking namespace derived from `arx.refsprefix` — e.g. `refs/arx/` → `refs/arx-remote/origin/`. Each pushed ref is mirrored there via `git update-ref` so that `arx list` and `arx status --all` can report an accurate `REMOTE` column without a network call.

`arx pull` inverts this: it fetches `refs/arx/*` from the remote into the tracking namespace first, then copies those refs into `refs/arx/*` locally. This preserves a clean record of the last known remote state regardless of any local-only archive entries that were added between pulls.

```bash
# pull fetches into tracking namespace, then promotes to local refs
git fetch origin 'refs/arx/*:refs/arx-remote/origin/*'
# then: git update-ref refs/arx/<branch> <sha>  for each tracking ref
```

This is also how fully automatic remote sync is possible without `git arx push/pull` when using both backends: if `.gitarchive` is committed to the repository, it syncs as part of the normal git object graph.

---

## Command Notes

### `arx update` and `arx status`

Both commands use `%(upstream)` from `git for-each-ref` to classify local branches:

- **Empty `%(upstream)`** — no upstream ever configured: the branch was never pushed ("local only").
- **Non-empty `%(upstream)`, `git rev-parse --verify` fails** — upstream was configured but the tracking ref no longer exists locally: the remote branch was deleted (after `git fetch --prune` or manual pruning).
- **Non-empty `%(upstream)`, `git rev-parse --verify` succeeds** — tracking ref exists: live remote branch, skip.

This approach is more robust than checking `%(upstream:track)` for the string `[gone]` because:
- `[gone]` can vary by git version or locale
- The ref-existence check is a direct, binary fact about the object store

Note: `git remote prune origin` removes the remote tracking ref (`refs/remotes/origin/branch`) but does **not** clear `branch.<name>.remote` or `branch.<name>.merge` from `.git/config`. So `%(upstream)` still outputs the full ref path for pruned branches. Checking whether that ref resolves handles both the "never had a remote" and "remote was deleted" cases.

**`arx update`** only processes remote-deleted branches (non-empty upstream that doesn't resolve). Never-pushed branches are skipped — they require an explicit `git arx add` if the user wants to archive them.

**`arx status`** (default) shows only remote-deleted branches, with archive states `Not archived`, `Archived`, `Archived as "<name>"`, or `Conflict`. Nothing is written.

**`arx status --all`** additionally shows:
1. Never-pushed local branches — shown with status `Local only` when not yet archived (or `Archived` / `Conflict` if they have been archived manually).
2. Archived branches that no longer exist locally — after the `git for-each-ref` loop, the command compares `arc_by_name` keys against the `local_branches` set to find orphan entries. Their authors are fetched in a single `git log --no-walk` call, with `(gc)` as a fallback for pruned commits. These rows are appended to the same `rows` array and go through the same sort and print path.
3. A **REMOTE** column (when the refs backend is active) — loaded once from `refs/arx-remote/origin/*` into `remote_sha_by_branch[branch]=sha` before the print loop. Each row is classified as `pushed` (remote SHA matches archive SHA), `ahead` (remote SHA differs), `local` (no tracking ref), or `-` (branch not in archive). The `-` case applies to `Not archived` rows where there is no archive entry to compare against.

`arx status` accepts `--sort=name|date` and `--order=asc|desc`. The default sort is `name`; the default order depends on the sort key — `asc` for name, `desc` for date — unless overridden explicitly. When sorting by date, name is used as a tiebreaker. Rows are collected first, then sorted as a post-processing step before printing. `arx list` uses the same sort/order logic.

**Color output.** Both `arx status` and `arx list` emit ANSI color codes only when stdout is a terminal (`[[ -t 1 ]]`). Piped or redirected output is always plain text. `arx status` colors the STATUS column: red (`Not archived`), green (`Archived`), light blue / bright cyan (`Archived as "..."`), yellow (`Conflict`), dim (`Local only`). Both commands color the REMOTE column: green (`pushed`), yellow (`ahead`), red (`local`), dim (`-`).

**`printf` byte-vs-character width.** `printf %-Ns` pads a field to N *bytes*, not N display columns. Author names containing multibyte UTF-8 characters (e.g. `ć`, `ž`) are longer in bytes than in characters, so subsequent columns shift left for those rows. `arx status` corrects for this before printing each row: it measures the string in both character count (`${#s}` with the active locale) and byte count (`${#s}` with `LC_ALL=C`), then widens the format field by the difference. The same correction is applied to the STATUS column when the REMOTE column is present — ANSI color codes add invisible bytes to the colored STATUS string, which would otherwise throw off its fixed-width padding.

### Performance (`arx update`, `arx status`, `arx list --author`)

For repos with many branches or archived entries, naive per-branch subprocess calls add up to tens of seconds. Three commands use bulk operations to avoid this.

**`arx update` and `arx status`** share the same two optimisations:

1. **Archive loaded once** – `_arx_read_all` is called once before the branch loop and its output is stored in two in-memory associative arrays: `arc_by_name[branch]=sha` and `arc_by_sha[sha]=name`. All per-branch archive lookups are then O(1) bash hash table reads instead of O(n) subprocess calls.

2. **Single `git for-each-ref` call** – a single call retrieves branch name, SHA, author date, and (for `status`) author name for every branch at once, replacing per-branch `git rev-parse` and `git log` calls:

```bash
# arx status (includes authorname for display)
git for-each-ref \
    --format='%(refname:short)%09%(objectname)%09%(authordate:iso-strict)%09%(authorname)%09%(upstream)' \
    refs/heads/

# arx update (authorname not needed)
git for-each-ref \
    --format='%(refname:short)%09%(objectname)%09%(authordate:iso-strict)%09%(upstream)' \
    refs/heads/
```

`arx update` also keeps the in-memory maps current after processing each branch – `arc_by_name` and `arc_by_sha` are updated regardless of `--dry-run` – so the simulation is accurate, and subsequent branches see the correct in-memory state whether or not writes are actually happening.

**`%(upstream)` must be last.** Tab (`%09`) is an IFS whitespace character. When `%(upstream)` is empty, it produces two consecutive tabs. Because IFS whitespace collapses, `read` treats `<TAB><TAB>` as a single separator – the empty field disappears and all subsequent fields shift left. Placing `%(upstream)` last avoids this: the trailing tab is stripped cleanly, and `upstream_ref` is assigned an empty string, which is the correct behaviour.

**`set -u` and associative arrays.** Accessing a missing key in an associative array with `set -u` enabled triggers an "unbound variable" error in bash 4.x. All array reads use `${arr[key]:-}` to provide an explicit empty-string default and suppress the error.

**`arx list --author`** – archived SHAs are not local branch refs, so `git for-each-ref` does not apply. Instead, all SHAs are collected from the sorted entries and passed to a single `git log --no-walk` call, reducing N subprocess calls to one:

```bash
git log --no-walk --format='%H %an' sha1 sha2 sha3 ...
```

The result is stored in `author_by_sha[sha]=name` and looked up during rendering. gc'd commits are absent from the output and fall back to `(gc)` via `${author_by_sha[$sha]:-\(gc\)}`.

### `arx add` – Conflict Detection

Before writing, `add` calls `_arx_lookup_branch` against the target name (which may be a custom archive name). Four outcomes:

1. **Not archived** – write and report `Archived:`.
2. **Archived with same SHA** – exit 0 with `Already archived:`. Idempotent; safe to call repeatedly.
3. **Archived with different SHA** – conflict. Exit 1 with an error and hints. `--force` overwrites; an `archive-name` argument stores under a different name instead.
4. **Not archived by target name, but SHA already present under a different name** – `_arx_lookup_sha` finds the duplicate. Prints a `Note:` line, then writes anyway (the user explicitly requested this archive entry).

`arx update` applies the same conflict logic for every candidate branch, using the in-memory `arc_by_name` and `arc_by_sha` maps (see Performance section) rather than calling `_arx_lookup_branch` and `_arx_lookup_sha` per branch. If the current SHA is already stored under a different name, the branch is skipped with an `Already safe:` message and counted separately in the summary. This prevents silent duplicate SHA storage during automatic archiving. If the user wants the branch indexed under its natural name too, they can run `git arx add <branch>` explicitly.

### `arx rename`

Implemented as `_arx_write(new) + _arx_delete(old)` – the abstraction layer fans out to all enabled backends automatically. There is no dedicated rename primitive in either backend; write-then-delete is equivalent.

### `arx log` – Argument Passthrough

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

### `arx checkout` – gc Detection

Before attempting to restore, the script checks whether the commit still exists:

```bash
if ! git cat-file -e "$sha"; then
    # commit was garbage collected
fi
```

`git cat-file -e <object>` exits 0 if the object exists in the object store, non-zero otherwise. It does not print anything. This is the correct low-level check – it works for any object type (commit, tree, blob) and does not require the object to be reachable.

### `arx prune`

Finds all archived branches that still exist as local branches, then deletes them.

Key behaviors:
- The currently checked-out branch is always skipped (git would reject the deletion anyway). It is listed separately in the output with a "Skipped (currently checked out)" notice.
- Without `--force`, the full list is printed and the user must type `"yes"` to proceed. This is intentional – `git branch -D` is irreversible from git's perspective (the archive is the only recovery path).
- `--dry-run` prints the same list and count as a real run but skips the confirmation prompt and does not delete anything.

### `arx sync` – Union Merge Algorithm

`sync` is only meaningful when both `arx.storerefs` and `arx.storefile` are enabled, since it reconciles two backends that can theoretically drift.

**When drift happens:**

In normal usage, drift should not occur – every write operation hits both backends atomically (within the script). Drift can arise from:

1. Someone manually edits `.gitarchive` with a text editor
2. Someone manually creates/deletes refs with raw git commands
3. A script crash between the file write and the ref write
4. Running `git fetch origin 'refs/arx/*:refs/arx/*'` directly instead of `git arx pull` (updates local arx refs but bypasses the tracking namespace and the file backend)

**Algorithm:**

```
for each branch in (refs ∪ file):
    refs-only → write to file
    file-only → write to refs
    both, same SHA → no-op
    both, different SHA → conflict
```

Non-conflicting entries are always processed. A conflict does not block other entries from being synced. After processing all entries, if any conflicts occurred, `sync` exits with status 1.

**`--dry-run`:** Runs the same comparison logic and prints the same output as a real sync, but skips all writes. A trailing `(dry run – no changes written)` line is appended. Works with or without `--force-file` / `--force-refs` – output shows exactly what would happen if the flag were run without `--dry-run`.

**`--force-file` / `--force-refs`:** When a SHA conflict is detected and a force flag is present, the designated backend is treated as the source of truth and the other is overwritten. This is an escape hatch for the rare case where the user knows which side is correct.

---

## Shell Completion

`git-arx-completion.bash` defines `_git_arx()` — the function name git-completion.bash looks for when the user presses Tab after `git arx`. The naming convention is the external command name with hyphens replaced by underscores.

The function is context-aware: it offers different completions depending on the subcommand at `words[2]`:

- Subcommand names at `cword == 2` (including aliases: `ls`, `rm`, `mv`)
- Archived branch names (via `git arx list`) for `checkout`, `log`, `remove`/`rm`, `rename`/`mv`
- Local branch names (via `__git_heads`) for `add`
- Per-subcommand flags for everything else

Archived branch names are fetched by calling `git arx list` at tab-press time and stripping the two header lines with `awk NR > 2`. This is a subprocess invocation on every completion for those commands — fast enough in practice, but noticeable on repos with very large archives.

---

## Testing

The test suite lives in `test.sh` and is an integration test suite – it runs the actual `git-arx` script against real git repositories created in a temporary directory. No mocking.

### Running the tests

```bash
bash test.sh
```

No install required. The script resolves the path to `git-arx` relative to its own location, so it works from any working directory.

### Structure

The suite is organized into sections, each exercising one command or scenario:

```
test_help          git arx help / -h
test_add           git arx add (normal, conflict, --force, archive-name)
test_remove        git arx remove
test_rename        git arx rename
test_list          git arx list (sorting, --author, --storage filter)
test_update        git arx update (--dry-run, --force, conflicts, already-safe)
test_log           git arx log (passthrough flags)
test_checkout      git arx checkout (restore, gc'd commit)
test_prune         git arx prune (--dry-run, --force, current branch skipped)
test_merge         git arx merge (dedup, conflicts)
test_refs_backend  refs-only storage
test_both_backend  both backends enabled (union reads, sync)
test_push_pull     git arx push / pull (requires a bare remote)
test_sync          git arx sync (--dry-run, --force-file, --force-refs)
test_slashed_branches  branch names with slashes
test_double_add    idempotency of add
test_error_cases   unknown commands, missing args, bad config
```

Each section uses `assert_ok`, `assert_fails`, and `assert_out` helpers. `assert_out` greps the combined stdout+stderr for a fixed string – tests are intentionally coarse-grained (output substring match) rather than exact, so minor wording changes in messages don't break the suite.

### Test isolation

Each test section resets the archive state via `reset_archive()` before running. This deletes `.gitarchive` and removes all `refs/arx/` refs, then resets storage to `file`-only. Branches deleted during a test are recreated by `recreate_branches()` where needed.

The entire repo lives in a `mktemp -d` temporary directory and is cleaned up via a `trap ... EXIT` at the end of the run.

---

## Versioning

To bump the version to `vX` (e.g. `v1.1`):

1. `git-arx` — update `VERSION="..."` near the top of the file
2. `install.sh` — update `VERSION="..."` to match the new tag (e.g. `"v1.1"`)
3. Commit, then create git tag `vX` and update the `latest` tag

Tag conventions:
- `latest` — always points to the newest release (move it on every release)
- `vX` tags (e.g. `v1`, `v1.1`) — immutable once created, never moved

---

## Known Limitations

- **No locking.** The archive file has no write lock. Concurrent invocations (unlikely for an interactive tool) could corrupt it. Acceptable trade-off.
- **bash 4+ required.** Uses `declare -A` associative arrays. macOS ships bash 3.2; users need to install bash via Homebrew and ensure it's on their PATH.
- **`merge` does not resolve SHA conflicts.** When the same branch appears in two files with different SHAs, the conflict is reported and the entry is skipped. The user must manually decide which SHA is correct and edit the output file. There is no `--force-file` / `--force-refs` equivalent for `merge` (unlike `sync`) because `merge` has no concept of a "primary" source.
- **`push/pull` hardcodes `origin`.** The remote name is not configurable. This could be added via `arx.remote` config in a future version.
- **Bash completion only.** `git-arx-completion.bash` covers bash. zsh and fish completion scripts are not provided.
