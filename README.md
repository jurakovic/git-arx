# git-bx — Branch arXiver

A git tool for archiving local branches. When you delete a branch, `git-bx` keeps a record of its name and last commit so you can list, inspect, and restore it later.

Invoked as `git bx <command>` via a git alias.

---

## Why git-bx?

Every developer eventually accumulates a graveyard of local branches — finished features, abandoned experiments, hotfixes from six months ago. You want to clean them up, but deleting a branch feels permanent. What if you need that commit again? So you leave them. Weeks later you have 40 branches and `git branch` is a wall of noise.

The usual answer is "just use `git reflog`" — but reflog is per-machine, expires after 90 days by default, gives you no branch names, and requires you to remember roughly when you were on that branch.

**Who this is for:**

- **Solo developers** who context-switch between many features and want a clean working tree without anxiety. Archive and delete freely, restore if you ever need to go back.
- **Teams on shared repos** where you don't always know whose branch is whose. `git bx status` shows the committer, so you can skip archiving a colleague's branch that somehow ended up on your machine.
- **Anyone doing periodic repo hygiene.** The whole workflow is three commands: `git bx status` to review, `git bx update` to archive, `git bx prune` to delete. Takes 30 seconds.

**Why not just tag the tip commit?** You could — but then you need to remember to do it before deleting, name it something sensible, and maintain your own tagging convention. `git-bx` does this automatically for all branches at once and keeps a searchable list.

**Why not GitHub/GitLab's "restore branch" button?** That only works if the branch was ever pushed. Local-only work — experiments, WIP commits, half-baked ideas — never touches the remote. Those are exactly the branches most worth archiving.

---

## Installation

