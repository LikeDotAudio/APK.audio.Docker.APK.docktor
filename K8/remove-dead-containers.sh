#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# ⚰️  Remove containers that have STOPPED. Ours included.
#   ./remove-dead-containers.sh                    sweep every stopped container
#   ./remove-dead-containers.sh --dry-run          say what that would take
#   ./remove-dead-containers.sh apk-serve-test     one, by name
#   ./remove-dead-containers.sh --force apk-probe  one, even if it is running
# The third removal verb, and the one the other two cannot say:
#   panic.sh                   every container on the host, running or not
#   remove-other-containers.sh every container that is not ours
#   THIS ONE                   every container that is not RUNNING, whoever owns it
# DEAD = exited, dead, created — docker own vocabulary, asked for with
# --filter status=, never matched out of the STATUS text (that is a rendered
# sentence that changes with the docker version).
# A `restarting` container is NOT dead and is never swept: its restart policy is
# doing what it was told and the sweep would race it. Name it if you mean it.
# NAMED, IT REFUSES A RUNNING CONTAINER — --force is how you say you meant it,
# and the only path here to docker rm -f. The sweep can never hit a running
# container, so --force changes nothing about the no-argument form.
# VOLUMES SURVIVE: docker rm without -v. A removed container is not a reason to
# lose the database it was attached to.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

DRY_RUN=0
FORCE=0
targets=()
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1;;
        --force)   FORCE=1;;
        -*)        log_error "unknown option: $argument"; exit 2;;
        *)         targets+=("$argument");;
    esac
done

# No names: the sweep. Docker decides what is dead, by state and not by prose.
if [ ${#targets[@]} -eq 0 ]; then
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        targets+=("$name")
    done <<< "$(docker ps -a --filter status=exited --filter status=dead \
                              --filter status=created --format '{{.Names}}')"

    if [ ${#targets[@]} -eq 0 ]; then
        log_info "No dead containers — everything on this host is running."
        announce DEAD_CONTAINERS_REMOVED "{\"count\":0,\"swept\":true}"
        exit 0
    fi

    echo "Found ${#targets[@]} stopped container(s):"
    for name in "${targets[@]}"; do
        printf '   • %s — %s\n' "$name" \
            "$(docker ps -a --filter "name=^${name}$" --format '{{.Status}}')"
    done
else
    # Named: every one has to exist, and a running one has to be meant. Both
    # checks run BEFORE anything is removed, so a typo in the third name does
    # not leave the first two gone.
    for name in "${targets[@]}"; do
        if ! docker inspect "$name" >/dev/null 2>&1; then
            log_error "no such container: $name"
            announce CONTAINER_REMOVE_FAILED "{\"container\":\"$name\",\"reason\":\"unknown\"}"
            exit 1
        fi
        state="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)"
        if [ "$state" = "running" ] && [ $FORCE -eq 0 ]; then
            log_error "$name is RUNNING. Stop it first, or pass --force to kill and remove it."
            announce CONTAINER_REMOVE_REFUSED "{\"container\":\"$name\",\"state\":\"$state\"}"
            exit 1
        fi
    done
fi

if [ $DRY_RUN -eq 1 ]; then
    log_warn "--dry-run: nothing removed."
    announce DEAD_CONTAINERS_DRY_RUN "{\"count\":${#targets[@]}}"
    exit 0
fi

worst=0
removed=()
for name in "${targets[@]}"; do
    echo "   • Removing $name..."
    # -f covers the container named with --force and the sweep losing a race to
    # something that started between the listing and here. Never -v.
    if docker rm -f "$name" 2>&1 | sed 's/^/     -> /'; then
        removed+=("$name")
        announce CONTAINER_REMOVED "{\"container\":\"$name\"}"
    else
        log_error "could not remove $name."
        announce CONTAINER_REMOVE_FAILED "{\"container\":\"$name\"}"
        worst=1
    fi
done

# The names, not just the count: this is the one line a reader has once the
# container is gone.
list="$(printf '"%s",' "${removed[@]}")"
announce DEAD_CONTAINERS_REMOVED "{\"count\":${#removed[@]},\"names\":[${list%,}]}"
log_info "Removed ${#removed[@]} container(s). Named volumes were not touched."
exit $worst
