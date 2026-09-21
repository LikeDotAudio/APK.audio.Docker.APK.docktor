#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧪 Ecosystem verification — what is true about the stack right now.
#   ./verify.sh
# Runs AFTER a mount (test-gates.sh is the pre-build gate). Exit 0 when nothing
# FAILED; warnings do not fail a run.
#   socket silent + container absent  -> WARN ("the stack is down" is an answer)
#   socket silent + container running -> FAIL (compose made it, the process died)
# No port is typed here: addresses come from endpoints.sh.
# Also the only place that asks a RUNNING node whether the hardware overlay
# actually handed it the devices — conditional on the decision, never on the
# hardware, so a bench with no puck is noted, not failed.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

echo "🧪 Running APK.audio Ecosystem Container Verification Tests..."
echo "==============================================================="

passed=0; failed=0; warnings=0

pass() { echo "  ✓ [Pass] $1"; passed=$((passed + 1)); }
fail() { echo "  ✗ [Fail] $1"; failed=$((failed + 1)); }
warn() { echo "  ! [Warn] $1"; warnings=$((warnings + 1)); }
note() { echo "  ℹ $1"; }

# Test 1: the compose CLI. _common.sh already exits without one, so reaching
# this line IS the pass — recorded anyway, or the suite reports one test fewer.
pass "Docker Compose CLI is available (${COMPOSE_BASE[*]})."

# Test 2: every compose project validates. Validating one and mounting eight is
# how a broken BareMetal compose file reached up.
validate_stack() {
    # Status read from the command SUBSTITUTION, not a later $?: an if/else
    # picking which array to run resets $? to the assignment exit code, which
    # is always 0 — so every project validated.
    local label="$1"; shift
    local out status
    out="$("$@" config 2>&1)"; status=$?
    if [ $status -eq 0 ]; then
        pass "Compose project '$label' is valid."
    else
        fail "Compose config validation failed for '$label':"
        echo "$out" | sed 's/^/      /'
    fi
}
validate_stack "apk-audio"          "${COMPOSE_CORE[@]}"
validate_stack "Node-BareMetal" "${COMPOSE_NODE[@]}"
# The other five, since for_each_stack drives them: a compose file this tool
# runs is one it must be able to parse. The two-line version of this list is how
# APK:audio:WebPortal carried a bind mount the daemon refuses.
validate_stack "Server:Broker:MQTT"    "${COMPOSE_MQTT[@]}"
validate_stack "Portal (DATABUS:Broker:MQTT portal-broker)" "${COMPOSE_PORTAL[@]}"
# Not driven by for_each_stack, and still a file `compose.sh plugins` runs.
validate_stack "APK:discovery"         "${COMPOSE_PLUGINS[@]}"
# THE POD ROOT FIRST, because it is what for_each_stack mounts: it `include:`s
# the three below, so it is the one file whose FAILURE stops the pod. The three
# are still validated individually -- an include that parses says nothing about
# whether the child is still mountable on its own, which it must be.
validate_stack "POD:protocols"         "${COMPOSE_PROTOCOLS[@]}"
validate_stack "Server:Discovery:NMOS" "${COMPOSE_NMOS[@]}"
validate_stack "PROTOCOL:DEV:AES70"    "${COMPOSE_AES70[@]}"
validate_stack "DATABASE:server:NETBOX" "${COMPOSE_NETBOX[@]}"
validate_stack "DATABASE:server:SQL"     "${COMPOSE_SQLCLUSTER[@]}"
# PROTOCOL:DEV:EMBER can fail config on the ENVIRONMENT rather than the file: it
# interpolates ${APKAUDIO_REPO:?}. _common.sh exports it, so a failure here
# means the export went away, not that the YAML is wrong.
validate_stack "PROTOCOL:DEV:EMBER"    "${COMPOSE_EMBER[@]}"
# LOGGER STORAGE interpolates ${APKAUDIO_REPO:?} for its bind device, same as Ember.
validate_stack "DATABSE:volume:Log STORAGE" "${COMPOSE_LOGGER[@]}"

# Which node this run validated: validate_stack passes identically whether or
# not COMPOSE_NODE names the hardware overlay, so this reports the decision.
# REPORTED, NOT ASSERTED here, and never counted as pass/fail/warn — a bench
# with no puck must not colour a verify run. The assertion against the running
# container is further down.
node_hardware_report

