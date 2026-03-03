# Git Worktree Manager - A tool to manage Git worktrees with ease
# PowerShell version converted from bash script

# Unicode symbols
$script:CHECK = "✓"
$script:CROSS = "✗"
$script:STAR = "★"
$script:ARROW = "▸"
$script:INFO = "ℹ️"
$script:WARNING = "⚠️"
$script:SEARCH = "🔍"

# Configuration
$script:DEFAULT_BRANCH_TYPE = "feature"
$script:WORKTREE_FOLDER = "trees"

# Progress message helpers
$script:LastProgressLength = 0

function Write-ProgressStart {
    param([string]$Message)
    $script:LastProgressLength = $Message.Length + 3  # +3 for "..."
    Write-Host "$Message..." -NoNewline
}

function Write-ProgressComplete {
    param(
        [string]$Message,
        [ValidateSet("success", "warning", "error", "info")]
        [string]$Status = "success"
    )

    $symbol = switch ($Status) {
        "success" { $script:CHECK }
        "warning" { $script:WARNING }
        "error"   { $script:CROSS }
        "info"    { $script:INFO }
    }

    $color = switch ($Status) {
        "success" { "Green" }
        "warning" { "Yellow" }
        "error"   { "Red" }
        "info"    { "Cyan" }
    }

    # Calculate padding to overwrite previous text
    $newLength = $Message.Length + 2  # +2 for symbol and space
    $paddingNeeded = [Math]::Max(0, $script:LastProgressLength - $newLength)
    $padding = " " * ($paddingNeeded + 5)  # +5 extra buffer

    Write-Host "`r${symbol} ${Message}${padding}" -ForegroundColor $color
    $script:LastProgressLength = 0
}

# Extract branch name from worktree list line
function Get-BranchFromWorktreeLine {
    param([string]$Line)
    $match = [regex]::Match($Line, '\[(.*?)\]')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

# Parse git worktree list output into structured objects
function Get-ParsedWorktrees {
    param([string]$RepoPath = $script:PROJECT_DIR)

    $worktreesOutput = git -C $RepoPath worktree list 2>$null
    if (-not $worktreesOutput) { return @() }

    $results = @()
    foreach ($line in ($worktreesOutput -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\s+', 2
        $path = $parts[0]
        $rest = $parts.Length -gt 1 ? $parts[1] : ""
        $branch = Get-BranchFromWorktreeLine -Line $rest
        $name = Split-Path -Leaf $path
        $isBare = $rest -match '\(bare\)'

        $results += [PSCustomObject]@{
            Path   = $path
            Branch = $branch
            Name   = $name
            IsBare = $isBare
        }
    }

    return $results
}

# Set upstream tracking for a branch
function Set-BranchUpstream {
    param(
        [string]$WorktreePath,
        [string]$BranchName,
        [switch]$Silent
    )

    if (-not $Silent) {
        Write-ProgressStart "Setting upstream tracking"
    }

    git -C $WorktreePath branch --set-upstream-to=origin/$BranchName $BranchName 2>$null | Out-Null

    if (-not $Silent) {
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Upstream tracking configured" -Status "success"
        } else {
            Write-ProgressComplete "Failed to set upstream tracking (continuing anyway)" -Status "warning"
        }
    }

    return ($LASTEXITCODE -eq 0)
}

# Configure fetch refspec for bare repository
function Set-FetchRefspec {
    param(
        [string]$RepoPath = $script:PROJECT_DIR,
        [switch]$Silent
    )

    $expectedFetch = "+refs/heads/*:refs/remotes/origin/*"

    if (-not $Silent) {
        Write-ProgressStart "Configuring fetch refspec"
    }

    git -C $RepoPath config remote.origin.fetch $expectedFetch 2>$null | Out-Null

    if (-not $Silent) {
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Fetch refspec configured" -Status "success"
        } else {
            Write-ProgressComplete "Failed to configure fetch refspec (continuing anyway)" -Status "warning"
        }
    }

    return ($LASTEXITCODE -eq 0)
}

