# Git Worktree Manager

Personal scripts to simplify working with `git worktree` — a feature that has been around for over 10 years but I only discovered last year (better late than never).

All contributions and comments are welcome, as long as you are respectful. I want to keep these scripts updated and evolving, so keep the ideas flowing!

## Supported Shells

- **PowerShell** (`pwsh/worktree.ps1`)
- **Bash** (`bash/worktree.sh`)
- **Zsh** (`zsh/worktree.sh`)
- **Nushell** (`nushell/worktree.nu`)

## Installation

Source the script for your shell. For PowerShell:

```powershell
. /path/to/pwsh/worktree.ps1
```

Add this line to your `$PROFILE` to load it automatically on every session.

## Commands

| Command | Description |
|---|---|
| `wt clone <url>` | Clone a repo as bare and set up worktree structure |
| `wt add <name> [type] [--from <worktree>]` | Create a new worktree (type defaults to `feature`) |
| `wt list` | List all worktrees (highlights current with ★) |
| `wt remove <name>` | Remove a specific worktree and its branch |
| `wt remove-all` | Remove all non-default worktrees (with confirmation) |
| `wt fix-fetch` | Fix fetch refspec configuration for bare repos |

### Examples

```bash
wt clone https://github.com/user/repo.git   # Clone as bare repo with main worktree
wt add my-feature                            # branch: feature/my-feature
wt add my-fix bug                            # branch: bug/my-fix
wt add hotfix --from my-feature              # branch: feature/hotfix, based on my-feature
wt list                                      # Show all worktrees
wt remove my-feature                         # Remove worktree and branch
```

## Configuration

### Rename the command

By default the command is `wt`. To change it, use either:

**Environment variable:**
```powershell
$env:WT_RENAME = "gw"
```

**Config file** (`~/.wtconfig`):
```ini
command_name = gw
```

Priority: environment variable > config file > default (`wt`).
