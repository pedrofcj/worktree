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

_WT_VERSION="1.3.0"
_WT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WT_REPO_DIR="$(dirname "$_WT_SCRIPT_DIR")"
if [[ -f "${_WT_REPO_DIR}/VERSION" ]]; then
    _WT_VERSION="$(head -n 1 "${_WT_REPO_DIR}/VERSION" | tr -d '\r')"
fi

# Read worktree folder configuration from env var or ~/.wtconfig
# Returns empty string if not configured (caller applies layout-dependent default)
_wt_get_worktree_folder() {
    # Priority 1: environment variable (empty string is a valid value)
    if [[ -n "${WT_WORKTREE_FOLDER+x}" ]]; then
        echo "$WT_WORKTREE_FOLDER"
        return 0
    fi

    # Priority 2: ~/.wtconfig file
    if [[ -f "$HOME/.wtconfig" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*worktree_folder[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
                local val="${BASH_REMATCH[1]}"
                # Trim trailing whitespace
                val="${val%"${val##*[![:space:]]}"}"
                echo "$val"
                return 0
            fi
        done < "$HOME/.wtconfig"
    fi

    # Not configured
    return 1
}

# --- Internal state ---
_wt_last_progress_length=0
_wt_project_dir=""
_wt_project_name=""
_wt_worktree_parent=""
_wt_project_root=""
_wt_layout_type=""

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

# Validate worktree name against reserved names and path rules
_wt_validate_name() {
    local name="$1"
    local reserved
    for reserved in ".git" ".bare" ".."; do
        if [[ "$name" == "$reserved" ]]; then
            printf '%s\n' "$(_red "${_WT_CROSS} Error: '${name}' is a reserved name and cannot be used as a worktree name")"
            return 1
        fi
    done

    if [[ "$name" == */* || "$name" == *\\* ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Worktree name '${name}' cannot contain path separators")"
        return 1
    fi

    if [[ -n "$_WT_WORKTREE_FOLDER" && "$name" == "$_WT_WORKTREE_FOLDER" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: '${name}' conflicts with the configured worktree folder name")"
        return 1
    fi

    return 0
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

# Detect repository layout (modern vs classic) and set _wt_layout_type and _wt_project_root
_wt_get_project_layout() {
    # Primary detection: check for wt.layout git config
    local layout_config
    layout_config=$(git -C "$_wt_project_dir" config --get wt.layout 2>/dev/null)
    if [[ $? -eq 0 && -n "$layout_config" ]]; then
        _wt_layout_type="$layout_config"
        if [[ "$layout_config" == "modern" ]]; then
            _wt_project_root=$(dirname "$_wt_project_dir")
        else
            _wt_project_root="$_wt_project_dir"
        fi
        return
    fi

    # Fallback heuristic: check if bare repo dir name is exactly ".git"
    local leaf_name
    leaf_name=$(basename "$_wt_project_dir")
    if [[ "$leaf_name" == ".git" ]]; then
        _wt_layout_type="modern"
        _wt_project_root=$(dirname "$_wt_project_dir")
    else
        _wt_layout_type="classic"
        _wt_project_root="$_wt_project_dir"
    fi
}

# ============================================================================
# Auto-update
# ============================================================================

_wt_get_auto_update_config() {
    if [[ -n "${WT_AUTO_UPDATE+x}" ]]; then
        [[ "$WT_AUTO_UPDATE" != "false" ]]
        return $?
    fi

    if [[ -f "$HOME/.wtconfig" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*auto_update[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
                local val="${BASH_REMATCH[1]}"
                val="${val%"${val##*[![:space:]]}"}"
                [[ "$val" != "false" ]]
                return $?
            fi
        done < "$HOME/.wtconfig"
    fi

    return 0
}

_wt_compare_version() {
    local v1="$1" v2="$2"
    local -a parts1 parts2
    local i max_len a b

    IFS='.' read -r -a parts1 <<< "$v1"
    IFS='.' read -r -a parts2 <<< "$v2"

    if (( ${#parts1[@]} > ${#parts2[@]} )); then
        max_len=${#parts1[@]}
    else
        max_len=${#parts2[@]}
    fi

    for (( i=0; i<max_len; i++ )); do
        a="${parts1[i]:-0}"
        b="${parts2[i]:-0}"
        (( 10#$a < 10#$b )) && { echo "-1"; return 0; }
        (( 10#$a > 10#$b )) && { echo "1"; return 0; }
    done

    echo "0"
}

_wt_get_repo_dir() {
    if [[ -n "$_WT_REPO_DIR" && -d "$_WT_REPO_DIR/.git" ]]; then
        echo "$_WT_REPO_DIR"
        return 0
    fi

    if [[ -n "$WT_REPO_DIR" && -d "$WT_REPO_DIR" ]]; then
        echo "$WT_REPO_DIR"
        return 0
    fi

    if [[ -f "$HOME/.wtconfig" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*repo_dir[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
                local dir="${BASH_REMATCH[1]}"
                dir="${dir%"${dir##*[![:space:]]}"}"
                if [[ -d "$dir" ]]; then
                    echo "$dir"
                    return 0
                fi
            fi
        done < "$HOME/.wtconfig"
    fi

    return 1
}

_wt_get_remote_version() {
    local repo_dir="$1"
    local remote_branch remote_version branch

    remote_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref origin/HEAD 2>/dev/null)
    if [[ $? -ne 0 || -z "$remote_branch" || "$remote_branch" == "origin/HEAD" ]]; then
        remote_branch=""
        for branch in main master; do
            if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
                remote_branch="origin/${branch}"
                break
            fi
        done
    fi

    [[ -z "$remote_branch" ]] && return 1

    remote_version=$(git -C "$repo_dir" show "${remote_branch}:VERSION" 2>/dev/null)
    [[ $? -ne 0 || -z "$remote_version" ]] && return 1

    echo "${remote_version%$'\r'}"
}

_wt_check_update() {
    _wt_get_auto_update_config || return 0

    local repo_dir
    repo_dir=$(_wt_get_repo_dir) || return 0

    local cache_file="$HOME/.wt_update_check"
    local now
    now=$(date +%s)

    if [[ -f "$cache_file" ]]; then
        local last_check="" cached_version=""
        {
            IFS= read -r last_check
            IFS= read -r cached_version
        } < "$cache_file"

        if [[ "$last_check" =~ ^[0-9]+$ ]] && (( now - last_check < 86400 )); then
            if [[ -n "$cached_version" && "$(_wt_compare_version "$_WT_VERSION" "$cached_version")" == "-1" ]]; then
                printf '%s\n' "$(_yellow "${_WT_WARNING} Update available: v${_WT_VERSION} → v${cached_version}. Run '${_WT_COMMAND_NAME:-wt} update' to update.")"
            fi
            return 0
        fi
    fi

    git -C "$repo_dir" fetch origin --quiet &>/dev/null
    if [[ $? -ne 0 ]]; then
        printf '%s\n' "$now" > "$cache_file"
        return 0
    fi

    local remote_version
    remote_version=$(_wt_get_remote_version "$repo_dir")
    if [[ -z "$remote_version" ]]; then
        printf '%s\n' "$now" > "$cache_file"
        return 0
    fi

    printf '%s\n%s\n' "$now" "$remote_version" > "$cache_file"

    if [[ "$(_wt_compare_version "$_WT_VERSION" "$remote_version")" == "-1" ]]; then
        printf '%s\n' "$(_yellow "${_WT_WARNING} Update available: v${_WT_VERSION} → v${remote_version}. Run '${_WT_COMMAND_NAME:-wt} update' to update.")"
    fi
}

_wt_update() {
    printf '%s\n' "$(_cyan "=== Checking for updates ===")"
    echo

    local repo_dir
    repo_dir=$(_wt_get_repo_dir)
    if [[ -z "$repo_dir" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Cannot determine the wt repository location")"
        printf '%s\n' "$(_yellow "   Set WT_REPO_DIR or add 'repo_dir = /path/to/wt' to ~/.wtconfig")"
        return 1
    fi

    printf '%s\n' "$(_cyan "${_WT_INFO} Repository: ${repo_dir}")"
    printf '%s\n' "$(_cyan "${_WT_INFO} Current version: v${_WT_VERSION}")"
    echo

    _wt_progress_start "Fetching latest version"
    git -C "$repo_dir" fetch origin --quiet &>/dev/null
    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to fetch updates (check your network connection)" "error"
        return 1
    fi
    _wt_progress_complete "Fetched latest version" "success"

    local remote_version
    remote_version=$(_wt_get_remote_version "$repo_dir")
    if [[ -z "$remote_version" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Could not determine remote version")"
        return 1
    fi

    local now cache_file
    now=$(date +%s)
    cache_file="$HOME/.wt_update_check"
    printf '%s\n%s\n' "$now" "$remote_version" > "$cache_file"

    if [[ "$(_wt_compare_version "$_WT_VERSION" "$remote_version")" != "-1" ]]; then
        printf '%s\n' "$(_green "${_WT_CHECK} Already up to date (v${_WT_VERSION})")"
        return 0
    fi

    printf '%s\n' "$(_cyan "${_WT_INFO} Latest version:  v${remote_version}")"
    echo
    printf '%s\n' "$(_yellow "${_WT_WARNING} Updating will overwrite any manual changes you've made to the script files.")"
    echo

    local response
    read -rp "Do you want to update? (y/N) " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Update cancelled")"
        return 0
    fi

    _wt_progress_start "Updating scripts"
    git -C "$repo_dir" pull &>/dev/null
    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to pull updates" "error"
        printf '%s\n' "$(_yellow "   You may have local changes that conflict. Resolve them in:")"
        printf '%s\n' "$(_yellow "   ${repo_dir}")"
        return 1
    fi
    _wt_progress_complete "Scripts updated to v${remote_version}" "success"

    _wt_progress_start "Reloading script"
    if source "${_WT_SCRIPT_DIR}/worktree.sh"; then
        _wt_progress_complete "Script reloaded (v${_WT_VERSION})" "success"
    else
        _wt_progress_complete "Failed to reload — restart your shell to use the new version" "warning"
    fi

    echo
    printf '%s\n' "$(_green "${_WT_CHECK} Successfully updated to v${remote_version}!")"
}

# ============================================================================
# Help
# ============================================================================

_wt_help() {
    local cmd="${_WT_COMMAND_NAME:-wt}"
    printf '%s\n' "$(_blue "=== Git Worktree Manager ===")"
    echo
    printf '%s%s\n' "$(_cyan "Usage: ")" "$(_yellow "${cmd} <command>")"
    echo
    printf '%s\n' "$(_cyan "Commands:")"
    printf '  %s\n' "$(_green "add <name> [type] [--from <worktree>]")"
    printf '                          %s\n' "Create a new worktree (type defaults to 'feature')"
    printf '  %s                %s\n' "$(_green "list")" "List all worktrees"
    printf '  %s       %s\n' "$(_green "remove <name>")" "Remove a specific worktree"
    printf '  %s          %s\n' "$(_green "remove-all")" "Remove all worktrees (with confirmation)"
    printf '  %s           %s\n' "$(_green "fix-fetch")" "Fix fetch refspec configuration for bare repos"
    printf '  %s         %s\n' "$(_green "clone <url>")" "Clone a repo as bare and set up worktree structure"
    printf '  %s             %s\n' "$(_green "migrate")" "Migrate a classic (trees/) layout to modern (.git) layout"
    printf '  %s              %s\n' "$(_green "update")" "Check for updates and apply them"
    printf '  %s             %s\n' "$(_green "version")" "Show current version"
    echo
    printf '%s\n' "$(_cyan "When creating a worktree:")"
    echo "  • Branch name format: <type>/<name> (default type is 'feature')"
    echo "  • If the branch doesn't exist, it creates a new branch"
    echo "  • If the branch already exists, it checks out the existing branch"
    echo "  • Use --from to base the new branch on another worktree's branch"
    echo
    printf '%s\n' "$(_cyan "Examples:")"
    printf '  %s\n    %s\n' "$(_yellow "${cmd} clone https://github.com/user/repo.git")" "# Clone repo as bare and set up main worktree"
    printf '  %s\n    %s\n' "$(_yellow "${cmd} add RDUCH-123-add-serialization")" "# Creates worktree with branch feature/RDUCH-123-add-serialization"
    printf '  %s\n    %s\n' "$(_yellow "${cmd} add RTJK-1223332-whatever bug")" "# Creates worktree with branch bug/RTJK-1223332-whatever"
    printf '  %s\n    %s\n' "$(_yellow "${cmd} add my-fix --from other-tree")" "# Creates worktree branching from other-tree's branch"
    printf '  %s  %s\n' "$(_yellow "${cmd} list")" "# List all worktrees (shows current with ${_WT_STAR})"
    printf '  %s  %s\n' "$(_yellow "${cmd} remove my-feature")" "# Remove specific worktree"
    printf '  %s  %s\n' "$(_yellow "${cmd} remove-all")" "# Remove all worktrees"
    printf '  %s  %s\n' "$(_yellow "${cmd} fix-fetch")" "# Fix fetch refspec configuration"
    printf '  %s  %s\n' "$(_yellow "${cmd} migrate")" "# Migrate classic layout to modern layout"
    printf '  %s  %s\n' "$(_yellow "${cmd} update")" "# Check for updates and apply them"
    printf '  %s  %s\n' "$(_yellow "${cmd} version")" "# Show current version"
    echo
    printf '%s\n' "$(_cyan "Configuration (~/.wtconfig or environment variables):")"
    printf '  %s  %s\n' "$(_green "command_name / WT_RENAME")" "Set custom command name"
    printf '  %s  %s\n' "$(_green "worktree_folder / WT_WORKTREE_FOLDER")" "Set worktree subfolder (default: project root)"
    printf '  %s  %s\n' "$(_green "auto_update / WT_AUTO_UPDATE")" "Enable/disable update check (default: true)"
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
    local cmd="${_WT_COMMAND_NAME:-wt}"

    # Detect default branch
    local detected_branch
    detected_branch=$(_wt_get_default_branch)

    # Check if a worktree for the default branch already exists (at any location)
    local worktrees
    worktrees=$(_wt_get_parsed_worktrees)

    if [[ -n "$detected_branch" && -n "$worktrees" ]]; then
        while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
            if [[ "$wt_bare" != "true" && "$wt_branch" == "$detected_branch" ]]; then
                main_path="$wt_path"
                main_branch="$detected_branch"
                break
            fi
        done <<< "$worktrees"
    fi

    # Fallback: check for common branch names if no worktree found yet
    if [[ -z "$main_path" && -n "$worktrees" ]]; then
        local b
        for b in main master develop trunk; do
            while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
                if [[ "$wt_bare" != "true" && "$wt_branch" == "$b" ]]; then
                    main_path="$wt_path"
                    main_branch="$b"
                    break 2
                fi
            done <<< "$worktrees"
        done
    fi

    # No existing worktree found - need to create one
    if [[ -z "$main_path" ]]; then
        printf '%s\n' "$(_yellow "Default branch worktree doesn't exist. Creating it...")"

        # If default branch wasn't detected, fix refspec and retry (handles bare repos cloned without wt)
        if [[ -z "$detected_branch" ]]; then
            _wt_set_fetch_refspec "$_wt_project_dir" "true"

            _wt_progress_start "Fetching all branches from bare repository"
            git -C "$_wt_project_dir" fetch --all &>/dev/null
            if [[ $? -eq 0 ]]; then
                _wt_progress_complete "Fetched all branches" "success"
            else
                _wt_progress_complete "Failed to fetch branches" "warning"
            fi

            detected_branch=$(_wt_get_default_branch)
        fi

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
            _wt_progress_complete "Worktree created at ${main_path}" "success"
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
    local cmd="${_WT_COMMAND_NAME:-wt}"

    # Parse --from flag from arguments
    local from_worktree=""
    local -a positional_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)
                if [[ -n "${2:-}" ]]; then
                    from_worktree="$2"
                    shift 2
                else
                    printf '%s\n' "$(_red "${_WT_CROSS} Error: --from requires a worktree name")"
                    return 1
                fi
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    local worktree_name="${positional_args[0]:-}"
    local branch_type="${positional_args[1]:-$_WT_DEFAULT_BRANCH_TYPE}"

    if [[ -z "$worktree_name" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify a name for the worktree")"
        printf '%s\n' "$(_yellow "   Usage: ${cmd} add <name> [type] [--from <worktree>]")"
        return 1
    fi

    # Validate worktree name
    if ! _wt_validate_name "$worktree_name"; then
        return 1
    fi

    # Resolve --from source branch
    local start_point=""
    if [[ -n "$from_worktree" ]]; then
        # When branching from another worktree, update that worktree instead of the default branch
        echo
        printf '%s\n' "$(_cyan "=== Ensuring source worktree '${from_worktree}' is up to date ===")"

        local worktrees
        worktrees=$(_wt_get_parsed_worktrees)
        local source_path="" source_branch=""

        while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
            if [[ "$wt_bare" != "true" && "$wt_name" == "$from_worktree" ]]; then
                source_path="$wt_path"
                source_branch="$wt_branch"
                break
            fi
        done <<< "$worktrees"

        if [[ -z "$source_path" ]]; then
            printf '%s\n' "$(_red "${_WT_CROSS} Error: Source worktree '${from_worktree}' not found")"
            printf '%s\n' "$(_yellow "   Run '${cmd} list' to see available worktrees")"
            return 1
        fi
        start_point="$source_branch"

        # Fetch all from bare repo
        _wt_progress_start "Fetching all branches from bare repository"
        git -C "$_wt_project_dir" fetch --all &>/dev/null
        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Fetched all branches" "success"
        else
            _wt_progress_complete "Failed to fetch all branches (continuing anyway)" "warning"
        fi

        # Pull the source worktree
        _wt_progress_start "Updating source worktree '${from_worktree}'"
        git -C "$source_path" pull &>/dev/null
        if [[ $? -eq 0 ]]; then
            _wt_progress_complete "Source worktree '${from_worktree}' updated" "success"
        else
            _wt_progress_complete "Failed to pull source worktree (continuing anyway)" "warning"
        fi
        echo
    else
        # Ensure main worktree exists and is updated
        echo
        printf '%s\n' "$(_cyan "=== Ensuring main worktree is up to date ===")"
        if ! _wt_init_main_worktree; then
            printf '%s\n' "$(_red "${_WT_CROSS} Failed to ensure main worktree. Aborting.")"
            return 1
        fi
        echo
    fi

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
    if [[ -n "$start_point" ]]; then
        printf '%s\n' "$(_cyan "   From: ${from_worktree} (branch: ${start_point})")"
    fi
    echo

    mkdir -p "$_wt_worktree_parent"

    # Check if branch already exists
    if _wt_branch_exists "$branch_name"; then
        if [[ -n "$start_point" ]]; then
            printf '%s\n' "$(_yellow "${_WT_WARNING} Branch '${branch_name}' already exists, --from flag will be ignored")"
        fi
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
        if [[ -n "$start_point" ]]; then
            git -C "$_wt_project_dir" worktree add -b "$branch_name" "$worktree_path" "$start_point" &>/dev/null
        else
            git -C "$_wt_project_dir" worktree add -b "$branch_name" "$worktree_path" &>/dev/null
        fi
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

    read -rp "Do you want to navigate to the new worktree? (Y/n) " response
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        cd "$worktree_path" || return 1
    fi
}

# Remove a specific worktree
_wt_remove() {
    local name="$1"
    local cmd="${_WT_COMMAND_NAME:-wt}"

    if [[ -z "$name" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify which worktree to remove")"
        printf '%s\n' "$(_yellow "   Usage: ${cmd} remove <worktree-name>")"
        return 1
    fi

    # Look up the worktree from git's worktree list by name (handles any location)
    local worktrees
    worktrees=$(_wt_get_parsed_worktrees)

    local worktree_path="" branch_name=""
    while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
        if [[ "$wt_bare" != "true" && "$wt_name" == "$name" ]]; then
            worktree_path="$wt_path"
            branch_name="$wt_branch"
            break
        fi
    done <<< "$worktrees"

    if [[ -z "$worktree_path" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Worktree '${name}' not found")"
        printf '%s\n' "$(_yellow "   Run '${cmd} list' to see available worktrees")"
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

    # Collect all non-bare worktrees, excluding the default branch
    local -a rm_paths=() rm_names=() rm_branches=()

    while IFS=$'\t' read -r path branch name is_bare; do
        [[ "$is_bare" == "true" ]] && continue
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

# Clone repository as bare with modern layout
_wt_clone() {
    local repo_url="$1"
    local cmd="${_WT_COMMAND_NAME:-wt}"

    if [[ -z "$repo_url" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Please specify a repository URL")"
        printf '%s\n' "$(_yellow "   Usage: ${cmd} clone <url>")"
        return 1
    fi

    # Extract repo name from URL (handles both HTTPS and SSH formats)
    local repo_name="${repo_url%.git}"
    repo_name="${repo_name##*[/:]}"
    local destination_path="${PWD}/${repo_name}"
    local bare_repo_path="${destination_path}/.git"

    if [[ -d "$destination_path" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Directory '${repo_name}' already exists")"
        printf '%s\n' "$(_yellow "   Please remove it or choose a different location")"
        return 1
    fi

    printf '%s\n' "$(_blue "=== Cloning repository as bare ===")"
    printf '%s\n' "$(_cyan "   URL: ${repo_url}")"
    printf '%s\n' "$(_cyan "   Destination: ./${repo_name}")"
    echo

    # Create project root directory
    mkdir -p "$destination_path"

    # Clone with --bare flag into .git subdirectory
    _wt_progress_start "Cloning repository"
    local clone_output
    clone_output=$(git clone --bare "$repo_url" "$bare_repo_path" 2>&1)

    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to clone repository" "error"
        printf '%s\n' "$(_yellow "   Error: ${clone_output}")"
        # Clean up the empty directory
        rm -rf "$destination_path" 2>/dev/null
        return 1
    fi
    _wt_progress_complete "Repository cloned" "success"

    # Ensure core.bare is explicitly set (safety for .git directory name)
    git -C "$bare_repo_path" config core.bare true &>/dev/null

    # Set layout marker
    git -C "$bare_repo_path" config wt.layout modern &>/dev/null

    # Configure fetch refspec for bare repo
    _wt_set_fetch_refspec "$bare_repo_path"

    # Fetch all branches
    _wt_progress_start "Fetching all branches"
    git -C "$bare_repo_path" fetch --all &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Fetched all branches" "success"
    else
        _wt_progress_complete "Failed to fetch all branches (continuing anyway)" "warning"
    fi

    # Detect default branch dynamically
    _wt_progress_start "Detecting default branch"
    local main_branch
    main_branch=$(_wt_get_default_branch "$bare_repo_path")

    if [[ -z "$main_branch" ]]; then
        _wt_progress_complete "Failed to detect default branch" "error"
        printf '%s\n' "$(_yellow "   The repository was cloned but no worktree was created.")"
        printf '%s\n' "$(_yellow "   You can manually create a worktree using: ${cmd} add <name>")"
        return 1
    fi
    _wt_progress_complete "Found default branch: ${main_branch}" "success"

    # Resolve worktree folder from config (no layout context needed - modern default is "")
    local worktree_folder
    if worktree_folder=$(_wt_get_worktree_folder); then
        : # use configured value
    else
        worktree_folder=""
    fi

    # Compute worktree parent
    local worktree_parent
    if [[ -n "$worktree_folder" ]]; then
        worktree_parent="${destination_path}/${worktree_folder}"
        mkdir -p "$worktree_parent"
    else
        worktree_parent="$destination_path"
    fi

    # Create worktree for default branch
    local main_wt_path="${worktree_parent}/${main_branch}"
    _wt_progress_start "Creating worktree for ${main_branch} branch"
    git -C "$bare_repo_path" worktree add "$main_wt_path" "$main_branch" &>/dev/null

    if [[ $? -ne 0 ]]; then
        _wt_progress_complete "Failed to create worktree for ${main_branch}" "error"
        return 1
    fi
    _wt_progress_complete "Worktree created at ${main_wt_path}" "success"

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
    printf '%s\n' "$(_cyan "   Project root: ${destination_path}")"
    printf '%s\n' "$(_cyan "   Bare repo: ${bare_repo_path}")"
    printf '%s\n' "$(_cyan "   Main worktree: ${main_wt_path}")"
    echo
    printf '%s\n' "$(_yellow "${_WT_INFO} The project root (${repo_name}/) is a container — work inside worktree directories.")"
    echo

    read -rp "Do you want to navigate to the main worktree? (Y/n) " response
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        cd "$main_wt_path" || return 1
    fi
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

# Migrate classic layout to modern layout
_wt_migrate() {
    # Precondition: must be classic layout
    if [[ "$_wt_layout_type" == "modern" ]]; then
        printf '%s\n' "$(_green "${_WT_CHECK} This repository already uses the modern layout")"
        printf '%s\n' "$(_cyan "   Bare repo: ${_wt_project_dir}")"
        printf '%s\n' "$(_cyan "   Project root: ${_wt_project_root}")"
        return
    fi

    # Compute new paths
    local old_root="$_wt_project_dir"
    local old_root_name
    old_root_name=$(basename "$old_root")
    local new_root_name="${old_root_name%.git}"
    local parent_dir
    parent_dir=$(dirname "$old_root")
    local new_root="${parent_dir}/${new_root_name}"
    local new_bare_repo="${new_root}/.git"

    # Check for collision
    if [[ -d "$new_root" ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Error: Directory '${new_root_name}' already exists")"
        printf '%s\n' "$(_yellow "   Cannot migrate — the target directory is taken")"
        return
    fi

    # Parse worktrees
    local worktrees
    worktrees=$(_wt_get_parsed_worktrees)
    local default_branch
    default_branch=$(_wt_get_default_branch)

    # Classify worktrees as internal (inside old_root) or external
    local -a move_paths=() move_names=() move_branches=()
    local -a ext_paths=() ext_names=()

    if [[ -n "$worktrees" ]]; then
        # Normalize old_root for comparison (lowercase, no trailing slash)
        local norm_old_root
        norm_old_root=$(echo "$old_root" | tr '[:upper:]' '[:lower:]')
        norm_old_root="${norm_old_root%/}"

        while IFS=$'\t' read -r wt_path wt_branch wt_name wt_bare; do
            [[ "$wt_bare" == "true" ]] && continue

            # Normalize worktree path for case-insensitive comparison
            local norm_wt_path
            norm_wt_path=$(echo "$wt_path" | tr '[:upper:]' '[:lower:]')
            norm_wt_path="${norm_wt_path%/}"

            if [[ "$norm_wt_path" == "${norm_old_root}/"* ]]; then
                move_paths+=("$wt_path")
                move_names+=("$wt_name")
                move_branches+=("$wt_branch")
            else
                ext_paths+=("$wt_path")
                ext_names+=("$wt_name")
            fi
        done <<< "$worktrees"
    fi

    # Resolve worktree folder for new layout (null = not configured, "" = explicitly empty)
    local worktree_folder
    if worktree_folder=$(_wt_get_worktree_folder); then
        : # use configured value
    else
        worktree_folder=""
    fi

    # Check for uncommitted changes
    local -a dirty_names=() dirty_counts=()
    local i
    for i in "${!move_paths[@]}"; do
        local status_output
        status_output=$(git -C "${move_paths[$i]}" status --porcelain 2>/dev/null)
        if [[ -n "$status_output" ]]; then
            local changed_files
            changed_files=$(echo "$status_output" | wc -l)
            changed_files="${changed_files// /}"
            dirty_names+=("${move_names[$i]}")
            dirty_counts+=("$changed_files")
        fi
    done

    # Show migration preview
    printf '%s\n' "$(_blue "=== Migration Preview ===")"
    echo
    printf '%s\n' "$(_cyan "Current layout (classic):")"
    printf '  %s\n' "Bare repo: ${old_root}"
    for i in "${!move_paths[@]}"; do
        printf '  %s\n' "Worktree: ${move_names[$i]} → ${move_paths[$i]}"
    done
    if [[ ${#ext_paths[@]} -gt 0 ]]; then
        printf '%s\n' "$(_yellow "  External worktrees (will NOT be moved):")"
        for i in "${!ext_paths[@]}"; do
            printf '%s\n' "$(_yellow "    ${ext_names[$i]} → ${ext_paths[$i]}")"
        done
    fi

    echo
    printf '%s\n' "$(_cyan "New layout (modern):")"
    printf '  %s\n' "Project root: ${new_root}"
    printf '  %s\n' "Bare repo: ${new_bare_repo}"
    for i in "${!move_names[@]}"; do
        local new_path
        if [[ -n "$worktree_folder" ]]; then
            new_path="${new_root}/${worktree_folder}/${move_names[$i]}"
        else
            new_path="${new_root}/${move_names[$i]}"
        fi
        printf '  %s\n' "Worktree: ${move_names[$i]} → ${new_path}"
    done
    echo

    # Warn about uncommitted changes
    if [[ ${#dirty_names[@]} -gt 0 ]]; then
        printf '%s\n' "$(_yellow "${_WT_WARNING} The following worktrees have uncommitted changes:")"
        for i in "${!dirty_names[@]}"; do
            printf '  %s\n' "$(_red "${_WT_CROSS} ${dirty_names[$i]} (${dirty_counts[$i]} modified files)")"
        done
        echo
        printf '%s\n' "$(_yellow "Uncommitted changes will be preserved during migration, but if anything")"
        printf '%s\n' "$(_yellow "goes wrong they could be lost.")"
        echo
    fi

    read -rp "Are you sure you want to migrate? (y/N) " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        printf '%s\n' "$(_red "${_WT_CROSS} Cancelled")"
        return
    fi

    # CWD safety: move out of the repo being migrated
    local saved_location="$PWD"
    local norm_pwd
    norm_pwd=$(echo "$PWD" | tr '[:upper:]' '[:lower:]')
    norm_pwd="${norm_pwd%/}"
    local norm_check
    norm_check=$(echo "$old_root" | tr '[:upper:]' '[:lower:]')
    norm_check="${norm_check%/}"
    if [[ "$norm_pwd" == "$norm_check" || "$norm_pwd" == "${norm_check}/"* ]]; then
        cd "$parent_dir" || return 1
        printf '%s\n' "$(_cyan "${_WT_INFO} Changed directory to ${parent_dir} (required for migration)")"
    fi

    echo
    printf '%s\n' "$(_blue "=== Migrating to modern layout ===")"

    # Step a: Create new project root
    _wt_progress_start "Creating project root '${new_root_name}'"
    if mkdir -p "$new_root" 2>/dev/null; then
        _wt_progress_complete "Project root created" "success"
    else
        _wt_progress_complete "Failed to create project root" "error"
        return
    fi

    # Step b: Create worktree subfolder if configured
    if [[ -n "$worktree_folder" ]]; then
        mkdir -p "${new_root}/${worktree_folder}" 2>/dev/null
    fi

    # Step c: Move worktrees
    local -a new_worktree_paths=()
    for i in "${!move_paths[@]}"; do
        local new_path
        if [[ -n "$worktree_folder" ]]; then
            new_path="${new_root}/${worktree_folder}/${move_names[$i]}"
        else
            new_path="${new_root}/${move_names[$i]}"
        fi

        _wt_progress_start "Moving worktree '${move_names[$i]}'"
        if mv "${move_paths[$i]}" "$new_path" 2>/dev/null; then
            _wt_progress_complete "Moved '${move_names[$i]}'" "success"
            new_worktree_paths+=("$new_path")
        else
            _wt_progress_complete "Failed to move '${move_names[$i]}'" "error"
            printf '%s\n' "$(_red "${_WT_CROSS} Migration failed. The old directory is still intact at: ${old_root}")"
            printf '%s\n' "$(_yellow "   Clean up the partial migration directory: ${new_root}")"
            return
        fi
    done

    # Add external worktree paths (they haven't moved but need repair)
    for i in "${!ext_paths[@]}"; do
        new_worktree_paths+=("${ext_paths[$i]}")
    done

    # Step d: Move bare repo to .git
    _wt_progress_start "Moving bare repo to ${new_bare_repo}"
    if mkdir -p "$new_bare_repo" 2>/dev/null; then
        # Move all items from old root to new .git
        # Skip any empty directories left behind after worktree moves
        local move_failed=false
        for item in "$old_root"/*  "$old_root"/.[!.]* "$old_root"/..?*; do
            [[ -e "$item" ]] || continue
            if [[ -d "$item" ]]; then
                # Check if directory is empty (likely old worktree folder after moves)
                if [[ -z "$(ls -A "$item" 2>/dev/null)" ]]; then
                    rmdir "$item" 2>/dev/null
                    continue
                fi
            fi
            if ! mv "$item" "$new_bare_repo/" 2>/dev/null; then
                move_failed=true
                break
            fi
        done

        if $move_failed; then
            _wt_progress_complete "Failed to move bare repo" "error"
            printf '%s\n' "$(_red "${_WT_CROSS} Migration failed during bare repo move.")"
            printf '%s\n' "$(_yellow "   Old directory: ${old_root}")"
            printf '%s\n' "$(_yellow "   New directory: ${new_root}")"
            printf '%s\n' "$(_yellow "   Manual recovery may be needed.")"
            return
        fi
        _wt_progress_complete "Bare repo moved" "success"
    else
        _wt_progress_complete "Failed to create .git directory" "error"
        return
    fi

    # Step e: Set config values
    git -C "$new_bare_repo" config core.bare true &>/dev/null
    git -C "$new_bare_repo" config wt.layout modern &>/dev/null

    # Step f: Repair worktree cross-references
    _wt_progress_start "Repairing worktree references"
    git -C "$new_bare_repo" worktree repair "${new_worktree_paths[@]}" &>/dev/null
    if [[ $? -eq 0 ]]; then
        _wt_progress_complete "Worktree references repaired" "success"
    else
        _wt_progress_complete "Worktree repair had issues (check manually)" "warning"
    fi

    # Step g: Verify
    _wt_progress_start "Verifying migration"
    local verify_output
    verify_output=$(git -C "$new_bare_repo" worktree list 2>/dev/null)
    if [[ $? -eq 0 && -n "$verify_output" ]]; then
        _wt_progress_complete "Migration verified" "success"
    else
        _wt_progress_complete "Verification failed — check worktree list manually" "warning"
    fi

    # Step h: Remove old directory
    _wt_progress_start "Removing old directory"
    if rm -rf "$old_root" 2>/dev/null; then
        _wt_progress_complete "Old directory removed" "success"
    else
        _wt_progress_complete "Could not remove old directory: ${old_root}" "warning"
        printf '%s\n' "$(_yellow "   You may need to remove it manually")"
    fi

    # Success
    echo
    printf '%s\n' "$(_green "${_WT_CHECK} Migration complete!")"
    printf '%s\n' "$(_cyan "   Project root: ${new_root}")"
    printf '%s\n' "$(_cyan "   Bare repo: ${new_bare_repo}")"
    echo

    # Find the default branch worktree for cd offer
    local default_wt_path=""
    for i in "${!move_names[@]}"; do
        if [[ "${move_branches[$i]}" == "$default_branch" || "${move_names[$i]}" == "$default_branch" ]]; then
            if [[ -n "$worktree_folder" ]]; then
                default_wt_path="${new_root}/${worktree_folder}/${move_names[$i]}"
            else
                default_wt_path="${new_root}/${move_names[$i]}"
            fi
            break
        fi
    done

    if [[ -n "$default_wt_path" && -d "$default_wt_path" ]]; then
        read -rp "Do you want to navigate to the main worktree? (Y/n) " response
        if [[ ! "$response" =~ ^[Nn]$ ]]; then
            cd "$default_wt_path" || return 1
        fi
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

    if [[ "$command" == "update" ]]; then
        _wt_update
        return
    fi

    if [[ "$command" == "version" || "$command" == "--version" ]]; then
        printf '%s\n' "$(_cyan "v${_WT_VERSION}")"
        return
    fi

    _wt_check_update

    # Initialize context (requires being inside a git repo)
    _wt_project_dir=$(_wt_get_git_root)
    if [[ -z "$_wt_project_dir" ]]; then
        return 1
    fi

    # Detect layout and set project root
    _wt_get_project_layout

    _wt_project_name=$(basename "$_wt_project_root")

    # Resolve worktree folder: config > layout default
    local configured_folder
    if configured_folder=$(_wt_get_worktree_folder); then
        _WT_WORKTREE_FOLDER="$configured_folder"
    elif [[ "$_wt_layout_type" == "classic" ]]; then
        _WT_WORKTREE_FOLDER="trees"
    else
        _WT_WORKTREE_FOLDER=""
    fi

    # Compute worktree parent path
    if [[ -n "$_WT_WORKTREE_FOLDER" ]]; then
        _wt_worktree_parent="${_wt_project_root}/${_WT_WORKTREE_FOLDER}"
    else
        _wt_worktree_parent="$_wt_project_root"
    fi

    case "$command" in
        add)        _wt_add "$@" ;;
        list)       _wt_list ;;
        remove)     _wt_remove "$*" ;;
        remove-all) _wt_remove_all ;;
        fix-fetch)  _wt_fix_fetch ;;
        migrate)    _wt_migrate ;;
        update)     _wt_update ;;
        version|--version)
            printf '%s\n' "$(_cyan "v${_WT_VERSION}")"
            ;;
        *)
            printf '%s\n' "$(_red "${_WT_CROSS} Error: Unknown command '${command}'")"
            printf '%s\n' "$(_yellow "   Run '${_WT_COMMAND_NAME:-wt} --help' to see available commands")"
            return 1
            ;;
    esac
}

# ============================================================================
# Configurable command name
# ============================================================================

# Resolve command name: env var > ~/.wtconfig file > default 'wt'
_WT_COMMAND_NAME="${WT_RENAME:-}"
if [[ -z "$_WT_COMMAND_NAME" ]]; then
    if [[ -f "$HOME/.wtconfig" ]]; then
        while IFS= read -r _wt_cfg_line; do
            if [[ "$_wt_cfg_line" =~ ^[[:space:]]*command_name[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
                _WT_COMMAND_NAME="${BASH_REMATCH[1]}"
                # Trim trailing whitespace
                _WT_COMMAND_NAME="${_WT_COMMAND_NAME%"${_WT_COMMAND_NAME##*[![:space:]]}"}"
                break
            fi
        done < "$HOME/.wtconfig"
        unset _wt_cfg_line
    fi
fi
if [[ -z "$_WT_COMMAND_NAME" ]]; then
    _WT_COMMAND_NAME="wt"
fi

# If the configured name differs from 'wt', create an alias function
if [[ "$_WT_COMMAND_NAME" != "wt" ]]; then
    eval "${_WT_COMMAND_NAME}() { wt \"\$@\"; }"
fi