# Get git root directory (for bare repositories)
function Get-GitRoot {
    # Get the git directory (for bare repos, this is the repo itself)
    $gitDir = git rev-parse --git-dir 2>$null
    if (-not $gitDir) {
        Write-Host "${script:CROSS} Error: Not inside a Git repository" -ForegroundColor Red
        return $null
    }

    # Convert to absolute path and normalize
    $gitDir = (Resolve-Path $gitDir).Path

    # Check if it's a bare repository
    $isBare = git rev-parse --is-bare-repository 2>$null
    if ($isBare -eq "true") {
        # For bare repos, the git-dir IS the repository
        return $gitDir
    }

    # Not directly in a bare repo - check if we're in a worktree of a bare repo
    $commonDir = git rev-parse --git-common-dir 2>$null
    if ($commonDir) {
        $commonDir = (Resolve-Path $commonDir).Path
        $isBareCommon = git -C $commonDir rev-parse --is-bare-repository 2>$null
        if ($isBareCommon -eq "true") {
            return $commonDir
        }
    }

    # Not in a bare repo or worktree of a bare repo
    Write-Host "${script:CROSS} Error: This script is designed for bare Git repositories" -ForegroundColor Red
    Write-Host "   Please run this command from a bare repository directory or one of its worktrees" -ForegroundColor Yellow
    return $null
}

# Show help
function Show-WorktreeHelp {
    Write-Host "=== Git Worktree Manager ===" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Usage: " -NoNewline -ForegroundColor Cyan
    Write-Host "wt <command>" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "add <name> [type]" -ForegroundColor Green -NoNewline
    Write-Host "     Create a new worktree (type defaults to 'feature')"
    Write-Host "  " -NoNewline
    Write-Host "list" -ForegroundColor Green -NoNewline
    Write-Host "                List all worktrees"
    Write-Host "  " -NoNewline
    Write-Host "remove <name>" -ForegroundColor Green -NoNewline
    Write-Host "       Remove a specific worktree"
    Write-Host "  " -NoNewline
    Write-Host "remove-all" -ForegroundColor Green -NoNewline
    Write-Host "          Remove all worktrees (with confirmation)"
    Write-Host "  " -NoNewline
    Write-Host "fix-fetch" -ForegroundColor Green -NoNewline
    Write-Host "           Fix fetch refspec configuration for bare repos"
    Write-Host "  " -NoNewline
    Write-Host "clone <url>" -ForegroundColor Green -NoNewline
    Write-Host "         Clone a repo as bare and set up worktree structure"
    Write-Host ""
    Write-Host "When creating a worktree:" -ForegroundColor Cyan
    Write-Host "  • Worktree is created at trees/<name>"
    Write-Host "  • Branch name format: <type>/<name> (default type is 'feature')"
    Write-Host "  • If the branch doesn't exist, it creates a new branch"
    Write-Host "  • If the branch already exists, it checks out the existing branch"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "wt add RDUCH-123-add-serialization" -ForegroundColor Yellow -NoNewline
    Write-Host "     # Creates trees/RDUCH-123-add-serialization with branch feature/RDUCH-123-add-serialization"
    Write-Host "  " -NoNewline
    Write-Host "wt add RTJK-1223332-whatever bug" -ForegroundColor Yellow -NoNewline
    Write-Host "    # Creates trees/RTJK-1223332-whatever with branch bug/RTJK-1223332-whatever"
    Write-Host "  " -NoNewline
    Write-Host "wt add look-at-this wowdude" -ForegroundColor Yellow -NoNewline
    Write-Host "          # Creates trees/look-at-this with branch wowdude/look-at-this"
    Write-Host "  " -NoNewline
    Write-Host "wt list" -ForegroundColor Yellow -NoNewline
    Write-Host "                              # List all worktrees (shows current with ★)"
    Write-Host "  " -NoNewline
    Write-Host "wt remove my-feature" -ForegroundColor Yellow -NoNewline
    Write-Host "                 # Remove specific worktree"
    Write-Host "  " -NoNewline
    Write-Host "wt remove-all" -ForegroundColor Yellow -NoNewline
    Write-Host "                        # Remove all worktrees"
    Write-Host "  " -NoNewline
    Write-Host "wt fix-fetch" -ForegroundColor Yellow -NoNewline
    Write-Host "                        # Fix fetch refspec configuration"
    Write-Host "  " -NoNewline
    Write-Host "wt clone https://github.com/user/repo.git" -ForegroundColor Yellow -NoNewline
    Write-Host "  # Clone repo as bare and set up main worktree"
    Write-Host ""
}

