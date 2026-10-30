#!/bin/bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
#
# 🧩 plugin-includes.sh — the discovery engine's `include:` list and the
#    PLUGINS/ folder agree. Prints each violation and exits 1 if any.
#
# WHY A CHECK AND NOT A GLOB. Compose has no glob `include:`, so
# POD.THICK/DISCOVERY.Engine/Docker/docker-compose.yml names every plugin by
# hand. A plugin folder whose compose file is not on that list never starts,
# and nothing says so (PLAN-3395.01: BLUETOOTH, NDI and SQL sat there). The
# list stays; this is what notices when it and the folder disagree.
#
# THE MARKER. Each PLUGINS/*/Docker/docker-compose.yml says at its top level
#     x-apk-plugin: true            include me — the engine's list must name me
#     x-apk-standalone: "<reason>"  do not include me, and why
# Compose ignores top-level `x-` keys, so the marker costs the file nothing.
# The exclusion is a different key, not `x-apk-plugin: false`, so the card's
# own `grep -q x-apk-plugin` check reads only the files meant to be included.
#
# WHAT FAILS
#   unmarked     neither marker: a new plugin must decide
#   missing      x-apk-plugin: true, and the engine's include: list does not name it
#   unwanted     x-apk-standalone, and the list names it anyway (or both markers)
#   dangling     the list names a path that does not exist
#   no profile   a service in a marked-true file has no `profiles:` — compose
#                starts such a service on EVERY node, whatever role it declared
#                (PLAN-3410.01: DESKTOP_MONITOR ran on headless servers)
#
# Read line by line, not through a YAML library, so it runs wherever bash and
# python3 do (CI, the DockTor image, a bare host).
#
# Usage: plugin-includes.sh [PODS-dir]   (default: the PODS this file lives under)
# naming.sh runs it, so the Naming workflow covers it.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PODS_DIR="${1:-$(cd "$HERE/../../.." && pwd -P)}"

python3 - "$PODS_DIR" <<'PY'
import os, re, sys

PODS = sys.argv[1]
THICK = os.path.join(PODS, 'POD.THICK')
PLUGINS = os.path.join(THICK, 'PLUGINS')
ENGINE = os.path.join(THICK, 'DISCOVERY.Engine', 'Docker', 'docker-compose.yml')
rel = lambda p: os.path.relpath(p, os.path.dirname(PODS))

bad = []

def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()

if not os.path.isfile(ENGINE):
    print(f'❌ no engine compose file at {rel(ENGINE)}')
    sys.exit(1)

# The engine's include: list, each `- path: "…"` resolved against the engine file.
base = os.path.dirname(ENGINE)
included = set()
for m in re.finditer(r'^\s*-\s*path:\s*["\']?([^"\'\n]+?)["\']?\s*$', read(ENGINE), re.M):
    p = os.path.normpath(os.path.join(base, m.group(1)))
    if not os.path.isfile(p):
        bad.append(f'dangling    {rel(ENGINE)} includes {m.group(1)}, which does not exist')
    included.add(p)


def services_without_profile(text):
    """Service names under the top-level `services:` that carry no `profiles:`."""
    out, svc, has, inside = [], None, False, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if re.match(r'^\S', line):                      # a top-level key
            if inside and svc and not has:
                out.append(svc)
            inside, svc, has = line.startswith('services:'), None, False
            continue
        if not inside:
            continue
        m = re.match(r'^  ([A-Za-z0-9_.-]+):\s*$', line)  # a service
        if m:
            if svc and not has:
                out.append(svc)
            svc, has = m.group(1), False
        elif re.match(r'^    profiles:', line):
            has = True
    if inside and svc and not has:
        out.append(svc)
    return out


for name in sorted(os.listdir(PLUGINS)):
    f = os.path.join(PLUGINS, name, 'Docker', 'docker-compose.yml')
    if not os.path.isfile(f):
        continue
    text = read(f)
    m = re.search(r'^x-apk-plugin:\s*(\S+)', text, re.M)
    mark = m.group(1).lower() if m else None
    standalone = re.search(r'^x-apk-standalone:\s*\S', text, re.M)
    p = os.path.normpath(f)
    if standalone:
        if mark is not None:
            bad.append(f'unwanted    {rel(f)} carries both x-apk-plugin and x-apk-standalone')
        elif p in included:
            bad.append(f'unwanted    {rel(f)} is x-apk-standalone but {rel(ENGINE)} includes it')
    elif mark is None:
        bad.append(f'unmarked    {rel(f)} — add `x-apk-plugin: true` (include me) or `x-apk-standalone: "<why not>"`')
    elif mark == 'true':
        if p not in included:
            bad.append(f'missing     {rel(f)} is x-apk-plugin: true but {rel(ENGINE)} does not include it')
        for svc in services_without_profile(text):
            bad.append(f'no profile  {rel(f)} service `{svc}` — it would start on every node')
    else:
        bad.append(f'unmarked    {rel(f)} — x-apk-plugin is `{mark}`; it is `true`, or the file says x-apk-standalone')

if bad:
    print('\n'.join(bad))
    print(f'❌ {len(bad)} plugin include problem(s)')
    sys.exit(1)
print(f'✅ the engine include list and PLUGINS/ agree ({len(included)} included)')
PY
