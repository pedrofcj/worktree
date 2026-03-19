# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Git Worktree Manager — CLI tool for simplifying `git worktree` workflows with bare repositories. Four parallel implementations exist for PowerShell, Bash, Zsh, and Nushell.

## Architecture

### Multi-Shell Parity

All four implementations (`pwsh/worktree.ps1`, `bash/worktree.sh`, `zsh/worktree.sh`, `nushell/worktree.nu`) share identical command interfaces, behavior, and output. **PowerShell is the reference implementation.** When making changes, apply to all four files.

### Core Design

- **Bare repo only**: The tool operates on bare-cloned repositories. Worktrees live in a `trees/` subfolder by convention, but the tool resolves worktrees by querying `git worktree list` (not by assuming paths).
- **Branch naming**: `<type>/<name>` (e.g., `feature/my-fix`, `bug/ticket-123`). Default type is `feature`.
- **Default branch protection**: The main/master worktree cannot be removed — it's the baseline for all others.

### Shared Function Structure

Every implementation follows the same flow with equivalent functions:

| Concept | PowerShell | Bash/Zsh | Nushell |
|---|---|---|---|
| Parse worktrees | `Get-ParsedWorktrees` | `_wt_get_parsed_worktrees` | `parse-worktrees` |
| Detect default branch | `Get-DefaultBranch` | `_wt_get_default_branch` | `default-branch` |
| Check branch exists | `Test-BranchExists` | `_wt_branch_exists` | `branch-exists` |
| Set fetch refspec | `Set-FetchRefspec` | `_wt_set_fetch_refspec` | `set-fetch-refspec` |
| Init main worktree | `Initialize-MainWorktree` | `_wt_init_main_worktree` | `ensure-main-worktree` |
| Compare versions | `Compare-WtVersion` | `_wt_compare_version` | `compare-version` |
| Check for updates | `Test-WtUpdate` | `_wt_check_update` | `check-update` |
| Apply update | `Update-WtScript` | `_wt_update` | `wt-update` |
| Entry point | `wt` | `wt` | `wt` |

### Key Pattern: Parsed Worktrees

All worktree lookups (remove, remove-all, init, --from) use the parsed output of `git worktree list` to find worktrees by name or branch, not by constructing paths under `trees/`. This is critical — worktrees can exist at any location.

### Command Name Configuration

The `wt` function is defined first, then optionally renamed at the end of the script based on `$WT_RENAME` env var or `~/.wtconfig` (`command_name = value`). All user-facing strings reference the configured name dynamically.

### Auto-Update System

- **Version source of truth**: `VERSION` file at the repo root (single line, e.g. `1.3.0`). Scripts read this file at source time; hardcoded fallback used if the file is missing.
- **Throttled check**: On each `wt` invocation, compares local version against the fetched `origin` version. Cached in `~/.wt_update_check` (line 1 = unix timestamp, line 2 = remote version). Network fetch happens at most once per 24 hours.
- **Version comparison is semantic** (not hash-based), so users can make local edits without triggering false update notices.
- **Repo path detection**: PowerShell uses `$PSScriptRoot`, Bash uses `${BASH_SOURCE[0]}`, Zsh uses `${(%):-%x}`. Nushell cannot auto-detect and relies on `$env.WT_REPO_DIR` or `repo_dir` in `~/.wtconfig`.
- **Re-source after update**: PowerShell/Bash/Zsh re-source the script in-place after `git pull`. Nushell cannot dynamically re-source, so it tells the user to restart their shell.

## Development Notes

- No build, lint, or test tooling exists. Manual testing against a bare repo is the workflow.
- Bash and Zsh implementations are near-identical — changes to one should be mirrored to the other.
- Nushell syntax is substantially different (records, pipes, `let`/`mut`) but the logic flow matches.
- Unicode symbols (`✓`, `✗`, `★`, `▸`) and color conventions (green=success, red=error, yellow=warning, cyan=info) are consistent across all implementations.
- When bumping the version, update **only** the `VERSION` file — all scripts read from it at load time.