# Test 3+: EVERY socket the ecosystem declares, taken from endpoints.sh.
# NO PORT NUMBERS HERE. Three were typed (1883, 9001, 3306), all from one of
# eight projects, so a mount where Broker-Mosquitto, Portal-Broker,
# NMOS-Registry, NMOS-Node, Netbox-App and the Ember pair all failed reported
# 0 FAILED, 0 WARNINGS. stacks.sh --report catches a stack entirely gone; it
# cannot catch one where compose created the containers and the process died.
# endpoints.sh reads its rows out of the compose files, so the probe list is a
# QUERY, and what it excludes (NMOS-Sandbox, NMOS-Testing) is already decided.
# The split, state from endpoints.sh (which asked docker), liveness from here:
#     absent  + silent   -> WARN   (the stack is down)
#     running + answers  -> PASS
#     running + silent   -> FAIL   (the mount is broken)
#     absent  + answers  -> WARN   (a stranger holds the port)
# LOOPBACK ROWS ONLY: the `· LAN` macvlan rows are not published host ports and
# black-hole from here by design; endpoints.sh probes those itself.
# THE LABEL IS PRINTED, NEVER THE URI — MariaDB row carries a password, and a
# verification suite is a thing people paste.
endpoints_script="$MANAGEMENT_SCRIPTS_DIR/endpoints.sh"
if [ ! -x "$endpoints_script" ] && [ ! -f "$endpoints_script" ]; then
    # A missing reader is a FAIL, never a skip: a suite that probes nothing
    # prints the same 0 FAILED as one that probed everything.
    fail "endpoints.sh is not at $endpoints_script -- no socket could be probed."
else
    probed=0
    seen_addresses=""
    while IFS=$'\t' read -r container kind label uri state; do
        [ -n "$uri" ] || continue

        # scheme off, userinfo off, path off -- what is left is host:port.
        hostport="${uri#*://}"
        hostport="${hostport##*@}"
        hostport="${hostport%%/*}"
        host="${hostport%:*}"
        port="${hostport##*:}"
        case "$port" in ''|*[!0-9]*) continue;; esac
        case "$host" in localhost|127.0.0.1) ;; *) continue;; esac

        # One probe per ADDRESS, not per row: the portal answers on two rows
        # of 8080 and NetBox on three of 8081 — one socket each.
        case " $seen_addresses " in *" $host:$port "*) continue;; esac
        seen_addresses="$seen_addresses $host:$port"
        probed=$((probed + 1))

        # /dev/tcp is a builtin, so this costs no process per port.
        if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            if [ "$state" = down ]; then
                warn "$container/$label answers on $host:$port but no such container is running."
            else
                pass "$container/$label reachable on $host:$port."
            fi
        elif [ "$state" = down ]; then
            warn "$container/$label ($host:$port) not reachable -- container is not running."
        else
            fail "$container/$label ($host:$port) is not reachable and $container IS running -- the process inside it is not listening."
        fi
    done < <("$endpoints_script" 2>/dev/null)

    if [ "$probed" -eq 0 ]; then
        fail "endpoints.sh named no loopback address -- the port table is empty or docker did not answer."
    else
        note "Probed $probed declared address(es) from endpoints.sh."
    fi
fi

# Then: what is actually up, named against what is expected.
running="$(docker ps --format '{{.Names}}' 2>/dev/null | paste -sd, -)"
note "Running Docker containers: ${running:-None}"
found=()
for expected in Storage-Broker SQL-Proxy SQL-Node-1 SQL-Node-2 SQL-Node-3 Storage-Portal Node-BareMetal; do
    case "${running,,}" in *"${expected,,}"*) found+=("$expected");; esac