# Check if branch exists
function Test-BranchExists {
    param(
        [string]$BranchName,
        [string]$RepoPath = $script:PROJECT_DIR
    )
    
    git -C $RepoPath show-ref --verify --quiet "refs/heads/${BranchName}" 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    
    git -C $RepoPath show-ref --verify --quiet "refs/remotes/origin/${BranchName}" 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    
    return $false
}

# Get the default branch name from remote
function Get-DefaultBranch {
    param(
        [string]$RepoPath = $script:PROJECT_DIR
    )
    
    # Ensure origin/HEAD is set by querying the remote
    git -C $RepoPath remote set-head origin --auto 2>$null | Out-Null
    
    # Try to get the default branch from origin/HEAD
    $defaultBranch = git -C $RepoPath rev-parse --abbrev-ref origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $defaultBranch -and $defaultBranch -ne "origin/HEAD") {
        return ($defaultBranch -replace 'origin/', '')
    }
    
    # Fallback: check for common default branch names
    if (Test-BranchExists -BranchName "main" -RepoPath $RepoPath) {
        return "main"
    }
    if (Test-BranchExists -BranchName "master" -RepoPath $RepoPath) {
        return "master"
    }
    
    return $null
}

# List worktrees
function Get-WorktreeList {
    $currentPath = $PWD.Path
    $worktrees = Get-ParsedWorktrees

    if ($worktrees.Count -eq 0) {
        Write-Host "No worktrees found" -ForegroundColor Yellow
        return
    }

    Write-Host "=== Git Worktrees for $script:PROJECT_NAME ===" -ForegroundColor Blue
    Write-Host ""
    Write-Host "[bare repository] → " -NoNewline -ForegroundColor White
    Write-Host "$script:PROJECT_DIR" -ForegroundColor Cyan
    Write-Host ""

    $hasWorktrees = $false

    foreach ($wt in $worktrees) {
        # Skip the bare repository itself, only show worktrees
        if (-not $wt.IsBare) {
            if (-not $hasWorktrees) {
                Write-Host "Worktrees:" -ForegroundColor Cyan
                $hasWorktrees = $true
            }

            $branch = $wt.Branch ?? ""

            # Normalize paths for comparison
            $normalizedWtPath = $wt.Path -replace '/', '\'
            if ($currentPath.StartsWith($normalizedWtPath)) {
                Write-Host "${script:STAR} " -NoNewline -ForegroundColor Cyan
                Write-Host "[current] " -NoNewline -ForegroundColor Cyan
            } else {
                Write-Host "  " -NoNewline
            }

            # Only show branch name if it's different from worktree name
            if ($wt.Name -eq $branch) {
                Write-Host "${script:ARROW} " -NoNewline -ForegroundColor Cyan
                Write-Host "$($wt.Name)" -ForegroundColor White
            } else {
                Write-Host "${script:ARROW} " -NoNewline -ForegroundColor Cyan
                Write-Host "$($wt.Name)" -NoNewline -ForegroundColor White
                Write-Host " → " -NoNewline
                Write-Host "$branch" -ForegroundColor Green
            }
            Write-Host "       $($wt.Path)"
        }
    }

    if (-not $hasWorktrees) {
        Write-Host "No worktrees found" -ForegroundColor Yellow
    }
}

