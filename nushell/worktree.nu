# Git Worktree Manager — manage bare-repo worktrees with ease
# Nushell port of pwsh/worktree.ps1

# Unicode symbols
const CHECK = "✓"
const CROSS = "✗"
const STAR = "★"
const ARROW = "▸"
const INFO = "ℹ️"
const WARNING = "⚠️"
const SEARCH = "🔍"

# Configuration
const DEFAULT_BRANCH_TYPE = "feature"

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Read worktree folder configuration from env var or ~/.wtconfig
# Returns the configured value, or null if not configured
def get-worktree-folder [] {
    # Priority 1: environment variable
    if "WT_WORKTREE_FOLDER" in $env {
        return $env.WT_WORKTREE_FOLDER
    }

    # Priority 2: ~/.wtconfig file
    let config_path = ($nu.home-path | path join ".wtconfig")
    if ($config_path | path exists) {
        let lines = (open $config_path | lines)
        for line in $lines {
            let m = ($line | parse --regex '^\s*worktree_folder\s*=\s*(?P<val>.+)\s*$')
            if not ($m | is-empty) {
                let val = ($m | first | get val | str trim)
                return $val
            }
        }
    }

    return null
}

# Detect repository layout (modern vs classic) and return project root.
# Returns a record { layout_type: string, project_root: string }.
def get-project-layout [project_dir: string] {
    # Primary detection: check for wt.layout git config
    let layout_config = (^git -C $project_dir config --get wt.layout | complete)
    if $layout_config.exit_code == 0 {
        let val = ($layout_config.stdout | str trim)
        if $val != "" {
            let root = if $val == "modern" {
                ($project_dir | path dirname)
            } else {
                $project_dir
            }
            return { layout_type: $val, project_root: $root }
        }
    }

    # Fallback heuristic: check if bare repo dir name is exactly ".git"
    let leaf = ($project_dir | path basename)
    if $leaf == ".git" {
        return { layout_type: "modern", project_root: ($project_dir | path dirname) }
    } else {
        return { layout_type: "classic", project_root: $project_dir }
    }
}

# Validate worktree name against reserved names and path rules
def validate-worktree-name [name: string, worktree_folder: string] {
    let reserved = [".git" ".bare" ".."]
    if $name in $reserved {
        print $"(ansi red)($CROSS) Error: '($name)' is a reserved name and cannot be used as a worktree name(ansi reset)"
        return false
    }

    if ($name | str contains "/") or ($name | str contains "\\") {
        print $"(ansi red)($CROSS) Error: Worktree name '($name)' cannot contain path separators(ansi reset)"
        return false
    }

    if $worktree_folder != "" and $name == $worktree_folder {
        print $"(ansi red)($CROSS) Error: '($name)' conflicts with the configured worktree folder name(ansi reset)"
        return false
    }

    true
}

# Detect the bare-repo root (works from bare dir or any of its worktrees).
# Returns the absolute path or null.
def get-git-root [] {
    let git_dir = (^git rev-parse --git-dir | complete)
    if $git_dir.exit_code != 0 {
        print $"(ansi red)($CROSS) Error: Not inside a Git repository(ansi reset)"
        return null
    }

    let git_dir_path = ($git_dir.stdout | str trim | path expand)

    let is_bare = (^git rev-parse --is-bare-repository | complete)
    if $is_bare.exit_code == 0 and ($is_bare.stdout | str trim) == "true" {
        return $git_dir_path
    }

    # Not directly bare — check if inside a worktree of a bare repo
    let common_dir = (^git rev-parse --git-common-dir | complete)
    if $common_dir.exit_code == 0 {
        let common_path = ($common_dir.stdout | str trim | path expand)
        let is_bare_common = (^git -C $common_path rev-parse --is-bare-repository | complete)
        if $is_bare_common.exit_code == 0 and ($is_bare_common.stdout | str trim) == "true" {
            return $common_path
        }
    }

    print $"(ansi red)($CROSS) Error: This command is designed for bare Git repositories(ansi reset)"
    print $"(ansi yellow)   Please run this command from a bare repository directory or one of its worktrees(ansi reset)"
    return null
}

# Resolve the command name from $env.WT_RENAME, ~/.wtconfig, or default "wt".
def resolve-command-name [] {
    # Check env var first
    if "WT_RENAME" in $env and ($env.WT_RENAME | str trim) != "" {
        return ($env.WT_RENAME | str trim)
    }

    # Check ~/.wtconfig file
    let config_path = ($nu.home-path | path join ".wtconfig")
    if ($config_path | path exists) {
        let lines = (open $config_path | lines)
        for line in $lines {
            let m = ($line | parse --regex '^\s*command_name\s*=\s*(?P<val>.+)\s*$')
            if not ($m | is-empty) {
                let val = ($m | first | get val | str trim)
                if $val != "" {
                    return $val
                }
            }
        }
    }

    "wt"
}

# Build a context record with layout-aware fields.
# Returns null when not in a bare repo.
def wt-context [] {
    let root = (get-git-root)
    if $root == null { return null }

    let layout = (get-project-layout $root)
    let name = ($layout.project_root | path basename)
    let cmd = (resolve-command-name)

    # Resolve worktree folder
    let configured = (get-worktree-folder)
    let wt_folder = if $configured != null {
        $configured
    } else if $layout.layout_type == "classic" {
        "trees"
    } else {
        ""
    }

    let parent = if $wt_folder != "" {
        ($layout.project_root | path join $wt_folder)
    } else {
        $layout.project_root
    }

    {
        project_dir: $root,
        project_root: $layout.project_root,
        project_name: $name,
        worktree_parent: $parent,
        worktree_folder: $wt_folder,
        layout_type: $layout.layout_type,
        cmd: $cmd
    }
}

