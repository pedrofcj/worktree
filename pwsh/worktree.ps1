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

# Version tracking
$script:WT_VERSION = "1.3.0"
$script:WT_SCRIPT_DIR = $PSScriptRoot
$script:WT_REPO_DIR = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { $null }
if ($script:WT_REPO_DIR) {
    $versionFile = Join-Path $script:WT_REPO_DIR "VERSION"
    if (Test-Path $versionFile) {
        $versionValue = (Get-Content $versionFile -TotalCount 1).Trim()
        if ($versionValue) {
            $script:WT_VERSION = $versionValue
        }
    }
}

# Read worktree folder configuration from env var or ~/.wtconfig
# Returns $null if not configured (caller applies layout-dependent default)
# Note: uses $null -ne check, NOT truthiness, because "" is a valid config value
# (meaning "worktrees directly in project root")
function Get-WorktreeFolder {
    # Priority 1: environment variable (empty string is a valid value)
    if ($null -ne $env:WT_WORKTREE_FOLDER) {
        return $env:WT_WORKTREE_FOLDER
    }

    # Priority 2: ~/.wtconfig file
    $wtConfigPath = Join-Path $HOME ".wtconfig"
    if (Test-Path $wtConfigPath) {
        foreach ($line in (Get-Content $wtConfigPath)) {
            if ($line -match '^\s*worktree_folder\s*=\s*(.+)\s*$') {
                return $Matches[1].Trim()
            }
        }
    }

    # Not configured
    return $null
}

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

# Detect repository layout (modern vs classic) and set PROJECT_ROOT
function Get-ProjectLayout {
    # Primary detection: check for wt.layout git config
    $layoutConfig = git -C $script:PROJECT_DIR config --get wt.layout 2>$null
    if ($LASTEXITCODE -eq 0 -and $layoutConfig) {
        $script:LAYOUT_TYPE = $layoutConfig
        if ($layoutConfig -eq "modern") {
            $script:PROJECT_ROOT = Split-Path -Parent $script:PROJECT_DIR
        } else {
            $script:PROJECT_ROOT = $script:PROJECT_DIR
        }
        return
    }

    # Fallback heuristic: check if bare repo dir name is exactly ".git"
    $leafName = Split-Path -Leaf $script:PROJECT_DIR
    if ($leafName -eq ".git") {
        $script:LAYOUT_TYPE = "modern"
        $script:PROJECT_ROOT = Split-Path -Parent $script:PROJECT_DIR
    } else {
        $script:LAYOUT_TYPE = "classic"
        $script:PROJECT_ROOT = $script:PROJECT_DIR
    }
}

# ============================================================================
# Auto-update
# ============================================================================

# Check if auto-update is enabled (default: true)
function Get-AutoUpdateConfig {
    # Priority 1: environment variable
    if ($null -ne $env:WT_AUTO_UPDATE) {
        return ($env:WT_AUTO_UPDATE -ne "false")
    }
    # Priority 2: ~/.wtconfig file
    $wtConfigPath = Join-Path $HOME ".wtconfig"
    if (Test-Path $wtConfigPath) {
        foreach ($line in (Get-Content $wtConfigPath)) {
            if ($line -match '^\s*auto_update\s*=\s*(.+)\s*$') {
                return ($Matches[1].Trim() -ne "false")
            }
        }
    }
    return $true
}

# Compare two semver strings. Returns -1 (v1 < v2), 0 (equal), 1 (v1 > v2)
function Compare-WtVersion {
    param([string]$v1, [string]$v2)
    $parts1 = $v1 -split '\.' | ForEach-Object { [int]$_ }
    $parts2 = $v2 -split '\.' | ForEach-Object { [int]$_ }
    $maxLen = [Math]::Max($parts1.Count, $parts2.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $a = if ($i -lt $parts1.Count) { $parts1[$i] } else { 0 }
        $b = if ($i -lt $parts2.Count) { $parts2[$i] } else { 0 }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }
    return 0
}

# Resolve the wt scripts repository path
function Get-WtRepoDir {
    # Auto-detected from script location
    if ($script:WT_REPO_DIR -and (Test-Path (Join-Path $script:WT_REPO_DIR ".git") -ErrorAction SilentlyContinue)) {
        return $script:WT_REPO_DIR
    }
    # Environment variable override
    if ($env:WT_REPO_DIR -and (Test-Path $env:WT_REPO_DIR -ErrorAction SilentlyContinue)) {
        return $env:WT_REPO_DIR
    }
    # ~/.wtconfig fallback
    $wtConfigPath = Join-Path $HOME ".wtconfig"
    if (Test-Path $wtConfigPath) {
        foreach ($line in (Get-Content $wtConfigPath)) {
            if ($line -match '^\s*repo_dir\s*=\s*(.+)\s*$') {
                $dir = $Matches[1].Trim()
                if (Test-Path $dir) { return $dir }
            }
        }
    }
    return $null
}