# Remove worktree
function Remove-Worktree {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Host "${script:CROSS} Error: Please specify which worktree to remove" -ForegroundColor Red
        Write-Host "   Usage: wt remove <worktree-name>" -ForegroundColor Yellow
        return
    }

    $worktreePath = Join-Path $script:WORKTREE_PARENT $Name

    if (-not (Test-Path $worktreePath)) {
        Write-Host "${script:CROSS} Error: Worktree '${Name}' not found at ${worktreePath}" -ForegroundColor Red
        return
    }

    # Get the default branch - it must always be preserved as the baseline
    $defaultBranch = Get-DefaultBranch

    # Protect the default branch worktree from removal
    if ($Name -eq $defaultBranch) {
        Write-Host "${script:CROSS} Error: Cannot remove the default branch worktree '${Name}'" -ForegroundColor Red
        Write-Host "   The default branch worktree is the baseline for all other worktrees." -ForegroundColor Yellow
        return
    }

    # Get the branch name associated with this worktree before removing it
    $worktrees = Get-ParsedWorktrees
    $normalizedWorktreePath = $worktreePath -replace '\\', '/'
    $branchName = $null

    foreach ($wt in $worktrees) {
        $normalizedPath = $wt.Path -replace '\\', '/'
        if ($normalizedPath -eq $normalizedWorktreePath) {
            $branchName = $wt.Branch
            break
        }
    }

    # Additional check: protect if the branch is the default branch
    if ($branchName -eq $defaultBranch) {
        Write-Host "${script:CROSS} Error: Cannot remove worktree '${Name}' - it uses the default branch '${defaultBranch}'" -ForegroundColor Red
        Write-Host "   The default branch worktree is the baseline for all other worktrees." -ForegroundColor Yellow
        return
    }

    Write-Host "=== Removing worktree '${Name}' ===" -ForegroundColor Yellow

    git -C $script:PROJECT_DIR worktree remove $worktreePath --force 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "${script:CHECK} Worktree '${Name}' removed successfully" -ForegroundColor Green

        # Delete the branch from local repository if branch name was found
        if ($branchName) {
            Write-ProgressStart "Deleting branch '${branchName}' from local repository"
            git -C $script:PROJECT_DIR branch -D $branchName 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-ProgressComplete "Branch '${branchName}' deleted" -Status "success"
            } else {
                Write-ProgressComplete "Failed to delete branch '${branchName}' (it may not exist locally)" -Status "warning"
            }
        }
    } else {
        Write-Host "${script:CROSS} Failed to remove worktree. It might have uncommitted changes." -ForegroundColor Red
        Write-Host "   Use 'cd ${worktreePath}' to check and commit/stash changes." -ForegroundColor Yellow
        return
    }
}

# Remove all worktrees
function Remove-AllWorktrees {
    $parsedWorktrees = Get-ParsedWorktrees
    $worktreesToRemove = @()

    # Get the default branch so we don't delete it (it's the baseline for all worktrees)
    $defaultBranch = Get-DefaultBranch

    # Normalize WORKTREE_PARENT for comparison (git uses forward slashes)
    $normalizedParent = $script:WORKTREE_PARENT -replace '\\', '/'

    # Collect worktrees in the trees folder, excluding the default branch
    foreach ($wt in $parsedWorktrees) {
        $normalizedPath = $wt.Path -replace '\\', '/'
        if ($normalizedPath.StartsWith($normalizedParent)) {
            # Skip the default branch worktree - it must always be preserved
            if ($wt.Branch -eq $defaultBranch -or $wt.Name -eq $defaultBranch) {
                continue
            }
            $worktreesToRemove += $wt
        }
    }

    if ($worktreesToRemove.Count -eq 0) {
        Write-Host "${script:INFO} No worktrees found to remove" -ForegroundColor Yellow
        return
    }

    Write-Host "=== Remove All Worktrees ===" -ForegroundColor Red
    Write-Host "${script:WARNING} This will remove the following worktrees:" -ForegroundColor Yellow

    foreach ($wt in $worktreesToRemove) {
        Write-Host "  ${script:CROSS} " -NoNewline -ForegroundColor Red
        Write-Host "$($wt.Name)"
    }

    Write-Host ""
    $response = Read-Host "Are you sure you want to remove all worktrees? (y/N)"

    if ($response -notmatch '^[Yy]$') {
        Write-Host "${script:CROSS} Cancelled" -ForegroundColor Red
        return
    }

    foreach ($wt in $worktreesToRemove) {
        Write-ProgressStart "Removing $($wt.Name)"
        git -C $script:PROJECT_DIR worktree remove $wt.Path --force 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Removed $($wt.Name)" -Status "success"

            # Delete the branch if it exists and is not the default branch
            if ($wt.Branch -and $wt.Branch -ne $defaultBranch) {
                git -C $script:PROJECT_DIR branch -D $wt.Branch 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ${script:CHECK} Deleted branch '$($wt.Branch)'" -ForegroundColor Green
                }
            }
        } else {
            Write-ProgressComplete "Failed to remove $($wt.Name) (might have uncommitted changes)" -Status "warning"
        }
    }

    Write-Host ""
    Write-Host "${script:CHECK} All worktrees removed" -ForegroundColor Green
}

