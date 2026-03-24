# git-arx – Branch Archive Tool for Git

A git tool for archiving local branches. Before you delete a branch, run `git-arx` to keep a record of its name and last commit so you can list, inspect, and restore it later.

---

## Why git-arx?

Every developer eventually accumulates a graveyard of local branches – finished features, abandoned experiments, hotfixes from six months ago. You want to clean them up, but deleting a branch feels permanent. What if you need that commit again? So you leave them. Weeks later you have 40 branches and `git branch` is a wall of noise.

The usual answer is "just use `git reflog`" – but reflog is per-machine, expires after 90 days by default, gives you no branch names, and requires you to remember roughly when you were on that branch.

**Who this is for:**

- **Solo developers** who context-switch between many features and want a clean working tree without anxiety. Archive and delete freely, restore if you ever need to go back.
- **Teams on shared repos** where you don't always know whose branch is whose. `git arx status` shows the committer, so you can skip archiving a colleague's branch that somehow ended up on your machine.
- **Anyone doing periodic repo hygiene.** The whole workflow is three commands: `git arx status` to review, `git arx update` to archive, `git arx prune` to delete. Takes 30 seconds.

**Why not just tag the tip commit?** You could – but then you need to remember to do it before deleting, name it something sensible, and maintain your own tagging convention. `git-arx` does this automatically for all branches at once and keeps a searchable list.

**Why not GitHub/GitLab's "restore branch" button?** That only works if the branch was ever pushed. Local-only work – experiments, WIP commits, half-baked ideas – never touches the remote. Those are exactly the branches most worth archiving.

---

## Compatibility

Requires **bash 4+**. Works anywhere that is present.

| Environment | Status | Notes |
|---|---|---|
| Linux | Supported | bash 4+ is standard |
| macOS – Homebrew bash | Supported | `brew install bash`, ensure it's first on `$PATH` |
| macOS – system bash | **Not supported** | Ships bash 3.2 (GPL); run `bash --version` to check |
| Windows – Git Bash (MINGW64) | Supported | Ships with bash 4.4+ |
| Windows – WSL | Supported | Linux environment |
| PowerShell / CMD | **Not supported** | No bash runtime |

The bash 4+ requirement comes from `declare -A` (associative arrays). On stock macOS the script will fail with a syntax error – install bash via Homebrew and confirm `which bash` points to it.

---

## Installation

**With curl:**

```bash
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/tags/latest/install.sh | bash
```

**From a local clone:**

```bash
bash install.sh
```

Both methods copy `git-arx` to `~/.local/bin` (Linux/macOS) or `~/bin` (Windows/MINGW64), make it executable, and set the global git alias:

```
git config --global alias.arx '!git-arx'
```

If the install directory is not on your `PATH`, the script will tell you what to add to your shell profile.

**Custom install path:**

```bash
bash install.sh /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/tags/latest/install.sh | bash -s -- /usr/local/bin
```

**Manual setup (no install script):**

```bash
cp git-arx ~/.local/bin/git-arx   # Linux/macOS
chmod +x ~/.local/bin/git-arx
git config --global alias.arx '!git-arx'
```

---

## Quick Start

```bash
# Preview archive status of local branches
git arx status

# Archive all local branches that have no remote tracking branch
git arx update

# Delete the branches you just archived
git arx prune

# See what's archived
git arx list

# Inspect commits on an archived branch
git arx log feature/my-feature --oneline

# Restore a branch
git arx checkout feature/my-feature
```

---

## Commands

### `git arx status`

Show all local branches with no remote upstream – the same set that `git arx update` would process – along with their current SHA, date, author, and archive status. Nothing is written.

```bash
git arx status
# BRANCH                                   SHA       DATE         AUTHOR               STATUS
# ------                                   ---       ----         ------               ------
# feature/old-idea                         a1b2c3d4  2025-11-15   Alice Smith          Not archived
# feature/stashed                          f00dface  2025-11-20   Bob Jones            Archived as "feature/stashed-v1"
# fix/quick-hack                           deadbeef  2025-10-01   Charlie Brown        Archived
```

