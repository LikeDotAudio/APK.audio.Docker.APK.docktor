#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🗑️ Remove every container on this host that is NOT part of APK.audio.
#   ./remove-other-containers.sh [--dry-run]
# The inverse of panic.sh: for reclaiming a bench that has collected other
# projects stopped containers without touching the stack you are working on.
# THE KEEP-SET IS READ FROM THE COMPOSE FILES, NEVER TYPED HERE: a container is
# ours if any APK:PODS/*/Docker/docker-compose.yml declares its
# container_name:, or if it carries a com.docker.compose.project label naming one
# of the projects those files declare (apk-audio, and nmos).
# ⚠️ A hand-written list of name substrings does not survive a rename. This
#    carried *apk*|*broker*|*mariadb* from when containers were named apk-*; the
#    DOCKERS split renamed them and eight of thirteen read as strangers and were
#    deleted by the sweep meant to spare them.
# The substring net is kept BENEATH the declared set, as a net and not the rule,
# so a hand-started apk-scratch still survives. The asymmetry is deliberate:
# keeping a stranger costs a line of output, removing one of ours costs the
# session.
# NO COMPOSE FILE PARSED IS A HARD FAILURE, not an empty keep-set — an empty set
# makes every container a stranger.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# */Docker/, one rung down. THIS IS THE ONE READER OF THE COMPOSE FILES THAT
# SAYS SO WHEN IT FINDS NONE — the guard below is why.
compose_files=("$DOCKERS_DIR"/*/Docker/docker-compose.yml)
if [ ! -e "${compose_files[0]}" ]; then
    log_error "No */Docker/docker-compose.yml under $DOCKERS_DIR."
    echo "  Refusing to sweep: with nothing parsed the keep-set is empty, and every"
    echo "  container on this host would read as a stranger."
    exit 1
fi

declare -A OURS_NAMES=()
declare -A OURS_PROJECTS=()

while IFS=$'\t' read -r kind value; do
    case "$kind" in
        c) OURS_NAMES["${value,,}"]=1;;
        p) OURS_PROJECTS["${value,,}"]=1;;
    esac
done < <(awk '
    function clean(s) {
        sub(/[[:space:]]*#.*$/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        gsub(/^["'\''"]|["'\''"]$/, "", s)
        return s
    }
    # container_name: is always indented under a service; a project name is the
    # only `name:` at column 0. Every named VOLUME also carries a name:, which
    # is why the project pattern is anchored and the service one is not.
    /^[[:space:]]+container_name:/ { v = clean(substr($0, index($0, ":") + 1)); if (length(v)) print "c\t" v }
    /^name:/                       { v = clean(substr($0, index($0, ":") + 1)); if (length(v)) print "p\t" v }
' "${compose_files[@]}")

if [ ${#OURS_NAMES[@]} -eq 0 ]; then
    log_error "Parsed ${#compose_files[@]} compose file(s) and found no container_name:."
    echo "  Refusing to sweep rather than treat the whole ecosystem as strangers."
    exit 1
fi

others=()
kept=0
while IFS=$'\t' read -r name project; do
    [ -z "$name" ] && continue
    if [ -n "${OURS_NAMES[${name,,}]:-}" ]; then kept=$((kept + 1)); continue; fi
    if [ -n "$project" ] && [ -n "${OURS_PROJECTS[${project,,}]:-}" ]; then kept=$((kept + 1)); continue; fi
    case "${name,,}" in
        *apk*|*broker*|*mariadb*) kept=$((kept + 1)); continue;;
    esac
    others+=("$name")
done < <(docker ps -a --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}')

echo "Keeping $kept APK.audio container(s); ${#OURS_NAMES[@]} declared across ${#compose_files[@]} compose file(s)."

if [ ${#others[@]} -eq 0 ]; then
    log_info "No non-APK system containers found to remove."
    exit 0
fi

echo "Found ${#others[@]} non-APK system container(s):"
printf '   • %s\n' "${others[@]}"

if [ $DRY_RUN -eq 1 ]; then
    log_warn "--dry-run: nothing removed."
    exit 0
fi

for name in "${others[@]}"; do
    echo "   • Removing $name..."
    docker rm -f "$name" 2>&1 | sed 's/^/     -> /'
done

announce OTHER_CONTAINERS_REMOVED "{\"count\":${#others[@]}}"
log_info "All non-APK system containers removed."
