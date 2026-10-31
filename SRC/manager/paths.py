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

# FIVE levels up from this file is PODS/ (in the manager image, four: the
# in-image /app/APK:DOCKERS/). The rungs are named rather than counted:
#   PODS/                                 DOCKERS_DIRECTORY
#     POD.manager/MANAGER.Docktor/        MANAGEMENT_DIRECTORY
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
# In the checkout the stack sits in its pod (PODS/POD.manager/MANAGER.Docktor),
# so the PODS root is one rung further; in the image it is /app/APK:DOCKERS.
if os.path.basename(DOCKERS_DIRECTORY).startswith('POD.'):
    DOCKERS_DIRECTORY = os.path.dirname(DOCKERS_DIRECTORY)
REPOSITORY_ROOT = os.path.abspath(os.path.join(DOCKERS_DIRECTORY, '..'))

# The backend scripts for K8 / Kubernetes container management live in `Docktor/K8`.
K8_SCRIPTS_DIRECTORY = os.path.join(MANAGEMENT_DIRECTORY, 'K8')
if not os.path.isdir(K8_SCRIPTS_DIRECTORY):
    K8_SCRIPTS_DIRECTORY = os.path.join(SOURCE_DIRECTORY, 'docker scripts')
DOCKER_SCRIPTS_DIRECTORY = K8_SCRIPTS_DIRECTORY

# NO COMPOSE FILE PATHS HERE — they live in `docker scripts/_common.sh` beside
# us and nowhere else, with the projects rule, the ordering and the UID/GID.

# THE CONTRACTS ARE A PACKAGE, NOT A PATH (2026-10-30 audit, DockTor #1). The
# image pip-installs apkaudio_contracts from contracts/python, which carries the
# broker-candidate list (broker_candidates) and the brand/state tokens as package
# data (tokens) since contracts 36273b972 — so nothing of NODE.BareMetal's and no
# loose token file is copied in any more. A host run from a checkout (K8.runner.py
# without the package installed) gets the SAME package from the checkout's own
# contracts/python, put on sys.path here and nowhere else.
try:
    import apkaudio_contracts  # noqa: F401
except ImportError:
    _CHECKOUT_CONTRACTS = os.path.join(REPOSITORY_ROOT, 'contracts', 'python')
    if os.path.isdir(os.path.join(_CHECKOUT_CONTRACTS, 'apkaudio_contracts')):
        import sys
        sys.path.insert(0, _CHECKOUT_CONTRACTS)

# THE BRAND ACCENT, WITHOUT A FALLBACK: a missing package is an import error,
# not a quietly different accent.
from apkaudio_contracts import tokens as _tokens  # noqa: E402

ACCENT = _tokens.BRAND_ACCENT_HEX