# Ensure main worktree exists and is updated
function Initialize-MainWorktree {
    $mainWorktreePath = $null
    $mainBranch = $null
    $worktreeCreated = $false

    # Detect the default branch from remote
    $detectedBranch = Get-DefaultBranch

    # Check if a worktree for the default branch already exists
    if ($detectedBranch) {
        $detectedPath = Join-Path $script:WORKTREE_PARENT $detectedBranch
        if (Test-Path $detectedPath) {
            $mainWorktreePath = $detectedPath
            $mainBranch = $detectedBranch
        }
    }

    # Fallback: check for common branch names if no worktree found yet
    if (-not $mainWorktreePath) {
        $commonBranches = @("main", "master", "develop", "trunk")
        foreach ($branch in $commonBranches) {
            $branchPath = Join-Path $script:WORKTREE_PARENT $branch
            if (Test-Path $branchPath) {
                $mainWorktreePath = $branchPath
                $mainBranch = $branch
                break
            }
        }
    }

    # No existing worktree found - need to create one
    if (-not $mainWorktreePath) {
        Write-Host "Default branch worktree doesn't exist. Creating it..." -ForegroundColor Yellow
        Write-ProgressStart "Detecting default branch"

        # Create parent directory if it doesn't exist
        New-Item -ItemType Directory -Path $script:WORKTREE_PARENT -Force | Out-Null

        if ($detectedBranch) {
            $mainBranch = $detectedBranch
            $mainWorktreePath = Join-Path $script:WORKTREE_PARENT $mainBranch
            Write-ProgressComplete "Found default branch: ${mainBranch}" -Status "success"
        } else {
            Write-ProgressComplete "Failed to detect default branch" -Status "error"
            return $false
        }

        # Create the worktree
        Write-ProgressStart "Creating ${mainBranch} worktree"
        git -C $script:PROJECT_DIR worktree add $mainWorktreePath $mainBranch 2>$null | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Worktree created at $script:WORKTREE_FOLDER/${mainBranch}" -Status "success"
            $worktreeCreated = $true
        } else {
            Write-ProgressComplete "Failed to create ${mainBranch} worktree" -Status "error"
            return $false
        }
    }

    # Set upstream tracking if worktree was just created
    if ($worktreeCreated) {
        Set-BranchUpstream -WorktreePath $mainWorktreePath -BranchName $mainBranch | Out-Null
    }

    # Update main worktree
    Write-ProgressStart "Updating ${mainBranch} worktree"
    git -C $mainWorktreePath pull 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "${mainBranch} worktree updated" -Status "success"
    } else {
        Write-ProgressComplete "Failed to pull ${mainBranch} worktree (continuing anyway)" -Status "warning"
    }

    # Fetch all from bare repo
    Write-ProgressStart "Fetching all branches from bare repository"
    git -C $script:PROJECT_DIR fetch --all 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "Fetched all branches" -Status "success"
    } else {
        Write-ProgressComplete "Failed to fetch all branches (continuing anyway)" -Status "warning"
    }

    return $true
}

