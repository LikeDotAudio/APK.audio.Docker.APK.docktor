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

# FOUR levels up from this file is APK:DOCKERS/. The rungs are named rather
# than counted:
#   APK:DOCKERS/                          DOCKERS_DIRECTORY
#     DockTor/                            MANAGEMENT_DIRECTORY
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

# The one place this package spells `docker scripts/`. runner.py runs the files
# in it and api.py reports where it is; both used to join it themselves.
DOCKER_SCRIPTS_DIRECTORY = os.path.join(SOURCE_DIRECTORY, 'docker scripts')

# NO COMPOSE FILE PATHS HERE — they live in `docker scripts/_common.sh` beside
# us and nowhere else, with the projects rule, the ordering and the UID/GID.

# The bare-metal SOURCE tree, and it is the stack SRC/ rather than the stack
# root. Needed for the two things that are NOT docker: the brand token below,
# and the broker-discovery module the MQTT broadcast imports.
# ⚠️ Both degrade QUIETLY when this is wrong (discovery falls back to loopback
#    inside an except), so a stale spelling costs a broker list without ever
#    costing an error message. The brand token below is read WITHOUT a fallback
#    precisely so this rung cannot go wrong in silence.
BAREMETAL_ROOT = os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal', 'SRC')

# The accent is stated once, in contracts, and read here rather than spelled.
# Read at import and DELIBERATELY WITHOUT A FALLBACK: a default would be a
# second spelling of the value and would go on painting the old colour after
# the token moved. This file sits inside the repository that holds the token,
# so an unreadable token is a broken checkout and says so on the first line.
BRAND_TOKENS = os.path.join(BAREMETAL_ROOT, 'contracts', 'tokens', 'brand.json')

with open(BRAND_TOKENS, encoding='utf-8') as _tokens:
    ACCENT = json.load(_tokens)['accent']['hex']
