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

# EVERY RUNG A STACK LIVES ON, which is four of them and not one:
#   APK:Docktor/Docker/                         the manager, at the top
#   POD:<pod>/Docker/                           a POD ROOT that only include:s
#   POD:<pod>/<stack>/Docker/                   the ordinary stack
#   POD:<pod>/<group>/<stack>/Docker/           APK:plugin:* under APK:plugin/
# ⚠️ THIS GLOB WAS ONE RUNG AND STAYED ONE RUNG AFTER THE PODS LANDED, so for
#    months it matched NOTHING and the sweep refused on the guard below — which
#    read as "the repo is broken" rather than "the glob is". It became dangerous
#    the day POD:protocols/Docker/docker-compose.yml appeared: suddenly the one
#    rung matched exactly ONE file, the first guard passed, and the keep-set was
#    one project. Only the SECOND guard (no container_name: in it) stood between
#    a --dry-run and a sweep that read the whole bench as strangers.
# A KEEP-SET BUILT FROM A GLOB MUST BE BUILT FROM ALL OF THEM. stacks.sh walks
# two rungs for the same reason; this walks four because it is the file that
# DELETES, and being short here is the expensive direction to be wrong in.
# THIS IS THE ONE READER OF THE COMPOSE FILES THAT SAYS SO WHEN IT FINDS NONE —
# the two guards below are why.
mapfile -t compose_files < <(find "$DOCKERS_DIR" -mindepth 3 -maxdepth 5 \
    -type f -name 'docker-compose.yml' -path '*/Docker/*' 2>/dev/null | sort)
if [ ${#compose_files[@]} -eq 0 ]; then
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
