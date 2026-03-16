# Git Worktree Manager

Personal scripts to simplify working with `git worktree` — a feature that has been around for over 10 years but I only discovered last year (better late than never).

All contributions and comments are welcome, as long as you are respectful. I want to keep these scripts updated and evolving, so keep the ideas flowing!

## Supported Shells

- **PowerShell** (`pwsh/worktree.ps1`)
- **Bash** (`bash/worktree.sh`)
- **Zsh** (`zsh/worktree.sh`)
- **Nushell** (`nushell/worktree.nu`)

## Installation

Source the script for your shell and add it to your shell profile to load automatically on every session.

**PowerShell** — add to `$PROFILE`:
```powershell
. /path/to/pwsh/worktree.ps1
```

**Bash** — add to `~/.bashrc`:
```bash
source /path/to/bash/worktree.sh
```

**Zsh** — add to `~/.zshrc`:
```bash
source /path/to/zsh/worktree.sh
```

**Nushell** — add to `$nu.config-path`:
```nu
source /path/to/nushell/worktree.nu
```

## Commands

| Command | Description |
|---|---|
| `wt clone <url>` | Clone a repo as bare and set up worktree structure |
| `wt add <name> [type] [--from <worktree>]` | Create a new worktree (type defaults to `feature`) |
| `wt list` | List all worktrees (highlights current with ★) |
| `wt remove <name>` | Remove a specific worktree and its branch |
| `wt remove-all` | Remove all non-default worktrees (with confirmation) |
| `wt fix-fetch` | Fix fetch refspec configuration for bare repos |
| `wt migrate` | Migrate a classic layout to modern layout |

### Examples

```bash
wt clone https://github.com/user/repo.git   # Clone as bare repo with main worktree
wt add my-feature                            # branch: feature/my-feature
wt add my-fix bug                            # branch: bug/my-fix
wt add hotfix --from my-feature              # branch: feature/hotfix, based on my-feature
wt list                                      # Show all worktrees
wt remove my-feature                         # Remove worktree and branch
wt migrate                                   # Convert classic layout to modern
```

## Project Layout

When you run `wt clone`, the repo is set up with a **modern layout**:

```
MyProject/
  .git/            ← bare repo (hidden)
  main/            ← default branch worktree
  my-feature/      ← your worktrees live here
```

Existing repos using the **classic layout** (`MyProject.git/trees/`) continue to work. You can convert them with `wt migrate`.

## Configuration

All configuration is optional. Settings can be placed in `~/.wtconfig` or set via environment variables. Priority: environment variable > config file > default.

```ini
# ~/.wtconfig
command_name = gw
worktree_folder = trees
```

### Rename the command

By default the command is `wt`. To change it:

**Environment variable:**
```powershell
# PowerShell
$env:WT_RENAME = "gw"

# Bash / Zsh
export WT_RENAME="gw"

# Nushell
$env.WT_RENAME = "gw"
```

**Config file** (`~/.wtconfig`):
```ini
command_name = gw
```

### Worktree subfolder

By default, modern-layout repos place worktrees directly in the project root. To use a subfolder instead:

**Environment variable:**
```powershell
# PowerShell
$env:WT_WORKTREE_FOLDER = "trees"

# Bash / Zsh
export WT_WORKTREE_FOLDER="trees"
```

**Config file** (`~/.wtconfig`):
```ini
worktree_folder = trees
```

This creates worktrees at `MyProject/trees/<name>/` instead of `MyProject/<name>/`. Classic-layout repos default to `trees/` for backward compatibility.
