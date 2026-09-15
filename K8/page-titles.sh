#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 🏷️ The name each page on this bench calls itself. Fetched once, remembered.
#   ./page-titles.sh                       every browsable endpoint
#   ./page-titles.sh http://localhost:5000 exactly these
#   ./page-titles.sh --remembered          print the cache, touch no network
# TAB rows, no header: URI TITLE SOURCE FETCHED_AT
# SOURCE is live | remembered (the cache answered) | unnamed (it answered with
# no title). A row prints for every URI asked about, whatever happened, so a
# caller can key on what it passed in.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# WHY THIS EXISTS: the dashboard draws a fallback launcher for every published
# port endpoints.sh does not declare, and those read `Open Port 5000`. Six at
# once on the NMOS bench, when every page states its own name in the one place
# HTML has for it (5000 NMOS Tests, 5001 NMOS Controller Testing Façade,
# 3208 🎛️ APK.audio — NMOS Bench).
# REMEMBERED, not just fetched: a title is only readable while the service is UP,
# and the moment an operator needs to know which page a port was is the moment it
# stopped answering.
# ⚠️ IT MUST NOT RENAME A DECLARED ENDPOINT. The endpoints.sh label is a decision
#    and this is an observation, so the caller decides and the dashboard uses
#    this only where the table said nothing.
# The cache is machine state, not a record: what THIS bench answered, with
# wall-clock stamps, and .gitignored for both reasons.
# Below the source line on purpose — check.sh prologue measures the opening
# comment run.
PAGE_TITLE_CACHE="$(dirname "$MANAGEMENT_SCRIPTS_DIR")/page-titles.json"

MODE=probe
if [ "${1:-}" = "--remembered" ]; then
    MODE=remembered
    shift
fi

# The addresses to ask about: those named on the command line, or every
# browsable endpoint. kind == open is the filter — mqtt:// and mysql:// have no
# title, and a GET at a broker port is a protocol error, not a name.
URIS=("$@")
if [ ${#URIS[@]} -eq 0 ]; then
    while IFS=$'\t' read -r _container kind _label uri _state; do
        [ "$kind" = open ] || continue
        case "$uri" in http://*|https://*) URIS+=("$uri") ;; esac
    done < <("$MANAGEMENT_SCRIPTS_DIR/endpoints.sh")
fi

[ ${#URIS[@]} -eq 0 ] && exit 0

# One GET per address into a FILE, not a variable: a NUL byte (any served
# binary, which is what a wrong port gives you) truncates a bash variable
# silently and the extractor would read half a document.
# --max-time 3 because this is on the path a card click takes. -L follows the
# redirect a shell app answers / with; --fail makes a 404 an absence rather than
# an error page whose <title> is "404 Not Found".
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT

if [ "$MODE" = probe ]; then
    index=0
    for uri in "${URIS[@]}"; do
        index=$((index + 1))
        if curl -fsSL --max-time 3 "$uri" -o "$PROBE_DIR/$index.body" 2>/dev/null; then
            printf '%s\n' "$uri" > "$PROBE_DIR/$index.uri"
        else
            rm -f "$PROBE_DIR/$index.body"
        fi
    done
fi

# Merge and print in ONE pass, in python3: the cache is JSON and <title> is not
# a line — it spans lines, carries entities and holds emoji. sed would work on
# the pages that happen to be one line, which is the worst outcome available.
python3 - "$PAGE_TITLE_CACHE" "$MODE" "$PROBE_DIR" "${URIS[@]}" <<'PYTHON'
import html
import json
import os
import re
import sys
import time

cache_path, mode, probe_dir = sys.argv[1], sys.argv[2], sys.argv[3]
uris = sys.argv[4:]

try:
    with open(cache_path, encoding='utf-8') as handle:
        cache = json.load(handle)
except (OSError, ValueError):
    cache = {}

# DOTALL because a <title> is regularly written across three lines, and the open
# tag is attribute-tolerant because a page may put a lang on it.
TITLE = re.compile(r'<title[^>]*>(.*?)</title>', re.IGNORECASE | re.DOTALL)


def title_of(body):
    """The page's own name, collapsed to one line, or '' if it states none."""
    found = TITLE.search(body)
    if not found:
        return ''
    return ' '.join(html.unescape(found.group(1)).split())


rows = []
for index, uri in enumerate(uris, start=1):
    remembered = cache.get(uri, {})
    body_path = os.path.join(probe_dir, f'{index}.body')

    if mode == 'probe' and os.path.exists(body_path):
        # errors=replace, not a decode guess: a page served without a charset
        # is usually UTF-8 and occasionally is not, and a UnicodeError here
        # would take the whole table down over one mis-declared page.
        with open(body_path, encoding='utf-8', errors='replace') as handle:
            title = title_of(handle.read())
        if title:
            cache[uri] = {'title': title, 'fetchedAt': time.time()}
            rows.append((uri, title, 'live', cache[uri]['fetchedAt']))
        else:
            # ANSWERED AND UNNAMED IS NOT UNREACHABLE, and the cache must not
            # be cleared by it — a page can lose its <title> for one deploy.
            rows.append((uri, remembered.get('title', ''), 'unnamed',
                         remembered.get('fetchedAt', 0)))
    elif remembered.get('title'):
        rows.append((uri, remembered['title'], 'remembered',
                     remembered.get('fetchedAt', 0)))
    else:
        rows.append((uri, '', 'unnamed', 0))

if mode == 'probe':
    # Temp file in the same directory then renamed: two dashboards on one bench
    # probe on every card click, and a half-written cache reads back as empty.
    temporary = cache_path + '.partial'
    try:
        with open(temporary, 'w', encoding='utf-8') as handle:
            json.dump(cache, handle, indent=2, sort_keys=True, ensure_ascii=False)
        os.replace(temporary, cache_path)
    except OSError:
        # A cache that cannot be written costs the NEXT run its memory and must
        # not cost THIS one its answer.
        pass

for uri, title, source, fetched_at in rows:
    stamp = (time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(fetched_at))
             if fetched_at else '')
    print(f'{uri}\t{title}\t{source}\t{stamp}')
PYTHON