# Read the remote version from the fetched origin
function Get-WtRemoteVersion {
    param([string]$RepoDir)

    # Determine the remote default branch for the wt repo
    $remoteBranch = git -C $RepoDir rev-parse --abbrev-ref origin/HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $remoteBranch -or $remoteBranch -eq "origin/HEAD") {
        foreach ($branch in @("main", "master")) {
            git -C $RepoDir show-ref --verify --quiet "refs/remotes/origin/$branch" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $remoteBranch = "origin/$branch"
                break
            }
        }
    }
    if (-not $remoteBranch) { return $null }

    $remoteVersion = git -C $RepoDir show "${remoteBranch}:VERSION" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $remoteVersion) { return $null }
    return $remoteVersion.Trim()
}

# Throttled update check — notifies user when a new version is available
function Test-WtUpdate {
    if (-not (Get-AutoUpdateConfig)) { return }

    $repoDir = Get-WtRepoDir
    if (-not $repoDir) { return }

    $cacheFile = Join-Path $HOME ".wt_update_check"
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if (Test-Path $cacheFile) {
        try {
            $cachedLines = @(Get-Content $cacheFile)
            $lastCheck = [long]$cachedLines[0].Trim()
            if (($now - $lastCheck) -lt 86400) {
                # Within throttle window — show cached notice if update available
                if ($cachedLines.Count -ge 2) {
                    $cachedVersion = $cachedLines[1].Trim()
                    if ($cachedVersion -and (Compare-WtVersion $script:WT_VERSION $cachedVersion) -lt 0) {
                        Write-Host "${script:WARNING} Update available: v${script:WT_VERSION} $([char]0x2192) v${cachedVersion}. Run '$($script:WT_COMMAND_NAME) update' to update." -ForegroundColor Yellow
                    }
                }
                return
            }
        } catch {
            # Corrupt cache file, continue with fresh check
        }
    }

    # Fetch silently
    git -C $repoDir fetch origin --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Network error — update timestamp to avoid retry flood
        Set-Content -Path $cacheFile -Value $now
        return
    }

    $remoteVersion = Get-WtRemoteVersion -RepoDir $repoDir
    if (-not $remoteVersion) {
        Set-Content -Path $cacheFile -Value $now
        return
    }

    # Write cache: line 1 = timestamp, line 2 = remote version
    Set-Content -Path $cacheFile -Value @($now, $remoteVersion)

    if ((Compare-WtVersion $script:WT_VERSION $remoteVersion) -lt 0) {
        Write-Host "${script:WARNING} Update available: v${script:WT_VERSION} $([char]0x2192) v${remoteVersion}. Run '$($script:WT_COMMAND_NAME) update' to update." -ForegroundColor Yellow
    }
}

# Update the wt scripts to the latest version
function Update-WtScript {
    Write-Host "=== Checking for updates ===" -ForegroundColor Cyan
    Write-Host ""

    $repoDir = Get-WtRepoDir
    if (-not $repoDir) {
        Write-Host "${script:CROSS} Cannot determine the wt repository location" -ForegroundColor Red
        Write-Host "   Set the WT_REPO_DIR environment variable or add 'repo_dir = /path/to/wt' to ~/.wtconfig" -ForegroundColor Yellow
        return
    }

    Write-Host "${script:INFO} Repository: ${repoDir}" -ForegroundColor Cyan
    Write-Host "${script:INFO} Current version: v${script:WT_VERSION}" -ForegroundColor Cyan
    Write-Host ""

    # Fetch latest
    Write-ProgressStart "Fetching latest version"
    git -C $repoDir fetch origin --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to fetch updates (check your network connection)" -Status "error"
        return
    }
    Write-ProgressComplete "Fetched latest version" -Status "success"

    $remoteVersion = Get-WtRemoteVersion -RepoDir $repoDir
    if (-not $remoteVersion) {
        Write-Host "${script:CROSS} Could not determine remote version" -ForegroundColor Red
        return
    }

    # Update cache
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cacheFile = Join-Path $HOME ".wt_update_check"
    Set-Content -Path $cacheFile -Value @($now, $remoteVersion)

    $comparison = Compare-WtVersion $script:WT_VERSION $remoteVersion
    if ($comparison -ge 0) {
        Write-Host "${script:CHECK} Already up to date (v${script:WT_VERSION})" -ForegroundColor Green
        return
    }

    Write-Host "${script:INFO} Latest version:  v${remoteVersion}" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "${script:WARNING} Updating will overwrite any manual changes you've made to the script files." -ForegroundColor Yellow
    Write-Host ""

    $response = Read-Host "Do you want to update? (y/N)"
    if ($response -notmatch '^[Yy]$') {
        Write-Host "${script:CROSS} Update cancelled" -ForegroundColor Red
        return
    }

    # Pull updates
    Write-ProgressStart "Updating scripts"
    git -C $repoDir pull 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to pull updates" -Status "error"
        Write-Host "   You may have local changes that conflict. Resolve them in:" -ForegroundColor Yellow
        Write-Host "   ${repoDir}" -ForegroundColor Yellow
        return
    }
    Write-ProgressComplete "Scripts updated to v${remoteVersion}" -Status "success"

    # Re-source the script to load the new version
    Write-ProgressStart "Reloading script"
    try {
        $scriptPath = Join-Path $script:WT_SCRIPT_DIR "worktree.ps1"
        . $scriptPath
        Write-ProgressComplete "Script reloaded (v${script:WT_VERSION})" -Status "success"
    } catch {
        Write-ProgressComplete "Failed to reload — restart your shell to use the new version" -Status "warning"
    }

    Write-Host ""
    Write-Host "${script:CHECK} Successfully updated to v${remoteVersion}!" -ForegroundColor Green
}

