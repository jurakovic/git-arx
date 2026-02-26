# git-bra: BRanch Archiver — Implementation Plan

## Context

A bash script invoked as `git bra <command>` (via git alias) that archives local git branches which have no remote tracking branch. The tool stores the branch name and HEAD SHA so deleted branches can be listed, inspected, and restored later. The repo currently contains only a README.md with notes — no existing code.

---

## Storage Backends

Configurable via `git config bra.storage` (default: `both`):

| Backend | What it does |
|---|---|
| `file` | Plain text `.gitarchive` file: `branch sha date` per line. Portable, committable, human-readable. Risk: commits can be gc'd. |
| `refs` | Local git refs under `refs/bra/<branch>`. Protects commits from `git gc`. Never pushed by default. |
| `both` (default) | Both simultaneously. Each covers the other's weakness. |

**`.gitarchive` format:** `feature/login <full-sha> <ISO-8601-date>` — one per line, `#` for comments, blank lines ignored.

**Config keys:**
- `bra.storage` — `file` / `refs` / `both` (default: `both`)
- `bra.file` — path to archive file (default: `.gitarchive`)

---

## Full Command Set

| Command | Backend required | Description |
|---|---|---|
| `bra update` | any | Archive all local branches with no remote upstream |
| `bra add <branch>` | any | Archive a single branch |
| `bra remove <branch>` | any | Remove a branch from archive |
| `bra list [--sort=name\|date] [--order=asc\|desc]` | any | List archived branches |
| `bra log <branch> [git-log-flags...]` | any | Delegate to native `git log <sha>` with all flags passed through |
| `bra checkout <branch>` | any | `git checkout -b <branch> <sha>` — warns if SHA was gc'd |
| `bra merge <f1> <f2> -o <out>` | file | Merge two `.gitarchive` files |
| `bra remote push` | refs | `git push origin 'refs/bra/*:refs/bra/*'` |
| `bra remote pull` | refs | `git fetch origin 'refs/bra/*:refs/bra/*'` + sync file if enabled |
| `bra sync` | both | Union merge backends; stop on SHA conflict |
| `bra sync --check` | both | Dry-run: show differences only |
| `bra sync --force-file` | both | Resolve SHA conflicts using `.gitarchive` as truth |
| `bra sync --force-refs` | both | Resolve SHA conflicts using refs as truth |

Commands used with the wrong backend print a clear error:
`"git-bra: bra remote push requires refs storage (current: file)"`

---

## Architecture

Single executable bash script `git-bra`. Sections via comments:
```
# --- CONFIG HELPERS ---
# --- BACKEND: FILE ---
# --- BACKEND: REFS ---
# --- ABSTRACTION LAYER ---
# --- COMMANDS ---
# --- ENTRY POINT ---
```

### Internal Abstraction Layer

All commands use only these three functions — never touch storage directly:

- `_bra_read_all()` — reads configured backend(s), outputs normalized `branch sha date` per line
  - `file`: parse `.gitarchive`
  - `refs`: `git for-each-ref --format='%(refname:short) %(objectname) %(creatordate:iso-strict)' refs/bra/`, strip `bra/` prefix
  - `both`: union merge (refs preferred; include file-only entries; surface SHA conflicts only in `sync`)
- `_bra_write(branch, sha, date)` — writes to all configured backends
- `_bra_delete(branch)` — removes from all configured backends

### Key Helper Functions

```
_bra_require_git          — die if not in a git repo
_bra_git_root             — git rev-parse --show-toplevel (cached as $BRA_GIT_ROOT)
_bra_config_storage/file  — read git config values with defaults
_bra_sanitize_refname     — validate via git check-ref-format
_bra_lookup_branch        — call _bra_read_all, return sha+date for a branch
_bra_sha_exists           — git cat-file -e <sha> (0/1)
_bra_require_storage      — guard for backend-specific commands
_bra_file_write           — atomic filter-then-append (rm + mv pattern for MINGW64)
_bra_refs_write           — git update-ref refs/bra/<branch> <sha>
```

