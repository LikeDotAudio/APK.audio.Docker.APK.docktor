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
REPOSITORY_ROOT = os.path.abspath(os.path.join(DOCKERS_DIRECTORY, '..'))

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

BRAND_TOKENS_CANDIDATES = [
    os.path.join(DOCKERS_DIRECTORY, 'POD:APK', 'APK:BareMetal', 'contracts', 'tokens', 'brand.json'),
    os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal', 'contracts', 'tokens', 'brand.json'),
]
BRAND_TOKENS = _find_first_existing_file(BRAND_TOKENS_CANDIDATES)

with open(BRAND_TOKENS, encoding='utf-8') as _tokens:
    ACCENT = json.load(_tokens)['accent']['hex']