# Show help
function Show-WorktreeHelp {
    $cmd = $script:WT_COMMAND_NAME
    if (-not $cmd) { $cmd = "wt" }
    Write-Host "=== Git Worktree Manager ===" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Usage: " -NoNewline -ForegroundColor Cyan
    Write-Host "${cmd} <command>" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "add <name> [type] [--from <worktree>]" -ForegroundColor Green -NoNewline
    Write-Host ""
    Write-Host "                          Create a new worktree (type defaults to 'feature')"
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
    Write-Host "  " -NoNewline
    Write-Host "migrate" -ForegroundColor Green -NoNewline
    Write-Host "             Migrate a classic (trees/) layout to modern (.git) layout"
    Write-Host "  " -NoNewline
    Write-Host "update" -ForegroundColor Green -NoNewline
    Write-Host "              Check for updates and apply them"
    Write-Host "  " -NoNewline
    Write-Host "version" -ForegroundColor Green -NoNewline
    Write-Host "             Show current version"
    Write-Host ""
    Write-Host "When creating a worktree:" -ForegroundColor Cyan
    Write-Host "  • Branch name format: <type>/<name> (default type is 'feature')"
    Write-Host "  • If the branch doesn't exist, it creates a new branch"
    Write-Host "  • If the branch already exists, it checks out the existing branch"
    Write-Host "  • Use --from to base the new branch on another worktree's branch"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "${cmd} clone https://github.com/user/repo.git" -ForegroundColor Yellow -NoNewline
    Write-Host "  # Clone repo as bare and set up main worktree"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} add RDUCH-123-add-serialization" -ForegroundColor Yellow -NoNewline
    Write-Host "     # Creates worktree with branch feature/RDUCH-123-add-serialization"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} add RTJK-1223332-whatever bug" -ForegroundColor Yellow -NoNewline
    Write-Host "    # Creates worktree with branch bug/RTJK-1223332-whatever"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} add my-fix --from other-tree" -ForegroundColor Yellow -NoNewline
    Write-Host "          # Creates worktree branching from other-tree's branch"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} list" -ForegroundColor Yellow -NoNewline
    Write-Host "                              # List all worktrees (shows current with ${script:STAR})"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} remove my-feature" -ForegroundColor Yellow -NoNewline
    Write-Host "                 # Remove specific worktree"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} remove-all" -ForegroundColor Yellow -NoNewline
    Write-Host "                        # Remove all worktrees"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} fix-fetch" -ForegroundColor Yellow -NoNewline
    Write-Host "                        # Fix fetch refspec configuration"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} migrate" -ForegroundColor Yellow -NoNewline
    Write-Host "                         # Migrate classic layout to modern layout"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} update" -ForegroundColor Yellow -NoNewline
    Write-Host "                          # Check for updates and apply them"
    Write-Host "  " -NoNewline
    Write-Host "${cmd} version" -ForegroundColor Yellow -NoNewline
    Write-Host "                         # Show current version"
    Write-Host ""
    Write-Host "Configuration (~/.wtconfig or environment variables):" -ForegroundColor Cyan
    Write-Host "  command_name / WT_RENAME              " -NoNewline -ForegroundColor Green
    Write-Host "Set custom command name"
    Write-Host "  worktree_folder / WT_WORKTREE_FOLDER  " -NoNewline -ForegroundColor Green
    Write-Host "Set worktree subfolder (default: project root)"
    Write-Host "  auto_update / WT_AUTO_UPDATE          " -NoNewline -ForegroundColor Green
    Write-Host "Enable/disable update check (default: true)"
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