---

## Key Implementation Details

**`bra log` passthrough:**
```bash
shift  # remove branch name, leaving git log flags in "$@"
exec git log "$sha" "$@"
```

**`bra update` detecting no-upstream branches:**
```bash
git for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads/
# Skip lines where upstream field is non-empty
```

**`bra checkout` gc check:**
```bash
if ! git cat-file -e "$sha"; then
    echo "WARNING: SHA for '$branch' was garbage collected. Use: git bra remove $branch" >&2
    exit 1
fi
```

**Atomic file write (MINGW64-safe):**
```bash
grep -v "^${branch} " "$archive" > "$tmpfile" || true
echo "${branch} ${sha} ${date}" >> "$tmpfile"
[[ -f "$archive" ]] && rm -f "$archive"
mv "$tmpfile" "$archive"
```

**`_bra_refs_read` prefix stripping:**
`%(refname:short)` for `refs/bra/feature/login` outputs `bra/feature/login` — strip `bra/` prefix to recover branch name.

---

## Files to Create

| File | Purpose |
|---|---|
| `git-bra` | The entire implementation — single executable bash script |
| `.gitattributes` | `git-bra text eol=lf` — enforces LF endings on Windows checkout, prevents "bad interpreter" errors |
| `install.sh` | Copies `git-bra` to `~/.local/bin` (or `~/bin` on MINGW64) and runs `git config --global alias.bra '!git-bra'` |

---

## Implementation Order

1. **Foundation**: shebang + `set -euo pipefail`, config helpers, `_bra_require_git`, entry point + dispatch, `cmd_help`
2. **File backend**: `_bra_file_read/write/delete`, wire into abstraction layer
3. **Core commands against file backend**: `add`, `list`, `remove`, `update`, `log`, `checkout`, `merge`
4. **Refs backend**: `_bra_refs_read/write/delete`, wire into abstraction layer
5. **Both backend + sync**: union merge in `_bra_read_all`, fan-out in `_bra_write/_bra_delete`, `cmd_sync`
6. **Remote commands**: `cmd_remote_push`, `cmd_remote_pull`
7. **Polish**: all backend-requirement error messages, `cmd_help` with full usage, `install.sh`, `.gitattributes`

---

## MINGW64/Windows Notes

- Use `#!/usr/bin/env bash` (not `#!/bin/bash`)
- Use `${archive}.tmp.$$` for temp files (not `mktemp -p`)
- `rm -f` before `mv` when overwriting (Windows can reject mv over existing file)
- Use `printf` not `echo -e`
- `declare -A` (associative arrays) requires bash 4+ — safe, Git for Windows ships bash 4.4+
- Script saved with LF line endings (enforced by `.gitattributes`)

---

## Verification

```bash
# Setup
mkdir /tmp/bra-test && cd /tmp/bra-test
git init && git commit --allow-empty -m "initial"
git checkout -b feature/test-1 && git commit --allow-empty -m "t1"
git checkout -b feature/test-2 && git commit --allow-empty -m "t2"
git checkout main

# File backend
git config bra.storage file
git bra add feature/test-1          # .gitarchive has 1 line
git bra update                      # .gitarchive has 2 lines
git bra list --sort=name            # alphabetical output
git bra log feature/test-1 --oneline
git bra remove feature/test-1
git branch -D feature/test-1
git bra checkout feature/test-1     # branch restored

# Refs backend
git config bra.storage refs
git bra add feature/test-2
git show-ref | grep refs/bra/       # ref exists

# Both + sync
git config bra.storage both
git bra sync --check                # shows diff
git bra sync                        # reconciles

# Remote (requires a bare repo as fake remote)
git init --bare /tmp/bra-remote.git
git remote add origin /tmp/bra-remote.git
git bra remote push
git bra remote pull

# Wrong-backend error
git config bra.storage file
git bra remote push                 # prints error about refs storage
```
