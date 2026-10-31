#!/bin/bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
#
# 🏷  naming.sh — every folder under PODS/ fits the POD.task pattern, and no
#    loose file sits in a root folder. Prints each violation and exits 1 if any.
#
#   PODS/                      POD.<pod>/ folders and README.md, nothing else
#   PODS/POD.<pod>/            GROUP.name stacks, one-word GROUP folders, Docker/,
#                              Documentation/ (a wiki — see .apk.scripts/wiki.py)
#   <GROUP>/ (a group folder)  GROUP.name stacks or one-word sub-groups; files:
#                              README.md, and display.json / manifest.json /
#                              families.json where code reads one at that root
#   GROUP.name/ (a stack)      any folders (its own source). A CONTAINER stack —
#                              one with Docker/ or SRC/ — keeps no loose files
#                              but README.md, LICENSE*, the dotfiles git and
#                              docker need, and display.json (the launcher's
#                              walk_project() reads it at the stack root and
#                              stops there). A check script lives in SRC/
#                              (SRC/check.sh), never at the stack root.
#                              An app stack (a Softapp: display.json + index.html,
#                              or + the `entry` its display.json names, at its
#                              root) is its own content.
#
# NAMED EXCEPTIONS (OWN_CONTENT below) are stacks with a Docker/ that are not
# container stacks, each with its reason; add one only with the reason.
#
# A stack is anything spelled GROUP.name: an UPPERCASE group word, a dot, and a
# name with no spaces or colons (`PLUGIN.DANTE`, `DATABASE.server.SQL`,
# `AUDIO.reader`). A group is one word with no dot (`PLUGINS`, `INSTRUMENTS`).
# A leading `_` marks a support folder a group keeps for itself (`_datasets`).
#
# OUT OF SCOPE ON PURPOSE: POD.THIN/OS/ — its folders are the window titles the
# shell shows ("Apple TV", "Bare Metal"), read straight off the directory.
#
# Usage: naming.sh [PODS-dir]      (default: the PODS this file lives under)
# It then runs plugin-includes.sh (the engine include list vs PLUGINS/).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PODS_DIR="${1:-$(cd "$HERE/../../.." && pwd -P)}"

python3 - "$PODS_DIR" <<'PY'
import json, os, re, sys

PODS = sys.argv[1]
POD = re.compile(r'^POD\.[A-Za-z][A-Za-z0-9_-]*$')
STACK = re.compile(r'^[A-Z][A-Z0-9_]*(\.[A-Za-z0-9][A-Za-z0-9_+-]*)+$')
GROUP = re.compile(r'^[A-Za-z][A-Za-z0-9_]*$')
SUPPORT = re.compile(r'^_[A-Za-z0-9_]+$')
ROLE = {'Docker', 'SRC', 'Documentation'}
SKIP = {'.git', 'node_modules', '__pycache__', 'target'}
OUT_OF_SCOPE = {os.path.join('POD.THIN', 'OS')}
# A stack that has Docker/ but is NOT a container stack, so its root is its own
# content — each with the reason (and the SDK checklist exception it mirrors).
OWN_CONTENT = {
    # WB-01/CC-03 exception: a static build input, not a container stack. The app
    # (src/, server/, package.json, vite.config.ts) stays at the repo root because
    # it deploys standalone to spog.like.audio by its own GitHub workflows; its
    # Docker/ holds only dist.Dockerfile, which WEB.Frontend-Assets builds as the
    # spog-dist context. It runs no service of its own.
    os.path.join('POD.THIN', 'WEB.SPOG'),
}
STACK_FILES = re.compile(r'^(README\.md|display\.json|LICENSE(\.md|\.txt)?|\.git|\.gitignore|\.gitmodules|\.gitattributes|\.dockerignore)$')

# A group root holds README.md and, where code reads one there, its contract:
# display.json (the OS shell's group tile), manifest.json (the bench family
# declarations the orchestrator merges across template roots) or families.json
# (INSTRUMENTS' family-to-folder rule, read by WEB.OsApi SRC/os_roots.py).
GROUP_FILES = re.compile(r'^(README\.md|display\.json|manifest\.json|families\.json)$')
GROUP_REPO_FILES = re.compile(GROUP_FILES.pattern[:-2] + r'|\.git|\.gitignore|\.gitmodules|\.gitattributes)$')

bad = []


def entries(path):
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return [], []
    dirs = [n for n in names if os.path.isdir(os.path.join(path, n)) and n not in SKIP]
    files = [n for n in names if not os.path.isdir(os.path.join(path, n))]
    return dirs, files


def loose(path, files, allowed):
    for f in files:
        if not allowed.match(f):
            bad.append(f'loose file   {os.path.relpath(os.path.join(path, f), PODS)}')


def group(path):
    """A pod or a group folder: stacks, sub-groups, a Docker/ role folder."""
    rel = os.path.relpath(path, PODS)
    if rel in OUT_OF_SCOPE:
        return
    dirs, files = entries(path)
    # Two names equal but for case collide on a case-insensitive checkout (macOS,
    # Windows): one overwrites the other, or the submodule clone fails.
    seen = {}
    for n in dirs + files:
        if n.lower() in seen:
            bad.append(f'case clash   {os.path.relpath(os.path.join(path, n), PODS)} vs {seen[n.lower()]}')
        seen.setdefault(n.lower(), n)
    loose(path, files, GROUP_REPO_FILES if os.path.exists(os.path.join(path, '.git')) else GROUP_FILES)
    for d in dirs:
        child = os.path.join(path, d)
        if STACK.match(d):
            stack(child)
        elif d in ROLE or SUPPORT.match(d) or d.startswith('.'):
            continue
        elif GROUP.match(d):
            group(child)
        else:
            bad.append(f'bad name     {os.path.relpath(child, PODS)}')


def declared_entry(path):
    """The root-level file a stack's display.json names as its `entry`, or None
    (WEB.OsApi osapi/apps.py declared_entry_file() opens the app there)."""
    try:
        with open(os.path.join(path, 'display.json'), encoding='utf-8') as fh:
            entry = json.load(fh).get('entry')
    except (OSError, ValueError, AttributeError):
        return None
    if isinstance(entry, str) and '/' not in entry and os.path.isfile(os.path.join(path, entry)):
        return entry
    return None


def stack(path):
    if os.path.relpath(path, PODS) in OWN_CONTENT:
        return
    dirs, files = entries(path)
    # an app stack is its own content, SRC/ or not (TRUNK-CASTER keeps its nested
    # repos in SRC/): a page app (index.html) or a desktop app whose display.json
    # entry sits at the root (CAPTURE.crawler: main.py, also Worker-CRAWLER)
    if 'display.json' in files and ('index.html' in files or declared_entry(path)):
        return
    if 'Docker' in dirs or 'SRC' in dirs:
        loose(path, files, STACK_FILES)


top_dirs, top_files = entries(PODS)
loose(PODS, top_files, re.compile(r'^README\.md$'))
for d in top_dirs:
    if POD.match(d):
        group(os.path.join(PODS, d))
    else:
        bad.append(f'bad name     {d}')

for line in bad:
    print(line)
print(f'{len(bad)} naming violation(s) under {PODS}', file=sys.stderr)
sys.exit(1 if bad else 0)
PY
rc=$?

# THE PLUGIN INCLUDE LIST is checked here too, so the Naming workflow (and any
# hook that runs naming.sh) runs it without a second step: a plugin folder the
# discovery engine never includes is a folder that does nothing (PLAN-3395.01).
bash "$HERE/plugin-includes.sh" "$PODS_DIR" || rc=1
exit $rc