# Validate worktree name against reserved names and path rules
function Test-ValidWorktreeName {
    param([string]$Name)

    $reservedNames = @(".git", ".bare", "..")

    if ($Name -in $reservedNames) {
        Write-Host "${script:CROSS} Error: '${Name}' is a reserved name and cannot be used as a worktree name" -ForegroundColor Red
        return $false
    }

    if ($Name -match '[/\\]') {
        Write-Host "${script:CROSS} Error: Worktree name '${Name}' cannot contain path separators" -ForegroundColor Red
        return $false
    }

    if ($script:WORKTREE_FOLDER -and $Name -eq $script:WORKTREE_FOLDER) {
        Write-Host "${script:CROSS} Error: '${Name}' conflicts with the configured worktree folder name" -ForegroundColor Red
        return $false
    }

    return $true
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
        Write-Host "   Usage: $($script:WT_COMMAND_NAME) remove <worktree-name>" -ForegroundColor Yellow
        return
    }

    # Look up the worktree from git's worktree list by name (handles any location)
    $worktrees = Get-ParsedWorktrees
    $matchedWorktree = $worktrees | Where-Object { $_.Name -eq $Name -and -not $_.IsBare } | Select-Object -First 1

    if ($matchedWorktree) {
        $worktreePath = $matchedWorktree.Path
        $branchName = $matchedWorktree.Branch
    } else {
        Write-Host "${script:CROSS} Error: Worktree '${Name}' not found" -ForegroundColor Red
        Write-Host "   Run '$($script:WT_COMMAND_NAME) list' to see available worktrees" -ForegroundColor Yellow
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

    # Collect all non-bare worktrees, excluding the default branch
    foreach ($wt in $parsedWorktrees) {
        if ($wt.IsBare) { continue }
        # Skip the default branch worktree - it must always be preserved
        if ($wt.Branch -eq $defaultBranch -or $wt.Name -eq $defaultBranch) {
            continue
        }
        $worktreesToRemove += $wt
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

    # Check if a worktree for the default branch already exists (at any location)
    $parsedWorktrees = Get-ParsedWorktrees

    if ($detectedBranch) {
        $matchedWorktree = $parsedWorktrees | Where-Object { $_.Branch -eq $detectedBranch -and -not $_.IsBare } | Select-Object -First 1
        if ($matchedWorktree) {
            $mainWorktreePath = $matchedWorktree.Path
            $mainBranch = $detectedBranch
        }
    }

    # Fallback: check for common branch names if no worktree found yet
    if (-not $mainWorktreePath) {
        $commonBranches = @("main", "master", "develop", "trunk")
        foreach ($branch in $commonBranches) {
            $matchedWorktree = $parsedWorktrees | Where-Object { $_.Branch -eq $branch -and -not $_.IsBare } | Select-Object -First 1
            if ($matchedWorktree) {
                $mainWorktreePath = $matchedWorktree.Path
                $mainBranch = $branch
                break
            }
        }
    }

    # No existing worktree found - need to create one
    if (-not $mainWorktreePath) {
        Write-Host "Default branch worktree doesn't exist. Creating it..." -ForegroundColor Yellow

        # If default branch wasn't detected, fix refspec and retry (handles bare repos cloned without wt)
        if (-not $detectedBranch) {
            Set-FetchRefspec -Silent | Out-Null

            Write-ProgressStart "Fetching all branches from bare repository"
            git -C $script:PROJECT_DIR fetch --all 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-ProgressComplete "Fetched all branches" -Status "success"
            } else {
                Write-ProgressComplete "Failed to fetch branches" -Status "warning"
            }

            $detectedBranch = Get-DefaultBranch
        }

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
            Write-ProgressComplete "Worktree created at ${mainWorktreePath}" -Status "success"
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

# Clone repository as bare with modern layout
function New-BareRepository {
    param([string[]]$Arguments)

    # Validate URL argument
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        Write-Host "${script:CROSS} Error: Please specify a repository URL" -ForegroundColor Red
        Write-Host "   Usage: $($script:WT_COMMAND_NAME) clone <url>" -ForegroundColor Yellow
        return
    }

    $repoUrl = $Arguments[0]

    if ([string]::IsNullOrWhiteSpace($repoUrl)) {
        Write-Host "${script:CROSS} Error: Please specify a repository URL" -ForegroundColor Red
        Write-Host "   Usage: $($script:WT_COMMAND_NAME) clone <url>" -ForegroundColor Yellow
        return
    }

    # Extract repo name from URL
    # Handle HTTPS: https://github.com/user/repo.git -> repo
    # Handle SSH: git@github.com:user/repo.git -> repo
    $repoName = $repoUrl -replace '\.git$', ''  # Remove .git suffix if present
    $repoName = $repoName -replace '.*[/:]', '' # Get last part after / or :

    $destinationPath = Join-Path $PWD.Path $repoName
    $bareRepoPath = Join-Path $destinationPath ".git"

    if (Test-Path $destinationPath) {
        Write-Host "${script:CROSS} Error: Directory '${repoName}' already exists" -ForegroundColor Red
        Write-Host "   Please remove it or choose a different location" -ForegroundColor Yellow
        return
    }

    Write-Host "=== Cloning repository as bare ===" -ForegroundColor Blue
    Write-Host "   URL: ${repoUrl}" -ForegroundColor Cyan
    Write-Host "   Destination: ./${repoName}" -ForegroundColor Cyan
    Write-Host ""

    # Create project root directory
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null

    # Clone with --bare flag into .git subdirectory
    Write-ProgressStart "Cloning repository"
    $cloneResult = git clone --bare $repoUrl $bareRepoPath 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to clone repository" -Status "error"
        Write-Host "   Error: $cloneResult" -ForegroundColor Yellow
        # Clean up the empty directory
        Remove-Item -Path $destinationPath -Force -Recurse -ErrorAction SilentlyContinue
        return
    }
    Write-ProgressComplete "Repository cloned" -Status "success"

    # Ensure core.bare is explicitly set (safety for .git directory name)
    git -C $bareRepoPath config core.bare true 2>$null | Out-Null

    # Set layout marker
    git -C $bareRepoPath config wt.layout modern 2>$null | Out-Null

    # Configure fetch refspec
    Set-FetchRefspec -RepoPath $bareRepoPath | Out-Null

    # Fetch all branches
    Write-ProgressStart "Fetching all branches"
    git -C $bareRepoPath fetch --all 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "Fetched all branches" -Status "success"
    } else {
        Write-ProgressComplete "Failed to fetch all branches (continuing anyway)" -Status "warning"
    }

    # Detect default branch dynamically
    Write-ProgressStart "Detecting default branch"
    $mainBranch = Get-DefaultBranch -RepoPath $bareRepoPath

    if (-not $mainBranch) {
        Write-ProgressComplete "Failed to detect default branch" -Status "error"
        Write-Host "   The repository was cloned but no worktree was created." -ForegroundColor Yellow
        Write-Host "   You can manually create a worktree using: $($script:WT_COMMAND_NAME) add <name>" -ForegroundColor Yellow
        return
    }
    Write-ProgressComplete "Found default branch: ${mainBranch}" -Status "success"

    # Resolve worktree folder from config (no layout context needed — modern default is "")
    $worktreeFolder = Get-WorktreeFolder
    if ($null -eq $worktreeFolder) {
        $worktreeFolder = ""
    }

    # Compute worktree parent
    if ($worktreeFolder) {
        $worktreeParent = Join-Path $destinationPath $worktreeFolder
        New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null
    } else {
        $worktreeParent = $destinationPath
    }

    # Create worktree for default branch
    $mainWorktreePath = Join-Path $worktreeParent $mainBranch
    Write-ProgressStart "Creating worktree for ${mainBranch} branch"
    git -C $bareRepoPath worktree add $mainWorktreePath $mainBranch 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-ProgressComplete "Failed to create worktree for ${mainBranch}" -Status "error"
        return
    }
    Write-ProgressComplete "Worktree created at ${mainWorktreePath}" -Status "success"

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
    Write-Host "   Project root: ${destinationPath}" -ForegroundColor Cyan
    Write-Host "   Bare repo: ${bareRepoPath}" -ForegroundColor Cyan
    Write-Host "   Main worktree: ${mainWorktreePath}" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "${script:INFO} The project root (${repoName}/) is a container — work inside worktree directories." -ForegroundColor Yellow
    Write-Host ""

    $response = Read-Host "Do you want to navigate to the main worktree? (Y/n)"
    if ($response -notmatch '^[Nn]$') {
        Set-Location $mainWorktreePath
    }
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