# Parse `git worktree list` into structured records.
def parse-worktrees [project_dir: string] {
    let output = (^git -C $project_dir worktree list | complete)
    if $output.exit_code != 0 or ($output.stdout | str trim) == "" {
        return []
    }

    $output.stdout
    | lines
    | where { |line| ($line | str trim) != "" }
    | each { |line|
        let parts = ($line | split row " " | where { |s| $s != "" })
        let path = ($parts | first)
        let branch = (
            $line
            | parse --regex '\[(?P<branch>.+?)\]'
            | if ($in | is-empty) { null } else { $in | first | get branch }
        )
        let name = ($path | path basename)
        let is_bare = ($line | str contains "(bare)")
        { path: $path, branch: $branch, name: $name, is_bare: $is_bare }
    }
}

# Check if a branch exists (local or remote).
def branch-exists [branch: string, project_dir: string] {
    let local = (^git -C $project_dir show-ref --verify --quiet $"refs/heads/($branch)" | complete)
    if $local.exit_code == 0 { return true }
    let remote = (^git -C $project_dir show-ref --verify --quiet $"refs/remotes/origin/($branch)" | complete)
    $remote.exit_code == 0
}

# Detect the default branch from origin/HEAD → main → master fallback.
def default-branch [project_dir: string] {
    # Ensure origin/HEAD is set
    ^git -C $project_dir remote set-head origin --auto | complete | ignore

    let head = (^git -C $project_dir rev-parse --abbrev-ref origin/HEAD | complete)
    if $head.exit_code == 0 {
        let branch = ($head.stdout | str trim)
        if $branch != "origin/HEAD" and $branch != "" {
            return ($branch | str replace --regex '^origin/' '')
        }
    }

    if (branch-exists "main" $project_dir) { return "main" }
    if (branch-exists "master" $project_dir) { return "master" }
    return null
}

# Set upstream tracking for a branch. Returns true on success.
def set-upstream [worktree_path: string, branch: string, --silent] {
    if not $silent {
        print $"  Setting upstream tracking..."
    }
    let result = (^git -C $worktree_path branch $"--set-upstream-to=origin/($branch)" $branch | complete)
    if not $silent {
        if $result.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Upstream tracking configured(ansi reset)"
        } else {
            print $"(ansi yellow)  ($WARNING) Failed to set upstream tracking \(continuing anyway\)(ansi reset)"
        }
    }
    $result.exit_code == 0
}

# Configure fetch refspec for a bare repository. Returns true on success.
def set-fetch-refspec [project_dir: string, --silent] {
    let expected = "+refs/heads/*:refs/remotes/origin/*"
    if not $silent {
        print "  Configuring fetch refspec..."
    }
    let result = (^git -C $project_dir config remote.origin.fetch $expected | complete)
    if not $silent {
        if $result.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Fetch refspec configured(ansi reset)"
        } else {
            print $"(ansi yellow)  ($WARNING) Failed to configure fetch refspec \(continuing anyway\)(ansi reset)"
        }
    }
    $result.exit_code == 0
}

# Ensure the main (default-branch) worktree exists and is updated.
# Returns true on success.
def ensure-main-worktree [project_dir: string, worktree_parent: string] {
    mut main_path: string = ""
    mut main_branch: string = ""
    mut created = false

    mut detected = (default-branch $project_dir)

    # Check if a worktree for the detected default branch already exists (at any location)
    let parsed_worktrees = (parse-worktrees $project_dir)

    if $detected != null {
        let matched = (
            $parsed_worktrees
            | where { |wt| $wt.branch == $detected and (not $wt.is_bare) }
        )
        if not ($matched | is-empty) {
            $main_path = ($matched | first | get path)
            $main_branch = $detected
        }
    }

    # Fallback: check common branch names by matching branch in worktree list
    if $main_path == "" {
        for branch in ["main" "master" "develop" "trunk"] {
            let matched = (
                $parsed_worktrees
                | where { |wt| $wt.branch == $branch and (not $wt.is_bare) }
            )
            if not ($matched | is-empty) {
                $main_path = ($matched | first | get path)
                $main_branch = $branch
                break
            }
        }
    }

    # No existing worktree — create one
    if $main_path == "" {
        print $"(ansi yellow)Default branch worktree doesn't exist. Creating it...(ansi reset)"

        # If default branch wasn't detected, fix refspec and retry (handles bare repos cloned without wt)
        if $detected == null {
            set-fetch-refspec $project_dir --silent | ignore

            print "  Fetching all branches from bare repository..."
            let fetch = (^git -C $project_dir fetch --all | complete)
            if $fetch.exit_code == 0 {
                print $"(ansi green)  ($CHECK) Fetched all branches(ansi reset)"
            } else {
                print $"(ansi yellow)  ($WARNING) Failed to fetch branches(ansi reset)"
            }

            $detected = (default-branch $project_dir)
        }

        print "  Detecting default branch..."

        mkdir $worktree_parent

        if $detected != null {
            $main_branch = $detected
            $main_path = ($worktree_parent | path join $main_branch)
            print $"(ansi green)  ($CHECK) Found default branch: ($main_branch)(ansi reset)"
        } else {
            print $"(ansi red)  ($CROSS) Failed to detect default branch(ansi reset)"
            return false
        }

        print $"  Creating ($main_branch) worktree..."
        let wt_result = (^git -C $project_dir worktree add $main_path $main_branch | complete)
        if $wt_result.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Worktree created at ($main_path)(ansi reset)"
            $created = true
        } else {
            print $"(ansi red)  ($CROSS) Failed to create ($main_branch) worktree(ansi reset)"
            return false
        }
    }

    # Set upstream if just created
    if $created {
        set-upstream $main_path $main_branch | ignore
    }

    # Pull latest
    print $"  Updating ($main_branch) worktree..."
    let pull = (^git -C $main_path pull | complete)
    if $pull.exit_code == 0 {
        print $"(ansi green)  ($CHECK) ($main_branch) worktree updated(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Failed to pull ($main_branch) worktree \(continuing anyway\)(ansi reset)"
    }

    # Fetch all from bare repo
    print "  Fetching all branches from bare repository..."
    let fetch = (^git -C $project_dir fetch --all | complete)
    if $fetch.exit_code == 0 {
        print $"(ansi green)  ($CHECK) Fetched all branches(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Failed to fetch all branches \(continuing anyway\)(ansi reset)"
    }

    true
}

