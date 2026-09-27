#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧱 Rebuild ONE container image and put it back, from whatever built it.
#   ./rebuild.sh APK-NMOS-Bridge
#   ./rebuild.sh Storage-Portal Storage-PHP
# The card-scoped rebuild. restart.sh keeps the old image; rebuild-core.sh builds
# a named service in the core file; rebuild-all.sh removes everything first.
# Between them sat containers the grid can select and no verb could rebuild —
# APK-NMOS-Bridge is in project nmos, named by neither COMPOSE_CORE nor
# COMPOSE_NODE.
# THE COMPOSE FILE IS ASKED OF THE CONTAINER, not of this folder: compose stamps
# com.docker.compose.project/.service/.project.config_files/.project.working_dir
# onto everything it creates, and those four ARE the invocation that built it.
# NO --remove-orphans (under the shared apk-audio project it would delete the
# rest of the ecosystem) and no port eviction (compose stops the old container
# before binding the new, and a KABOOM scoped to one card would take whatever
# else answers on that port).
# Gated like every other build path. The gates run ONCE, before the first
# container. Exits non-zero if any named container fails; every one is attempted.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

if [ $# -eq 0 ]; then
    log_error "usage: rebuild.sh <container-name-or-id> [more...]"
    exit 2
fi

log_step "Enforcing upstream pre-build container test gates..."
if ! "$MANAGEMENT_SCRIPTS_DIR/test-gates.sh"; then
    log_error "Rebuild cancelled: upstream pre-build test gates failed."
    exit 1
fi

# One label, or empty. docker inspect --format prints the literal <no value>
# for a missing key, which is non-empty and so reads as an answer.
label_of() {
    local value
    value="$(docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null)"
    [ "$value" = "<no value>" ] && value=""
    printf '%s' "$value"
}

# The rebuilt container mounts the external log volume; LOGGER STORAGE owns it.
ensure_log_storage

worst=0
built=0
for container in "$@"; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "no such container: $container"
        announce CONTAINER_REBUILD_FAILED "{\"container\":\"$container\",\"reason\":\"unknown\"}"
        worst=1
        continue
    fi

    # THE MANAGER CANNOT REBUILD ITSELF FROM INSIDE: compose stops the container
    # running this script between the stop and the start, and the bench is left
    # with DockTor Exited (137) and a `<id>_DockTor` stuck in Created. So from
    # inside, the rebuild is HANDED OFF to a detached sibling off the manager's
    # own image — panic.sh's pattern — which runs the checkout's
    # `manager.sh up` (build, then recreate) and outlives the swap. From a host
    # terminal there is nothing to detach from and the loop below does it.
    if [ -f /.dockerenv ] && { [ "$container" = "$MANAGER_CONTAINER" ] \
        || [ "$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null)" = "/$MANAGER_CONTAINER" ]; }; then
        manager_script="$MANAGEMENT_SCRIPTS_DIR/manager.sh"
        case "$MANAGEMENT_SCRIPTS_DIR" in
            /app/*)
                from_checkout="$REPO_ROOT/${MANAGEMENT_SCRIPTS_DIR#/app/}/manager.sh"
                [ -f "$from_checkout" ] && manager_script="$from_checkout"
                ;;
        esac
        # No checkout bound means nothing to build from: refuse, as before.
        if [ ! -f "$manager_script" ] || [ ! -d "$DOCKERS_DIR" ]; then
            log_error "Refusing to rebuild $MANAGER_CONTAINER: no checkout is bound here to build it from."
            echo "  From a host terminal:  ./APK:PODS/Docktor/K8/manager.sh up"
            announce CONTAINER_REBUILD_REFUSED "{\"container\":\"$container\",\"reason\":\"no_checkout\"}"
            worst=3
            continue
        fi
        rebuild_container="${MANAGER_CONTAINER}-Self-Rebuild"
        log_step "Handing the $MANAGER_CONTAINER rebuild to a detached sibling ($rebuild_container)"
        docker rm -f "$rebuild_container" >/dev/null 2>&1 || true
        # --mount, NEVER -v: repo paths carry colons. --network host to match
        # the manager. No --rm, so `docker logs` still answers after the swap.
        if docker run -d \
                --name "$rebuild_container" \
                --network host \
                --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
                --mount "type=bind,source=$REPO_ROOT,target=$REPO_ROOT" \
                --workdir "$REPO_ROOT" \
                --env APKAUDIO_REPO="$REPO_ROOT" \
                --env APKAUDIO_UID="${APKAUDIO_UID:-}" \
                --env APKAUDIO_GID="${APKAUDIO_GID:-}" \
                --env APKAUDIO_NO_OPEN=1 \
                "$MANAGER_IMAGE" \
                bash "$manager_script" up >/dev/null 2>&1; then
            announce CONTAINER_REBUILD_HANDOFF "{\"container\":\"$container\",\"helper\":\"$rebuild_container\",\"image\":\"$MANAGER_IMAGE\"}"
            echo ""
            echo "🩺 $MANAGER_CONTAINER REBUILD HANDED OFF to $rebuild_container."
            echo "   It builds the new image first; if the build fails, the old $MANAGER_CONTAINER keeps running."
            echo "   When it swaps, THIS TAB GOES DARK FOR A MOMENT — reload and it is the new one."
            echo "   Watch it with:  docker logs -f $rebuild_container"
            continue
        fi
        log_error "Could not start $rebuild_container from $MANAGER_IMAGE — nothing was touched."
        announce CONTAINER_REBUILD_HANDOFF_FAILED "{\"container\":\"$container\",\"helper\":\"$rebuild_container\",\"image\":\"$MANAGER_IMAGE\"}"
        worst=3
        continue
    fi

    project="$(label_of "$container" com.docker.compose.project)"
    service="$(label_of "$container" com.docker.compose.service)"
    config_files="$(label_of "$container" com.docker.compose.project.config_files)"
    working_dir="$(label_of "$container" com.docker.compose.project.working_dir)"

    # A container docker run created by hand has no service to build and no
    # file to build it from. Say so rather than guessing at a compose file.
    if [ -z "$project" ] || [ -z "$service" ] || [ -z "$config_files" ]; then
        log_error "$container was not created by compose — there is no compose service to rebuild."
        log_warn  "Use restart.sh to bounce it, or rebuild whatever image it runs by hand."
        announce CONTAINER_REBUILD_FAILED "{\"container\":\"$container\",\"reason\":\"not_compose\"}"
        worst=1
        continue
    fi

    # The label is a comma-separated list in the order compose was given them,
    # and the order matters: later files override earlier ones.
    compose=("${COMPOSE_BASE[@]}")
    missing=""
    IFS=',' read -ra files <<< "$config_files"
    for file in "${files[@]}"; do
        file="${file#"${file%%[![:space:]]*}"}"   # ltrim
        file="${file%"${file##*[![:space:]]}"}"   # rtrim
        [ -z "$file" ] && continue
        if [ ! -f "$file" ]; then
            missing="$file"
            break
        fi
        compose+=(-f "$file")
    done

    # Inside the manager this is the bind spelling going wrong, not a deleted
    # file: the checkout is mounted at the host own path precisely so a label
    # written by the daemon resolves in here too.
    if [ -n "$missing" ]; then
        log_error "$container names a compose file that is not here: $missing"
        announce CONTAINER_REBUILD_FAILED "{\"container\":\"$container\",\"reason\":\"config_missing\",\"path\":\"$missing\"}"
        worst=1
        continue
    fi

    compose+=(-p "$project")
    # Relative build contexts and env_file paths resolve against this; the
    # default (the first compose file directory) is only right by accident.
    [ -n "$working_dir" ] && compose+=(--project-directory "$working_dir")

    log_step "Rebuilding $container (service '$service' in project '$project')"
    announce COMPOSE_RUN "{\"action\":\"build\",\"container\":\"$container\",\"project\":\"$project\",\"services\":\"$service\"}"

    if ! "${compose[@]}" build "$service"; then
        status=$?
        log_error "$container: build failed (exit $status). The old container is untouched and still running."
        announce COMPOSE_RESULT "{\"action\":\"build\",\"container\":\"$container\",\"exit_code\":$status}"
        worst=$status
        continue
    fi

    "${compose[@]}" up -d "$service"
    status=$?
    announce COMPOSE_RESULT "{\"action\":\"build+up\",\"container\":\"$container\",\"exit_code\":$status}"
    if [ $status -ne 0 ]; then
        log_error "$container: rebuilt, but the replacement would not come up (exit $status)."
        worst=$status
        continue
    fi

    built=1
    log_info "$container rebuilt and running."
    announce CONTAINER_REBUILT "{\"container\":\"$container\",\"project\":\"$project\",\"service\":\"$service\"}"
done

# ONCE, AFTER THE LOOP, and only if something was actually built: a sweep
# between two containers would throw away the base layers the second one is
# about to reuse.
[ $built -eq 1 ] && clean_build_cache "the container rebuild"

exit $worst
