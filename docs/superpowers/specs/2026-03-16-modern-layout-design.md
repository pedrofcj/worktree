# Modern Layout & Clone Redesign

**Date:** 2026-03-16
**Scope:** PowerShell implementation (`pwsh/worktree.ps1`) first; bash/zsh/nushell to follow in separate specs
**Status:** Approved

## Summary

Redesign the worktree folder structure so that `wt clone` creates a clean project directory with the bare repo hidden inside `.git`, and worktrees as sibling directories. Add layout auto-detection for backward compatibility, a configurable worktree subfolder, and a migration command for existing repos.

## Requirements

### R1: New clone layout (modern)
`wt clone <url>` creates:
```
ShedEnergy/
  .git/            ← bare repo (hidden)
  main/            ← default branch worktree
```
Instead of the current (classic) layout:
```
ShedEnergy.git/    ← bare repo IS the directory
  trees/
    main/
```

### R2: Auto-detect layout
When running `wt add/remove/list/etc.` inside an existing repo, the tool detects which layout is in use and behaves accordingly. No user configuration required.

### R3: Configurable worktree subfolder
- Env var: `WT_WORKTREE_FOLDER`
- Config file (`~/.wtconfig`): `worktree_folder = <value>`
- When set, worktrees are created at `<project_root>/<folder>/<name>`
- When unset: modern layout → project root directly; classic layout → `trees/` (backward compat)

### R4: Migration command
`wt migrate` converts a classic layout repo to modern layout with preview, confirmation, and uncommitted-changes warnings.

### R5: Backward compatibility
Existing classic repos continue to work without any configuration changes. All existing commands (`add`, `remove`, `remove-all`, `list`, `fix-fetch`) work in both layouts.

## Architecture

### New Variables

| Variable | Purpose |
|---|---|
| `$script:PROJECT_ROOT` | User-facing project directory. Modern: parent of `.git`. Classic: same as `PROJECT_DIR`. |
| `$script:LAYOUT_TYPE` | `"modern"` or `"classic"` — used by `migrate`, `clone`, and messages. |

### Existing Variable Changes

| Variable | Old behavior | New behavior |
|---|---|---|
| `$script:WORKTREE_FOLDER` | Hardcoded `"trees"` | Read from config, or layout-dependent default |
| `$script:WORKTREE_PARENT` | `Join-Path $PROJECT_DIR "trees"` | `Join-Path $PROJECT_ROOT $WORKTREE_FOLDER` (or just `$PROJECT_ROOT` if folder is empty) |

### Config Resolution Order

**Worktree folder (`Get-WorktreeFolder`):**
1. `$env:WT_WORKTREE_FOLDER` → use value
2. `worktree_folder` in `~/.wtconfig` → use value
3. Not set → return `$null` (caller applies layout-dependent default)

**Layout-dependent defaults when config returns `$null`:**
- Modern layout → `""` (empty, worktrees in project root)
- Classic layout → `"trees"` (preserve existing behavior)

### Layout Detection (`Get-ProjectLayout`)

**Primary detection:** Check for `wt.layout` git config value (set by `wt clone` and `wt migrate`):
```
git -C $PROJECT_DIR config --get wt.layout → "modern" or "classic" or not set
```

**Fallback heuristic** (for repos not created/migrated by `wt`):
```
if (Split-Path -Leaf $PROJECT_DIR) -eq ".git":
    → LAYOUT_TYPE = "modern"
    → PROJECT_ROOT = parent of PROJECT_DIR
else:
    → LAYOUT_TYPE = "classic"
    → PROJECT_ROOT = PROJECT_DIR
```

Note: The heuristic checks whether the leaf directory name is exactly `.git` (a hidden directory), NOT whether the path merely ends with `.git` suffix. This prevents `ShedEnergy.git` (a classic bare repo) from being falsely detected as modern.

`wt clone` sets `git config wt.layout modern` after cloning. `wt migrate` sets `git config wt.layout modern` after migration. This makes detection deterministic for repos managed by `wt`.

Runs once inside `wt` after `Get-GitRoot`, before dispatching to subcommands.

### `Get-GitRoot` Update for Modern Layout

When a bare repo lives at `ShedEnergy/.git`, git may report `core.bare = true` but the `.git` directory name is conventionally non-bare. `Get-GitRoot` must handle this.

After cloning bare into `.git`, `wt clone` explicitly sets `core.bare = true` in the repo config to ensure git recognizes it as bare.

**Behavior by invocation context:**

| Context | `git rev-parse --git-dir` | `--is-bare-repository` | `Get-GitRoot` result |
|---|---|---|---|
| Inside `.git` dir itself | `.` | `true` | Resolve to absolute `.git` path (existing logic) |
| In project root `ShedEnergy/` | `.git` | `true` | Resolve `.git` to absolute path (existing logic) |
| Inside a worktree `ShedEnergy/main/` | `ShedEnergy/.git/worktrees/main` | `false` | Falls to `--git-common-dir` → resolves to `ShedEnergy/.git` (existing logic) |

