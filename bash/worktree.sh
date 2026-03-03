#!/usr/bin/env bash
# Git Worktree Manager - manage Git worktrees with ease

# --- Color helpers (no-ops if already defined by dependencies.sh) ---
type _green  &>/dev/null || _green()  { printf '\033[32m%s\033[0m' "$*"; }
type _red    &>/dev/null || _red()    { printf '\033[31m%s\033[0m' "$*"; }
type _yellow &>/dev/null || _yellow() { printf '\033[33m%s\033[0m' "$*"; }
type _cyan   &>/dev/null || _cyan()   { printf '\033[36m%s\033[0m' "$*"; }
type _blue   &>/dev/null || _blue()   { printf '\033[34m%s\033[0m' "$*"; }

# --- Constants ---
_WT_CHECK="✓"
_WT_CROSS="✗"
_WT_STAR="★"
_WT_ARROW="▸"
_WT_INFO="ℹ️"
_WT_WARNING="⚠️"
_WT_SEARCH="🔍"

# --- Configuration ---
_WT_DEFAULT_BRANCH_TYPE="feature"
_WT_WORKTREE_FOLDER="trees"

# --- Internal state ---
_wt_last_progress_length=0
_wt_project_dir=""
_wt_project_name=""
_wt_worktree_parent=""

# ============================================================================
# Progress helpers
# ============================================================================

