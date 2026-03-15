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
| Entry point | `wt` | `wt` | `wt` |

### Key Pattern: Parsed Worktrees

All worktree lookups (remove, remove-all, init, --from) use the parsed output of `git worktree list` to find worktrees by name or branch, not by constructing paths under `trees/`. This is critical — worktrees can exist at any location.

### Command Name Configuration

The `wt` function is defined first, then optionally renamed at the end of the script based on `$WT_RENAME` env var or `~/.wtconfig` (`command_name = value`). All user-facing strings reference the configured name dynamically.

## Development Notes

- No build, lint, or test tooling exists. Manual testing against a bare repo is the workflow.
- Bash and Zsh implementations are near-identical — changes to one should be mirrored to the other.
- Nushell syntax is substantially different (records, pipes, `let`/`mut`) but the logic flow matches.
- Unicode symbols (`✓`, `✗`, `★`, `▸`) and color conventions (green=success, red=error, yellow=warning, cyan=info) are consistent across all implementations.
