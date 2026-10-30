#!/bin/bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
#
# 🧩 new-plugin.sh NAME ROLE [--dry-run] — a new Generation B plugin, from the template (PLAN-3411.01).
#
#   new-plugin.sh ZZTEST discovery --dry-run    print every file it would create and every edit, change nothing
#   new-plugin.sh ZZTEST discovery              do it
#
# WHAT IT DOES. Copies PODS/POD.THICK/PLUGINS/_template to PLUGINS/PLUGIN.<NAME>,
# replacing the three placeholders in every path and file:
#     PLUGINNAME  -> NAME              (stack, container Plugin-NAME)
#     pluginname  -> name, lowercased  (bus token, crate apkaudio-name, bin apk-name)
#     pluginrole  -> ROLE              (the compose profile: which node role starts it)
# then, in a real run only:
#   1. creates the PRIVATE GitHub repository <owner>/APK.plugin.<ROLE>.<NAME>
#      (owner read off DISCOVERY.Engine's origin, not typed here) and pushes the copy;
#   2. `git submodule add`s it at PODS/POD.THICK/PLUGINS/PLUGIN.<NAME>;
#   3. adds its compose file to DISCOVERY.Engine/Docker/docker-compose.yml's include:,
#      `members/PLUGIN.<NAME>` to the engine's Cargo members with the link beside it
#      (DISCOVERY.Engine/SRC/members/, PLAN-3397.01), and the crate to Cargo.lock
#      (`cargo update --workspace`, which touches workspace members only);
#   4. runs plugin-includes.sh, which must pass.
# It commits nothing in the superproject or the engine: it prints the two commits.
#
# Those three engine edits are the five-file step PLAN-3395/3396 shrank: the
# Dockerfile and DockTor need none (the Dockerfile COPYs PLUGINS/ whole, and
# DockTor reads the plugin's own labels).
#
# THE ROLE IS A PROFILE. The known ones are read off the plugins that exist,
# not listed here; a new one is allowed and said so — it starts nowhere until
# a node's COMPOSE_PROFILES names it.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"

python3 - "$REPO_ROOT" "$@" <<'PY'
import os, re, shutil, subprocess, sys, tempfile

root, args = sys.argv[1], sys.argv[2:]
dry = '--dry-run' in args
pos = [a for a in args if a != '--dry-run']
if len(pos) != 2:
    sys.exit('usage: new-plugin.sh NAME ROLE [--dry-run]   e.g. new-plugin.sh ZZTEST discovery --dry-run')
name, role = pos
if not re.fullmatch(r'[A-Z][A-Z0-9_]*', name):
    sys.exit(f'NAME is UPPER_SNAKE (PING, SOUNDCARD_IN), not {name!r}')
if not re.fullmatch(r'[a-z][a-z0-9_-]*', role):
    sys.exit(f'ROLE is a lowercase compose profile (discovery, l2, control), not {role!r}')
token = name.lower()

THICK = os.path.join(root, 'PODS', 'POD.THICK')
PLUGINS = os.path.join(THICK, 'PLUGINS')
TEMPLATE = os.path.join(PLUGINS, '_template')
ENGINE = os.path.join(THICK, 'DISCOVERY.Engine')
COMPOSE = os.path.join(ENGINE, 'Docker', 'docker-compose.yml')
CARGO = os.path.join(ENGINE, 'SRC', 'Cargo.toml')
MEMBERS = os.path.join(ENGINE, 'SRC', 'members')
stack = f'PLUGIN.{name}'
dest = os.path.join(PLUGINS, stack)
rel = lambda p: os.path.relpath(p, root)

if not os.path.isdir(TEMPLATE):
    sys.exit(f'no template at {rel(TEMPLATE)}')
if os.path.exists(dest):
    sys.exit(f'{rel(dest)} already exists')

