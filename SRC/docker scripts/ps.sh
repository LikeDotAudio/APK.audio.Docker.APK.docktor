#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📋 One snapshot of every container.
#   ./ps.sh
# TAB rows, no header: NAME STATUS PORTS IMAGE NETWORK_MODE PROJECT
# PROJECT is docker own com.docker.compose.project label, empty for a container
# nothing composed. A label recorded at creation survives a rename; the
# hand-written substring net it replaced did not.
# TWO docker calls, never one per container — a per-container call turned a
# dashboard refresh into one process spawn per card.
# NETWORK_MODE is a separate call (docker ps --format has no placeholder) and is
# not cosmetic: the BareMetal node runs network_mode: host, so it publishes no
# ports and a reader judging health by the Ports column calls it broken.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

listing="$(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}')" || exit 1
[ -z "$listing" ] && exit 0

names=()
while IFS= read -r row; do
    [ -z "$row" ] && continue
    names+=("${row%%$'\t'*}")
done <<< "$listing"

# {{.Name}} comes back with a leading slash; strip it so the caller joins on the
# same spelling docker ps gave it.
modes="$(docker inspect --format '{{.Name}}	{{.HostConfig.NetworkMode}}' "${names[@]}" 2>/dev/null)"

# Both halves travel as ENVIRONMENT: `python3 - <<PY` IS already a stdin
# redirection, so a second one replaces the program with the data.
LISTING="$listing" MODES="$modes" python3 - <<'PY'
import os

modes = {}
for line in (os.environ.get("MODES") or "").splitlines():
    if "\t" in line:
        name, mode = line.split("\t", 1)
        modes[name.lstrip("/")] = mode.strip()

for row in (os.environ.get("LISTING") or "").splitlines():
    if not row:
        continue
    fields = (row.split("\t") + [""] * 5)[:5]
    # NETWORK_MODE is inserted BEFORE the project, so the five fields the
    # previous contract promised keep their positions.
    print("\t".join(fields[:4] + [modes.get(fields[0], ""), fields[4]]))
PY
