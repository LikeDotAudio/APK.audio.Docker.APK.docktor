# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📍 Where everything is. Four paths, resolved once, imported everywhere.

OWNS locations, and the brand accent read out of one of them. It holds NO
compose file path and no port — those live in `docker scripts/_common.sh`, the
only copy of them.
The deepest module in the package: it imports nothing of ours, so everything
else can import it without a cycle.
"""

import os
import json

# FOUR levels up from this file is APK:PODS/ (in the manager image it is the
# in-image /app/APK:DOCKERS/). The rungs are named rather than counted:
#   APK:PODS/                             DOCKERS_DIRECTORY
#     Docktor/                            MANAGEMENT_DIRECTORY
#       Docker/  docker-compose.manager.yml, Dockerfile.manager
#       SRC/                              SOURCE_DIRECTORY
#         docker scripts/                 every verb, one file each
#         manager/                        MANAGER_PACKAGE — this file
# SOURCE_DIRECTORY EXISTS SO NOBODY COUNTS `..` AT A CALL SITE: when the SRC/
# split landed MANAGEMENT_DIRECTORY silently became SRC/, so consumers wanting
# `docker scripts/` kept working while consumers wanting the stack root got an
# answer one rung down and the compose glob came back empty.
# The entry script computes the same thing from its own location; the two agree
# by both walking from a __file__ rather than by either being told.
MANAGER_PACKAGE = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIRECTORY = os.path.dirname(MANAGER_PACKAGE)
MANAGEMENT_DIRECTORY = os.path.dirname(SOURCE_DIRECTORY)
DOCKERS_DIRECTORY = os.path.dirname(MANAGEMENT_DIRECTORY)
# DOCKTOR_DOCKERS_DIR wins when it names a real folder — the standalone image
# lives at /app/docktor, where the walk above lands on /app.
if os.path.isdir(os.environ.get('DOCKTOR_DOCKERS_DIR') or ''):
    DOCKERS_DIRECTORY = os.path.abspath(os.environ['DOCKTOR_DOCKERS_DIR'])
# DockTor filed INSIDE a pod (SUPPORT.pod/Docker.Backend.DockTor): the parent
# is the pod, and the estate holding every pod is one rung further up.
elif DOCKERS_DIRECTORY.endswith('.pod'):
    DOCKERS_DIRECTORY = os.path.dirname(DOCKERS_DIRECTORY)
REPOSITORY_ROOT = os.path.abspath(os.path.join(DOCKERS_DIRECTORY, '..'))

# `pods` or `apk` — the same test _common.sh makes. In a `pods` estate the
# APK.audio manager file (docker-compose.manager.yml, project `apk-audio`) is
# not a stack: nothing drives it, and counting it made every apk-audio
# container on a shared host read as ours. The readers skip what this names.
import glob as _glob
ESTATE_LAYOUT = ('pods' if not _glob.glob(os.path.join(DOCKERS_DIRECTORY, 'POD:*'))
                 and _glob.glob(os.path.join(DOCKERS_DIRECTORY, '*.pod')) else 'apk')
# The estate's own settings, read the way _common.sh reads them: DOCKTOR_* keys
# only, never over a value already in the environment. Here too, because a
# DockTor started from a terminal (bin/docktor serve) never sources _common.sh.
if ESTATE_LAYOUT == 'pods':
    try:
        with open(os.path.join(DOCKERS_DIRECTORY, 'docktor.env'), encoding='utf-8') as _settings:
            for _line in _settings:
                _key, _sep, _value = _line.split('#', 1)[0].strip().partition('=')
                if _sep and _key.startswith('DOCKTOR_') and _key not in os.environ:
                    os.environ[_key] = _value.strip().strip('"')
    except OSError:
        pass

# DOCKTOR_APK_INTEGRATIONS=off — the estate is not APK.audio: no broker
# discovery out of APK:BareMetal, no chat onto the APK.audio bus on 1883, no
# APK.audio pre-build gates, no .apk.skills synch. Each of those only ever
# reported that its APK.audio half was missing. On unless an estate says off.
APK_INTEGRATIONS = os.environ.get('DOCKTOR_APK_INTEGRATIONS', 'on').lower() not in ('off', '0', 'false', 'no')

if ESTATE_LAYOUT == 'pods' and not os.environ.get('DOCKTOR_IGNORE_COMPOSE'):
    os.environ['DOCKTOR_IGNORE_COMPOSE'] = os.pathsep.join(
        _glob.glob(os.path.join(DOCKERS_DIRECTORY, '*', 'Docker', 'docker-compose.manager.yml'))
        + _glob.glob(os.path.join(DOCKERS_DIRECTORY, '*', '*', 'Docker', 'docker-compose.manager.yml')))

# The backend scripts for K8 / Kubernetes container management live in `Docktor/K8`.
K8_SCRIPTS_DIRECTORY = os.path.join(MANAGEMENT_DIRECTORY, 'K8')
if not os.path.isdir(K8_SCRIPTS_DIRECTORY):
    K8_SCRIPTS_DIRECTORY = os.path.join(SOURCE_DIRECTORY, 'docker scripts')
DOCKER_SCRIPTS_DIRECTORY = K8_SCRIPTS_DIRECTORY

# NO COMPOSE FILE PATHS HERE — they live in `docker scripts/_common.sh` beside
# us and nowhere else, with the projects rule, the ordering and the UID/GID.

# The bare-metal SOURCE tree, and it is the stack SRC/ rather than the stack
# root. Needed for the two things that are NOT docker: the brand token below,
# and the broker-discovery module the MQTT broadcast imports.
# ⚠️ Both degrade QUIETLY when this is wrong (discovery falls back to loopback
#    inside an except), so a stale spelling costs a broker list without ever
#    costing an error message. The brand token below is read WITHOUT a fallback
#    precisely so this rung cannot go wrong in silence.
def _find_first_existing_file(candidates):
    for c in candidates:
        if os.path.exists(c):
            return c
    return candidates[0]

def _find_first_existing_dir(candidates):
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[0]

BAREMETAL_SRC_CANDIDATES = [
    os.path.join(DOCKERS_DIRECTORY, 'POD:APK', 'APK:BareMetal', 'SRC'),
    os.path.join(DOCKERS_DIRECTORY, 'POD:APK', 'APK:BareMetal'),
    os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal', 'SRC'),
    os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal'),
]
BAREMETAL_ROOT = _find_first_existing_dir(BAREMETAL_SRC_CANDIDATES)

# THE CONTRACTS MOVED UP TO THE CHECKOUT ROOT and this list did not follow, so
# the open() below raised at IMPORT — not a missing accent, a package that
# could not be imported at all, and with it the server, the CLI and every verb.
# The root spelling is FIRST because that is where the tree keeps contracts now;
# the two BareMetal spellings stay for a checkout that still carries its own.
BRAND_TOKENS_CANDIDATES = [
    os.path.join(REPOSITORY_ROOT, 'contracts', 'tokens', 'brand.json'),
    os.path.join(DOCKERS_DIRECTORY, 'POD:APK', 'APK:BareMetal', 'contracts', 'tokens', 'brand.json'),
    os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal', 'contracts', 'tokens', 'brand.json'),
]
# DOCKTOR_BRAND_TOKENS names the file outright, ahead of every spelling above.
if os.environ.get('DOCKTOR_BRAND_TOKENS'):
    BRAND_TOKENS_CANDIDATES.insert(0, os.environ['DOCKTOR_BRAND_TOKENS'])
BRAND_TOKENS = _find_first_existing_file(BRAND_TOKENS_CANDIDATES)

# AN ESTATE THAT IS NOT APK.audio HAS NO brand.json AT ALL, and raising here
# took the whole package down with it. It still does not go wrong in silence:
# the fallback accent is said on stderr, once, at import, naming every path.
DEFAULT_ACCENT = '#3b82f6'
try:
    with open(BRAND_TOKENS, encoding='utf-8') as _tokens:
        ACCENT = json.load(_tokens)['accent']['hex']
except (OSError, ValueError, KeyError, TypeError) as _error:
    import sys
    sys.stderr.write('DockTor: no brand accent (%s); using %s. Looked in: %s\n'
                     % (_error, DEFAULT_ACCENT, ', '.join(BRAND_TOKENS_CANDIDATES)))
    ACCENT = DEFAULT_ACCENT