def run(*cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()

origin = run('git', '-C', ENGINE, 'remote', 'get-url', 'origin')
owner = re.search(r'github\.com[:/]([^/]+)/', origin).group(1)
repo = f'APK.plugin.{role}.{name}'
url = f'https://github.com/{owner}/{repo}'

# Known roles: every profile some plugin's compose file already uses.
known = set()
for d in os.listdir(PLUGINS):
    f = os.path.join(PLUGINS, d, 'Docker', 'docker-compose.yml')
    if d.startswith('_') or not os.path.isfile(f):
        continue
    for m in re.finditer(r'^\s*profiles:\s*\[([^\]]*)\]', open(f, encoding='utf-8').read(), re.M):
        known.update(p.strip() for p in m.group(1).split(',') if p.strip())

SUBST = (('PLUGINNAME', name), ('pluginname', token), ('pluginrole', role))
def sub(text):
    for a, b in SUBST:
        text = text.replace(a, b)
    return text

SKIP = {'target', '__pycache__', 'Cargo.lock'}
files = []
for d, dirs, names in os.walk(TEMPLATE):
    dirs[:] = sorted(x for x in dirs if x not in SKIP)
    for n in sorted(names):
        if n in SKIP:
            continue
        src = os.path.join(d, n)
        files.append((src, sub(os.path.relpath(src, TEMPLATE))))

# The two engine edits, computed now so a dry run shows them exactly.
include = f'  - path: "../../PLUGINS/{stack}/Docker/docker-compose.yml"'
ctext = open(COMPOSE, encoding='utf-8').read()
paths = list(re.finditer(r'^\s*-\s*path:.*$', ctext, re.M))
if not paths:
    sys.exit(f'no include: list in {rel(COMPOSE)}')
new_compose = ctext[:paths[-1].end()] + '\n' + include + ctext[paths[-1].end():]
member = f'    "members/{stack}",'
mtext = open(CARGO, encoding='utf-8').read()
mm = re.search(r'^\s*members\s*=\s*\[.*?^\]', mtext, re.M | re.S)
if not mm:
    sys.exit(f'no members = [ … ] in {rel(CARGO)}')
new_cargo = mtext[:mm.end() - 1] + member + '\n' + mtext[mm.end() - 1:]
link_target = os.path.relpath(os.path.join(dest, 'SRC'), MEMBERS)

print(f'🧩 {stack}: token `{token}`, crate apkaudio-{token}, bin apk-{token}, container Plugin-{name}, profile `{role}`')
if role not in known:
    print(f'   ℹ️  `{role}` is a NEW profile (known: {", ".join(sorted(known))}) — no node starts it until COMPOSE_PROFILES names it')
print(f'   files it {"would create" if dry else "creates"} under {rel(dest)}/:')
for _, out in files:
    print(f'     {out}')
print(f'   {"would " if dry else ""}create private repository {owner}/{repo} and `git submodule add {url} {rel(dest)}`')
print(f'   {"would " if dry else ""}edit {rel(COMPOSE)}: + {include.strip()}')
print(f'   {"would " if dry else ""}edit {rel(CARGO)}: + {member.strip()}  (link members/{stack} -> {link_target})')
print(f'   {"would " if dry else ""}add apkaudio-{token} to {rel(os.path.join(ENGINE, "SRC", "Cargo.lock"))} (cargo update --workspace --offline)')
if dry:
    sys.exit(0)

# ── for real ───────────────────────────────────────────────────────────────
work = tempfile.mkdtemp(prefix='apk-new-plugin-')
for src, out in files:
    target = os.path.join(work, out)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    try:
        text = open(src, encoding='utf-8').read()
    except UnicodeDecodeError:
        shutil.copy2(src, target)
        continue
    with open(target, 'w', encoding='utf-8') as f:
        f.write(sub(text))
    shutil.copymode(src, target)
run('git', 'init', '-q', '-b', 'main', cwd=work)
run('git', 'add', '-A', cwd=work)
run('git', 'commit', '-q', '-m', f'{stack}: made from PODS/POD.THICK/PLUGINS/_template by new-plugin.sh (PLAN-3411.01)', cwd=work)
run('gh', 'repo', 'create', f'{owner}/{repo}', '--private', '--source', work, '--remote', 'origin', '--push')
print(f'   ✅ {url} created and pushed')
run('git', '-C', root, 'submodule', 'add', '-b', 'main', url, rel(dest))
print(f'   ✅ submodule {rel(dest)}')
with open(COMPOSE, 'w', encoding='utf-8') as f:
    f.write(new_compose)
with open(CARGO, 'w', encoding='utf-8') as f:
    f.write(new_cargo)
os.makedirs(MEMBERS, exist_ok=True)
os.symlink(link_target, os.path.join(MEMBERS, stack))
subprocess.run(['cargo', 'update', '--workspace', '--offline', '--manifest-path', CARGO], check=True)
print('   ✅ engine include, member, link and lockfile')
PY
status=$?
[ $status -ne 0 ] && exit $status
case " $* " in *" --dry-run "*) exit 0 ;; esac
"$HERE/plugin-includes.sh" || exit 1
NAME="$1"
cat <<EOF

Next — commit the two edits it made (it commits nothing itself):
  git -C PODS/POD.THICK/DISCOVERY.Engine add SRC/members/PLUGIN.$NAME && git -C PODS/POD.THICK/DISCOVERY.Engine commit -m "PLUGIN.$NAME: include and member" -- Docker/docker-compose.yml SRC/Cargo.toml SRC/Cargo.lock SRC/members/PLUGIN.$NAME
  git commit -m "PLUGIN.$NAME: new plugin submodule" -- .gitmodules PODS/POD.THICK/PLUGINS/PLUGIN.$NAME PODS/POD.THICK/DISCOVERY.Engine
Then build and start it:
  docker compose -f 'PODS/POD.THICK/DISCOVERY.Engine/Docker/docker-compose.yml' --profile build build
EOF
