# Modern Layout & Clone Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the PowerShell worktree manager to use a modern layout where `wt clone` places the bare repo inside `.git` with worktrees as siblings, while maintaining backward compatibility with the classic `trees/` layout.

**Architecture:** Single-file modification to `pwsh/worktree.ps1`. New functions (`Get-WorktreeFolder`, `Get-ProjectLayout`, `Test-ValidWorktreeName`, `Convert-ToModernLayout`) are added. The `wt` init block is rewritten to detect layout and compute variables. No new files created.

**Tech Stack:** PowerShell, Git CLI

**Spec:** `docs/superpowers/specs/2026-03-16-modern-layout-design.md`

---

## Chunk 1: Foundation — Config Reading and Layout Detection

These tasks add the new helper functions that everything else depends on. No existing behavior changes yet.

### Task 1: Add `Get-WorktreeFolder` function

**Files:**
- Modify: `pwsh/worktree.ps1:14-15` (replace hardcoded `WORKTREE_FOLDER`)

This function reads the worktree folder config from env var or `~/.wtconfig`. It has NO dependency on `PROJECT_DIR` or layout — it only reads external config. Returns `$null` if nothing is configured.

- [ ] **Step 1: Add `Get-WorktreeFolder` function after line 15**

Insert after the `$script:DEFAULT_BRANCH_TYPE` line. **Keep** `$script:WORKTREE_FOLDER = "trees"` for now (it will be removed in Task 11 after all other changes are in place, so existing behavior is not broken between tasks):

```powershell
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
```

- [ ] **Step 2: Verify the function is syntactically valid**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1; Get-WorktreeFolder"`
Expected: No error, returns empty output (since no config exists)

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): add Get-WorktreeFolder config reader"
```

---

### Task 2: Add `Get-ProjectLayout` function

**Files:**
- Modify: `pwsh/worktree.ps1` (add function after `Get-GitRoot`)

This function detects whether the repo uses modern or classic layout. It sets `$script:PROJECT_ROOT` and `$script:LAYOUT_TYPE`. Primary detection uses `wt.layout` git config; fallback checks if the bare repo dir name is `.git`.

- [ ] **Step 1: Add `Get-ProjectLayout` function after `Get-GitRoot`**

Insert after the closing `}` of `Get-GitRoot` (after line 177):

```powershell
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
```

- [ ] **Step 2: Verify function loads without error**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1"`
Expected: No error (function is defined but not called yet)

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): add Get-ProjectLayout for layout auto-detection"
```

---

### Task 3: Add `Test-ValidWorktreeName` function

**Files:**
- Modify: `pwsh/worktree.ps1` (add function after `Test-BranchExists`)

Validates worktree names against reserved names, path separators, and config collisions.

- [ ] **Step 1: Add `Test-ValidWorktreeName` function**

Insert after `Test-BranchExists`:

```powershell
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
```

- [ ] **Step 2: Verify function loads without error**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1"`
Expected: No error

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): add Test-ValidWorktreeName validation"
```

---

### Task 4: Rewrite the `wt` init block

**Files:**
- Modify: `pwsh/worktree.ps1:924-930` (the init block inside `function wt`)

Replace the hardcoded init with the new layout-aware sequence.

- [ ] **Step 1: Replace the init block**

Replace lines 924-930 (after the clone dispatch, before `$command = $Arguments[0]`):

Old:
```powershell
    # Initialize variables (requires being inside a git repo)
    $script:PROJECT_DIR = Get-GitRoot
    if (-not $script:PROJECT_DIR) {
        return
    }
    $script:PROJECT_NAME = Split-Path -Leaf $script:PROJECT_DIR
    $script:WORKTREE_PARENT = Join-Path $script:PROJECT_DIR "trees"
```

New:
```powershell
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
```

- [ ] **Step 2: Add `migrate` to the switch block**

In the `switch ($command)` block, add before the `default` case:

```powershell
        "migrate" {
            Convert-ToModernLayout
        }
```

Note: `Convert-ToModernLayout` is not defined until Task 9. Running `wt migrate` between Task 4 and Task 9 will error — this is expected.

- [ ] **Step 3: Verify existing commands still work in a classic repo**

Run from inside any existing bare repo:
```
pwsh -NoProfile -Command ". ./pwsh/worktree.ps1; wt list"
```
Expected: Same output as before (classic layout detected, `trees/` used)

- [ ] **Step 4: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): rewrite wt init block with layout-aware variable resolution"
```

---

## Chunk 2: Update Existing Commands