_wt_progress_start() {
    local msg="$1"
    _wt_last_progress_length=$(( ${#msg} + 3 ))
    printf '%s...' "$msg"
}

_wt_progress_complete() {
    local msg="$1" status="${2:-success}"
    local symbol color

    case "$status" in
        success) symbol="$_WT_CHECK";   color='\033[32m' ;;
        warning) symbol="$_WT_WARNING"; color='\033[33m' ;;
        error)   symbol="$_WT_CROSS";   color='\033[31m' ;;
        info)    symbol="$_WT_INFO";    color='\033[36m' ;;
    esac

    local new_len=$(( ${#msg} + 4 ))
    local pad_needed=$(( _wt_last_progress_length - new_len ))
    (( pad_needed < 0 )) && pad_needed=0
    (( pad_needed += 5 ))
    local padding
    printf -v padding '%*s' "$pad_needed" ''

    printf "\r${color}%s %s%s\033[0m\n" "$symbol" "$msg" "$padding"
    _wt_last_progress_length=0
}

# ============================================================================
# Git parsing helpers
# ============================================================================

# Parse git worktree list --porcelain into tab-separated records
# Output: path\tbranch\tname\tis_bare (one line per worktree)
_wt_get_parsed_worktrees() {
    local repo_path="${1:-$_wt_project_dir}"
    local output
    output=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
    [[ -z "$output" ]] && return 1

    local path="" branch="" is_bare="false"

    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            # Emit previous record if exists
            if [[ -n "$path" ]]; then
                printf '%s\t%s\t%s\t%s\n' "$path" "$branch" "${path##*/}" "$is_bare"
            fi
            path="${line#worktree }"
            branch=""
            is_bare="false"
        elif [[ "$line" == "bare" ]]; then
            is_bare="true"
        elif [[ "$line" == branch\ * ]]; then
            branch="${line#branch refs/heads/}"
        fi
    done <<< "$output"

    # Emit last record
    if [[ -n "$path" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$path" "$branch" "${path##*/}" "$is_bare"
    fi
}

# ============================================================================
# Git helpers
# ============================================================================

# Check if branch exists (local or remote)
_wt_branch_exists() {
    local branch="$1" repo="${2:-$_wt_project_dir}"
    git -C "$repo" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null && return 0
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null && return 0
    return 1
}

# Get the default branch name from remote (outputs to stdout)
_wt_get_default_branch() {
    local repo="${1:-$_wt_project_dir}"

    # Ensure origin/HEAD is set
    git -C "$repo" remote set-head origin --auto &>/dev/null

    local default_branch
    default_branch=$(git -C "$repo" rev-parse --abbrev-ref origin/HEAD 2>/dev/null)
    if [[ $? -eq 0 && -n "$default_branch" && "$default_branch" != "origin/HEAD" ]]; then
        echo "${default_branch#origin/}"
        return 0
    fi

    # Fallback: check common branch names
    if _wt_branch_exists "main" "$repo"; then echo "main"; return 0; fi
    if _wt_branch_exists "master" "$repo"; then echo "master"; return 0; fi

    return 1
}

# Set upstream tracking for a branch
_wt_set_upstream() {
    local wt_path="$1" branch="$2" silent="${3:-false}"

    [[ "$silent" != "true" ]] && _wt_progress_start "Setting upstream tracking"

    git -C "$wt_path" branch --set-upstream-to="origin/${branch}" "$branch" &>/dev/null
    local rc=$?

    if [[ "$silent" != "true" ]]; then
        if (( rc == 0 )); then
            _wt_progress_complete "Upstream tracking configured" "success"
        else
            _wt_progress_complete "Failed to set upstream tracking (continuing anyway)" "warning"
        fi
    fi

    return $rc
}

# Configure fetch refspec for bare repository
_wt_set_fetch_refspec() {
    local repo="${1:-$_wt_project_dir}" silent="${2:-false}"
    local expected="+refs/heads/*:refs/remotes/origin/*"

    [[ "$silent" != "true" ]] && _wt_progress_start "Configuring fetch refspec"

    git -C "$repo" config remote.origin.fetch "$expected" &>/dev/null
    local rc=$?

    if [[ "$silent" != "true" ]]; then
        if (( rc == 0 )); then
            _wt_progress_complete "Fetch refspec configured" "success"
        else
            _wt_progress_complete "Failed to configure fetch refspec (continuing anyway)" "warning"
        fi
    fi

    return $rc
}

# Get git root directory for bare repositories (outputs path to stdout, errors to stderr)
_wt_get_git_root() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    if [[ -z "$git_dir" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Not inside a Git repository")" >&2
        return 1
    fi

    git_dir=$(realpath "$git_dir")

    # Check if directly in a bare repo
    if [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
        echo "$git_dir"
        return 0
    fi

    # Check if in a worktree of a bare repo
    local common_dir
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    if [[ -n "$common_dir" ]]; then
        common_dir=$(realpath "$common_dir")
        if [[ "$(git -C "$common_dir" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
            echo "$common_dir"
            return 0
        fi
    fi

    printf '%s\n' "$(_red "${_WT_CROSS} Error: This script is designed for bare Git repositories")" >&2
    printf '%s\n' "$(_yellow "   Please run this command from a bare repository directory or one of its worktrees")" >&2
    return 1
}

# ============================================================================
# Help
# ============================================================================

_wt_help() {
    printf '%s\n' "$(_blue "=== Git Worktree Manager ===")"
    echo
    printf '%s%s\n' "$(_cyan "Usage: ")" "$(_yellow "wt <command>")"
    echo
    printf '%s\n' "$(_cyan "Commands:")"
    printf '  %s     %s\n' "$(_green "add <name> [type]")" "Create a new worktree (type defaults to 'feature')"
    printf '  %s                %s\n' "$(_green "list")" "List all worktrees"
    printf '  %s       %s\n' "$(_green "remove <name>")" "Remove a specific worktree"
    printf '  %s          %s\n' "$(_green "remove-all")" "Remove all worktrees (with confirmation)"
    printf '  %s           %s\n' "$(_green "fix-fetch")" "Fix fetch refspec configuration for bare repos"
    printf '  %s         %s\n' "$(_green "clone <url>")" "Clone a repo as bare and set up worktree structure"
    echo
    printf '%s\n' "$(_cyan "When creating a worktree:")"
    echo "  • Worktree is created at trees/<name>"
    echo "  • Branch name format: <type>/<name> (default type is 'feature')"
    echo "  • If the branch doesn't exist, it creates a new branch"
    echo "  • If the branch already exists, it checks out the existing branch"
    echo
    printf '%s\n' "$(_cyan "Examples:")"
    printf '  %s\n    %s\n' "$(_yellow "wt add RDUCH-123-add-serialization")" "# Creates trees/RDUCH-123-add-serialization with branch feature/RDUCH-123-add-serialization"
    printf '  %s\n    %s\n' "$(_yellow "wt add RTJK-1223332-whatever bug")" "# Creates trees/RTJK-1223332-whatever with branch bug/RTJK-1223332-whatever"
    printf '  %s\n    %s\n' "$(_yellow "wt add look-at-this wowdude")" "# Creates trees/look-at-this with branch wowdude/look-at-this"
    printf '  %s  %s\n' "$(_yellow "wt list")" "# List all worktrees (shows current with ${_WT_STAR})"
    printf '  %s  %s\n' "$(_yellow "wt remove my-feature")" "# Remove specific worktree"
    printf '  %s  %s\n' "$(_yellow "wt remove-all")" "# Remove all worktrees"
    printf '  %s  %s\n' "$(_yellow "wt fix-fetch")" "# Fix fetch refspec configuration"
    printf '  %s\n    %s\n' "$(_yellow "wt clone https://github.com/user/repo.git")" "# Clone repo as bare and set up main worktree"
    echo
}

# ============================================================================
# Worktree operations
# ============================================================================

# List worktrees
_wt_list() {
    local current_path="$PWD"

    printf '%s\n' "$(_blue "=== Git Worktrees for ${_wt_project_name} ===")"
    echo
    printf '\033[37m[bare repository]\033[0m → %s\n' "$(_cyan "$_wt_project_dir")"
    echo

    local has_worktrees=false
    local worktrees
    worktrees=$(_wt_get_parsed_worktrees)

    if [[ -z "$worktrees" ]]; then
        printf '%s\n' "$(_yellow "No worktrees found")"
        return
    fi

    while IFS=$'\t' read -r path branch name is_bare; do
        [[ "$is_bare" == "true" ]] && continue

        if ! $has_worktrees; then
            printf '%s\n' "$(_cyan "Worktrees:")"
            has_worktrees=true
        fi

        # Check if current directory is within this worktree
        if [[ "$current_path" == "$path" || "$current_path" == "$path/"* ]]; then
            printf '%s ' "$(_cyan "${_WT_STAR} [current]")"
        else
            printf '  '
        fi

        # Show name and branch (only show branch if different from name)
        if [[ "$name" == "$branch" ]]; then
            printf '%s \033[37m%s\033[0m\n' "$(_cyan "$_WT_ARROW")" "$name"
        else
            printf '%s \033[37m%s\033[0m → %s\n' "$(_cyan "$_WT_ARROW")" "$name" "$(_green "$branch")"
        fi
        printf '       %s\n' "$path"
    done <<< "$worktrees"

    if ! $has_worktrees; then
        printf '%s\n' "$(_yellow "No worktrees found")"
    fi
}

# Ensure main/default branch worktree exists and is updated
_wt_init_main_worktree() {
    local main_path="" main_branch="" worktree_created=false

    # Detect default branch
    local detected_branch
    detected_branch=$(_wt_get_default_branch)

    # Check if worktree for default branch already exists
    if [[ -n "$detected_branch" ]]; then
        local detected_path="${_wt_worktree_parent}/${detected_branch}"
        if [[ -d "$detected_path" ]]; then
            main_path="$detected_path"
            main_branch="$detected_branch"
        fi
    fi

    # Fallback: check common branch names
    if [[ -z "$main_path" ]]; then
        local b
        for b in main master develop trunk; do
            local bp="${_wt_worktree_parent}/${b}"
            if [[ -d "$bp" ]]; then
                main_path="$bp"
                main_branch="$b"
                break
            fi
        done
    fi

    # No existing worktree found - create one
    if [[ -z "$main_path" ]]; then
        printf '%s\n' "$(_yellow "Default branch worktree doesn't exist. Creating it...")"
        _wt_progress_start "Detecting default branch"

        mkdir -p "$_wt_worktree_parent"

        if [[ -n "$detected_branch" ]]; then
            main_branch="$detected_branch"
            main_path="${_wt_worktree_parent}/${main_branch}"
            _wt_progress_complete "Found default branch: ${main_branch}" "success"
        else
            _wt_progress_complete "Failed to detect default branch" "error"
            return 1
        fi

        _wt_progress_start "Creating ${main_branch} worktree"
        git -C "$_wt_project_dir" worktree add "$main_path" "$main_branch" &>/dev/null

        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Worktree created at ${_WT_WORKTREE_FOLDER}/${main_branch}" "success"
            worktree_created=true
        else
            _wt_progress_complete "Failed to create ${main_branch} worktree" "error"
            return 1
        fi
    fi

    # Set upstream tracking if worktree was just created
    if $worktree_created; then
        _wt_set_upstream "$main_path" "$main_branch"
    fi

    # Update main worktree
    _wt_progress_start "Updating ${main_branch} worktree"
    git -C "$main_path" pull &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "${main_branch} worktree updated" "success"
    else
        _wt_progress_complete "Failed to pull ${main_branch} worktree (continuing anyway)" "warning"
    fi

    # Fetch all branches from bare repository
    _wt_progress_start "Fetching all branches from bare repository"
    git -C "$_wt_project_dir" fetch --all &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Fetched all branches" "success"
    else
        _wt_progress_complete "Failed to fetch all branches (continuing anyway)" "warning"
    fi

    return 0
}

# Create worktree
_wt_add() {
    local worktree_name="$1"
    local branch_type="${2:-$_WT_DEFAULT_BRANCH_TYPE}"

    if [[ -z "$worktree_name" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify a name for the worktree")"
        printf '%s\n' "$(_yellow "   Usage: wt add <name> [type]")"
        return 1
    fi

    # Ensure main worktree exists and is updated
    echo
    printf '%s\n' "$(_cyan "=== Ensuring main worktree is up to date ===")"
    if ! _wt_init_main_worktree; then
        printf '%s\n' "$(_red "${_WT_CROSS} Failed to ensure main worktree. Aborting.")"
        return 1
    fi
    echo

    # Branch name: {type}/{name}
    local branch_name="${branch_type}/${worktree_name}"
    # Worktree path: trees/{name}
    local worktree_path="${_wt_worktree_parent}/${worktree_name}"

    if [[ -d "$worktree_path" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Worktree '${worktree_name}' already exists at ${worktree_path}")"
        printf '%s\n' "$(_yellow "   To navigate to it: cd ${worktree_path}")"
        return 1
    fi

    printf '%s\n' "$(_green "=== Creating worktree '${worktree_name}' ===")"
    printf '%s\n' "$(_cyan "   Branch: ${branch_name}")"
    printf '%s\n' "$(_cyan "   Path: ${worktree_path}")"
    echo

    mkdir -p "$_wt_worktree_parent"

    # Check if branch already exists
    if _wt_branch_exists "$branch_name"; then
        printf '%s\n' "$(_blue "${_WT_SEARCH} Branch '${branch_name}' already exists. Creating worktree from existing branch...")"
        _wt_progress_start "Creating worktree"
        git -C "$_wt_project_dir" worktree add "$worktree_path" "$branch_name" &>/dev/null
        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Worktree created" "success"
        else
            _wt_progress_complete "Failed to create worktree" "error"
            return 1
        fi
    else
        _wt_progress_start "Creating worktree"
        git -C "$_wt_project_dir" worktree add -b "$branch_name" "$worktree_path" &>/dev/null
        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Worktree created" "success"
        else
            _wt_progress_complete "Failed to create worktree" "error"
            return 1
        fi
    fi

    # Set upstream tracking if remote branch exists
    if git -C "$_wt_project_dir" show-ref --verify --quiet "refs/remotes/origin/${branch_name}" 2>/dev/null; then
        _wt_set_upstream "$worktree_path" "$branch_name"
    else
        printf '%s\n' "$(_cyan "${_WT_INFO} No remote branch found (new local branch)")"
    fi

    echo
    printf '%s\n' "$(_green "${_WT_CHECK} Worktree '${worktree_name}' created at:")"
    printf '%s\n' "$(_cyan "   ${worktree_path}")"
    printf '%s\n' "$(_cyan "   Branch: ${branch_name}")"
    echo
    printf '%s\n' "$(_yellow "To navigate to your new worktree, run:")"
    echo "   cd ${worktree_path}"
}

# Remove a specific worktree
_wt_remove() {
    local name="$1"

    if [[ -z "$name" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify which worktree to remove")"
        printf '%s\n' "$(_yellow "   Usage: wt remove <worktree-name>")"
        return 1
    fi

    local worktree_path="${_wt_worktree_parent}/${name}"

    if [[ ! -d "$worktree_path" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Worktree '${name}' not found at ${worktree_path}")"
        return 1
    fi

    # Get default branch - must always be preserved as baseline
    local default_branch
    default_branch=$(_wt_get_default_branch)

    # Protect the default branch worktree from removal
    if [[ "$name" == "$default_branch" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Cannot remove the default branch worktree '${name}'")"
        printf '%s\n' "$(_yellow "   The default branch worktree is the baseline for all other worktrees.")"
        return 1
    fi

    # Get the branch name associated with this worktree
    local branch_name=""
    local worktrees
    worktrees=$(_wt_get_parsed_worktrees)

    while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
        if [[ "$wt_path" == "$worktree_path" ]]; then
            branch_name="$wt_branch"
            break
        fi
    done <<< "$worktrees"

    # Additional check: protect if the branch is the default branch
    if [[ -n "$branch_name" && "$branch_name" == "$default_branch" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Cannot remove worktree '${name}' - it uses the default branch '${default_branch}'")"
        printf '%s\n' "$(_yellow "   The default branch worktree is the baseline for all other worktrees.")"
        return 1
    fi

    printf '%s\n' "$(_yellow "=== Removing worktree '${name}' ===")"

    git -C "$_wt_project_dir" worktree remove "$worktree_path" --force &>/dev/null

    if [[ $? -eq 0 ]]; then
        printf '%s\n' "$(_green "${_WT_CHECK} Worktree '${name}' removed successfully")"

        # Delete the branch from local repository
        if [[ -n "$branch_name" ]]; then
            _wt_progress_start "Deleting branch '${branch_name}' from local repository"
            git -C "$_wt_project_dir" branch -D "$branch_name" &>/dev/null
            if [[ $? -eq 0 ]]; then
                _wt_progress_complete "Branch '${branch_name}' deleted" "success"
            else
                _wt_progress_complete "Failed to delete branch '${branch_name}' (it may not exist locally)" "warning"
            fi
        fi
    else
        printf '%s\n' "$(_red "${_WT_CROSS} Failed to remove worktree. It might have uncommitted changes.")"
        printf '%s\n' "$(_yellow "   Use 'cd ${worktree_path}' to check and commit/stash changes.")"
        return 1
    fi
}

# Remove all worktrees (with confirmation)
_wt_remove_all() {
    local worktrees default_branch
    worktrees=$(_wt_get_parsed_worktrees)
    default_branch=$(_wt_get_default_branch)

    # Collect removable worktrees (skip bare, skip outside trees/, skip default branch)
    local -a rm_paths=() rm_names=() rm_branches=()

    while IFS=$'\t' read -r path branch name is_bare; do
        [[ "$is_bare" == "true" ]] && continue
        [[ "$path" != "${_wt_worktree_parent}/"* ]] && continue
        [[ "$branch" == "$default_branch" || "$name" == "$default_branch" ]] && continue

        rm_paths+=("$path")
        rm_names+=("$name")
        rm_branches+=("$branch")
    done <<< "$worktrees"

    if [[ ${#rm_paths[@]} -eq 0 ]]; then
        printf '%s\n' "$(_yellow "${_WT_INFO} No worktrees found to remove")"
        return
    fi

    printf '%s\n' "$(_red "=== Remove All Worktrees ===")"
    printf '%s\n' "$(_yellow "${_WT_WARNING} This will remove the following worktrees:")"

    local display_name
    for display_name in "${rm_names[@]}"; do
        printf '  %s %s\n' "$(_red "$_WT_CROSS")" "$display_name"
    done

    echo
    read -rp "Are you sure you want to remove all worktrees? (y/N) " response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Cancelled")"
        return
    fi

    local i
    for i in "${!rm_paths[@]}"; do
        local path="${rm_paths[$i]}"
        local name="${rm_names[$i]}"
        local branch="${rm_branches[$i]}"

        _wt_progress_start "Removing ${name}"
        git -C "$_wt_project_dir" worktree remove "$path" --force &>/dev/null

        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Removed ${name}" "success"

            # Delete the branch if it exists and is not the default
            if [[ -n "$branch" && "$branch" != "$default_branch" ]]; then
                git -C "$_wt_project_dir" branch -D "$branch" &>/dev/null
                if [[ $? -eq 0 ]]; then
                    printf '  %s\n' "$(_green "${_WT_CHECK} Deleted branch '${branch}'")"
                fi
            fi
        else
            _wt_progress_complete "Failed to remove ${name} (might have uncommitted changes)" "warning"
        fi
    done

    echo
    printf '%s\n' "$(_green "${_WT_CHECK} All worktrees removed")"
}

# Clone repository as bare and set up worktree structure
_wt_clone() {
    local repo_url="$1"

    if [[ -z "$repo_url" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify a repository URL")"
        printf '%s\n' "$(_yellow "   Usage: wt clone <url>")"
        return 1
    fi

    # Extract repo name from URL (handles both HTTPS and SSH formats)
    local repo_name="${repo_url%.git}"
    repo_name="${repo_name##*[/:]}"
    local bare_name="${repo_name}.git"
    local dest="${PWD}/${bare_name}"

    if [[ -d "$dest" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Directory '${bare_name}' already exists")"
        printf '%s\n' "$(_yellow "   Please remove it or choose a different location")"
        return 1
    fi

    printf '%s\n' "$(_blue "=== Cloning repository as bare ===")"
    printf '%s\n' "$(_cyan "   URL: ${repo_url}")"
    printf '%s\n' "$(_cyan "   Destination: ./${bare_name}")"
    echo

    # Clone with --bare flag
    _wt_progress_start "Cloning repository"
    local clone_output
    clone_output=$(git clone --bare "$repo_url" "$dest" 2>&1)

    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to clone repository" "error"
        printf '%s\n' "$(_yellow "   Error: ${clone_output}")"
        return 1
    fi
    _wt_progress_complete "Repository cloned" "success"

    # Configure fetch refspec for bare repo
    _wt_set_fetch_refspec "$dest"

    # Fetch all branches
    _wt_progress_start "Fetching all branches"
    git -C "$dest" fetch --all &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Fetched all branches" "success"
    else
        _wt_progress_complete "Failed to fetch all branches (continuing anyway)" "warning"
    fi

    # Detect default branch
    _wt_progress_start "Detecting default branch"
    local main_branch
    main_branch=$(_wt_get_default_branch "$dest")

    if [[ -z "$main_branch" ]]; then
        _wt_progress_complete "Failed to detect default branch" "error"
        printf '%s\n' "$(_yellow "   The repository was cloned but no worktree was created.")"
        printf '%s\n' "$(_yellow "   You can manually create a worktree using: wt add <name>")"
        return 1
    fi
    _wt_progress_complete "Found default branch: ${main_branch}" "success"

    # Create trees folder and default branch worktree
    local trees_path="${dest}/${_WT_WORKTREE_FOLDER}"
    mkdir -p "$trees_path"

    local main_wt_path="${trees_path}/${main_branch}"
    _wt_progress_start "Creating worktree for ${main_branch} branch"
    git -C "$dest" worktree add "$main_wt_path" "$main_branch" &>/dev/null

    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to create worktree for ${main_branch}" "error"
        return 1
    fi
    _wt_progress_complete "Worktree created at ${_WT_WORKTREE_FOLDER}/${main_branch}" "success"

    # Set upstream tracking
    _wt_set_upstream "$main_wt_path" "$main_branch"

    # Pull latest changes
    _wt_progress_start "Pulling latest changes"
    git -C "$main_wt_path" pull &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Worktree updated" "success"
    else
        _wt_progress_complete "Failed to pull (continuing anyway)" "warning"
    fi

    echo
    printf '%s\n' "$(_green "${_WT_CHECK} Repository setup complete!")"
    printf '%s\n' "$(_cyan "   Bare repo: ${dest}")"
    printf '%s\n' "$(_cyan "   Main worktree: ${main_wt_path}")"
    echo
    printf '%s\n' "$(_yellow "To start working, run:")"
    echo "   cd ${bare_name}/${_WT_WORKTREE_FOLDER}/${main_branch}"
}

# Fix fetch refspec configuration
_wt_fix_fetch() {
    printf '%s\n' "$(_cyan "=== Checking fetch refspec configuration ===")"
    echo

    local expected="+refs/heads/*:refs/remotes/origin/*"
    local current
    current=$(git -C "$_wt_project_dir" config --get remote.origin.fetch 2>/dev/null)
    local rc=$?

    if [[ $rc -eq 0 && -n "$current" ]]; then
        printf '%s %s\n' "$(_blue "${_WT_INFO} Current fetch refspec:")" "$current"

        if [[ "$current" == "$expected" ]]; then
            printf '%s\n' "$(_green "${_WT_CHECK} Fetch refspec is already correctly configured")"
            echo
            return 0
        else
            printf '%s\n' "$(_yellow "${_WT_WARNING} Fetch refspec is configured but not optimal for bare repos with worktrees")"
            printf '%s\n' "$(_yellow "   Current: ${current}")"
            printf '%s\n' "$(_yellow "   Expected: ${expected}")"
            echo
        fi
    else
        printf '%s\n' "$(_yellow "${_WT_WARNING} Fetch refspec is not configured")"
        printf '%s\n' "$(_yellow "   This prevents fetching remote branches properly in bare repositories")"
        echo
    fi

    _wt_set_fetch_refspec "$_wt_project_dir"

    echo
    _wt_progress_start "Fetching all branches from origin"
    git -C "$_wt_project_dir" fetch origin &>/dev/null

    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Fetched all branches" "success"
        echo
        printf '%s\n' "$(_green "${_WT_CHECK} Fetch refspec fixed successfully!")"
        printf '%s\n' "$(_cyan "   Remote branches are now available as 'remotes/origin/<branch-name>'")"
        printf '%s\n' "$(_cyan "   You can now create worktrees from remote branches")"
    else
        _wt_progress_complete "Fetch refspec configured, but fetch failed" "warning"
        printf '%s\n' "$(_yellow "   You may need to run 'git fetch origin' manually")"
    fi
}

# ============================================================================
# Main entry point
# ============================================================================

wt() {
    local command="${1:-}"
    shift 2>/dev/null || true

    # Handle no arguments or help
    if [[ -z "$command" || "$command" == "--help" || "$command" == "-h" ]]; then
        _wt_help
        return
    fi

    # Handle clone separately (doesn't require being inside a git repo)
    if [[ "$command" == "clone" ]]; then
        _wt_clone "$@"
        return
    fi

    # Initialize context (requires being inside a git repo)
    _wt_project_dir=$(_wt_get_git_root)
    if [[ -z "$_wt_project_dir" ]]; then
        return 1
    fi
    _wt_project_name=$(basename "$_wt_project_dir")
    _wt_worktree_parent="${_wt_project_dir}/${_WT_WORKTREE_FOLDER}"

    case "$command" in
        add)        _wt_add "$@" ;;
        list)       _wt_list ;;
        remove)     _wt_remove "$*" ;;
        remove-all) _wt_remove_all ;;
        fix-fetch)  _wt_fix_fetch ;;
        *)
            printf '%s\n' "$(_red "${_WT_CROSS} Error: Unknown command '${command}'")"
            printf '%s\n' "$(_yellow "   Run 'wt --help' to see available commands")"
            return 1
            ;;
    esac
}
