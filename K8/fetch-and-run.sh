#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🐙 Fetch Git repositories & run their Docker containers.
# Usage:
#   ./fetch-and-run.sh                                    auto-discover all Git sub-repos under APK:PODS/
#   ./fetch-and-run.sh <repo_url_or_path_1> [...]         fetch & run specific repo URLs or local directories
#   ./fetch-and-run.sh --file repos.txt [--build]        read repos list from file

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TARGET_DIR="${APKAUDIO_REPOS_DIR:-$REPO_ROOT/..}"
BUILD=0
REBUILD=0
REPOS=()

for arg in "$@"; do
    case "$arg" in
        --build)   BUILD=1;;
        --rebuild) REBUILD=1;;
        --file)    FILE_MODE=1;;
        -*)        if [ "${PREV_ARG:-}" = "--file" ]; then
                       REPOS_FILE="$arg"
                   else
                       log_warn "Unknown option: $arg"
                   fi;;
        *)         if [ "${PREV_ARG:-}" = "--file" ]; then
                       REPOS_FILE="$arg"
                   else
                       REPOS+=("$arg")
                   fi;;
    esac
    PREV_ARG="$arg"
done

if [ -n "${REPOS_FILE:-}" ] && [ -f "$REPOS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed 's/#.*//' | xargs)"
        [ -n "$line" ] && REPOS+=("$line")
    done < "$REPOS_FILE"
fi

# AUTO-DISCOVERY: Default to all sub-repositories inside $DOCKERS_DIR if no repos specified
if [ ${#REPOS[@]} -eq 0 ]; then
    log_info "No repositories specified on command line. Auto-discovering Git repositories under $DOCKERS_DIR..."
    for dir in "$DOCKERS_DIR"/*/; do
        if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
            REPOS+=("$dir")
        fi
    done
fi

if [ ${#REPOS[@]} -eq 0 ]; then
    log_error "No Git repositories found under $DOCKERS_DIR."
    exit 2
fi

log_step "Processing ${#REPOS[@]} Git repository entry/entries..."

for entry in "${REPOS[@]}"; do
    SUB_TARGETS=()

    if [[ "$entry" =~ ^(https?://|git@|ssh://) ]]; then
        repo_name="$(basename "$entry" .git)"
        local_path="$TARGET_DIR/$repo_name"
        log_step "Fetching remote Git repository: $entry"
        if [ -d "$local_path/.git" ] || [ -f "$local_path/.git" ]; then
            log_info "Updating existing repository at $local_path..."
            git -C "$local_path" pull --ff-only 2>/dev/null || log_warn "Git pull failed for $local_path; continuing."
        else
            log_info "Cloning $entry to $local_path..."
            git clone "$entry" "$local_path" || { log_error "Failed to clone $entry"; continue; }
        fi
        SUB_TARGETS+=("$local_path")
    elif [ -d "$entry" ]; then
        abs_path="$(cd "$entry" && pwd)"
        if [ -d "$abs_path/.git" ] || [ -f "$abs_path/.git" ]; then
            SUB_TARGETS+=("$abs_path")
        else
            # Parent directory containing multiple sub-repositories
            log_info "Scanning directory $abs_path for Git sub-repositories..."
            for sub in "$abs_path"/*/; do
                if [ -d "$sub/.git" ] || [ -f "$sub/.git" ]; then
                    SUB_TARGETS+=("$sub")
                fi
            done
        fi
    else
        log_error "Repository entry '$entry' is neither a valid directory nor a valid Git URL."
        continue
    fi

    for repo_dir in "${SUB_TARGETS[@]}"; do
        repo_name="$(basename "$repo_dir")"
        github_name=""
        if [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ]; then
            remote_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null)"
            if [ -n "$remote_url" ]; then
                github_name="$(basename "$remote_url" .git)"
                repo_name="$github_name"
            fi
        fi
        log_step "Processing GitHub repository: $repo_name ($repo_dir)"

        # Pull latest Git changes
        if [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ]; then
            log_info "Git pull for $repo_name..."
            git -C "$repo_dir" pull --ff-only 2>/dev/null || log_warn "Git pull for $repo_name failed or has local changes; continuing."
        fi

        # Find docker compose files
        mapfile -t COMPOSE_FILES < <(find "$repo_dir" -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \) ! -path "*/node_modules/*" ! -path "*/.git/*")

        if [ ${#COMPOSE_FILES[@]} -eq 0 ]; then
            log_warn "No docker-compose file found in $repo_name ($repo_dir)."
            continue
        fi

        for compose_file in "${COMPOSE_FILES[@]}"; do
            log_step "Launching stack: $compose_file"
            comp_dir="$(dirname "$compose_file")"
            if [ "$REBUILD" = "1" ]; then
                docker compose -f "$compose_file" build --no-cache
            fi
            if [ "$BUILD" = "1" ] || [ "$REBUILD" = "1" ]; then
                docker compose -f "$compose_file" up -d --build
            else
                docker compose -f "$compose_file" up -d
            fi
            announce STACK_FETCHED_AND_RUN "{\"repo\":\"$repo_name\",\"compose_file\":\"$compose_file\"}"
        done
    done
done

log_step "Fetch and run complete across all sub-repositories."
"$MANAGEMENT_SCRIPTS_DIR/status.sh" || true
