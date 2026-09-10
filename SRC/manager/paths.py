# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""📍 Where everything is. Four paths, resolved once, imported everywhere.

WHAT THIS MODULE OWNS. Locations, and the brand accent that is read out of one
of them. It holds NO compose file path and no port — those live in
`DockTor/SRC/docker scripts/_common.sh`, the only copy of them, and
the reason is that this package's copy was the one that could only be exercised
through a Tkinter window and so was the one that drifted.

It is the deepest module in the package: it imports nothing of ours, so every
other module can import it without a cycle.
"""

import os
import json

# FOUR levels up from this file is APK:DOCKERS/, and it was THREE until the
# 2026-09-06 split gave every stack a `SRC/` beside a `Docker/`. That is the
# whole shape now, and the rungs are named rather than counted:
#
#   APK:DOCKERS/                          DOCKERS_DIRECTORY
#     DockTor/                  MANAGEMENT_DIRECTORY
#       Docker/  docker-compose.manager.yml, Dockerfile.manager
#       SRC/                              SOURCE_DIRECTORY
#         docker scripts/                 every verb, one file each
#         manager/                        MANAGER_PACKAGE — this file
#
# SOURCE_DIRECTORY EXISTS SO NOBODY COUNTS `..` AT A CALL SITE. When the split
# landed, `MANAGEMENT_DIRECTORY` silently became SRC/ — every consumer asking
# it for `docker scripts/` kept working, and every consumer asking it for the
# stack root got the wrong answer one rung down, which is how DOCKERS_DIRECTORY
# came to name `DockTor/` and the compose glob came back empty. Each
# rung has a name of its own now, so a wrong one is a wrong WORD in a diff
# rather than a `..` nobody can count without a directory listing.
#
# The entry script sits in DOCKERS_DIRECTORY and computes the same thing from
# its own location; these must agree, and they agree by both walking from a
# __file__ rather than by either being told.
MANAGER_PACKAGE = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIRECTORY = os.path.dirname(MANAGER_PACKAGE)
MANAGEMENT_DIRECTORY = os.path.dirname(SOURCE_DIRECTORY)
DOCKERS_DIRECTORY = os.path.dirname(MANAGEMENT_DIRECTORY)
REPOSITORY_ROOT = os.path.abspath(os.path.join(DOCKERS_DIRECTORY, '..'))

# The one place this package spells `docker scripts/`. runner.py runs the files
# in it and api.py reports where it is; both used to join it onto
# MANAGEMENT_DIRECTORY themselves, which is two spellings of a rung that moved.
DOCKER_SCRIPTS_DIRECTORY = os.path.join(SOURCE_DIRECTORY, 'docker scripts')

# NO COMPOSE FILE PATHS HERE. They live in `docker scripts/_common.sh` beside us
# and nowhere else -- along with the two-projects rule, the ordering, and the
# UID/GID the node runs as. This package had its own copy of all four until
# 2026-09-03, and a copy that can only be exercised through a GUI is a copy that
# drifts unobserved.

# The bare-metal SOURCE tree, which is not the repository root's any more: it
# moved under the container that builds it, so `APK:BareMetal/` at the root is
# a path from before the move. Still needed here for the two things that are
# NOT docker: the brand token below, and the broker-discovery module the MQTT
# broadcast imports. Both degrade QUIETLY when it is wrong -- the discovery
# falls back to loopback inside an except -- so a stale spelling costs a broker
# list without ever costing an error message.
# One level, not two: the nested inner folder was dissolved on 2026-09-04 and
# its 6,505 files rose to the stack root. The stack root itself was spelled
# `Node:BareMetal` for a day and is `APK:BareMetal` again since 2026-09-05.
#
# AND IT IS THE STACK'S `SRC/`, NOT THE STACK ROOT, since the 2026-09-06 split:
# `contracts/` and `Baremetal:Manager/` went down a rung with everything else
# that is source, and only `Docker/` stayed at the top. This is the constant
# whose failure the paragraph above calls quiet -- the brand token below is
# read WITHOUT a fallback precisely so that this one rung cannot go wrong in
# silence, and on 2026-09-06 it was the line that said so.
BAREMETAL_ROOT = os.path.join(DOCKERS_DIRECTORY, 'APK:BareMetal', 'SRC')

# The accent is stated once, in contracts, and read here rather than spelled.
# Read at import, and DELIBERATELY WITHOUT A FALLBACK: a default would be a
# second spelling of the value, which is the thing `check.sh brand` exists to
# stop, and it would go on painting the old colour after the token moved. This
# file sits inside the repository that holds the token, so an unreadable token
# is a broken checkout and is meant to say so on the first line.
BRAND_TOKENS = os.path.join(BAREMETAL_ROOT, 'contracts', 'tokens', 'brand.json')

with open(BRAND_TOKENS, encoding='utf-8') as _tokens:
    ACCENT = json.load(_tokens)['accent']['hex']