# ---------------------------------------------------------------------------
# Exported commands
# ---------------------------------------------------------------------------

# Show styled help with examples
export def wt [] {
    let cmd = (resolve-command-name)
    print $"(ansi blue)=== Git Worktree Manager ===(ansi reset)"
    print ""
    print $"(ansi cyan)Usage: (ansi yellow)($cmd) <command>(ansi reset)"
    print ""
    print $"(ansi cyan)Commands:(ansi reset)"
    print $"  (ansi green)add <name> [type] [--from <worktree>](ansi reset)"
    print "                          Create a new worktree (type defaults to 'feature')"
    print $"  (ansi green)list(ansi reset)                List all worktrees"
    print $"  (ansi green)remove <name>(ansi reset)       Remove a specific worktree"
    print $"  (ansi green)remove-all(ansi reset)          Remove all worktrees \(with confirmation\)"
    print $"  (ansi green)fix-fetch(ansi reset)           Fix fetch refspec configuration for bare repos"
    print $"  (ansi green)clone <url>(ansi reset)         Clone a repo as bare and set up worktree structure"
    print $"  (ansi green)migrate(ansi reset)             Migrate a classic \(trees/\) layout to modern \(.git\) layout"
    print ""
    print $"(ansi cyan)When creating a worktree:(ansi reset)"
    print "  • Branch name format: <type>/<name> (default type is 'feature')"
    print "  • If the branch doesn't exist, it creates a new branch"
    print "  • If the branch already exists, it checks out the existing branch"
    print "  • Use --from to base the new branch on another worktree's branch"
    print ""
    print $"(ansi cyan)Examples:(ansi reset)"
    print $"  (ansi yellow)($cmd) clone https://github.com/user/repo.git(ansi reset)  # Clone repo as bare and set up main worktree"
    print $"  (ansi yellow)($cmd) add RDUCH-123-add-serialization(ansi reset)     # Creates worktree with branch feature/RDUCH-123-add-serialization"
    print $"  (ansi yellow)($cmd) add RTJK-1223332-whatever bug(ansi reset)    # Creates worktree with branch bug/RTJK-1223332-whatever"
    print $"  (ansi yellow)($cmd) add look-at-this wowdude(ansi reset)          # branch wowdude/look-at-this"
    print $"  (ansi yellow)($cmd) add my-fix --from other-tree(ansi reset)          # Creates worktree branching from other-tree's branch"
    print $"  (ansi yellow)($cmd) list(ansi reset)                              # List all worktrees \(($STAR) = current\)"
    print $"  (ansi yellow)($cmd) remove my-feature(ansi reset)                 # Remove specific worktree"
    print $"  (ansi yellow)($cmd) remove-all(ansi reset)                        # Remove all worktrees"
    print $"  (ansi yellow)($cmd) fix-fetch(ansi reset)                        # Fix fetch refspec configuration"
    print $"  (ansi yellow)($cmd) migrate(ansi reset)                         # Migrate classic layout to modern layout"
    print ""
    print $"(ansi cyan)Configuration \(~/.wtconfig or environment variables\):(ansi reset)"
    print $"  (ansi green)command_name / WT_RENAME(ansi reset)              Set custom command name"
    print $"  (ansi green)worktree_folder / WT_WORKTREE_FOLDER(ansi reset)  Set worktree subfolder \(default: project root\)"
    print ""
}

