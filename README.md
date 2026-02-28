# git-bra — BRanch Archiver

A git tool for archiving local branches. When you delete a branch, `git-bra` keeps a record of its name and last commit so you can list, inspect, and restore it later.

Invoked as `git bra <command>` via a git alias.

---

## Installation

```bash
bash install.sh
```

This copies `git-bra` to `~/bin` (Windows/MINGW64) or `~/.local/bin` (Linux/macOS), makes it executable, and sets the global git alias:

```
git config --global alias.bra '!git-bra'
```

If the install directory is not on your `PATH`, the script will tell you what to add to your shell profile.

**Custom install path:**

```bash
bash install.sh /usr/local/bin
```

**Manual setup (no install script):**

```bash
cp git-bra ~/.local/bin/git-bra
chmod +x ~/.local/bin/git-bra
git config --global alias.bra '!git-bra'
```

---

## Quick Start

```bash
# Archive all local branches that have no remote tracking branch
git bra update

# See what's archived
git bra list

# Inspect commits on an archived branch
git bra log feature/my-feature --oneline

# Restore a branch
git bra checkout feature/my-feature
```

---

## Commands

### `git bra add <branch>`

Archive a single branch. Stores its name and current HEAD SHA.

```bash
git bra add feature/my-feature
# Archived: feature/my-feature at a1b2c3d4
```

If the branch is already in the archive, this updates its record to the current HEAD.

---

### `git bra remove <branch>`

Remove a branch from the archive.

```bash
git bra remove feature/my-feature
# Removed: feature/my-feature
```

This does not delete the local branch — only removes it from the archive.

---

### `git bra update`

Archive all local branches that have no remote tracking branch configured. Useful as a regular cleanup step before deleting stale branches.

```bash
git bra update
# Archived: feature/old-idea
# Archived: fix/quick-hack
# Done. Archived 2 branch(es).
```

Branches that have a live upstream (e.g. `origin/main`) are skipped. Branches whose upstream was deleted on the remote (shown as `[gone]` in `git branch -vv`) are archived.

---

### `git bra list`

List all archived branches.

```bash
git bra list
# BRANCH                                   SHA       DATE
# ------                                   ---       ----
# feature/my-feature                       a1b2c3d4  2025-11-15
# fix/old-bug                              deadbeef  2025-10-01
```

**Options:**

| Option | Description |
|---|---|
| `--sort=name` | Sort alphabetically by branch name |
| `--sort=date` | Sort by commit date (default) |
| `--order=asc` | Ascending order |
| `--order=desc` | Descending order (default) |
| `--storage=file\|refs\|both` | Show only branches from the given backend (default: configured storage) |

```bash
git bra list --sort=name --order=asc
git bra list --storage=refs
git bra list --storage=file
```

---

### `git bra log <branch> [git-log-flags...]`

Show the commit history of an archived branch. All flags are passed directly to `git log`, so anything that works with `git log` works here.

```bash
git bra log feature/my-feature
git bra log feature/my-feature --oneline
git bra log feature/my-feature --oneline -10
git bra log feature/my-feature --stat
git bra log feature/my-feature --format="%h %s" --since="2 weeks ago"
```

---

### `git bra checkout <branch>`

Restore an archived branch by creating a new local branch at the archived SHA.

```bash
git bra checkout feature/my-feature
# Switched to a new branch 'feature/my-feature'
# Restored branch: feature/my-feature at a1b2c3d4
```

If the commit no longer exists (garbage collected), you will see a warning:

```
git-bra: WARNING: SHA a1b2c3d4 for branch "feature/my-feature" appears to have been garbage collected.
The branch cannot be restored. You can remove it with: git bra remove feature/my-feature
```

If a local branch with the same name already exists, the command exits with an error rather than overwriting it.

---

### `git bra merge <file1> <file2> -o <output>`

Merge two `.gitarchive` files into one. Useful when syncing archives between machines without a shared remote.

```bash
git bra merge .gitarchive /backup/.gitarchive -o merged.gitarchive
# Merged 14 entries to merged.gitarchive (1 conflict(s) skipped)
```

- Entries present in only one file are kept as-is.
- Entries present in both files with the **same SHA** are deduplicated.
- Entries present in both files with **different SHAs** are reported as conflicts and skipped — they will not appear in the output.

Requires `file` storage to be enabled.

---

### `git bra remote push`

Push archived refs to the remote, making them available to other clones of the repository.

```bash
git bra remote push
# To origin
#  * [new ref]   refs/bra/feature/my-feature -> refs/bra/feature/my-feature
```

Requires `refs` storage to be enabled.

---

### `git bra remote pull`

Fetch archived refs from the remote. If `both` storage is configured, the `.gitarchive` file is automatically updated to match.

```bash
git bra remote pull
# From origin
#  * [new ref]   refs/bra/feature/my-feature -> refs/bra/feature/my-feature
# Synced fetched refs to .gitarchive
```

Requires `refs` storage to be enabled.

---

### `git bra sync`

Reconcile the two local storage backends when they have drifted out of sync. Performs a union merge: anything present in either backend is written to both.