The **STATUS** column reflects the current state of each branch in the archive:

| Status | Meaning |
|---|---|
| `Not archived` | Not in the archive – `update` would archive this branch. |
| `Archived` | Already in the archive with the same SHA – `update` would skip it. |
| `Archived as "<name>"` | SHA is already archived under a different name – `update` would skip it. |
| `Conflict (archived: <sha>)` | In the archive under this name but with a different SHA – `update` would skip it unless `--force`. |

Useful as a preview step before running `update`, especially in shared repositories where you want to confirm which branches are yours. Once satisfied, run `git arx update` to write the archive.

**Options:**

| Option | Description |
|---|---|
| `--sort=name` | Sort alphabetically by branch name (default) |
| `--sort=date` | Sort by commit date |
| `--order=asc` | Ascending order (default) |
| `--order=desc` | Descending order |

```bash
git arx status --sort=date --order=desc
```

---

### `git arx update`

Archive all local branches that have no remote tracking branch configured.

```bash
git arx update
# Archived: feature/old-idea
# Archived: fix/quick-hack
# Done. Archived 2 branch(es).
```

Branches that have a live upstream (e.g. `origin/main`) are skipped. Branches whose upstream was deleted on the remote (shown as `[gone]` in `git branch -vv`) are archived.

Branches that already have the same SHA in the archive are silently skipped. Branches with a **different** SHA in the archive are reported as conflicts and skipped – use `--force` to overwrite them.

```
Conflict: feature/my-feature (archived: a1b2c3d4, current: deadbeef) – skipped
Done. Archived 2 branch(es), 1 conflict(s) skipped.
```

Branches whose current SHA is **already archived under a different name** are also skipped – the SHA is already safe, and no duplicate entry is needed. The summary reports these separately.

```
Already safe: feature/my-feature (a1b2c3d4 archived as "feature/my-feature-old") – skipped
Done. Archived 1 branch(es), 1 already safe (SHA archived under different name).
```

If you do want the branch indexed under its natural name as well (so that `git arx checkout feature/my-feature` works), run `git arx add feature/my-feature` explicitly.

**Options:**

| Option | Description |
|---|---|
| `--force`, `-f` | Overwrite archived entries whose SHA has changed. Outputs `Updated:` instead of `Archived:` for those branches. |
| `--dry-run`, `-n` | Show which branches would be archived or conflict without writing anything. Produces the same output as a real run, followed by `(dry run – no changes written)`. |

```bash
git arx update --dry-run
git arx update --force
```

Run `git arx prune` to delete the archived branches from your local repo.

---

### `git arx prune`

Delete all local branches that are currently in the archive. Prompts for confirmation before proceeding.

```bash
git arx prune
# The following local branches will be permanently deleted:
#   feature/old-idea
#   fix/quick-hack
#
# WARNING: This is a dangerous operation. Deleted branches cannot be
# recovered from git – only from the git-arx archive.
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
| `--dry-run`, `-n` | Show which branches would be deleted without deleting anything. Produces the same output as a real run, followed by `(dry run – no changes written)`. |

```bash
git arx prune --force
git arx prune --dry-run
```

---

### `git arx list`

List all archived branches.

```bash
git arx list
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
| `--storage=file\|refs` | Show only branches from the given backend (default: all configured backends) |
| `--author` | Add an AUTHOR column showing the last committer on each branch |

```bash
git arx list --sort=name --order=asc
git arx list --storage=refs
git arx list --storage=file
git arx list --author
```

---

### `git arx log <branch> [git-log-flags...]`

Show the commit history of an archived branch. All flags are passed directly to `git log`, so anything that works with `git log` works here.

```bash
git arx log feature/my-feature
git arx log feature/my-feature --oneline
git arx log feature/my-feature --oneline -10
git arx log feature/my-feature --stat
git arx log feature/my-feature --format="%h %s" --since="2 weeks ago"
```