# Create a new worktree with a typed branch (e.g. feature/name, bug/name)
export def "wt add" [
    name: string       # Worktree directory name
    type: string = "feature"  # Branch type prefix (feature, bug, etc.)
    --from: string = ""  # Source worktree name to branch from
] {
    let ctx = (wt-context)
    if $ctx == null { return }

    # Validate worktree name
    if not (validate-worktree-name $name $ctx.worktree_folder) {
        return
    }

    mut start_point: string = ""

    if $from != "" {
        # --from mode: update the source worktree instead of the default branch
        print ""
        print $"(ansi cyan)=== Ensuring source worktree '($from)' is up to date ===(ansi reset)"

        let parsed_worktrees = (parse-worktrees $ctx.project_dir)
        let source_matches = (
            $parsed_worktrees
            | where { |wt| $wt.name == $from and (not $wt.is_bare) }
        )
        if ($source_matches | is-empty) {
            print $"(ansi red)($CROSS) Error: Source worktree '($from)' not found(ansi reset)"
            print $"(ansi yellow)   Run '($ctx.cmd) list' to see available worktrees(ansi reset)"
            return
        }
        let source_wt = ($source_matches | first)
        $start_point = ($source_wt.branch | default "")

        # Fetch all from bare repo
        print "  Fetching all branches from bare repository..."
        let fetch = (^git -C $ctx.project_dir fetch --all | complete)
        if $fetch.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Fetched all branches(ansi reset)"
        } else {
            print $"(ansi yellow)  ($WARNING) Failed to fetch all branches \(continuing anyway\)(ansi reset)"
        }

        # Pull the source worktree
        print $"  Updating source worktree '($from)'..."
        let pull = (^git -C $source_wt.path pull | complete)
        if $pull.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Source worktree '($from)' updated(ansi reset)"
        } else {
            print $"(ansi yellow)  ($WARNING) Failed to pull source worktree \(continuing anyway\)(ansi reset)"
        }
        print ""
    } else {
        # Standard mode: ensure main worktree is up to date
        print ""
        print $"(ansi cyan)=== Ensuring main worktree is up to date ===(ansi reset)"
        if not (ensure-main-worktree $ctx.project_dir $ctx.worktree_parent) {
            print $"(ansi red)($CROSS) Failed to ensure main worktree. Aborting.(ansi reset)"
            return
        }
        print ""
    }

    let branch_name = $"($type)/($name)"
    let worktree_path = ($ctx.worktree_parent | path join $name)

    if ($worktree_path | path exists) {
        print $"(ansi red)($CROSS) Error: Worktree '($name)' already exists at ($worktree_path)(ansi reset)"
        print $"(ansi yellow)   To navigate to it: cd ($worktree_path)(ansi reset)"
        return
    }

    print $"(ansi green)=== Creating worktree '($name)' ===(ansi reset)"
    print $"(ansi cyan)   Branch: ($branch_name)(ansi reset)"
    print $"(ansi cyan)   Path: ($worktree_path)(ansi reset)"
    if $start_point != "" {
        print $"(ansi cyan)   From: ($from) \(branch: ($start_point)\)(ansi reset)"
    }
    print ""

    mkdir $ctx.worktree_parent

    if (branch-exists $branch_name $ctx.project_dir) {
        if $start_point != "" {
            print $"(ansi yellow)($WARNING) Branch '($branch_name)' already exists, --from flag will be ignored(ansi reset)"
        }
        print $"(ansi blue)($SEARCH) Branch '($branch_name)' already exists. Creating worktree from existing branch...(ansi reset)"
        print "  Creating worktree..."
        let result = (^git -C $ctx.project_dir worktree add $worktree_path $branch_name | complete)
        if $result.exit_code != 0 {
            print $"(ansi red)  ($CROSS) Failed to create worktree(ansi reset)"
            return
        }
        print $"(ansi green)  ($CHECK) Worktree created(ansi reset)"
    } else {
        print "  Creating worktree..."
        let result = if $start_point != "" {
            (^git -C $ctx.project_dir worktree add -b $branch_name $worktree_path $start_point | complete)
        } else {
            (^git -C $ctx.project_dir worktree add -b $branch_name $worktree_path | complete)
        }
        if $result.exit_code != 0 {
            print $"(ansi red)  ($CROSS) Failed to create worktree(ansi reset)"
            return
        }
        print $"(ansi green)  ($CHECK) Worktree created(ansi reset)"
    }

    # Set upstream if remote branch exists
    let remote_check = (^git -C $ctx.project_dir show-ref --verify --quiet $"refs/remotes/origin/($branch_name)" | complete)
    if $remote_check.exit_code == 0 {
        set-upstream $worktree_path $branch_name | ignore
    } else {
        print $"(ansi cyan)  ($INFO) No remote branch found \(new local branch\)(ansi reset)"
    }

    print ""
    print $"(ansi green)($CHECK) Worktree '($name)' created at:(ansi reset)"
    print $"(ansi cyan)   ($worktree_path)(ansi reset)"
    print $"(ansi cyan)   Branch: ($branch_name)(ansi reset)"
    print ""

    let response = (input "Do you want to navigate to the new worktree? (Y/n) ")
    if not ($response =~ '^[Nn]$') {
        cd $worktree_path
    }
}

# List all worktrees, marking the current one with ★
export def "wt list" [] {
    let ctx = (wt-context)
    if $ctx == null { return }

    let worktrees = (parse-worktrees $ctx.project_dir)
    if ($worktrees | is-empty) {
        print $"(ansi yellow)No worktrees found(ansi reset)"
        return
    }

    print $"(ansi blue)=== Git Worktrees for ($ctx.project_name) ===(ansi reset)"
    print ""
    print $"(ansi white)[bare repository](ansi reset) → (ansi cyan)($ctx.project_dir)(ansi reset)"
    print ""

    let current_path = ($env.PWD | path expand | str downcase)
    mut has_worktrees = false

    for wt in $worktrees {
        if not $wt.is_bare {
            if not $has_worktrees {
                print $"(ansi cyan)Worktrees:(ansi reset)"
                $has_worktrees = true
            }

            let branch = (if $wt.branch != null { $wt.branch } else { "" })
            let normalized = ($wt.path | path expand | str downcase)
            let is_current = ($current_path | str starts-with $normalized)

            mut prefix = "  "
            if $is_current {
                $prefix = $"(ansi cyan)($STAR) [current] (ansi reset)"
            }

            if $wt.name == $branch {
                print $"($prefix)(ansi cyan)($ARROW) (ansi white)($wt.name)(ansi reset)"
            } else {
                print $"($prefix)(ansi cyan)($ARROW) (ansi white)($wt.name)(ansi reset) → (ansi green)($branch)(ansi reset)"
            }
            print $"       ($wt.path)"
        }
    }

    if not $has_worktrees {
        print $"(ansi yellow)No worktrees found(ansi reset)"
    }
}

