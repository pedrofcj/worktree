# Changelog

All notable changes to the Git Worktree Manager will be documented in this file.

## 2026-03-15

### Added
- **`--from` flag for `add` command**: Create a new worktree based on another existing worktree's branch (`wt add my-fix --from other-tree`). The source worktree is pulled before branching to ensure the new branch starts from the latest state.
- **Configurable command name**: Rename the `wt` command via the `WT_RENAME` environment variable or a `~/.wtconfig` file (`command_name = gw`). All help text and error messages reflect the configured name.
- **Auto-navigate prompt on `add`**: After creating a new worktree, prompts the user to `cd` into it automatically.
- **Automatic refspec fix on `add`**: When the default branch cannot be detected (common with repos cloned via `git clone --bare` instead of `wt clone`), the fetch refspec is automatically fixed and branches are fetched before retrying.

### Fixed
- **`remove` command now finds worktrees at any path**: Previously only looked in the `trees/` folder. Now uses `git worktree list` as the source of truth, so worktrees created outside `trees/` can be removed by name.
- **`remove-all` command now finds all worktrees**: Previously only removed worktrees under the `trees/` folder. Now removes all non-bare, non-default-branch worktrees regardless of location.
- **`add` command detects existing default branch worktree at any path**: `Initialize-MainWorktree` previously only checked `trees/` for the default branch worktree. Now queries `git worktree list` by branch name, avoiding conflicts when the main worktree exists elsewhere.

## 2026-03-03

### Added
- Initial release with support for Bash, Zsh, PowerShell, and Nushell.
- `wt clone <url>` - Clone a repository as bare and set up worktree structure.
- `wt add <name> [type]` - Create a new worktree with automatic branch naming (`type/name`).
- `wt list` - List all worktrees with current worktree indicator.
- `wt remove <name>` - Remove a specific worktree and its branch.
- `wt remove-all` - Remove all non-default worktrees with confirmation.
- `wt fix-fetch` - Fix fetch refspec configuration for bare repositories.
- Default branch protection (cannot remove main/master worktree).
- Automatic upstream tracking configuration.
- Colored output with Unicode status symbols.