---

### `git arx checkout <branch>`

Restore an archived branch by creating a new local branch at the archived SHA.

```bash
git arx checkout feature/my-feature
# Switched to a new branch 'feature/my-feature'
# Restored branch: feature/my-feature at a1b2c3d4
```

If the commit no longer exists (garbage collected), you will see a warning:

```
git-arx: WARNING: SHA a1b2c3d4 for branch "feature/my-feature" appears to have been garbage collected.
The branch cannot be restored. You can remove it with: git arx remove feature/my-feature
```

If a local branch with the same name already exists, the command exits with an error rather than overwriting it.

---

### `git arx add <branch> [archive-name] [--force]`

Archive a single branch manually. Stores its name and current HEAD SHA.

```bash
git arx add feature/my-feature
# Archived: feature/my-feature at a1b2c3d4
```

If the branch is already in the archive with the **same SHA**, the command succeeds silently:

```
Already archived: feature/my-feature at a1b2c3d4
```

If the branch is already in the archive with a **different SHA** (a conflict), the command exits with an error and suggests two options:

```
git-arx: conflict: "feature/my-feature" is already archived at a1b2c3d4 (current: deadbeef)
To overwrite:                  git arx add feature/my-feature --force
To archive under a new name:   git arx add feature/my-feature <archive-name>
```

If the branch's current SHA is **already archived under a different name**, a note is printed before archiving – the command still proceeds, since you explicitly asked for it:

```
Note: a1b2c3d4 is already archived as "feature/my-feature-old"
Archived: feature/my-feature at a1b2c3d4
```

**Options and arguments:**

| Argument / Option | Description |
|---|---|
| `archive-name` | Archive under this name instead of the branch name. Useful when an existing archive entry would conflict. |
| `--force`, `-f` | Overwrite an existing archive entry, even if the SHA differs. |

```bash
# Overwrite the existing archive entry
git arx add feature/my-feature --force

# Store under a different name to avoid conflict
git arx add feature/my-feature feature/my-feature-old
```

`git arx add` never creates duplicate entries – the archive stores exactly one record per name. Running it again on an already-archived branch with the same SHA exits 0 silently. If the SHA has changed, it errors with a conflict; use `--force` to overwrite.

---

### `git arx remove <branch>`

Remove a branch from the archive.

```bash
git arx remove feature/my-feature
# Removed: feature/my-feature
```

This does not delete the local branch – only removes it from the archive.

---

### `git arx rename <old-name> <new-name>`

Rename an archived branch. Updates the entry in all enabled backends.

```bash
git arx rename feature/my-feature feature/my-feature-v1
# Renamed: feature/my-feature -> feature/my-feature-v1
```

The command exits with an error if the old name is not in the archive, or if the new name already exists.

**Why this is useful – git ref namespace collisions:**

The refs backend stores entries as git refs under `refs/arx/<branch-name>`. Because git refs are hierarchical (stored as files in a directory tree), a branch named `update` stored as `refs/arx/update` and a branch named `update/packages` stored as `refs/arx/update/packages` cannot coexist – `refs/arx/update` is either a file or a directory, not both.

If this situation arises, rename the existing shorter entry first:

```bash
git arx rename update update-legacy
git arx add update/packages   # now refs/arx/update/ can be created
```

---

### `git arx merge <file1> <file2> -o <output>`

Merge two `.gitarchive` files into one. Useful when syncing archives between machines without a shared remote.

```bash
git arx merge .gitarchive /backup/.gitarchive -o merged.gitarchive
# Merged 14 entries to merged.gitarchive (1 conflict(s) skipped)
```

- Entries present in only one file are kept as-is.
- Entries present in both files with the **same SHA** are deduplicated.
- Entries present in both files with **different SHAs** are reported as conflicts and skipped – they will not appear in the output.

Requires `arx.storefile` to be enabled.

---

### `git arx push`

Push archived refs to the remote, making them available to other clones of the repository.