### Task 5: Update `Get-WorktreeList` for modern layout display

**Files:**
- Modify: `pwsh/worktree.ps1` — `Get-WorktreeList` function (lines 289-343)

The header and project name must use `PROJECT_ROOT`/`PROJECT_NAME`. The `[bare repository]` line keeps using `PROJECT_DIR`.

- [ ] **Step 1: Update the header line**

In `Get-WorktreeList`, change:
```powershell
    Write-Host "=== Git Worktrees for $script:PROJECT_NAME ===" -ForegroundColor Blue
```

No change needed — `$script:PROJECT_NAME` is now derived from `PROJECT_ROOT` in the init block, so this automatically shows the correct name.

Verify mentally: in modern layout, `PROJECT_ROOT` = `ShedEnergy`, so `PROJECT_NAME` = `ShedEnergy`. Correct.

- [ ] **Step 2: Verify `PROJECT_DIR` line is still correct**

Line 302: `Write-Host "$script:PROJECT_DIR" -ForegroundColor Cyan` — this stays as-is. In modern layout it shows `ShedEnergy/.git` which is correct (user needs to know where the bare repo is).

No code change needed for this task — the init block rewrite in Task 4 handles everything.

- [ ] **Step 3: Commit (skip if no changes)**

No code changes needed — the init block rewrite handles the display fix.

---

### Task 6: Fix `Initialize-MainWorktree` hardcoded message

**Files:**
- Modify: `pwsh/worktree.ps1` — `Initialize-MainWorktree` function (line 541)

- [ ] **Step 1: Fix the success message**

Change line 541:
```powershell
            Write-ProgressComplete "Worktree created at $script:WORKTREE_FOLDER/${mainBranch}" -Status "success"
```
To:
```powershell
            Write-ProgressComplete "Worktree created at ${mainWorktreePath}" -Status "success"
```

This uses the actual computed path instead of the hardcoded folder name.

- [ ] **Step 2: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "fix(pwsh): use actual path in Initialize-MainWorktree success message"
```

---

### Task 7: Add name validation to `New-Worktree`

**Files:**
- Modify: `pwsh/worktree.ps1` — `New-Worktree` function (after line 778)

- [ ] **Step 1: Add validation call after the name is parsed**

After the empty-name check (line 778: `return`), add:

```powershell
    # Validate worktree name
    if (-not (Test-ValidWorktreeName -Name $worktreeName)) {
        return
    }
```

- [ ] **Step 2: Verify existing `wt add` still works**

Run from inside a bare repo:
```
pwsh -NoProfile -Command ". ./pwsh/worktree.ps1; wt add test-feature"
```
Expected: Creates worktree as before (name passes validation)

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): validate worktree names against reserved names"
```

---

## Chunk 3: Redesign `wt clone`

### Task 8: Rewrite `New-BareRepository` for modern layout

**Files:**
- Modify: `pwsh/worktree.ps1` — `New-BareRepository` function (lines 576-685)

This is the largest single change. The function is rewritten to clone into `<name>/.git` instead of `<name>.git`, set `core.bare` and `wt.layout`, respect the worktree folder config, and offer to `cd` into the default branch worktree.

- [ ] **Step 1: Rewrite `New-BareRepository`**

Replace the entire function (lines 576-685) with:

```powershell
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
```

- [ ] **Step 2: Verify the function loads without syntax errors**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1"`
Expected: No error

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): rewrite wt clone for modern layout (.git bare repo)"
```

---

## Chunk 4: Add `wt migrate` Command

### Task 9: Implement `Convert-ToModernLayout`

**Files:**
- Modify: `pwsh/worktree.ps1` (add function after `Repair-FetchRefspec`)

This is the most complex function. It converts a classic repo to modern layout with preview, confirmation, CWD safety, and `git worktree repair`.

- [ ] **Step 1: Add `Convert-ToModernLayout` function**

Insert after the closing `}` of `Repair-FetchRefspec`:

```powershell
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
    $savedLocation = $PWD.Path
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
```

- [ ] **Step 2: Verify function loads without syntax errors**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1"`
Expected: No error

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): add wt migrate command for classic-to-modern conversion"
```

---

## Chunk 5: Update Help Text and Final Polish

### Task 10: Update `Show-WorktreeHelp`

**Files:**
- Modify: `pwsh/worktree.ps1` — `Show-WorktreeHelp` function (lines 180-245)

- [ ] **Step 1: Add `migrate` command and configuration section**

In the Commands section, add after the `clone` line:

```powershell
    Write-Host "  " -NoNewline
    Write-Host "migrate" -ForegroundColor Green -NoNewline
    Write-Host "             Migrate a classic (trees/) layout to modern (.git) layout"