# Clone repository as bare
function New-BareRepository {
    param([string[]]$Arguments)

    # Validate URL argument
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        Write-Host "${script:CROSS} Error: Please specify a repository URL" -ForegroundColor Red
        Write-Host "   Usage: wt clone <url>" -ForegroundColor Yellow
        return
    }

    $repoUrl = $Arguments[0]

    if ([string]::IsNullOrWhiteSpace($repoUrl)) {
        Write-Host "${script:CROSS} Error: Please specify a repository URL" -ForegroundColor Red
        Write-Host "   Usage: wt clone <url>" -ForegroundColor Yellow
        return
    }

    # Extract repo name from URL
    # Handle HTTPS: https://github.com/user/repo.git -> repo
    # Handle SSH: git@github.com:user/repo.git -> repo
    $repoName = $repoUrl -replace '\.git$', ''  # Remove .git suffix if present
    $repoName = $repoName -replace '.*[/:]', '' # Get last part after / or :
    $bareRepoName = "${repoName}.git"

    $destinationPath = Join-Path $PWD.Path $bareRepoName

    if (Test-Path $destinationPath) {
        Write-Host "${script:CROSS} Error: Directory '${bareRepoName}' already exists" -ForegroundColor Red
        Write-Host "   Please remove it or choose a different location" -ForegroundColor Yellow
        return
    }

    Write-Host "=== Cloning repository as bare ===" -ForegroundColor Blue
    Write-Host "   URL: ${repoUrl}" -ForegroundColor Cyan
    Write-Host "   Destination: ./${bareRepoName}" -ForegroundColor Cyan
    Write-Host ""

    # Clone with --bare flag
    Write-ProgressStart "Cloning repository"
    $cloneResult = git clone --bare $repoUrl $destinationPath 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to clone repository" -Status "error"
        Write-Host "   Error: $cloneResult" -ForegroundColor Yellow
        return
    }
    Write-ProgressComplete "Repository cloned" -Status "success"

    # Configure fetch refspec
    Set-FetchRefspec -RepoPath $destinationPath | Out-Null

    # Fetch all branches
    Write-ProgressStart "Fetching all branches"
    git -C $destinationPath fetch --all 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "Fetched all branches" -Status "success"
    } else {
        Write-ProgressComplete "Failed to fetch all branches (continuing anyway)" -Status "warning"
    }

    # Detect default branch dynamically
    Write-ProgressStart "Detecting default branch"
    $mainBranch = Get-DefaultBranch -RepoPath $destinationPath

    if (-not $mainBranch) {
        Write-ProgressComplete "Failed to detect default branch" -Status "error"
        Write-Host "   The repository was cloned but no worktree was created." -ForegroundColor Yellow
        Write-Host "   You can manually create a worktree using: wt add <name>" -ForegroundColor Yellow
        return
    }
    Write-ProgressComplete "Found default branch: ${mainBranch}" -Status "success"

    # Create trees folder
    $treesPath = Join-Path $destinationPath $script:WORKTREE_FOLDER
    New-Item -ItemType Directory -Path $treesPath -Force | Out-Null

    # Create worktree for default branch
    $mainWorktreePath = Join-Path $treesPath $mainBranch
    Write-ProgressStart "Creating worktree for ${mainBranch} branch"
    git -C $destinationPath worktree add $mainWorktreePath $mainBranch 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to create worktree for ${mainBranch}" -Status "error"
        return
    }
    Write-ProgressComplete "Worktree created at $script:WORKTREE_FOLDER/${mainBranch}" -Status "success"

    # Set upstream tracking branch
    Set-BranchUpstream -WorktreePath $mainWorktreePath -BranchName $mainBranch | Out-Null

    # Pull latest changes
    Write-ProgressStart "Pulling latest changes"
    git -C $mainWorktreePath pull 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "Worktree updated" -Status "success"
    } else {
        Write-ProgressComplete "Failed to pull (continuing anyway)" -Status "warning"
    }

    Write-Host ""
    Write-Host "${script:CHECK} Repository setup complete!" -ForegroundColor Green
    Write-Host "   Bare repo: ${destinationPath}" -ForegroundColor Cyan
    Write-Host "   Main worktree: ${mainWorktreePath}" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To start working, run:" -ForegroundColor Yellow
    Write-Host "   cd ${bareRepoName}\$script:WORKTREE_FOLDER\${mainBranch}"
}