done
if [ ${#found[@]} -gt 0 ]; then
    pass "Active APK containers: $(IFS=', '; echo "${found[*]}")"
else
    warn "No APK ecosystem containers active (run Management/APK.audio:mount.sh, or click Remount)."
fi

# Then: the overlay that was NAMED actually reached the node that came up.
# check.sh node-hardware proves COMPOSE_NODE names the overlay when every device
# it declares is present; a file-reading lane cannot ask whether the container
# RECEIVED them, and the original defect was measured at that end
# (HostConfig.Devices: null on a running node with the puck plugged in).
# The overlay can be named, merged, and still yield a node with no devices: a
# services: key that does not match the base name, a devices: list compose
# merges by replacement rather than append, or an agent left off by agents.json.
# CONDITIONAL ON THE DECISION, NEVER ON THE HARDWARE — what is asserted is
# agreement between the decision and the container docker actually has. A node
# that is down is a WARNING.
node_hardware_container="Node-BareMetal"

# The agent switches the overlay flips, read OUT OF THE OVERLAY rather than
# typed here, so a switch added later is asserted with no edit. It lives here
# rather than in _common.sh because that file is sourced by every verb and only
# this suite needs to know which switches the overlay owns.
node_hardware_agents() {
    [ -f "$BAREMETAL_HARDWARE_COMPOSE_FILE" ] || return 0
    awk '
        /^[[:space:]]*environment:[[:space:]]*$/ { in_env = 1; next }
        in_env && /^[[:space:]]*#/               { next }
        in_env && /^[[:space:]]*$/               { next }
        in_env && /^[[:space:]]*-[[:space:]]/    {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            sub(/=.*$/, "", line)
            if (line ~ /^APK_AGENT_/) print line
            next
        }
        in_env                                   { in_env = 0 }
    ' "$BAREMETAL_HARDWARE_COMPOSE_FILE" 2>/dev/null
}

if [ -z "${NODE_HARDWARE_OVERLAY:-}" ]; then
    note "Hardware overlay not engaged (${NODE_HARDWARE_WHY:-no reason recorded}) -- no device assertion made against $node_hardware_container."
elif ! node_running="$(docker inspect --format '{{.State.Running}}' "$node_hardware_container" 2>/dev/null)"; then
    warn "Hardware overlay engaged (${NODE_HARDWARE_WHY}) but there is no $node_hardware_container container to inspect."
elif [ "$node_running" != "true" ]; then
    warn "Hardware overlay engaged (${NODE_HARDWARE_WHY}) but $node_hardware_container is not running."
else
    node_devices_json="$(docker inspect --format '{{json .HostConfig.Devices}}' "$node_hardware_container" 2>/dev/null)"
    node_devices_want="$(node_hardware_devices | grep -c . || true)"
    case "${node_devices_json:-null}" in
        ''|null|'[]')
            # The exact shape a person previously found by hand.
            fail "$node_hardware_container was mounted WITH the hardware overlay and HostConfig.Devices is ${node_devices_json:-empty} -- the overlay was named and the daemon handed over nothing. Expected $node_devices_want device(s) from $BAREMETAL_HARDWARE_COMPOSE_FILE."
            ;;
        *)
            node_devices_got="$(printf '%s' "$node_devices_json" | grep -o '"PathOnHost"' | grep -c . || true)"
            if [ "$node_devices_got" != "$node_devices_want" ]; then
                # A devices: list merged by REPLACEMENT lands here: the
                # container has devices, just not these ones.
                fail "$node_hardware_container has $node_devices_got device(s) and the overlay declares $node_devices_want -- the merge did not append."
            else
                # COUNT ONLY, and it says so: a replacement merge landing the
                # same number of wrong devices passes this and fails the loop
                # below. "Received all the devices" would be a lie here.
                pass "$node_hardware_container carries $node_devices_got device node(s) -- the count the hardware overlay declares."
            fi
            # Named individually as well as counted: a replacement merge with
            # the same COUNT is otherwise indistinguishable.
            while IFS= read -r node_dev; do
                [ -n "$node_dev" ] || continue
                case "$node_devices_json" in
                    *"\"PathOnHost\":\"$node_dev\""*)
                        pass "$node_hardware_container carries $node_dev." ;;
                    *)
                        fail "$node_hardware_container does NOT carry $node_dev, which the hardware overlay declares." ;;
                esac
            done < <(node_hardware_devices)

            # And the switch: a device handed to a container whose agent is
            # off publishes as much as no device. The expected value follows
            # the overlay own ${APK_AGENT_X:-on}, so a bench that exported the
            # switch is held to what it asked for.
            node_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$node_hardware_container" 2>/dev/null)"
            while IFS= read -r node_agent; do
                [ -n "$node_agent" ] || continue
                node_agent_want="${!node_agent:-on}"
                node_agent_got="$(printf '%s\n' "$node_env" | sed -n "s/^$node_agent=//p" | tail -1)"
                if [ -z "$node_agent_got" ]; then
                    fail "$node_hardware_container has no $node_agent in its environment at all -- the overlay's environment block did not reach it."
                elif [ "$node_agent_got" != "$node_agent_want" ]; then
                    fail "$node_hardware_container has $node_agent=$node_agent_got and the engaged overlay asks for $node_agent_want -- agents.json or a stale container won the merge."
                else
                    pass "$node_hardware_container has $node_agent=$node_agent_got."
                fi
            done < <(node_hardware_agents)
            ;;
    esac
fi

# Last: the PHP tier, if its harness is in the checkout. An absent harness and
# a MISSPELLED one are indistinguishable, which is how this whole tier vanished
# from verify without a line of output when the rung moved.
# The comment above turned out to be about ITSELF: the rung moved again with the
# pods, this line did not, and the whole PHP tier went back to being skipped in
# silence. stack_dir() is what finds the stack now, under whichever POD: holds it.
api_tests="$(stack_dir 'DATABASE:server:SQL')/SRC/APK:API/tests/run.sh"
if [ -f "$api_tests" ]; then
    note "Running APK:API integration test script..."
    if out="$( cd "$REPO_ROOT" && bash "$api_tests" 2>&1 )"; then
        pass "APK:API MariaDB & PHP 7.4 integration tests passed."
    else
        warn "APK:API integration tests did not pass:"
        echo "$out" | sed 's/^/      /'
    fi
fi

echo "==============================================================="
echo "📊 Container Test Results: $passed PASSED, $failed FAILED, $warnings WARNINGS"
echo
announce CONTAINER_TESTS "{\"passed\":$passed,\"failed\":$failed,\"warnings\":$warnings}"
[ $failed -eq 0 ]
