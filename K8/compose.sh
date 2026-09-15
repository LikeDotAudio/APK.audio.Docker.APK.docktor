#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🧰 The escape hatch: any compose action, against one stack or all.
#   ./compose.sh both logs -f
#   ./compose.sh core ps            ./compose.sh nmos ps
#   ./compose.sh ember logs -f      ./compose.sh node exec baremetal bash
#   ./compose.sh netbox exec netbox-postgres psql -U netbox
# The verbs beside this file have a policy attached (an order, a gate, an
# eviction). This one has none — that is its job.
# It still resolves the compose command and every project file from _common.sh,
# so an ad-hoc call cannot get the array-versus-string quoting wrong or forget
# a project.
# `both` (synonym `all`) follows for_each_stack rather than freezing at the two
# stacks that existed when the word was chosen.
# UP-SHAPED ACTIONS GET NO PORT EVICTION HERE — use up.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TARGET="${1:-}"; shift || true

case "$TARGET" in
    core)      "${COMPOSE_CORE[@]}" "$@";;
    node)      "${COMPOSE_NODE[@]}" "$@";;
    mqtt)      "${COMPOSE_MQTT[@]}" "$@";;
    portal)    "${COMPOSE_PORTAL[@]}" "$@";;
    nmos)      "${COMPOSE_NMOS[@]}" "$@";;
    aes70)     "${COMPOSE_AES70[@]}" "$@";;
    netbox)    "${COMPOSE_NETBOX[@]}" "$@";;
    ember)     "${COMPOSE_EMBER[@]}" "$@";;
    logger)    "${COMPOSE_LOGGER[@]}" "$@";;
    both|all)  for_each_stack forward "$@";;
    *)
        log_error "usage: compose.sh {logger|core|mqtt|portal|nmos|aes70|ember|netbox|node|both} <compose args...>"
        exit 2
        ;;
esac