# Fix fetch refspec configuration
function Repair-FetchRefspec {
    Write-Host "=== Checking fetch refspec configuration ===" -ForegroundColor Cyan
    Write-Host ""

    # Check if fetch refspec is configured
    $currentFetch = git -C $script:PROJECT_DIR config --get remote.origin.fetch 2>$null
    $expectedFetch = "+refs/heads/*:refs/remotes/origin/*"

    if ($LASTEXITCODE -eq 0 -and $currentFetch) {
        Write-Host "${script:INFO} Current fetch refspec: " -NoNewline -ForegroundColor Blue
        Write-Host "$currentFetch" -ForegroundColor White

        if ($currentFetch -eq $expectedFetch) {
            Write-Host "${script:CHECK} Fetch refspec is already correctly configured" -ForegroundColor Green
            Write-Host ""
            return $true
        } else {
            Write-Host "${script:WARNING} Fetch refspec is configured but not optimal for bare repos with worktrees" -ForegroundColor Yellow
            Write-Host "   Current: $currentFetch" -ForegroundColor Yellow
            Write-Host "   Expected: $expectedFetch" -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host "${script:WARNING} Fetch refspec is not configured" -ForegroundColor Yellow
        Write-Host "   This prevents fetching remote branches properly in bare repositories" -ForegroundColor Yellow
        Write-Host ""
    }

    # Configure the correct fetch refspec
    $refspecSet = Set-FetchRefspec -RepoPath $script:PROJECT_DIR

    if ($refspecSet) {
        Write-Host ""

        # Optionally fetch to update remote branches
        Write-ProgressStart "Fetching all branches from origin"
        git -C $script:PROJECT_DIR fetch origin 2>$null | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Fetched all branches" -Status "success"
            Write-Host ""
            Write-Host "${script:CHECK} Fetch refspec fixed successfully!" -ForegroundColor Green
            Write-Host "   Remote branches are now available as 'remotes/origin/<branch-name>'" -ForegroundColor Cyan
            Write-Host "   You can now create worktrees from remote branches" -ForegroundColor Cyan
            return $true
        } else {
            Write-ProgressComplete "Fetch refspec configured, but fetch failed" -Status "warning"
            Write-Host "   You may need to run 'git fetch origin' manually" -ForegroundColor Yellow
            return $true
        }
    } else {
        return $false
    }
}