```bash
git arx push
# To origin
#  * [new ref]   refs/arx/feature/my-feature -> refs/arx/feature/my-feature
```

Use `--dry-run` (`-n`) to see what would be pushed without actually pushing:

```bash
git arx push --dry-run
# To origin
#  * [new ref]   refs/arx/feature/my-feature -> refs/arx/feature/my-feature
# (dry run – no changes written)
```

Requires `arx.storerefs` to be enabled.

---

### `git arx pull`

Fetch archived refs from the remote. If `arx.storefile` is also enabled, the `.gitarchive` file is automatically updated to match.

```bash
git arx pull
# From origin
#  * [new ref]   refs/arx/feature/my-feature -> refs/arx/feature/my-feature
# Synced fetched refs to .gitarchive
```

Requires `arx.storerefs` to be enabled.

---

### `git arx sync`

Reconcile the two local storage backends when they have drifted out of sync. Performs a union merge: anything present in either backend is written to both.

```bash
git arx sync
# Synced to file: feature/old-idea
# Sync complete.
```

**Flags:**

| Flag | Description |
|---|---|
| `--dry-run`, `-n` | Show what would change without making any changes. Produces the same output as a real run, followed by `(dry run – no changes written)`. Combine with `--force-file` or `--force-refs` to preview what those would do. |
| `--force-file` | Treat `.gitarchive` as the source of truth: resolve SHA conflicts using the file's SHA, and delete any refs-only entries from refs (they are absent from the file). |
| `--force-refs` | Treat refs as the source of truth: resolve SHA conflicts using the ref's SHA, and delete any file-only entries from the file (they are absent from refs). |

```bash
git arx sync --dry-run
# Synced to file: feature/old-idea
# Sync complete.
# (dry run – no changes written)

git arx sync --dry-run --force-refs
# Resolved (force-refs): feature/old-idea -> file=a1b2c3d4
# Removed from file (force-refs): fix/dead-end
# Sync complete.
# (dry run – no changes written)

git arx sync --force-refs
# Resolved (force-refs): feature/old-idea -> file=a1b2c3d4
# Removed from file (force-refs): fix/dead-end
# Sync complete.
```

If `sync` encounters a SHA conflict and no `--force-*` flag is given, it reports the conflict and exits with a non-zero status. Entries without conflicts are still synced.

Requires both `arx.storerefs` and `arx.storefile` to be enabled.

---

Run `git arx help` (or `--help`, `-h`) to print the built-in usage summary at any time.

---

## Storage Backends

### Refs backend – `refs/arx/` (enabled by default)

Git refs stored under `refs/arx/<branch-name>` inside `.git/refs/` (configurable via `arx.refsprefix`). These are standard git refs that git tracks natively.

```bash
# Inspect directly
git show-ref | grep refs/arx/
git log refs/arx/feature/my-feature --oneline
```

**Strengths:**
- As long as a ref exists, `git gc` will never prune the commit it points to – archived commits are safe
- Native git integration – any git command that accepts a ref or SHA works
- Can be shared via `git arx push` / `git arx pull`

**Weakness:** Lives in `.git/` – not portable, not visible outside the repo. If the repo is recloned from scratch, refs are not automatically restored (unless you pushed them with `git arx push`).

**Why it's on by default:** The primary promise of git-arx is that you can archive a branch and restore it later. If only the file backend is used, a `git gc` run after deletion can silently prune the archived commit – the record in `.gitarchive` becomes a dead pointer. The refs backend prevents this at no cost to the user. Safety first.

### File backend – `.gitarchive` (disabled by default)

A plain text file at the repository root (or wherever `arx.filepath` points). One entry per line:

```
# git-arx archive – do not edit manually
feature/my-feature a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 2025-11-15T10:30:00+01:00
fix/old-bug deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2025-10-01T08:00:00+00:00
```