# Remove a specific worktree (protects default branch)
export def "wt remove" [
    name: string  # Worktree directory name to remove
] {
    let ctx = (wt-context)
    if $ctx == null { return }

    # Look up the worktree from git's worktree list by name (handles any location)
    let worktrees = (parse-worktrees $ctx.project_dir)
    let matched = (
        $worktrees
        | where { |wt| $wt.name == $name and (not $wt.is_bare) }
    )

    if ($matched | is-empty) {
        print $"(ansi red)($CROSS) Error: Worktree '($name)' not found(ansi reset)"
        print $"(ansi yellow)   Run '($ctx.cmd) list' to see available worktrees(ansi reset)"
        return
    }

    let matched_wt = ($matched | first)
    let worktree_path = $matched_wt.path
    let branch_name = $matched_wt.branch

    let def_branch = (default-branch $ctx.project_dir)

    # Protect by name
    if $def_branch != null and $name == $def_branch {
        print $"(ansi red)($CROSS) Error: Cannot remove the default branch worktree '($name)'(ansi reset)"
        print $"(ansi yellow)   The default branch worktree is the baseline for all other worktrees.(ansi reset)"
        return
    }

    # Protect by branch
    if $branch_name != null and $def_branch != null and $branch_name == $def_branch {
        print $"(ansi red)($CROSS) Error: Cannot remove worktree '($name)' — it uses the default branch '($def_branch)'(ansi reset)"
        print $"(ansi yellow)   The default branch worktree is the baseline for all other worktrees.(ansi reset)"
        return
    }

    print $"(ansi yellow)=== Removing worktree '($name)' ===(ansi reset)"

    let result = (^git -C $ctx.project_dir worktree remove $worktree_path --force | complete)
    if $result.exit_code == 0 {
        print $"(ansi green)($CHECK) Worktree '($name)' removed successfully(ansi reset)"

        if $branch_name != null {
            print $"  Deleting branch '($branch_name)' from local repository..."
            let del = (^git -C $ctx.project_dir branch -D $branch_name | complete)
            if $del.exit_code == 0 {
                print $"(ansi green)  ($CHECK) Branch '($branch_name)' deleted(ansi reset)"
            } else {
                print $"(ansi yellow)  ($WARNING) Failed to delete branch '($branch_name)' \(it may not exist locally\)(ansi reset)"
            }
        }
    } else {
        print $"(ansi red)($CROSS) Failed to remove worktree. It might have uncommitted changes.(ansi reset)"
        print $"(ansi yellow)   Use 'cd ($worktree_path)' to check and commit/stash changes.(ansi reset)"
    }
}

# Remove all non-default worktrees (with confirmation)
export def "wt remove-all" [] {
    let ctx = (wt-context)
    if $ctx == null { return }

    let parsed = (parse-worktrees $ctx.project_dir)
    let def_branch = (default-branch $ctx.project_dir)

    mut to_remove = []
    for wt in $parsed {
        # Consider all non-bare worktrees, not just those under worktree_parent
        if $wt.is_bare { continue }
        # Skip default branch worktree
        if $def_branch != null and ($wt.branch == $def_branch or $wt.name == $def_branch) {
            continue
        }
        $to_remove = ($to_remove | append $wt)
    }

    if ($to_remove | is-empty) {
        print $"(ansi yellow)($INFO) No worktrees found to remove(ansi reset)"
        return
    }

    print $"(ansi red)=== Remove All Worktrees ===(ansi reset)"
    print $"(ansi yellow)($WARNING) This will remove the following worktrees:(ansi reset)"
    for wt in $to_remove {
        print $"  (ansi red)($CROSS)(ansi reset) ($wt.name)"
    }
    print ""

    let response = (input "Are you sure you want to remove all worktrees? (y/N) ")
    if not ($response =~ '^[Yy]$') {
        print $"(ansi red)($CROSS) Cancelled(ansi reset)"
        return
    }

    for wt in $to_remove {
        print $"  Removing ($wt.name)..."
        let result = (^git -C $ctx.project_dir worktree remove $wt.path --force | complete)
        if $result.exit_code == 0 {
            print $"(ansi green)  ($CHECK) Removed ($wt.name)(ansi reset)"
            if $wt.branch != null and ($def_branch == null or $wt.branch != $def_branch) {
                let del = (^git -C $ctx.project_dir branch -D $wt.branch | complete)
                if $del.exit_code == 0 {
                    print $"    (ansi green)($CHECK) Deleted branch '($wt.branch)'(ansi reset)"
                }
            }
        } else {
            print $"(ansi yellow)  ($WARNING) Failed to remove ($wt.name) \(might have uncommitted changes\)(ansi reset)"
        }
    }

    print ""
    print $"(ansi green)($CHECK) All worktrees removed(ansi reset)"
}