# Create worktree
function New-Worktree {
    param([string[]]$Arguments)

    # Ensure Arguments is an array
    if ($null -eq $Arguments) {
        $Arguments = @()
    }

    if ($Arguments.Count -eq 0) {
        Write-Host "${script:CROSS} Error: Please specify a name for the worktree" -ForegroundColor Red
        Write-Host "   Usage: wt add <name> [type]" -ForegroundColor Yellow
        return
    }

    # Ensure main worktree exists and is updated
    Write-Host ""
    Write-Host "=== Ensuring main worktree is up to date ===" -ForegroundColor Cyan
    if (-not (Initialize-MainWorktree)) {
        Write-Host "${script:CROSS} Failed to ensure main worktree. Aborting." -ForegroundColor Red
        return
    }
    Write-Host ""

    # Parse arguments: first is name, second (optional) is type
    $worktreeName = $Arguments[0]
    $branchType = $Arguments.Count -gt 1 ? $Arguments[1] : $script:DEFAULT_BRANCH_TYPE

    if ([string]::IsNullOrWhiteSpace($worktreeName)) {
        Write-Host "${script:CROSS} Error: Please specify a name for the worktree" -ForegroundColor Red
        Write-Host "   Usage: wt add <name> [type]" -ForegroundColor Yellow
        return
    }

    # Branch name format: {type}/{name}
    $branchName = "${branchType}/${worktreeName}"

    # Worktree path: trees/{name}
    $worktreePath = Join-Path $script:WORKTREE_PARENT $worktreeName

    if (Test-Path $worktreePath) {
        Write-Host "${script:CROSS} Error: Worktree '${worktreeName}' already exists at ${worktreePath}" -ForegroundColor Red
        Write-Host "   To navigate to it: cd ${worktreePath}" -ForegroundColor Yellow
        return
    }

    Write-Host "=== Creating worktree '${worktreeName}' ===" -ForegroundColor Green
    Write-Host "   Branch: ${branchName}" -ForegroundColor Cyan
    Write-Host "   Path: ${worktreePath}" -ForegroundColor Cyan
    Write-Host ""

    # Create parent directory
    New-Item -ItemType Directory -Path $script:WORKTREE_PARENT -Force | Out-Null

    # Check if branch exists
    if (Test-BranchExists -BranchName $branchName) {
        Write-Host "${script:SEARCH} Branch '${branchName}' already exists. Creating worktree from existing branch..." -ForegroundColor Blue
        Write-ProgressStart "Creating worktree"
        git -C $script:PROJECT_DIR worktree add $worktreePath $branchName 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Worktree created" -Status "success"
        } else {
            Write-ProgressComplete "Failed to create worktree" -Status "error"
            return
        }
    } else {
        Write-ProgressStart "Creating worktree"
        git -C $script:PROJECT_DIR worktree add -b $branchName $worktreePath 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Worktree created" -Status "success"
        } else {
            Write-ProgressComplete "Failed to create worktree" -Status "error"
            return
        }
    }

    # Set upstream tracking if remote branch exists
    git -C $script:PROJECT_DIR show-ref --verify --quiet "refs/remotes/origin/${branchName}" 2>$null
    if ($LASTEXITCODE -eq 0) {
        # Remote branch exists, set tracking
        Set-BranchUpstream -WorktreePath $worktreePath -BranchName $branchName | Out-Null
    } else {
        # No remote branch - this is a new local branch
        Write-Host "${script:INFO} No remote branch found (new local branch)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "${script:CHECK} Worktree '${worktreeName}' created at:" -ForegroundColor Green
    Write-Host "   $worktreePath" -ForegroundColor Cyan
    Write-Host "   Branch: $branchName" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To navigate to your new worktree, run:" -ForegroundColor Yellow
    Write-Host "   cd $worktreePath"
}

# Main function
function wt {
    param(
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Arguments
    )
    
    # Handle no arguments or help
    if ($Arguments.Count -eq 0 -or $Arguments[0] -in @("--help", "-h")) {
        Show-WorktreeHelp
        return
    }
    
    # Handle clone command separately (doesn't require being inside a git repo)
    if ($Arguments[0] -eq "clone") {
        $cloneArgs = @()
        if ($Arguments.Count -gt 1) {
            for ($i = 1; $i -lt $Arguments.Count; $i++) {
                $cloneArgs += $Arguments[$i]
            }
        }
        New-BareRepository -Arguments $cloneArgs
        return
    }
    
    # Initialize variables (requires being inside a git repo)
    $script:PROJECT_DIR = Get-GitRoot
    if (-not $script:PROJECT_DIR) {
        return
    }
    $script:PROJECT_NAME = Split-Path -Leaf $script:PROJECT_DIR
    $script:WORKTREE_PARENT = Join-Path $script:PROJECT_DIR "trees"
    
    $command = $Arguments[0]
    $remainingArgs = @()
    if ($Arguments.Count -gt 1) {
        for ($i = 1; $i -lt $Arguments.Count; $i++) {
            $remainingArgs += $Arguments[$i]
        }
    }
    
    switch ($command) {
        "add" {
            New-Worktree -Arguments $remainingArgs
        }
        "list" {
            Get-WorktreeList
        }
        "remove" {
            Remove-Worktree -Name ($remainingArgs -join " ")
        }
        "remove-all" {
            Remove-AllWorktrees
        }
        "fix-fetch" {
            Repair-FetchRefspec | Out-Null
        }
        default {
            Write-Host "${script:CROSS} Error: Unknown command '${command}'" -ForegroundColor Red
            Write-Host "   Run 'wt --help' to see available commands" -ForegroundColor Yellow
            return
        }
    }
}