**Strengths:**
- Human-readable – inspect it with any text editor or `cat .gitarchive`
- Portable – copy it anywhere, email it, commit it to the repo
- If committed to the repository, it syncs automatically with every `git push`/`git pull`
- Can be merged between machines with `git arx merge`

**Weakness:** The archive is just a text file. Git does not know it exists, so commits referenced in it can be pruned by `git gc` once they become unreachable (if the refs backend is also disabled).

**Why it's off by default:** Most users don't need a visible file in their working tree. The refs backend already provides durable, GC-safe storage locally. Enable the file backend when you want a human-readable audit trail, to commit the archive to the repo for team sharing, or to sync archives between machines without a shared remote.

### Using both backends together

Enable both for maximum coverage – refs protect commits from GC, while the file provides a portable, human-readable backup that can be committed to the repo and shared via normal `git push`/`git pull`.

```bash
git config arx.storerefs true
git config arx.storefile true
```

With both enabled, writes go to both backends; reads prefer refs and supplement with any file-only entries. The `git arx sync` command reconciles the two if they drift.

---

## Configuration

All settings are managed via `git config`. They can be set per-repo or globally.

### `arx.storerefs`

Controls whether the refs backend is used. Default: `true`. The refs prefix defaults to `refs/arx/` and can be changed with `arx.refsprefix`.

```bash
git config arx.storerefs true   # default – GC-safe local storage
git config arx.storerefs false  # disable if you use file backend only
```

### `arx.storefile`

Controls whether the file backend (`.gitarchive`) is used. Default: `false`.

```bash
git config arx.storefile true   # enable for human-readable archives or team sharing
git config arx.storefile false  # default
```

### `arx.filepath`

Path to the archive file, relative to the repository root. Default: `.gitarchive`.

```bash
git config arx.filepath .git/arx-archive   # keep it out of the working tree
git config arx.filepath my-archive.txt
```

### `arx.refsprefix`

Refs namespace prefix for the refs backend. Default: `refs/arx/`. Must start with `refs/` and end with `/`.

```bash
git config arx.refsprefix refs/arx/        # default
git config arx.refsprefix refs/archive/    # custom namespace
```

Changing this after branches are already archived under the old prefix will orphan the existing refs. Migrate by running `git arx push` before changing, updating the prefix on both ends, then running `git arx pull`.

---

## Workflows

### Basic local usage

```bash
# Archive and delete stale branches in two steps
git arx update
git arx prune

# Later, need to find something
git arx list
git arx log feature/done-1 --oneline

# Restore if needed
git arx checkout feature/done-1
```

### Syncing across machines (with a shared remote)

The refs backend is enabled by default, so just push your archived refs along with your normal push:

```bash
git arx update
git arx push
```

On another machine:

```bash
git arx pull
git arx list
```

### Syncing across machines (no shared remote)

Use file storage and copy the `.gitarchive` file between machines:

```bash
# Machine A
git arx update
scp .gitarchive machine-b:~/project/.gitarchive-a

# Machine B
git arx merge .gitarchive .gitarchive-a -o .gitarchive
```

Or commit `.gitarchive` to the repository – it will sync along with the rest of the codebase via normal git push/pull.

### Using the file backend for team sharing

Enable the file backend and commit `.gitarchive` to the repo – it will sync automatically with every `git push`/`git pull`, no `git arx push/pull` needed:

```bash
git config arx.storefile true
# Optionally commit it so it syncs with the repo
echo '.gitarchive' >> .gitignore  # or don't, and commit it instead
```

### Using only the file backend (no GC protection)

If you prefer a visible text file and are not concerned about `git gc`:

```bash
git config arx.storefile true
git config arx.storerefs false
```

---

## Notes

- Branch names with slashes (e.g. `feature/login`) work correctly in both backends.

---

## Internals

Implementation details, design decisions, and architectural notes are in [INTERNALS.md](INTERNALS.md).

---

## License

MIT License – see [LICENSE](LICENSE).

---

*Implemented with [Claude Code](https://claude.com/product/claude-code). The concept, design, and all product decisions are my own.*