# Check and fix fetch refspec configuration for bare repos
export def "wt fix-fetch" [] {
    let ctx = (wt-context)
    if $ctx == null { return }

    let expected = "+refs/heads/*:refs/remotes/origin/*"

    print $"(ansi cyan)=== Checking fetch refspec configuration ===(ansi reset)"
    print ""

    let current = (^git -C $ctx.project_dir config --get remote.origin.fetch | complete)
    let current_val = ($current.stdout | str trim)

    if $current.exit_code == 0 and $current_val != "" {
        print $"(ansi blue)($INFO) Current fetch refspec: (ansi white)($current_val)(ansi reset)"

        if $current_val == $expected {
            print $"(ansi green)($CHECK) Fetch refspec is already correctly configured(ansi reset)"
            print ""
            return
        } else {
            print $"(ansi yellow)($WARNING) Fetch refspec is configured but not optimal for bare repos with worktrees(ansi reset)"
            print $"(ansi yellow)   Current: ($current_val)(ansi reset)"
            print $"(ansi yellow)   Expected: ($expected)(ansi reset)"
            print ""
        }
    } else {
        print $"(ansi yellow)($WARNING) Fetch refspec is not configured(ansi reset)"
        print $"(ansi yellow)   This prevents fetching remote branches properly in bare repositories(ansi reset)"
        print ""
    }

    set-fetch-refspec $ctx.project_dir | ignore
    print ""

    print "  Fetching all branches from origin..."
    let fetch = (^git -C $ctx.project_dir fetch origin | complete)
    if $fetch.exit_code == 0 {
        print $"(ansi green)  ($CHECK) Fetched all branches(ansi reset)"
        print ""
        print $"(ansi green)($CHECK) Fetch refspec fixed successfully!(ansi reset)"
        print $"(ansi cyan)   Remote branches are now available as 'remotes/origin/<branch-name>'(ansi reset)"
        print $"(ansi cyan)   You can now create worktrees from remote branches(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Fetch refspec configured, but fetch failed(ansi reset)"
        print $"(ansi yellow)   You may need to run 'git fetch origin' manually(ansi reset)"
    }
}

# Clone a repository as bare and set up modern worktree structure
export def "wt clone" [
    url: string  # Repository URL (HTTPS or SSH)
] {
    let cmd = (resolve-command-name)

    # Extract repo name from URL
    let repo_name = ($url | str replace --regex '\.git$' '' | str replace --regex '.*[/:]' '')
    let destination_path = ($env.PWD | path join $repo_name)
    let bare_repo_path = ($destination_path | path join ".git")

    if ($destination_path | path exists) {
        print $"(ansi red)($CROSS) Error: Directory '($repo_name)' already exists(ansi reset)"
        print $"(ansi yellow)   Please remove it or choose a different location(ansi reset)"
        return
    }

    print $"(ansi blue)=== Cloning repository as bare ===(ansi reset)"
    print $"(ansi cyan)   URL: ($url)(ansi reset)"
    print $"(ansi cyan)   Destination: ./($repo_name)(ansi reset)"
    print ""

    # Create project root directory
    mkdir $destination_path

    # Clone with --bare flag into .git subdirectory
    print "  Cloning repository..."
    let clone = (^git clone --bare $url $bare_repo_path | complete)
    if $clone.exit_code != 0 {
        print $"(ansi red)  ($CROSS) Failed to clone repository(ansi reset)"
        print $"(ansi yellow)   Error: ($clone.stderr | str trim)(ansi reset)"
        # Clean up the empty directory
        rm -rf $destination_path
        return
    }
    print $"(ansi green)  ($CHECK) Repository cloned(ansi reset)"

    # Ensure core.bare is explicitly set (safety for .git directory name)
    ^git -C $bare_repo_path config core.bare true | complete | ignore

    # Set layout marker
    ^git -C $bare_repo_path config wt.layout modern | complete | ignore

    # Configure fetch refspec
    set-fetch-refspec $bare_repo_path | ignore

    # Fetch all branches
    print "  Fetching all branches..."
    let fetch = (^git -C $bare_repo_path fetch --all | complete)
    if $fetch.exit_code == 0 {
        print $"(ansi green)  ($CHECK) Fetched all branches(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Failed to fetch all branches \(continuing anyway\)(ansi reset)"
    }

    # Detect default branch
    print "  Detecting default branch..."
    let main_branch = (default-branch $bare_repo_path)
    if $main_branch == null {
        print $"(ansi red)  ($CROSS) Failed to detect default branch(ansi reset)"
        print $"(ansi yellow)   The repository was cloned but no worktree was created.(ansi reset)"
        print $"(ansi yellow)   You can manually create a worktree using: ($cmd) add <name>(ansi reset)"
        return
    }
    print $"(ansi green)  ($CHECK) Found default branch: ($main_branch)(ansi reset)"

    # Resolve worktree folder from config (no layout context needed — modern default is "")
    let configured = (get-worktree-folder)
    let wt_folder = if $configured != null {
        $configured
    } else {
        ""
    }

    # Compute worktree parent
    let worktree_parent = if $wt_folder != "" {
        let p = ($destination_path | path join $wt_folder)
        mkdir $p
        $p
    } else {
        $destination_path
    }

    # Create worktree for default branch
    let main_path = ($worktree_parent | path join $main_branch)
    print $"  Creating worktree for ($main_branch) branch..."
    let wt_result = (^git -C $bare_repo_path worktree add $main_path $main_branch | complete)
    if $wt_result.exit_code != 0 {
        print $"(ansi red)  ($CROSS) Failed to create worktree for ($main_branch)(ansi reset)"
        return
    }
    print $"(ansi green)  ($CHECK) Worktree created at ($main_path)(ansi reset)"

    # Set upstream tracking
    set-upstream $main_path $main_branch | ignore

    # Pull latest
    print "  Pulling latest changes..."
    let pull = (^git -C $main_path pull | complete)
    if $pull.exit_code == 0 {
        print $"(ansi green)  ($CHECK) Worktree updated(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Failed to pull \(continuing anyway\)(ansi reset)"
    }

    print ""
    print $"(ansi green)($CHECK) Repository setup complete!(ansi reset)"
    print $"(ansi cyan)   Project root: ($destination_path)(ansi reset)"
    print $"(ansi cyan)   Bare repo: ($bare_repo_path)(ansi reset)"
    print $"(ansi cyan)   Main worktree: ($main_path)(ansi reset)"
    print ""
    print $"(ansi yellow)($INFO) The project root \(($repo_name)/\) is a container — work inside worktree directories.(ansi reset)"
    print ""

    let response = (input "Do you want to navigate to the main worktree? (Y/n) ")
    if not ($response =~ '^[Nn]$') {
        cd $main_path
    }
}