All three contexts are handled by the existing `Get-GitRoot` logic. The key requirement is that `core.bare = true` is set in the repo config, which `wt clone` and `wt migrate` ensure.

### `PROJECT_NAME` Derivation

`$script:PROJECT_NAME` must be derived from `$script:PROJECT_ROOT` (not `PROJECT_DIR`):
- Modern layout: `Split-Path -Leaf $PROJECT_ROOT` → `ShedEnergy`
- Classic layout: `Split-Path -Leaf $PROJECT_ROOT` → `ShedEnergy.git`

This is set in the `wt` function init block after `Get-ProjectLayout` runs.

### Init Block Rewrite

The `wt` function init block (lines 924-930 in current code) must be rewritten to:
1. Call `Get-GitRoot` → sets `PROJECT_DIR`
2. Call `Get-ProjectLayout` → sets `PROJECT_ROOT`, `LAYOUT_TYPE`
3. Derive `PROJECT_NAME` from `PROJECT_ROOT`
4. Call `Get-WorktreeFolder` → get configured value or `$null`
5. Apply layout-dependent default if `$null` (modern → `""`, classic → `"trees"`)
6. Compute `WORKTREE_PARENT`: if `WORKTREE_FOLDER` is empty, use `$PROJECT_ROOT` directly; otherwise `Join-Path $PROJECT_ROOT $WORKTREE_FOLDER`
7. Add `"migrate"` to the switch dispatch block → calls `Convert-ToModernLayout`

### Worktree Parent Resolution

| Layout | WORKTREE_FOLDER | WORKTREE_PARENT |
|---|---|---|
| Modern, unset | `""` | `ShedEnergy/` |
| Modern, `trees` | `"trees"` | `ShedEnergy/trees/` |
| Classic, unset | `"trees"` (forced) | `ShedEnergy.git/trees/` |
| Classic, explicit `trees` | `"trees"` | `ShedEnergy.git/trees/` |

## Command Changes

### `wt clone` (`New-BareRepository`)

1. Destination: `$repoName` (not `$repoName.git`)
2. Bare clone into: `<destination>/.git`
3. Explicitly set `core.bare = true` in the cloned repo config
4. Read worktree folder config via `Get-WorktreeFolder` (standalone function, no dependency on `PROJECT_DIR`/`PROJECT_ROOT`/`LAYOUT_TYPE` — only reads env var and `~/.wtconfig`) — if user has a value configured (e.g., `worktree_folder = trees`), use it; if unconfigured, default to `""` (worktrees directly in project root, consistent with modern layout default)
5. Create worktrees at `<destination>/<folder>/<main>` or `<destination>/<main>`
6. Set `git config wt.layout modern` in the new bare repo
7. Post-clone: explain project root is a container, offer to `cd` into default branch worktree

### `wt add` (`New-Worktree`)

Path construction requires no logic changes — already uses `$script:WORKTREE_PARENT`. However, `New-Worktree` calls `Initialize-MainWorktree` which uses `$script:WORKTREE_PARENT` and hardcoded messages — these are fixed as part of the `Initialize-MainWorktree` update below. The `wt` function init block rewrite (see Architecture section) ensures all variables are set correctly before `New-Worktree` runs.

**New validation:** Reject reserved names (`.git`, `.bare`, `..`, names containing path separators, and names matching the configured `WORKTREE_FOLDER` value) as worktree names.

### `wt migrate` (new: `Convert-ToModernLayout`)

**Preconditions:**
- Must be classic layout (`LAYOUT_TYPE -eq "classic"`)
- Sibling directory (e.g., `ShedEnergy/`) must not already exist