```

Replace the "When creating a worktree" section to be layout-aware:

```powershell
    Write-Host "When creating a worktree:" -ForegroundColor Cyan
    Write-Host "  • Branch name format: <type>/<name> (default type is 'feature')"
    Write-Host "  • If the branch doesn't exist, it creates a new branch"
    Write-Host "  • If the branch already exists, it checks out the existing branch"
    Write-Host "  • Use --from to base the new branch on another worktree's branch"
```

Update examples to show modern layout paths (without `trees/` prefix):

```powershell
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
```

Add configuration section at the end (before the closing `Write-Host ""`):

```powershell
    Write-Host ""
    Write-Host "Configuration (~/.wtconfig or environment variables):" -ForegroundColor Cyan
    Write-Host "  command_name / WT_RENAME              " -NoNewline -ForegroundColor Green
    Write-Host "Set custom command name"
    Write-Host "  worktree_folder / WT_WORKTREE_FOLDER  " -NoNewline -ForegroundColor Green
    Write-Host "Set worktree subfolder (default: project root)"
```

- [ ] **Step 2: Verify help output**

Run: `pwsh -NoProfile -Command ". ./pwsh/worktree.ps1; wt --help"`
Expected: Shows updated help with `migrate` command and configuration section

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "feat(pwsh): update help text with migrate command and config docs"
```

---

### Task 11: Remove hardcoded `$script:WORKTREE_FOLDER` at top of file

**Files:**
- Modify: `pwsh/worktree.ps1:15`

- [ ] **Step 1: Remove the hardcoded line**

Remove line 15:
```powershell
$script:WORKTREE_FOLDER = "trees"
```

This value is now set dynamically in the `wt` init block (Task 4). Leaving it would set a default that gets overridden, which is confusing.

- [ ] **Step 2: Verify no function references `WORKTREE_FOLDER` before the init block sets it**

The only pre-init-block use of `WORKTREE_FOLDER` is in `New-BareRepository` (clone), which now computes its own value via `Get-WorktreeFolder`. All other uses happen after the init block. Safe to remove.

- [ ] **Step 3: Commit**

```bash
git add pwsh/worktree.ps1
git commit -m "refactor(pwsh): remove hardcoded WORKTREE_FOLDER, now set dynamically"
```

---

### Task 12: Manual testing

No code changes — validation only.

- [ ] **Step 1: Test `wt clone` creates modern layout**

```
cd /tmp
pwsh -NoProfile -Command ". /path/to/worktree.ps1; wt clone https://github.com/pedrofcj/ShedEnergy.git"
```

Verify:
- `ShedEnergy/` directory created (not `ShedEnergy.git/`)
- `ShedEnergy/.git/` contains bare repo
- `git -C ShedEnergy/.git config --get core.bare` returns `true`
- `git -C ShedEnergy/.git config --get wt.layout` returns `modern`
- `ShedEnergy/main/` (or default branch) worktree exists
- Offered to `cd` into worktree

- [ ] **Step 2: Test `wt add` in modern layout**

From inside a worktree of the modern repo:
```
wt add test-branch
```

Verify:
- Worktree created at `ShedEnergy/test-branch/` (not `ShedEnergy/trees/test-branch/`)

- [ ] **Step 3: Test `wt list` in modern layout**

```
wt list
```

Verify:
- Header shows "Git Worktrees for ShedEnergy" (not ".git")
- Bare repo line shows full `.git` path

- [ ] **Step 4: Test classic repo backward compatibility**

From inside an existing classic bare repo:
```
wt list
wt add compat-test
```

Verify:
- List works as before
- New worktree created in `trees/compat-test/`

- [ ] **Step 5: Test `wt add` with reserved name**

```
wt add .git
```

Verify: Error message about reserved name

- [ ] **Step 6: Test `WT_WORKTREE_FOLDER` config**

```
$env:WT_WORKTREE_FOLDER = "workspaces"
wt add configured-test
```

Verify: Worktree created in `<root>/workspaces/configured-test/`

- [ ] **Step 7: Final commit — all tests pass**

```bash
git add -A
git commit -m "feat(pwsh): complete modern layout implementation

Adds modern layout support where wt clone creates RepoName/.git
instead of RepoName.git. Includes layout auto-detection, configurable
worktree folder (WT_WORKTREE_FOLDER / ~/.wtconfig), wt migrate command,
and full backward compatibility with classic layout."
```