# Migrate classic (trees/) layout to modern (.git) layout
export def "wt migrate" [] {
    let ctx = (wt-context)
    if $ctx == null { return }

    # Precondition: must be classic layout
    if $ctx.layout_type == "modern" {
        print $"(ansi green)($CHECK) This repository already uses the modern layout(ansi reset)"
        print $"(ansi cyan)   Bare repo: ($ctx.project_dir)(ansi reset)"
        print $"(ansi cyan)   Project root: ($ctx.project_root)(ansi reset)"
        return
    }

    # Compute new paths
    let old_root = $ctx.project_dir
    let old_root_name = ($old_root | path basename)
    let new_root_name = ($old_root_name | str replace --regex '\.git$' '')
    let new_root = (($old_root | path dirname) | path join $new_root_name)
    let new_bare_repo = ($new_root | path join ".git")

    # Check for collision
    if ($new_root | path exists) {
        print $"(ansi red)($CROSS) Error: Directory '($new_root_name)' already exists(ansi reset)"
        print $"(ansi yellow)   Cannot migrate — the target directory is taken(ansi reset)"
        return
    }

    # Parse worktrees
    let parsed_worktrees = (parse-worktrees $ctx.project_dir)
    let default_branch_val = (default-branch $ctx.project_dir)

    mut worktrees_to_move = []
    mut external_worktrees = []

    for wt in $parsed_worktrees {
        if $wt.is_bare { continue }
        let normalized_wt = ($wt.path | path expand | str downcase)
        let normalized_old = ($old_root | path expand | str downcase)
        if ($normalized_wt | str starts-with $"($normalized_old)/") or ($normalized_wt | str starts-with $"($normalized_old)\\") {
            $worktrees_to_move = ($worktrees_to_move | append $wt)
        } else {
            $external_worktrees = ($external_worktrees | append $wt)
        }
    }

    # Resolve worktree folder for new layout (null = not configured, "" = explicitly empty)
    let configured = (get-worktree-folder)
    let worktree_folder = if $configured != null {
        $configured
    } else {
        ""
    }

    # Check for uncommitted changes
    mut dirty_worktrees = []
    for wt in $worktrees_to_move {
        let status = (^git -C $wt.path status --porcelain | complete)
        if $status.exit_code == 0 and ($status.stdout | str trim) != "" {
            let changed_files = ($status.stdout | lines | where { |l| ($l | str trim) != "" } | length)
            $dirty_worktrees = ($dirty_worktrees | append { name: $wt.name, changed_files: $changed_files })
        }
    }

    # Show migration preview
    print $"(ansi blue)=== Migration Preview ===(ansi reset)"
    print ""
    print $"(ansi cyan)Current layout \(classic\):(ansi reset)"
    print $"(ansi white)  Bare repo: ($old_root)(ansi reset)"
    for wt in $worktrees_to_move {
        print $"(ansi white)  Worktree: ($wt.name) → ($wt.path)(ansi reset)"
    }
    if not ($external_worktrees | is-empty) {
        print $"(ansi yellow)  External worktrees \(will NOT be moved\):(ansi reset)"
        for wt in $external_worktrees {
            print $"(ansi yellow)    ($wt.name) → ($wt.path)(ansi reset)"
        }
    }

    print ""
    print $"(ansi cyan)New layout \(modern\):(ansi reset)"
    print $"(ansi white)  Project root: ($new_root)(ansi reset)"
    print $"(ansi white)  Bare repo: ($new_bare_repo)(ansi reset)"
    for wt in $worktrees_to_move {
        let new_path = if $worktree_folder != "" {
            ($new_root | path join $worktree_folder | path join $wt.name)
        } else {
            ($new_root | path join $wt.name)
        }
        print $"(ansi white)  Worktree: ($wt.name) → ($new_path)(ansi reset)"
    }
    print ""

    # Warn about uncommitted changes
    if not ($dirty_worktrees | is-empty) {
        print $"(ansi yellow)($WARNING) The following worktrees have uncommitted changes:(ansi reset)"
        for dw in $dirty_worktrees {
            print $"  (ansi red)($CROSS) ($dw.name) \(($dw.changed_files) modified files\)(ansi reset)"
        }
        print ""
        print $"(ansi yellow)Uncommitted changes will be preserved during migration, but if anything(ansi reset)"
        print $"(ansi yellow)goes wrong they could be lost.(ansi reset)"
        print ""
    }

    let response = (input "Are you sure you want to migrate? (y/N) ")
    if not ($response =~ '^[Yy]$') {
        print $"(ansi red)($CROSS) Cancelled(ansi reset)"
        return
    }

    # CWD safety: move out of the repo being migrated
    let saved_location = $env.PWD
    let normalized_pwd = ($env.PWD | path expand | str downcase)
    let normalized_old_root = ($old_root | path expand | str downcase)
    if $normalized_pwd == $normalized_old_root or ($normalized_pwd | str starts-with $"($normalized_old_root)/") or ($normalized_pwd | str starts-with $"($normalized_old_root)\\") {
        let parent_dir = ($old_root | path dirname)
        cd $parent_dir
        print $"(ansi cyan)($INFO) Changed directory to ($parent_dir) \(required for migration\)(ansi reset)"
    }

    print ""
    print $"(ansi blue)=== Migrating to modern layout ===(ansi reset)"

    # Step a: Create new project root
    print $"  Creating project root '($new_root_name)'..."
    try {
        mkdir $new_root
        print $"(ansi green)  ($CHECK) Project root created(ansi reset)"
    } catch {
        print $"(ansi red)  ($CROSS) Failed to create project root(ansi reset)"
        return
    }

    # Step b: Create worktree subfolder if configured
    if $worktree_folder != "" {
        let worktree_subfolder = ($new_root | path join $worktree_folder)
        mkdir $worktree_subfolder
    }

    # Step c: Move worktrees
    mut new_worktree_paths = []
    for wt in $worktrees_to_move {
        let new_path = if $worktree_folder != "" {
            ($new_root | path join $worktree_folder | path join $wt.name)
        } else {
            ($new_root | path join $wt.name)
        }

        print $"  Moving worktree '($wt.name)'..."
        try {
            mv $wt.path $new_path
            print $"(ansi green)  ($CHECK) Moved '($wt.name)'(ansi reset)"
            $new_worktree_paths = ($new_worktree_paths | append $new_path)
        } catch {
            print $"(ansi red)  ($CROSS) Failed to move '($wt.name)'(ansi reset)"
            print $"(ansi red)($CROSS) Migration failed. The old directory is still intact at: ($old_root)(ansi reset)"
            print $"(ansi yellow)   Clean up the partial migration directory: ($new_root)(ansi reset)"
            return
        }
    }

    # Add external worktree paths (they haven't moved but need repair)
    for wt in $external_worktrees {
        $new_worktree_paths = ($new_worktree_paths | append $wt.path)
    }

    # Step d: Move bare repo to .git
    print $"  Moving bare repo to ($new_bare_repo)..."
    try {
        mkdir $new_bare_repo

        # Move all items from old root to new .git, skip empty directories
        let items = (ls -a $old_root | where { |item| $item.name != "." and $item.name != ".." })
        for item in $items {
            if $item.type == "dir" {
                let remaining = (ls -a $item.name | where { |i| ($i.name | path basename) != "." and ($i.name | path basename) != ".." })
                if ($remaining | is-empty) {
                    # Empty directory (likely the old worktree folder after moves)
                    rm -rf $item.name
                    continue
                }
            }
            mv $item.name $new_bare_repo
        }
        print $"(ansi green)  ($CHECK) Bare repo moved(ansi reset)"
    } catch {
        print $"(ansi red)  ($CROSS) Failed to move bare repo(ansi reset)"
        print $"(ansi red)($CROSS) Migration failed during bare repo move.(ansi reset)"
        print $"(ansi yellow)   Old directory: ($old_root)(ansi reset)"
        print $"(ansi yellow)   New directory: ($new_root)(ansi reset)"
        print $"(ansi yellow)   Manual recovery may be needed.(ansi reset)"
        return
    }

    # Step e: Set config values
    ^git -C $new_bare_repo config core.bare true | complete | ignore
    ^git -C $new_bare_repo config wt.layout modern | complete | ignore

    # Step f: Repair worktree cross-references
    print "  Repairing worktree references..."
    let repair_result = (^git -C $new_bare_repo worktree repair ...$new_worktree_paths | complete)
    if $repair_result.exit_code == 0 {
        print $"(ansi green)  ($CHECK) Worktree references repaired(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Worktree repair had issues \(check manually\)(ansi reset)"
    }

    # Step g: Verify
    print "  Verifying migration..."
    let verify = (^git -C $new_bare_repo worktree list | complete)
    if $verify.exit_code == 0 and ($verify.stdout | str trim) != "" {
        print $"(ansi green)  ($CHECK) Migration verified(ansi reset)"
    } else {
        print $"(ansi yellow)  ($WARNING) Verification failed — check worktree list manually(ansi reset)"
    }

    # Step h: Remove old directory
    print "  Removing old directory..."
    try {
        rm -rf $old_root
        print $"(ansi green)  ($CHECK) Old directory removed(ansi reset)"
    } catch {
        print $"(ansi yellow)  ($WARNING) Could not remove old directory: ($old_root)(ansi reset)"
        print $"(ansi yellow)   You may need to remove it manually(ansi reset)"
    }

    # Success
    print ""
    print $"(ansi green)($CHECK) Migration complete!(ansi reset)"
    print $"(ansi cyan)   Project root: ($new_root)(ansi reset)"
    print $"(ansi cyan)   Bare repo: ($new_bare_repo)(ansi reset)"
    print ""

    # Find the default branch worktree for cd offer
    mut default_worktree_path: string = ""
    for wt in $worktrees_to_move {
        if ($wt.branch == $default_branch_val or $wt.name == $default_branch_val) {
            $default_worktree_path = if $worktree_folder != "" {
                ($new_root | path join $worktree_folder | path join $wt.name)
            } else {
                ($new_root | path join $wt.name)
            }
            break
        }
    }

    if $default_worktree_path != "" and ($default_worktree_path | path exists) {
        let cd_response = (input "Do you want to navigate to the main worktree? (Y/n) ")
        if not ($cd_response =~ '^[Nn]$') {
            cd $default_worktree_path
        }
    }
}

# ---------------------------------------------------------------------------
# Alias support: if command name is not "wt", create an alias
# ---------------------------------------------------------------------------
# NOTE: In nushell, dynamic aliasing at source-time is limited.
# Users should add the following to their config if they use a custom name:
#   alias mycmd = wt
#   alias "mycmd add" = wt add
#   ... etc.
# The resolve-command-name function ensures all user-facing strings
# (help, usage, error messages) use the configured name.