**Flow:**
1. Parse all worktrees, check each for uncommitted changes
2. Show migration preview (current vs. new paths)
3. If uncommitted changes found: warn with details, explain risk, ask `(y/N)`
4. If clean: simpler confirmation `(y/N)`
5. **CWD check (Windows directory locking):** Before executing any moves, check if `$PWD` is inside the old bare repo directory tree. If so, `Set-Location` to the parent of the old bare repo before proceeding. After migration, offer to `cd` into the default branch worktree at its new location.
6. Execute (order matters):
   a. Create new project root directory (sibling, name without `.git`)
   b. Create worktree subfolder inside new root if `WORKTREE_FOLDER` is configured
   c. **Move worktrees:** Use `Get-ParsedWorktrees` to get absolute paths for all non-bare worktrees. For each:
      - If the worktree path is a child of the old bare repo directory → move it to `<new_root>/<folder>/<name>` (or `<new_root>/<name>` if no folder)
      - If the worktree path is **external** (not a child of the old bare repo) → leave it in place; `git worktree repair` will fix its cross-references
      - Track the list of new worktree paths for the repair step
   d. Move the bare repo to `<new_root>/.git` using a two-step approach for Windows compatibility:
      - First, move all contents of the old bare repo (excluding any remaining worktree subdirs) into `<new_root>/.git` (create `.git` dir, then move items)
      - Alternative: if `Rename-Item` on the whole directory works (no locked files), use that
   e. Set `core.bare = true` and `wt.layout = modern` in `<new_root>/.git/config`
   f. Run `git -C <new_root>/.git worktree repair <path1> <path2> ...` passing ALL worktree paths (both moved and external) as explicit arguments. This fixes both directions: each worktree's `.git` pointer file (which still references the old bare repo path) and the bare repo's `worktrees/<name>/gitdir` entries (which still reference old worktree paths).
   g. Verify: run `git -C <new_root>/.git worktree list` to confirm all worktrees are valid
   h. Remove old directory (only if verification passed; may already be empty after moves)
7. **If any step fails:** Print error with details of what succeeded and what failed. Do NOT remove the old directory. Clean up any partially-created directories (`<new_root>` if empty). Print instructions for manual recovery.
8. Print success, show new paths, offer to `cd` into default branch worktree

### `wt list` (`Get-WorktreeList`)

Minor update: the header line and project name must use `$script:PROJECT_ROOT` and `$script:PROJECT_NAME` (derived from `PROJECT_ROOT` per init block rewrite) so the header reads "Git Worktrees for ShedEnergy" not "Git Worktrees for .git". The `[bare repository] → <path>` info line continues to use `$script:PROJECT_DIR` (the actual bare repo path, e.g., `ShedEnergy/.git`) — this is correct and useful for users to know where the bare repo lives.

### `wt remove`, `wt remove-all`, `wt fix-fetch`

No changes needed. These use parsed worktree paths (absolute) from `git worktree list` or `$script:PROJECT_DIR` for git operations (which remains the bare repo path in both layouts).

### `Initialize-MainWorktree`

Minor fix: success message currently hardcodes `$script:WORKTREE_FOLDER` — change to show actual path.

### `Show-WorktreeHelp`

- Add `migrate` command to list
- Update path examples (remove `trees/` prefix since modern is the new default)
- Add "Configuration" section documenting `WT_WORKTREE_FOLDER` / `worktree_folder`

## New Functions

| Function | Purpose |
|---|---|
| `Get-WorktreeFolder` | Read worktree folder from env/config, return `$null` if unset |
| `Get-ProjectLayout` | Detect layout type and set `PROJECT_ROOT`, `LAYOUT_TYPE` |
| `Convert-ToModernLayout` | Execute the `wt migrate` command |
| `Test-ValidWorktreeName` | Validate worktree name against reserved names and path rules |

## Edge Cases

- **Name validation:** Reject `.git`, `.bare`, `..`, names containing path separators, and names matching the configured `WORKTREE_FOLDER` value — in both layouts
- **Migration target exists:** If `ShedEnergy/` already exists alongside `ShedEnergy.git/`, refuse migration
- **Already modern:** `wt migrate` on modern repo prints message and exits
- **Clone collision:** If `ShedEnergy/` already exists, refuse clone (same as current behavior with `ShedEnergy.git/`)
- **Classic with configured folder:** If user has `worktree_folder = custom` in `~/.wtconfig`, migration moves worktrees to `<new_root>/custom/<name>`

## Testing Strategy

Manual testing against bare repos (no automated test tooling exists). Test matrix:

1. `wt clone` → verify modern layout created correctly
2. `wt add` in modern layout → worktree in project root
3. `wt add` in classic layout → worktree in `trees/` (unchanged)
4. `wt add` with `WT_WORKTREE_FOLDER=custom` in both layouts
5. `wt migrate` on classic repo → verify modern layout, paths, `git worktree repair`
6. `wt migrate` with uncommitted changes → verify warning flow
7. `wt list/remove/remove-all` in both layouts
8. `wt migrate` on already-modern repo → graceful message
9. `wt clone` followed by verifying `core.bare = true` is set
10. `wt clone` with `worktree_folder = trees` in `~/.wtconfig` → verify subfolder used
11. `wt list` in modern layout → verify header shows project name, not `.git`
12. `wt add` with reserved names (`.git`, `..`) → verify rejection
13. `wt migrate` on classic repo with external worktrees → verify external left in place, cross-refs fixed
14. `wt migrate` while CWD is inside the repo being migrated → verify CWD is moved safely
15. `wt migrate` on classic repo with custom `worktree_folder` config → verify worktrees placed in subfolder