**With curl (no clone needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-bx/master/install.sh | bash
```

**From a local clone:**

```bash
bash install.sh
```

Both methods copy `git-bx` to `~/bin` (Windows/MINGW64) or `~/.local/bin` (Linux/macOS), make it executable, and set the global git alias:

```
git config --global alias.bx '!git-bx'
```

If the install directory is not on your `PATH`, the script will tell you what to add to your shell profile.

**Custom install path:**

```bash
bash install.sh /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-bx/master/install.sh | bash -s -- /usr/local/bin
```

**Manual setup (no install script):**

```bash
cp git-bx ~/.local/bin/git-bx
chmod +x ~/.local/bin/git-bx
git config --global alias.bx '!git-bx'
```

---

## Compatibility

Requires **bash 4+** and **git**. Works anywhere those are present.

| Environment | Status | Notes |
|---|---|---|
| Linux | Supported | bash 4+ is standard |
| Windows — Git Bash (MINGW64) | Supported | Ships with bash 4.4+ |
| Windows — WSL | Supported | Linux environment |
| macOS — Homebrew bash | Supported | `brew install bash`, ensure it's first on `$PATH` |
| macOS — system bash | **Not supported** | Ships bash 3.2 (GPL); run `bash --version` to check |
| PowerShell / CMD | **Not supported** | No bash runtime |

The bash 4+ requirement comes from `declare -A` (associative arrays). On stock macOS the script will fail with a syntax error — install bash via Homebrew and confirm `which bash` points to it.

---

## Quick Start

```bash
# Preview which branches would be archived (with author)
git bx status

# Archive all local branches that have no remote tracking branch
git bx update

# Delete the branches you just archived
git bx prune

# See what's archived
git bx list

# Inspect commits on an archived branch
git bx log feature/my-feature --oneline

# Restore a branch
git bx checkout feature/my-feature
```

---

## Commands

### `git bx add <branch>`

Archive a single branch. Stores its name and current HEAD SHA.

```bash
git bx add feature/my-feature
# Archived: feature/my-feature at a1b2c3d4
```

If the branch is already in the archive, this updates its record to the current HEAD.

---

### `git bx remove <branch>`

Remove a branch from the archive.

```bash
git bx remove feature/my-feature
# Removed: feature/my-feature
```

This does not delete the local branch — only removes it from the archive.

---

### `git bx status`

Show which local branches would be archived by `git bx update` — branches with no remote tracking branch — along with their last committer. Nothing is written.

```bash
git bx status
# BRANCH                                   AUTHOR
# ------                                   ------
# feature/old-idea                         Alice Smith
# fix/quick-hack                           Bob Jones
# 2 branch(es) would be archived by "git bx update".
```

Useful as a preview step before running `update`, especially in shared repositories where you want to confirm which branches are yours.

---

### `git bx update`

Archive all local branches that have no remote tracking branch configured. Useful as a regular cleanup step before deleting stale branches.

```bash
git bx update
# Archived: feature/old-idea
# Archived: fix/quick-hack
# Done. Archived 2 branch(es).
```

Branches that have a live upstream (e.g. `origin/main`) are skipped. Branches whose upstream was deleted on the remote (shown as `[gone]` in `git branch -vv`) are archived.

---

### `git bx prune`

Delete all local branches that are currently in the archive. Prompts for confirmation before proceeding.

```bash
git bx prune
# The following local branches will be permanently deleted:
#   feature/old-idea
#   fix/quick-hack
#
# WARNING: This is a dangerous operation. Deleted branches cannot be
# recovered from git — only from the git-bx archive.
# Type "yes" to continue: yes
# Deleted branch feature/old-idea (was a1b2c3d4).
# Deleted branch fix/quick-hack (was deadbeef).
# Done. Deleted 2 branch(es).
```

If you are currently checked out on an archived branch, it is skipped with a notice.

**Options:**

| Option | Description |
|---|---|
| `--force`, `-f` | Skip the confirmation prompt and delete immediately. |

```bash
git bx prune --force
```

A typical workflow is `git bx update` followed by `git bx prune` — archive first, then delete in one step.

---

### `git bx list`

List all archived branches.

```bash
git bx list
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
| `--author` | Add an AUTHOR column showing the last committer on each branch |

```bash
git bx list --sort=name --order=asc
git bx list --storage=refs
git bx list --storage=file
git bx list --author
```

---

### `git bx log <branch> [git-log-flags...]`

Show the commit history of an archived branch. All flags are passed directly to `git log`, so anything that works with `git log` works here.

```bash
git bx log feature/my-feature
git bx log feature/my-feature --oneline
git bx log feature/my-feature --oneline -10
git bx log feature/my-feature --stat
git bx log feature/my-feature --format="%h %s" --since="2 weeks ago"
```

---

### `git bx checkout <branch>`

Restore an archived branch by creating a new local branch at the archived SHA.

```bash
git bx checkout feature/my-feature
# Switched to a new branch 'feature/my-feature'
# Restored branch: feature/my-feature at a1b2c3d4
```

If the commit no longer exists (garbage collected), you will see a warning:

```
git-bx: WARNING: SHA a1b2c3d4 for branch "feature/my-feature" appears to have been garbage collected.
The branch cannot be restored. You can remove it with: git bx remove feature/my-feature
```

If a local branch with the same name already exists, the command exits with an error rather than overwriting it.

---

### `git bx merge <file1> <file2> -o <output>`

Merge two `.gitarchive` files into one. Useful when syncing archives between machines without a shared remote.

```bash
git bx merge .gitarchive /backup/.gitarchive -o merged.gitarchive
# Merged 14 entries to merged.gitarchive (1 conflict(s) skipped)
```

- Entries present in only one file are kept as-is.
- Entries present in both files with the **same SHA** are deduplicated.
- Entries present in both files with **different SHAs** are reported as conflicts and skipped — they will not appear in the output.

Requires `file` storage to be enabled.

---

### `git bx push`

Push archived refs to the remote, making them available to other clones of the repository.

```bash
git bx push
# To origin
#  * [new ref]   refs/bx/feature/my-feature -> refs/bx/feature/my-feature
```

Use `--dry-run` to see what would be pushed without actually pushing:

```bash
git bx push --dry-run
# To origin
#  * [new ref]   refs/bx/feature/my-feature -> refs/bx/feature/my-feature
# (dry run — no changes written)
```

Requires `refs` storage to be enabled.

---

### `git bx pull`

Fetch archived refs from the remote. If `both` storage is configured, the `.gitarchive` file is automatically updated to match.

```bash
git bx pull
# From origin
#  * [new ref]   refs/bx/feature/my-feature -> refs/bx/feature/my-feature
# Synced fetched refs to .gitarchive
```

Requires `refs` storage to be enabled.

---

### `git bx sync`

Reconcile the two local storage backends when they have drifted out of sync. Performs a union merge: anything present in either backend is written to both.

```bash
git bx sync
# Synced to file: feature/old-idea
# Sync complete.
```

**Flags:**

| Flag | Description |
|---|---|
| `--check` | Dry-run. Show differences without making any changes. |
| `--force-file` | Treat `.gitarchive` as the source of truth: resolve SHA conflicts using the file's SHA, and delete any refs-only entries from refs (they are absent from the file). |
| `--force-refs` | Treat refs as the source of truth: resolve SHA conflicts using the ref's SHA, and delete any file-only entries from the file (they are absent from refs). |

```bash
git bx sync --check
# refs-only: feature/old-idea (a1b2c3d4)
# Check complete.

git bx sync --force-refs
# Resolved (force-refs): feature/old-idea -> file=a1b2c3d4
# Removed from file (force-refs): fix/dead-end
# Sync complete.
```

If `sync` encounters a SHA conflict and no `--force-*` flag is given, it reports the conflict and exits with a non-zero status. Entries without conflicts are still synced.

Requires `both` storage to be enabled.

---

### `git bx help`

Print the built-in usage summary.

```bash
git bx help
git bx --help
git bx -h
```

---

## Configuration

All settings are managed via `git config`. They can be set per-repo or globally.

### `bx.storage`

Controls which storage backend(s) are used.

```bash
git config bx.storage both    # default
git config bx.storage file
git config bx.storage refs
```

| Value | Description |
|---|---|
| `both` | Use both backends simultaneously. Recommended default. |
| `file` | Plain text `.gitarchive` file only. |
| `refs` | Git refs under `refs/bx/` only. |

### `bx.file`

Path to the archive file, relative to the repository root. Default: `.gitarchive`.

```bash
git config bx.file .git/bx-archive   # keep it out of the working tree
git config bx.file my-archive.txt
```

---

## Storage Backends

### File backend — `.gitarchive`

A plain text file at the repository root (or wherever `bx.file` points). One entry per line:

```
# git-bx archive — do not edit manually
feature/my-feature a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 2025-11-15T10:30:00+01:00
fix/old-bug deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2025-10-01T08:00:00+00:00
```

**Strengths:**
- Human-readable — inspect it with any text editor or `cat .gitarchive`
- Portable — copy it anywhere, email it, commit it to the repo
- If committed to the repository, it syncs automatically with every `git push`/`git pull`
- Can be merged between machines with `git bx merge`

**Weakness:** The archive is just a text file. Git does not know it exists, so commits referenced in it can be pruned by `git gc` once they become unreachable.

### Refs backend — `refs/bx/`

Git refs stored under `refs/bx/<branch-name>` inside `.git/refs/`. These are standard git refs that git tracks natively.

```bash
# Inspect directly
git show-ref | grep refs/bx/
git log refs/bx/feature/my-feature --oneline
```

**Strengths:**
- As long as a ref exists, `git gc` will never prune the commit it points to
- Native git integration — any git command that accepts a ref or SHA works
- Can be shared via `git bx push` / `git bx pull`

**Weakness:** Lives in `.git/` — not portable, not visible outside the repo. If the repo is recloned from scratch, refs are not automatically restored (unless you pushed them with `git bx push`).

### Both (default)

Uses both backends for every operation. Writes go to both; reads prefer refs and supplement with any file-only entries.

Each backend covers the other's weakness:
- Refs protect commits from gc; file provides portability and human-readability
- If you commit `.gitarchive` to the repo, you get automatic remote sync for free — no need to use `git bx push/pull`

---

## Workflows

### Basic local usage

```bash
# Archive and delete stale branches in two steps
git bx update
git bx prune

# Later, need to find something
git bx list
git bx log feature/done-1 --oneline

# Restore if needed
git bx checkout feature/done-1
```

### Syncing across machines (with a shared remote)

Enable refs storage (included in the default `both`), then push your archived refs along with your normal push:

```bash
git bx update
git bx push
```

On another machine:

```bash
git bx pull
git bx list
```

### Syncing across machines (no shared remote)

Use file storage and copy the `.gitarchive` file between machines:

```bash
# Machine A
git bx update
scp .gitarchive machine-b:~/project/.gitarchive-a

# Machine B
git bx merge .gitarchive .gitarchive-a -o .gitarchive
```

Or commit `.gitarchive` to the repository — it will sync along with the rest of the codebase via normal git push/pull.

### Using only the file backend (lightweight)

If you don't need gc protection and just want a simple log:

```bash
git config bx.storage file
git config bx.file .gitarchive

# Optionally commit it so it syncs with the repo
echo '.gitarchive' >> .gitignore  # or don't, and commit it instead
```

---

## Notes

- `git bx update` detects branches to archive by checking whether the upstream tracking ref exists locally via `git rev-parse --verify`. If `%(upstream)` (the full ref path, e.g. `refs/remotes/origin/branch`) resolves to nothing, the branch is archived. This handles both branches that never had a remote and branches whose remote was deleted (after `git fetch --prune`).
- `git bx add` on an already-archived branch updates the record to the current HEAD — it does not duplicate the entry.
- Branch names with slashes (e.g. `feature/login`) work correctly in both backends.

---

## License

MIT License — see [LICENSE](LICENSE).

---

*Implemented with [Claude Code](https://claude.ai/claude-code). The concept, design, and all product decisions are my own.*
