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
    # with DockTor Exited (137) and a `<id>_DockTor` stuck in Created. Same rule
    # as up-stack.sh. From a host terminal it is safe.
    if [ -f /.dockerenv ] && { [ "$container" = "$MANAGER_CONTAINER" ] \
        || [ "$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null)" = "/$MANAGER_CONTAINER" ]; }; then
        log_error "Refusing to rebuild $MANAGER_CONTAINER from inside $MANAGER_CONTAINER."
        echo "  It would stop the container running this rebuild halfway through."
        echo "  From a host terminal:  ./APK:PODS/Docktor/K8/manager.sh up"
        announce CONTAINER_REBUILD_REFUSED "{\"container\":\"$container\",\"reason\":\"self\"}"
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