```bash
git bra sync
# Synced to file: feature/old-idea
# Sync complete.
```

**Flags:**

| Flag | Description |
|---|---|
| `--check` | Dry-run. Show differences without making any changes. |
| `--force-file` | On SHA conflict, use `.gitarchive` as the source of truth. |
| `--force-refs` | On SHA conflict, use refs as the source of truth. |

```bash
git bra sync --check
# refs-only: feature/old-idea (a1b2c3d4)
# Check complete.

git bra sync --force-refs
# Resolved (force-refs): feature/old-idea -> file=a1b2c3d4
# Sync complete.
```

If `sync` encounters a SHA conflict and no `--force-*` flag is given, it reports the conflict and exits with a non-zero status. Entries without conflicts are still synced.

Requires `both` storage to be enabled.

---

### `git bra help`

Print the built-in usage summary.

```bash
git bra help
git bra --help
git bra -h
```

---

## Configuration

All settings are managed via `git config`. They can be set per-repo or globally.

### `bra.storage`

Controls which storage backend(s) are used.

```bash
git config bra.storage both    # default
git config bra.storage file
git config bra.storage refs
```

| Value | Description |
|---|---|
| `both` | Use both backends simultaneously. Recommended default. |
| `file` | Plain text `.gitarchive` file only. |
| `refs` | Git refs under `refs/bra/` only. |

### `bra.file`

Path to the archive file, relative to the repository root. Default: `.gitarchive`.

```bash
git config bra.file .git/bra-archive   # keep it out of the working tree
git config bra.file my-archive.txt
```

---

## Storage Backends

### File backend — `.gitarchive`

A plain text file at the repository root (or wherever `bra.file` points). One entry per line:

```
# git-bra archive — do not edit manually
feature/my-feature a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 2025-11-15T10:30:00+01:00
fix/old-bug deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2025-10-01T08:00:00+00:00
```

**Strengths:**
- Human-readable — inspect it with any text editor or `cat .gitarchive`
- Portable — copy it anywhere, email it, commit it to the repo
- If committed to the repository, it syncs automatically with every `git push`/`git pull`
- Can be merged between machines with `git bra merge`

**Weakness:** The archive is just a text file. Git does not know it exists, so commits referenced in it can be pruned by `git gc` once they become unreachable.

### Refs backend — `refs/bra/`

Git refs stored under `refs/bra/<branch-name>` inside `.git/refs/`. These are standard git refs that git tracks natively.

```bash
# Inspect directly
git show-ref | grep refs/bra/
git log refs/bra/feature/my-feature --oneline
```

**Strengths:**
- As long as a ref exists, `git gc` will never prune the commit it points to
- Native git integration — any git command that accepts a ref or SHA works
- Can be shared via `git bra remote push` / `git bra remote pull`

**Weakness:** Lives in `.git/` — not portable, not visible outside the repo. If the repo is recloned from scratch, refs are not automatically restored (unless you pushed them with `git bra remote push`).

### Both (default)

Uses both backends for every operation. Writes go to both; reads prefer refs and supplement with any file-only entries.

Each backend covers the other's weakness:
- Refs protect commits from gc; file provides portability and human-readability
- If you commit `.gitarchive` to the repo, you get automatic remote sync for free — no need to use `git bra remote push/pull`

---

## Workflows

### Basic local usage

```bash
# Before cleaning up branches
git bra update
git branch -d feature/done-1 feature/done-2

# Later, need to find something
git bra list
git bra log feature/done-1 --oneline

# Restore if needed
git bra checkout feature/done-1
```

### Syncing across machines (with a shared remote)

Enable refs storage (included in the default `both`), then push your archived refs along with your normal push:

```bash
git bra update
git bra remote push
```

On another machine:

```bash
git bra remote pull
git bra list
```

### Syncing across machines (no shared remote)

Use file storage and copy the `.gitarchive` file between machines:

```bash
# Machine A
git bra update
scp .gitarchive machine-b:~/project/.gitarchive-a

# Machine B
git bra merge .gitarchive .gitarchive-a -o .gitarchive
```

Or commit `.gitarchive` to the repository — it will sync along with the rest of the codebase via normal git push/pull.

### Using only the file backend (lightweight)

If you don't need gc protection and just want a simple log:

```bash
git config bra.storage file
git config bra.file .gitarchive

# Optionally commit it so it syncs with the repo
echo '.gitarchive' >> .gitignore  # or don't, and commit it instead
```

---

## Notes

- `git bra update` detects branches to archive by checking whether the upstream tracking ref exists locally via `git rev-parse --verify`. If `%(upstream)` (the full ref path, e.g. `refs/remotes/origin/branch`) resolves to nothing, the branch is archived. This handles both branches that never had a remote and branches whose remote was deleted (after `git fetch --prune`).
- `git bra add` on an already-archived branch updates the record to the current HEAD — it does not duplicate the entry.
- Branch names with slashes (e.g. `feature/login`) work correctly in both backends.
- The tool requires bash 4+ (for associative arrays). Git for Windows ships with bash 4.4 or later.