# Migrate classic layout to modern layout
function Convert-ToModernLayout {
    # Precondition: must be classic layout
    if ($script:LAYOUT_TYPE -eq "modern") {
        Write-Host "${script:CHECK} This repository already uses the modern layout" -ForegroundColor Green
        Write-Host "   Bare repo: $script:PROJECT_DIR" -ForegroundColor Cyan
        Write-Host "   Project root: $script:PROJECT_ROOT" -ForegroundColor Cyan
        return
    }

    # Compute new paths
    $oldRoot = $script:PROJECT_DIR
    $oldRootName = Split-Path -Leaf $oldRoot
    $newRootName = $oldRootName -replace '\.git$', ''
    $newRoot = Join-Path (Split-Path -Parent $oldRoot) $newRootName
    $newBareRepo = Join-Path $newRoot ".git"

    # Check for collision
    if (Test-Path $newRoot) {
        Write-Host "${script:CROSS} Error: Directory '${newRootName}' already exists" -ForegroundColor Red
        Write-Host "   Cannot migrate — the target directory is taken" -ForegroundColor Yellow
        return
    }

    # Parse worktrees
    $parsedWorktrees = Get-ParsedWorktrees
    $worktreesToMove = @()
    $externalWorktrees = @()
    $defaultBranch = Get-DefaultBranch

    foreach ($wt in $parsedWorktrees) {
        if ($wt.IsBare) { continue }
        $normalizedWtPath = ($wt.Path -replace '/', '\').TrimEnd('\')
        $normalizedOldRoot = ($oldRoot -replace '/', '\').TrimEnd('\')
        # Case-insensitive check with trailing separator to avoid prefix-overlap
        # (e.g., "MyProject.git" must not match "MyProject.git-backup")
        if ($normalizedWtPath.StartsWith($normalizedOldRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $worktreesToMove += $wt
        } else {
            $externalWorktrees += $wt
        }
    }

    # Resolve worktree folder for new layout (null = not configured, "" = explicitly empty)
    $worktreeFolder = Get-WorktreeFolder
    if ($null -eq $worktreeFolder) {
        $worktreeFolder = ""
    }

    # Check for uncommitted changes
    $dirtyWorktrees = @()
    foreach ($wt in $worktreesToMove) {
        $status = git -C $wt.Path status --porcelain 2>$null
        if ($status) {
            $changedFiles = ($status | Measure-Object).Count
            $dirtyWorktrees += [PSCustomObject]@{
                Name = $wt.Name
                ChangedFiles = $changedFiles
            }
        }
    }

    # Show migration preview
    Write-Host "=== Migration Preview ===" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Current layout (classic):" -ForegroundColor Cyan
    Write-Host "  Bare repo: ${oldRoot}" -ForegroundColor White
    foreach ($wt in $worktreesToMove) {
        Write-Host "  Worktree: $($wt.Name) → $($wt.Path)" -ForegroundColor White
    }
    if ($externalWorktrees.Count -gt 0) {
        Write-Host "  External worktrees (will NOT be moved):" -ForegroundColor Yellow
        foreach ($wt in $externalWorktrees) {
            Write-Host "    $($wt.Name) → $($wt.Path)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "New layout (modern):" -ForegroundColor Cyan
    Write-Host "  Project root: ${newRoot}" -ForegroundColor White
    Write-Host "  Bare repo: ${newBareRepo}" -ForegroundColor White
    foreach ($wt in $worktreesToMove) {
        if ($worktreeFolder) {
            $newPath = Join-Path $newRoot (Join-Path $worktreeFolder $wt.Name)
        } else {
            $newPath = Join-Path $newRoot $wt.Name
        }
        Write-Host "  Worktree: $($wt.Name) → ${newPath}" -ForegroundColor White
    }
    Write-Host ""

    # Warn about uncommitted changes
    if ($dirtyWorktrees.Count -gt 0) {
        Write-Host "${script:WARNING} The following worktrees have uncommitted changes:" -ForegroundColor Yellow
        foreach ($dw in $dirtyWorktrees) {
            Write-Host "  ${script:CROSS} $($dw.Name) ($($dw.ChangedFiles) modified files)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Uncommitted changes will be preserved during migration, but if anything" -ForegroundColor Yellow
        Write-Host "goes wrong they could be lost." -ForegroundColor Yellow
        Write-Host ""
    }

    $response = Read-Host "Are you sure you want to migrate? (y/N)"
    if ($response -notmatch '^[Yy]$') {
        Write-Host "${script:CROSS} Cancelled" -ForegroundColor Red
        return
    }

    # CWD safety: move out of the repo being migrated (Windows directory locking)
    $normalizedPwd = ($PWD.Path -replace '/', '\').TrimEnd('\')
    $normalizedOldRoot = ($oldRoot -replace '/', '\').TrimEnd('\')
    if ($normalizedPwd -eq $normalizedOldRoot -or
        $normalizedPwd.StartsWith($normalizedOldRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $parentDir = Split-Path -Parent $oldRoot
        Set-Location $parentDir
        Write-Host "${script:INFO} Changed directory to ${parentDir} (required for migration)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "=== Migrating to modern layout ===" -ForegroundColor Blue

    # Step a: Create new project root
    Write-ProgressStart "Creating project root '${newRootName}'"
    try {
        New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
        Write-ProgressComplete "Project root created" -Status "success"
    } catch {
        Write-ProgressComplete "Failed to create project root: $_" -Status "error"
        return
    }

    # Step b: Create worktree subfolder if configured
    if ($worktreeFolder) {
        $worktreeSubfolder = Join-Path $newRoot $worktreeFolder
        New-Item -ItemType Directory -Path $worktreeSubfolder -Force | Out-Null
    }

    # Step c: Move worktrees
    $newWorktreePaths = @()
    foreach ($wt in $worktreesToMove) {
        if ($worktreeFolder) {
            $newPath = Join-Path $newRoot (Join-Path $worktreeFolder $wt.Name)
        } else {
            $newPath = Join-Path $newRoot $wt.Name
        }

        Write-ProgressStart "Moving worktree '$($wt.Name)'"
        try {
            Move-Item -Path $wt.Path -Destination $newPath -Force
            Write-ProgressComplete "Moved '$($wt.Name)'" -Status "success"
            $newWorktreePaths += $newPath
        } catch {
            Write-ProgressComplete "Failed to move '$($wt.Name)': $_" -Status "error"
            Write-Host "${script:CROSS} Migration failed. The old directory is still intact at: ${oldRoot}" -ForegroundColor Red
            Write-Host "   Clean up the partial migration directory: ${newRoot}" -ForegroundColor Yellow
            return
        }
    }

    # Add external worktree paths (they haven't moved but need repair)
    foreach ($wt in $externalWorktrees) {
        $newWorktreePaths += $wt.Path
    }

    # Step d: Move bare repo to .git
    Write-ProgressStart "Moving bare repo to ${newBareRepo}"
    try {
        New-Item -ItemType Directory -Path $newBareRepo -Force | Out-Null

        # Move all items from old root to new .git
        # Skip any empty directories left behind after worktree moves
        $itemsToMove = Get-ChildItem -Path $oldRoot -Force
        foreach ($item in $itemsToMove) {
            if ($item.PSIsContainer) {
                $remaining = Get-ChildItem -Path $item.FullName -Force
                if (-not $remaining) {
                    # Empty directory (likely the old worktree folder after moves)
                    Remove-Item -Path $item.FullName -Force
                    continue
                }
            }
            Move-Item -Path $item.FullName -Destination $newBareRepo -Force
        }
        Write-ProgressComplete "Bare repo moved" -Status "success"
    } catch {
        Write-ProgressComplete "Failed to move bare repo: $_" -Status "error"
        Write-Host "${script:CROSS} Migration failed during bare repo move." -ForegroundColor Red
        Write-Host "   Old directory: ${oldRoot}" -ForegroundColor Yellow
        Write-Host "   New directory: ${newRoot}" -ForegroundColor Yellow
        Write-Host "   Manual recovery may be needed." -ForegroundColor Yellow
        return
    }

    # Step e: Set config values
    git -C $newBareRepo config core.bare true 2>$null | Out-Null
    git -C $newBareRepo config wt.layout modern 2>$null | Out-Null

    # Step f: Repair worktree cross-references
    Write-ProgressStart "Repairing worktree references"
    $repairArgs = @("-C", $newBareRepo, "worktree", "repair") + $newWorktreePaths
    git @repairArgs 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ProgressComplete "Worktree references repaired" -Status "success"
    } else {
        Write-ProgressComplete "Worktree repair had issues (check manually)" -Status "warning"
    }

    # Step g: Verify
    Write-ProgressStart "Verifying migration"
    $verifyOutput = git -C $newBareRepo worktree list 2>$null
    if ($LASTEXITCODE -eq 0 -and $verifyOutput) {
        Write-ProgressComplete "Migration verified" -Status "success"
    } else {
        Write-ProgressComplete "Verification failed — check worktree list manually" -Status "warning"
    }

    # Step h: Remove old directory
    Write-ProgressStart "Removing old directory"
    try {
        # Old root should be empty or nearly empty after moving everything
        Remove-Item -Path $oldRoot -Force -Recurse -ErrorAction Stop
        Write-ProgressComplete "Old directory removed" -Status "success"
    } catch {
        Write-ProgressComplete "Could not remove old directory: ${oldRoot}" -Status "warning"
        Write-Host "   You may need to remove it manually" -ForegroundColor Yellow
    }

    # Success
    Write-Host ""
    Write-Host "${script:CHECK} Migration complete!" -ForegroundColor Green
    Write-Host "   Project root: ${newRoot}" -ForegroundColor Cyan
    Write-Host "   Bare repo: ${newBareRepo}" -ForegroundColor Cyan
    Write-Host ""

    # Find the default branch worktree for cd offer
    $defaultWorktreePath = $null
    foreach ($wt in $worktreesToMove) {
        if ($wt.Branch -eq $defaultBranch -or $wt.Name -eq $defaultBranch) {
            if ($worktreeFolder) {
                $defaultWorktreePath = Join-Path $newRoot (Join-Path $worktreeFolder $wt.Name)
            } else {
                $defaultWorktreePath = Join-Path $newRoot $wt.Name
            }
            break
        }
    }

    if ($defaultWorktreePath -and (Test-Path $defaultWorktreePath)) {
        $response = Read-Host "Do you want to navigate to the main worktree? (Y/n)"
        if ($response -notmatch '^[Nn]$') {
            Set-Location $defaultWorktreePath
        }
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
        Write-Host "   Usage: $($script:WT_COMMAND_NAME) add <name> [type] [--from <worktree>]" -ForegroundColor Yellow
        return
    }

    # Parse --from flag from arguments
    $fromWorktree = $null
    $positionalArgs = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq "--from" -and ($i + 1) -lt $Arguments.Count) {
            $fromWorktree = $Arguments[$i + 1]
            $i++  # skip the value
        } else {
            $positionalArgs += $Arguments[$i]
        }
    }

    # Parse positional arguments: first is name, second (optional) is type
    $worktreeName = $positionalArgs[0]
    $branchType = $positionalArgs.Count -gt 1 ? $positionalArgs[1] : $script:DEFAULT_BRANCH_TYPE

    if ([string]::IsNullOrWhiteSpace($worktreeName)) {
        Write-Host "${script:CROSS} Error: Please specify a name for the worktree" -ForegroundColor Red
        Write-Host "   Usage: $($script:WT_COMMAND_NAME) add <name> [type] [--from <worktree>]" -ForegroundColor Yellow
        return
    }

    # Validate worktree name
    if (-not (Test-ValidWorktreeName -Name $worktreeName)) {
        return
    }

    # Resolve --from source branch
    $startPoint = $null
    if ($fromWorktree) {
        # When branching from another worktree, update that worktree instead of the default branch
        Write-Host ""
        Write-Host "=== Ensuring source worktree '${fromWorktree}' is up to date ===" -ForegroundColor Cyan

        $parsedWorktrees = Get-ParsedWorktrees
        $sourceWorktree = $parsedWorktrees | Where-Object { $_.Name -eq $fromWorktree -and -not $_.IsBare } | Select-Object -First 1
        if (-not $sourceWorktree) {
            Write-Host "${script:CROSS} Error: Source worktree '${fromWorktree}' not found" -ForegroundColor Red
            Write-Host "   Run '$($script:WT_COMMAND_NAME) list' to see available worktrees" -ForegroundColor Yellow
            return
        }
        $startPoint = $sourceWorktree.Branch

        # Fetch all from bare repo
        Write-ProgressStart "Fetching all branches from bare repository"
        git -C $script:PROJECT_DIR fetch --all 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Fetched all branches" -Status "success"
        } else {
            Write-ProgressComplete "Failed to fetch all branches (continuing anyway)" -Status "warning"
        }

        # Pull the source worktree
        Write-ProgressStart "Updating source worktree '${fromWorktree}'"
        git -C $sourceWorktree.Path pull 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-ProgressComplete "Source worktree '${fromWorktree}' updated" -Status "success"
        } else {
            Write-ProgressComplete "Failed to pull source worktree (continuing anyway)" -Status "warning"
        }
        Write-Host ""
    } else {
        # Ensure main worktree exists and is updated
        Write-Host ""
        Write-Host "=== Ensuring main worktree is up to date ===" -ForegroundColor Cyan
        if (-not (Initialize-MainWorktree)) {
            Write-Host "${script:CROSS} Failed to ensure main worktree. Aborting." -ForegroundColor Red
            return
        }
        Write-Host ""
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
    if ($startPoint) {
        Write-Host "   From: ${fromWorktree} (branch: ${startPoint})" -ForegroundColor Cyan
    }
    Write-Host ""

    # Create parent directory
    New-Item -ItemType Directory -Path $script:WORKTREE_PARENT -Force | Out-Null

    # Check if branch exists
    if (Test-BranchExists -BranchName $branchName) {
        if ($startPoint) {
            Write-Host "${script:WARNING} Branch '${branchName}' already exists, --from flag will be ignored" -ForegroundColor Yellow
        }
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
        if ($startPoint) {
            git -C $script:PROJECT_DIR worktree add -b $branchName $worktreePath $startPoint 2>$null | Out-Null
        } else {
            git -C $script:PROJECT_DIR worktree add -b $branchName $worktreePath 2>$null | Out-Null
        }
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

    $response = Read-Host "Do you want to navigate to the new worktree? (Y/n)"
    if ($response -notmatch '^[Nn]$') {
        Set-Location $worktreePath
    }
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
    
    # Handle commands that don't require being inside a git repo
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

    if ($Arguments[0] -eq "update") {
        Update-WtScript
        return
    }

    if ($Arguments[0] -in @("version", "--version")) {
        Write-Host "v${script:WT_VERSION}" -ForegroundColor Cyan
        return
    }

    # Auto-update check (throttled, silent on errors)
    Test-WtUpdate

    # Initialize variables (requires being inside a git repo)
    $script:PROJECT_DIR = Get-GitRoot
    if (-not $script:PROJECT_DIR) {
        return
    }

    # Detect layout and set PROJECT_ROOT
    Get-ProjectLayout

    $script:PROJECT_NAME = Split-Path -Leaf $script:PROJECT_ROOT

    # Resolve worktree folder: config > layout default
    $configuredFolder = Get-WorktreeFolder
    if ($null -ne $configuredFolder) {
        $script:WORKTREE_FOLDER = $configuredFolder
    } elseif ($script:LAYOUT_TYPE -eq "classic") {
        $script:WORKTREE_FOLDER = "trees"
    } else {
        $script:WORKTREE_FOLDER = ""
    }

    # Compute worktree parent path
    if ($script:WORKTREE_FOLDER) {
        $script:WORKTREE_PARENT = Join-Path $script:PROJECT_ROOT $script:WORKTREE_FOLDER
    } else {
        $script:WORKTREE_PARENT = $script:PROJECT_ROOT
    }
    
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
        "migrate" {
            Convert-ToModernLayout
        }
        "update" {
            Update-WtScript
        }
        "version" {
            Write-Host "v${script:WT_VERSION}" -ForegroundColor Cyan
        }
        default {
            Write-Host "${script:CROSS} Error: Unknown command '${command}'" -ForegroundColor Red
            Write-Host "   Run '$($script:WT_COMMAND_NAME) --help' to see available commands" -ForegroundColor Yellow
            return
        }
    }
}

# Resolve command name: env var > ini file > default 'wt'
$script:WT_COMMAND_NAME = $env:WT_RENAME
if (-not $script:WT_COMMAND_NAME) {
    $wtConfigPath = Join-Path $HOME ".wtconfig"
    if (Test-Path $wtConfigPath) {
        foreach ($line in (Get-Content $wtConfigPath)) {
            if ($line -match '^\s*command_name\s*=\s*(.+)\s*$') {
                $script:WT_COMMAND_NAME = $Matches[1].Trim()
                break
            }
        }
    }
}
if (-not $script:WT_COMMAND_NAME) {
    $script:WT_COMMAND_NAME = "wt"
}

# Rename function if configured
if ($script:WT_COMMAND_NAME -ne "wt") {
    if (Get-Command $script:WT_COMMAND_NAME -CommandType Function -ErrorAction SilentlyContinue) {
        Remove-Item -Path "function:$($script:WT_COMMAND_NAME)" -Force -ErrorAction SilentlyContinue
    }
    if (Get-Command wt -CommandType Function -ErrorAction SilentlyContinue) {
        Rename-Item -Path "function:wt" -NewName $script:WT_COMMAND_NAME -Force -ErrorAction SilentlyContinue
    }
}
