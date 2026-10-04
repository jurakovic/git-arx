# git-arx

`git-arx` is a git tool for archiving local branches. Before you delete a branch, run `git-arx` to keep a record of its name and last commit so you can list, inspect, and restore it later.

---

## Table of Contents

- [Why git-arx?](#why-git-arx)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Compatibility](#compatibility)
- [Commands](#commands)
- [Storage Backends](#storage-backends)
  - [Clone size](#clone-size)
- [Configuration](#configuration)
- [Workflows](#workflows)
- [Shell Completion](#shell-completion)
- [Internals](#internals)
- [License](#license)

---

## Why git-arx?

Every developer eventually accumulates a graveyard of local branches – finished features, abandoned experiments, hotfixes from six months ago. You want to clean them up, but deleting a branch feels permanent. What if you need that commit again? So you leave them. Weeks later you have 40 branches and `git branch` is a wall of noise.

The usual answer is "just use `git reflog`" – but reflog is per-machine, expires after 90 days by default, gives you no branch names, and requires you to remember roughly when you were on that branch.

**Who this is for:**

- **Solo developers** who context-switch between many features and want a clean working tree without anxiety. Archive and delete freely, restore if you ever need to go back.
- **Teams on shared repos** where you don't always know whose branch is whose. `git arx status` shows the committer, so you can skip archiving a colleague's branch that somehow ended up on your machine.
- **Anyone doing periodic repo hygiene.** The whole workflow is three commands: `git arx status` to review, `git arx update` to archive, `git arx prune` to delete. Takes 30 seconds.

**Why not just tag the tip commit?** `git tag archive/my-feature my-feature` is the most common advice online, and it works – but it is manual and one branch at a time. You have to remember to do it before each deletion, invent a naming convention, and maintain it yourself. There is no bulk operation, no way to survey which branches are already archived, and no clean restoration command. Tags also live in the same namespace as release tags, so they show up in `git tag -l` and anywhere else tags are listed. `git-arx` automates the discovery and archiving for all stale branches at once and keeps the archive separate from your release history.

**Why not rename branches with a prefix?** `git branch -m old-feature archive/old-feature` keeps the branch visible with a prefix, which does not solve the original problem – the branch still appears in `git branch` output, just with a different name.

**Why not GitHub/GitLab's "restore branch" button?** That only works if the branch was ever pushed. Local-only work – experiments, WIP commits, half-baked ideas – never touches the remote. Those are exactly the branches most worth archiving.

---

## Installation

**Install the latest version from GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/install.sh | bash
```

**Alternatively, install from a local clone:**

```bash
git clone https://github.com/jurakovic/git-arx.git
cd git-arx
bash install.sh
```

Both methods copy `git-arx` to `~/.local/bin` (Linux/macOS) or `~/bin` (Windows/MINGW64), make it executable, and set the global git alias:

```bash
git config --global alias.arx '!git-arx'
```

If the install directory is not on your `PATH`, the script will tell you what to add to your shell profile.

**Custom install path:**

```bash
bash install.sh /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/install.sh | bash -s -- /usr/local/bin
```

**Manual setup (no install script):**

```bash
cp git-arx ~/.local/bin/git-arx   # Linux/macOS
chmod +x ~/.local/bin/git-arx
git config --global alias.arx '!git-arx'
```

**Uninstall:**

```bash
bash uninstall.sh
curl -fsSL https://raw.githubusercontent.com/jurakovic/git-arx/refs/heads/master/uninstall.sh | bash
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

## Compatibility

Requires **bash 4+**. When invoked as `git arx`, Git for Windows provides its own bash runtime, so PowerShell and CMD work without bash on `$PATH`.

| Environment | Status | Notes |
|---|---|---|
| Linux | Supported | bash 4+ is standard |
| macOS – Homebrew bash | Supported | `brew install bash`, ensure it's first on `$PATH` |
| macOS – system bash | **Not supported** | Ships bash 3.2 (GPL); run `bash --version` to check |
| Windows – Git Bash (MINGW64) | Supported | Ships with bash 4.4+ |
| Windows – WSL | Supported | Linux environment |
| PowerShell / CMD | Supported | Git for Windows provides the bash runtime; `git arx` works, no shell completion |

The bash 4+ requirement comes from `declare -A` (associative arrays). On stock macOS the script will fail with a syntax error – install bash via Homebrew and confirm `which bash` points to it.

---

## Commands

### `git arx status`

Show all local branches with no remote upstream – the same set that `git arx update` would process – along with their current SHA, commit date and time, author, and archive status. Nothing is written.

Use `--all` / `-a` to also include never-pushed local branches (shown as `Local only`) and archived branches that no longer exist locally. Branches with a live remote upstream are never listed.

```bash
git arx status
# BRANCH                                   SHA       DATE                  AUTHOR               STATUS
# ------                                   ---       ----                  ------               ------
# feature/old-idea                         a1b2c3d4  2025-11-15 10:30:00   Alice Smith          Not archived
# feature/stashed                          f00dface  2025-11-20 14:05:12   Bob Jones            Archived as "feature/stashed-v1"
# fix/quick-hack                           deadbeef  2025-10-01 08:00:00   Charlie Brown        Archived
```

The **STATUS** column reflects the current state of each branch in the archive:

| Status | Meaning |
|---|---|
| `Not archived` | Not in the archive – `update` would archive this branch. |
| `Archived` | Already in the archive with the same SHA – `update` would skip it. |
| `Archived as "<name>"` | SHA is already archived under a different name – `update` would skip it. |
| `Conflict (archived: <sha>)` | In the archive under this name but with a different SHA – `update` would skip it unless `--force`. |
| `Local only` | Never pushed to any remote – only visible with `--all`. `update` does not process these; use `git arx add` to archive manually. |

When writing to a terminal, status values are color-coded: `Not archived` in red, `Archived` in green, `Archived as "..."` in light blue, `Conflict` in yellow, and `Local only` in dim.

With `--all`, a **REMOTE** column is also shown (when the refs backend is active), indicating the remote state of each ref. Values are the same as in `git arx list` (`pushed`, `ahead`, `local`, `-`), plus one additional value:

| Value | Meaning |
|---|---|
| `remote` | Not in the local archive but still exists on the remote — recoverable via `git arx pull`. |

Useful as a preview step before running `update`, especially in shared repositories where you want to confirm which branches are yours. Once satisfied, run `git arx update` to write the archive.

**Options:**

| Option | Description |
|---|---|
| `--sort=name` | Sort alphabetically by branch name (default) |
| `--sort=date` | Sort by commit date – by when the commit was made, even across timezones; the DATE column shows each author's local time |
| `--order=asc` | Ascending order |
| `--order=desc` | Descending order |
| `--all`, `-a` | Also show never-pushed branches and archived branches with no local counterpart |

The default order depends on the sort key: `asc` for `--sort=name`, `desc` for `--sort=date`. When dates are equal, name is used as a tiebreaker.

```bash
git arx status --sort=date
git arx status --sort=date --order=asc
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
| `--force`, `-f` | Overwrite archived entries whose SHA has changed. Outputs `Updated:` instead of `Archived:` for those branches. Branches that are "already safe" (current SHA archived under a different name) are still skipped; use `git arx add <branch>` to index them under their own name. |
| `--dry-run`, `-n` | Show which branches would be archived or conflict without writing anything. Produces the same output as a real run, followed by `(dry run – no changes written)`. |

```bash
git arx update --dry-run
git arx update --force
```

Run `git arx prune` to delete the archived branches from your local repo.

---

### `git arx prune`

Delete all local branches whose current commit is in the archive. Prompts for confirmation before proceeding.

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

A branch is matched by **commit**, not by name – the same rule `status` and `update` use. This has two consequences.

A branch whose commit is archived under a **different name** is deleted, because the commit is already safe under that other name. The name change is shown in the list so you see it before confirming – after deletion, the branch is restorable only under the archived name:

```
# The following local branches will be permanently deleted:
#   feature/my-feature (archived as "feature/my-feature-old")
```

A branch that merely happens to sit on the same commit as an archived branch – your default branch after a fast-forward merge, for instance – is left alone. To be deleted this way, the branch has to have been archived itself: either it is already in the archive under its own name, or its remote branch was deleted (the `update` "already safe" case).

A branch whose **name** is in the archive but which has moved on to a commit that is in no archive entry at all is *not* deleted – deleting it would lose those commits for good. It is reported as a conflict and skipped, and the command exits non-zero:

```
# Skipped (archived at a different SHA – re-archive with "git arx add <branch> --force"):
#   feature/my-feature (archived: a1b2c3d4, current: deadbeef)
#
# Done. Deleted 2 branch(es), 1 conflict(s) skipped.
```

Run `git arx add <branch> --force` to re-archive it at its current SHA, then prune again. If several branches are affected and their remotes are gone, `git arx update --force` re-archives them in one go.

With both backends enabled, only refs count when deciding what to delete – a ref is what keeps the commit from being garbage collected once its branch is gone. A branch whose archive entry exists only in `.gitarchive` (the backends have drifted, or the entry came from a teammate's committed archive file) is skipped with a notice, and the command exits non-zero. Run `git arx sync` to write the missing refs, then prune again:

```
# Skipped (archived in the file only, no ref protects the commit – run "git arx sync", then prune again):
#   feature/from-teammate
```

Branches that are not in the archive at all are left alone silently, as are branches whose remote branch still exists. A branch that is checked out – here or in another worktree (`git worktree`) – is skipped with a notice, including when it has moved past its archived SHA; branches checked out elsewhere are listed with their worktree's path.

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

List all archived branches. Alias: `ls`.

```bash
git arx list
# BRANCH                                   SHA       DATE                  REMOTE
# ------                                   ---       ----                  ------
# feature/my-feature                       a1b2c3d4  2025-11-15 10:30:00   pushed
# fix/old-bug                              deadbeef  2025-10-01 08:00:00   local
```

The **REMOTE** column is shown when the refs backend is active (the default). It reflects the last known remote state — updated by `git arx push` and `git arx pull`, with no network call at list time:

| Value | Meaning |
|---|---|
| `pushed` | Remote has this ref at the same SHA. |
| `ahead` | Remote has this ref but at a different (older) SHA — you have unpushed changes. |
| `local` | Remote has never seen this ref. |

**Options:**

| Option | Description |
|---|---|
| `--sort=name` | Sort alphabetically by branch name |
| `--sort=date` | Sort by commit date (default) – by when the commit was made, even across timezones |
| `--order=asc` | Ascending order |
| `--order=desc` | Descending order |
| `--storage=file\|refs` | Show only branches from the given backend (default: all configured backends). Hides the REMOTE column when `file` is specified. |
| `--author` | Add an AUTHOR column showing the last committer on each branch |

The default order depends on the sort key: `desc` for `--sort=date`, `asc` for `--sort=name`. When dates are equal, name is used as a tiebreaker.

```bash
git arx list --sort=name
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
| `archive-name` | Archive under this name instead of the branch name. Useful when an existing archive entry would conflict. Must be a valid branch name, since `checkout` restores it as one. |
| `--force`, `-f` | Overwrite an existing archive entry, even if the SHA differs. |

```bash
# Overwrite the existing archive entry
git arx add feature/my-feature --force
# Archived: feature/my-feature at deadbeef

# Store under a different name to avoid conflict
git arx add feature/my-feature feature/my-feature-old
# Archived: feature/my-feature (as feature/my-feature-old) at deadbeef
```

`git arx add` never creates duplicate entries – the archive stores exactly one record per name. Running it again on an already-archived branch with the same SHA exits 0 silently. If the SHA has changed, it errors with a conflict; use `--force` to overwrite.

---

### `git arx remove <branch>`

Remove a branch from the archive. Alias: `rm`.

```bash
git arx remove feature/my-feature
# Removed: feature/my-feature
```

This does not delete the local branch – only removes it from the archive.

---

### `git arx rename <old-name> <new-name>`

Rename an archived branch. Updates the entry in all enabled backends. Alias: `mv`.

```bash
git arx rename feature/my-feature feature/my-feature-v1
# Renamed: feature/my-feature -> feature/my-feature-v1
```

The command exits with an error if the old name is not in the archive, if the new name already exists, or if the new name is not a valid branch name.

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
- Entries present in both files with **different SHAs** are reported as conflicts and skipped – they will not appear in the output, and the command exits with a non-zero status.

Both files are read exactly like the archive itself, so lines that aren't valid entries are reported and left out.

Requires `arx.storefile` to be enabled.

---

### `git arx push`

Push archived refs to the remote, making them available to other clones of the repository. The outcome is listed per ref, and local remote-tracking refs are updated for every ref the remote accepted, so that `git arx list` and `git arx status --all` can report accurate `REMOTE` values without a network call.

```bash
git arx push
# Pushed: feature/my-feature (new)
# Done. Pushed 1 ref(s).
```

A ref the remote refuses – re-archived here at a commit that does not descend from the remote copy, or changed on the remote since your last pull – is reported, the other refs are still pushed and tracked, and the command exits non-zero:

```
# Pushed: feature/new-one (new)
# Rejected: feature/my-feature (non-fast-forward)
# Done. Pushed 1 ref(s), 1 rejected.
# Run "git arx fetch" to see which side changed; "git arx push --force" replaces the remote copies.
```

Use `--force` (`-f`) to force-push refs whose SHA has changed (e.g. after re-archiving a branch at a different commit):

```bash
git arx push --force
```

Use `--dry-run` (`-n`) to see what would be pushed without actually pushing:

```bash
git arx push --dry-run
# Pushed: feature/my-feature (new)
# Done. Pushed 1 ref(s).
# (dry run – no changes written)
```

Use `--delete` (`-d`) to delete a single archived ref from the remote. Also cleans up the local remote-tracking ref:

```bash
git arx push --delete feature/my-feature
```

Use `--prune` to delete all remote refs that no longer exist in the local archive — the mirror image of a normal push:

```bash
git arx push --prune
```

Requires `arx.storerefs` to be enabled.

---

### `git arx fetch`

Preview what `git arx pull` would bring in, without downloading anything. Uses `git ls-remote` to query the remote and compares against local refs — no objects are transferred.

```bash
git arx fetch
# BRANCH                                   SHA       STATUS
# ------                                   ---       ------
# feature/my-feature                       a1b2c3d4  up to date
# fix/old-bug                              cafe1234  new
# refactor                                 deadbeef  changed
# wip/experiment                           ab12ef34  local
```

| Status | Meaning |
|---|---|
| `new` | On the remote, not locally — `pull` would add it. |
| `up to date` | Same SHA locally and on the remote — `pull` is a no-op for this branch. |
| `changed` | Changed on the remote since your last push or pull — `pull` would update local to the remote SHA. |
| `ahead` | Re-archived locally since your last push or pull, remote unchanged — `pull` keeps your copy; `push` would publish it. |
| `conflict` | Changed on both sides since your last push or pull — `pull` keeps your copy and reports it. |
| `local` | Local only, not on the remote — unaffected by `pull`. |

Requires `arx.storerefs` to be enabled.

---

### `git arx pull`

Fetch archived refs from the remote. Remote-tracking refs are updated so that `git arx list` and `git arx status --all` reflect the current remote state — including refs force-pushed from another machine (`git arx push --force`) and refs deleted on the remote, whose tracking refs are pruned. Local archive entries themselves are never deleted by `pull`. If `arx.storefile` is also enabled, the `.gitarchive` file is automatically updated to match.

A local entry is updated only when the remote's copy is the newer one: entries missing locally are added, and entries you have not changed since your last push or pull take the remote's SHA. An entry you re-archived since then (`git arx add --force`) is kept as is – `push` publishes it. If it changed on both sides, `pull` keeps your copy, reports it, and exits non-zero:

```bash
git arx pull
# From origin
#  * [new ref]   refs/arx/feature/my-feature -> refs/arx-remote/origin/feature/my-feature
# Synced fetched refs to .gitarchive
```

```
# Kept local (changed both here and on the remote since the last push or pull):
#   feature/my-feature (local: a1b2c3d4, remote: deadbeef)
# To keep both, rename the local entry ("git arx rename <branch> <new-name>") and pull again;
# to replace the remote copy instead, run "git arx push --force".
```

`git arx fetch` previews these outcomes without changing anything.

Requires `arx.storerefs` to be enabled.

---

### `git arx purge`

Delete **all** archived refs from the remote. Unlike `git arx push --prune` (which only deletes remote refs that are absent from your local archive) and `git arx push --delete <branch>` (which deletes one named ref), `purge` removes every `refs/arx/*` ref the remote holds, regardless of local state. Your local archive is never touched — only the remote copies are removed. Local remote-tracking refs are pruned to match. Prompts for confirmation before proceeding.

```bash
git arx purge
# The following archived refs will be deleted from the remote (origin):
#   feature/my-feature
#   fix/old-bug
#
# NOTE: This deletes the remote copies of all archived refs.
# Your local archive is not affected – re-publish anytime with git arx push.
# Type "yes" to continue: yes
# To origin
#  - [deleted]   refs/arx/feature/my-feature
#  - [deleted]   refs/arx/fix/old-bug
# Done. Deleted 2 remote ref(s).
```

This is the cleanup step for a workflow where the remote is only a transfer channel: secondary workspaces `push` archived refs, the primary `pull`s them, and then `purge` clears the remote so it never accumulates an archive.

**Options:**

| Option | Description |
|---|---|
| `--force`, `-f` | Skip the confirmation prompt and delete immediately. |
| `--dry-run`, `-n` | Show which remote refs would be deleted without deleting anything. Produces the same output as a real run, followed by `(dry run – no changes written)`. |

```bash
git arx purge --dry-run
git arx purge --force
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

A file entry whose commit is not in this repository – a teammate archived a branch you never fetched – cannot become a ref. `sync` skips it with a notice (`Skipped: <branch> – commit ... is not in this repository`), syncs everything else, and exits non-zero.

Requires both `arx.storerefs` and `arx.storefile` to be enabled.

---

### `git arx config [<key> [<value>]]`

View and change the `arx.*` settings described in [Configuration](#configuration). With no arguments, lists every setting with the value in effect and where it comes from – `default`, or the git config scope that sets it (`local`, `global`, `system`, ...):

```bash
git arx config
# storerefs   true         default
# storefile   true         local
# filepath    .gitarchive  default
# refsprefix  refs/arx/    global
```

A value git-arx cannot use is flagged in the source column: a non-boolean storage flag (`local – invalid value "maybe" ignored`, the default applies) or a malformed refs prefix (`local – invalid`, other commands refuse to run until it is fixed).

With a key, prints the value in effect; with a key and a value, sets it. The `arx.` prefix is optional (`storefile` and `arx.storefile` are the same key):

```bash
git arx config storefile           # true
git arx config storefile yes
# Set arx.storefile = true in local config.
# note: 3 archived entries found only in refs – run "git arx sync" to copy them into the file.
```

Values are validated before anything is written, and stored in normalized form – booleans as `true`/`false`, the refs prefix with its trailing `/`. A value git-arx would reject (a non-boolean storage flag, an absolute `filepath`, a refs prefix that fails the rules under [`arx.refsprefix`](#arxrefsprefix)) is refused, as is any change that would leave both storage backends disabled. Unknown keys are refused rather than written.

Changes that would make archived entries invisible prompt for confirmation, showing how many entries are affected. Nothing is moved or deleted – the entries stay where they are and come back if the setting is reverted:

| Change | Entries no longer read |
|---|---|
| `storerefs` → `false` | entries found only in refs (`git arx sync` first copies them into the file) |
| `storefile` → `false` | entries found only in the file (`git arx sync` first copies them into refs) |
| `refsprefix` changed | every ref under the old prefix |
| `filepath` changed | every entry in the old file |

```bash
git arx config refsprefix refs/archive
# WARNING: 12 archived entries under refs/arx/ will no longer be read (the refs are left in place).
# Type "yes" to continue:
```

`git arx config` runs even when the configuration is broken. With both backends disabled or an invalid refs prefix, every other command refuses to run, so this is how to fix it.

**Flags:**

| Flag | Description |
|---|---|
| `--global` | Write to the global (user) config instead of the repository's. If the repository overrides the key, a note says the change has no effect here. |
| `--unset` | Remove the key from the local (or, with `--global`, the global) config, so a lower scope or the default applies. |
| `--force`, `-f` | Skip the confirmation prompt. The warning is still printed. |

Settings can also be changed with native `git config arx.<key> <value>`, which skips the validation and warnings. See [Using native `git config`](#using-native-git-config).

---

### `git arx upgrade`

Check whether a newer version of `git-arx` is available and optionally install it. Compares the installed version (a short commit hash) against the latest commit on `master` and, if they differ, prompts before installing.

```bash
git arx upgrade
# Checking for updates...
# Current: abc1234
# Latest:  def5678
#
# Install latest version? [y/N]
```

Use `-y` to skip the confirmation prompt and install automatically:

```bash
git arx upgrade -y
```

If the installed version is already current:

```bash
git arx upgrade
# Checking for updates...
# Already up to date (abc1234).
```

The command detects the current install directory from the running binary and re-runs `install.sh` there, so the upgraded file lands in the same location. Not applicable when running from source (`VERSION="dev"`).

> **Note:** `git arx update` archives your branches. `git arx upgrade` upgrades the tool itself.

---

Run `git arx help` (or `-h`) to print the built-in usage summary at any time.

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

Lines starting with `#` are comments – unless they have the shape of an entry, because git allows branch names that start with `#`. Since the file can be committed and shared, git-arx treats its contents as untrusted input: a line whose SHA is not a full hex object name is reported and ignored, so nothing from the file ever reaches git as a command-line option.

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
git arx config storerefs true
git arx config storefile true
```

With both enabled, writes go to refs first, then to the file – if git refuses the ref (for example a [name collision](#git-arx-rename-old-name-new-name)), nothing is written to either. Reads prefer refs and supplement with any file-only entries. The `git arx sync` command reconciles the two if they drift.

### Clone size

Archiving a branch preserves all of its objects. Because `refs/arx/*` is outside the default clone refspec (`refs/heads/*`, `refs/tags/*`), a regular `git clone` will not transfer those objects — they stay on the remote until explicitly fetched with `git arx pull`. A mirror clone (`git clone --mirror`), which fetches all refs, will include them.

If reducing remote storage is the goal, delete the branch without archiving it. The objects will become unreachable and the hosting provider can prune them during the next GC run. For archived refs that were already pushed, remove them from the remote with `git arx push --delete <branch>` (single ref) or `git arx push --prune` (everything no longer in the local archive).

---

## Configuration

All settings are stored in git config under `arx.*` and are managed with [`git arx config`](#git-arx-config-key-value), which validates each value before writing it. They can be set per-repo (the default) or globally with `--global`. Boolean settings accept any git boolean spelling (`true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`).

### Using native `git config`

Since the settings are ordinary git config keys, native `git config` reads and writes them too. Every `git arx config` command in this section has a native equivalent:

```bash
git config arx.storefile true            # git arx config storefile true
git config --global arx.storerefs true   # git arx config storerefs true --global
git config --unset arx.filepath          # git arx config --unset filepath
git config --get-regexp '^arx\.'         # git arx config (without defaults or sources)
```

Native `git config` writes values unchecked. It does not refuse invalid values, does not normalize them, and does not warn when a change hides archived entries. A value git-arx cannot use is caught the next time a command runs: an invalid storage flag falls back to its default, and an invalid refs prefix or both backends disabled makes every command stop with an error until it is fixed.

### `arx.storerefs`

Controls whether the refs backend is used. Default: `true`. The refs prefix defaults to `refs/arx/` and can be changed with `arx.refsprefix`.

```bash
git arx config storerefs true   # default – GC-safe local storage
git arx config storerefs false  # disable if you use file backend only
```

### `arx.storefile`

Controls whether the file backend (`.gitarchive`) is used. Default: `false`.

```bash
git arx config storefile true   # enable for human-readable archives or team sharing
git arx config storefile false  # default
```

At least one of `arx.storerefs` and `arx.storefile` must be enabled. With both disabled there is nowhere to store anything, so every command stops with an error.

### `arx.filepath`

Path to the archive file, relative to the repository root. Default: `.gitarchive`.

```bash
git arx config filepath .git/arx-archive   # keep it out of the working tree
git arx config filepath my-archive.txt
```

### `arx.refsprefix`

Refs namespace prefix for the refs backend. Default: `refs/arx/`. Must be of the form `refs/<namespace>/`: a value that does not name a namespace under `refs/` (including a bare `refs/`) is rejected with an error, and a missing trailing `/` is appended automatically. It must also be a namespace of its own – a prefix inside one of git's (`refs/heads/`, `refs/tags/`, `refs/remotes/`, `refs/notes/`, ...) is rejected, since `prune` and `purge` would treat those refs as the archive and delete them.

```bash
git arx config refsprefix refs/arx/        # default
git arx config refsprefix refs/archive/    # custom namespace
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

### Remote as a transfer channel (archive only on the primary)

When you want the archive to live on **one** primary workspace and use the remote
purely to ferry archived branches in from secondary workspaces — without the
remote permanently holding an archive:

```bash
# secondary workspace – archive locally, then push to hand it off
git arx add my-branch     # or: git arx update
git arx push

# primary workspace – pull the refs into the local archive, then clear the remote
git arx pull
git arx purge
```

Normal `git push` never touches `refs/arx/*`, so the archive stays local by
default — the remote only carries refs during the brief window between a
secondary's `push` and the primary's `purge`. To keep secondary workspaces clean
too, run `git arx remove my-branch` there after the handoff.

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
git arx config storefile true
# Optionally commit it so it syncs with the repo
echo '.gitarchive' >> .gitignore  # or don't, and commit it instead
```

### Using only the file backend (no GC protection)

If you prefer a visible text file and are not concerned about `git gc`:

```bash
git arx config storefile true
git arx config storerefs false
```

---

## Shell Completion

Tab completion for subcommands, flags, and branch names in bash.

`install.sh` installs the completion script automatically to `~/.local/share/bash-completion/completions/git-arx`. Restart your shell afterwards.

**Manual installation:**

```bash
# Copy the completion script to the user completions directory
cp git-arx-completion.bash ~/.local/share/bash-completion/completions/git-arx

# Or source it directly from your ~/.bashrc
echo 'source /path/to/git-arx-completion.bash' >> ~/.bashrc
```

Requires bash-completion and git-completion.bash to be active in the shell (standard on most Linux distributions and Git for Windows; on macOS install via `brew install bash-completion@2`).

---

## Internals

Implementation details, design decisions, and architectural notes are in [INTERNALS.md](INTERNALS.md).

---

## License

MIT License – see [LICENSE](LICENSE).

---

<sub>*Implemented with [Claude Code](https://claude.com/product/claude-code). The concept, design, and all product decisions are my own.*</sub>
