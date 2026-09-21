# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🎨 What a state MEANS and what it is drawn as. One table, served to clients.

OWNS the reading of a docker status word, an app-plane state word, the role
glyph, and the colours all three draw from. Reads no docker, runs no script,
renders nothing: every function takes a string and returns data.
PYTHON AND NOT CSS because these came out of the Tkinter card widget as the
only copy, and a stylesheet copy would be a second one — a colour learnt from
the grid that disagrees in the detail pane. Served at /api/palette; the client
writes them into CSS custom properties at boot, so web/manager.css holds no
colour literal for a state.
THE ACCENT IS paths.ACCENT, read out of contracts/tokens/brand.json: a default
here would be a second spelling of the brand.
"""

import zlib

from .paths import ACCENT


# ---------------------------------------------------------------------------
# THE PALETTE MEANS SOMETHING. Five colours, one reading each, used the same way
# on every surface, so a colour learnt in one place is learnt in all.
# Green was doing all of this alone: `Up 4 minutes` and `Up 4 minutes (healthy)`
# painted identically, making a container with NO healthcheck look like one
# that had passed its own.
# ---------------------------------------------------------------------------
OK = "#00e676"      # up, and it says so itself -- a healthcheck passed
LIVE = "#29b6f6"    # up, with nothing attesting to it. Running != healthy.
WARM = "#ffc400"    # starting, restarting, working hard
HOT = "#ff3333"     # unhealthy, exited, dead, out of headroom
IDLE = "#78909c"    # created, paused, or simply nobody measuring
# THE SIXTH, AND NOT A CONTAINER STATE — which is why it needed its own colour.
# Every tone above answers "how is this container doing"; a stale image is a
# container doing FINE on code the repository has moved past, so it can be `ok`
# and this at once. Violet is off the green-amber-red axis on purpose: a
# different QUESTION, not a worse answer, and far enough from LIVE cyan for the
# ~8% the STATUS_STYLES header is written for.
STALE = "#b388ff"   # the image is older than the code it was built from

TONES = {"ok": OK, "live": LIVE, "warm": WARM, "hot": HOT, "idle": IDLE,
         "stale": STALE, "accent": ACCENT}

# ---------------------------------------------------------------------------
# WHAT THE STATUS WORD MEANS, keyed on the first word docker prints. The emoji
# carries the state a second time — a card read at arm length is a shape before
# it is a sentence, and colour alone fails the ~8% who cannot separate green
# from amber.
# `pulse` is "ALIVE", the one thing no still frame can fake: a stopped tab and a
# stopped container look identical until something moves.
# ---------------------------------------------------------------------------
STATUS_STYLES = {
    "healthy":    ("\U0001F49A", "ok",   True),   # up, healthcheck passing
    "starting":   ("⏳",     "warm", True),   # up, healthcheck undecided
    "unhealthy":  ("⚠",     "hot",  True),   # up, and failing its check
    "up":         ("▶",     "live", True),   # up, no healthcheck at all
    "restarting": ("\U0001F501", "warm", True),   # in a restart loop
    "paused":     ("⏸",     "idle", False),  # frozen on purpose
    "created":    ("\U0001F195", "idle", False),  # never started
    "exited":     ("⛔",     "hot",  False),  # stopped
    "dead":       ("\U0001F480", "hot",  False),  # unrecoverable
}
STATUS_UNKNOWN = ("❓", "idle", False)

# The three words remove-dead-containers.sh sweeps on. `restarting` is
# deliberately absent: a container whose restart policy is working is not
# rubbish, and offering to remove it invites a click that races it.
DEAD_PREFIXES = ("exited", "dead", "created")

# ---------------------------------------------------------------------------
# WHAT AN APP STATE LOOKS LIKE, keyed on the words apps.sh prints. The word is
# drawn BESIDE the dot, not instead of it: `disabled` and `idle` are the two
# this exists to tell apart — both are "not running", one is news.
# An unknown state is drawn grey WITH ITS OWN WORD, so a state added to apps.sh
# appears unstyled rather than not at all.
# ---------------------------------------------------------------------------
APP_STATE_TONES = {
    "running":  "ok",
    "idle":     "warm",
    "stopped":  "hot",
    "down":     "hot",
    "disabled": "idle",
}
APP_STATE_UNKNOWN_COLOUR = "#9aa0aa"

# ---------------------------------------------------------------------------
# WHAT A TOPIC STATE LOOKS LIKE, keyed on the three words topics.sh prints.
# `live` AND `retained` ARE NOT THE SAME NEWS, which is the only reason this
# table is separate: retained is durable state the broker handed over on
# subscribe, possibly hours old from a publisher that may be gone; live arrived
# with the retain flag clear inside the window. Painting both green makes a
# silent bench look busy.
# `departed` IS HOT, NOT GREY: an empty retained payload is MQTT only way of
# withdrawing a topic, and a topic that has gone is the one to notice.
# ---------------------------------------------------------------------------
BUS_STATE_TONES = {
    "live":     "ok",
    "retained": "warm",
    "departed": "hot",
}
# Only `running` breathes, for the same reason the container dot does: a state
# that is not moving must not look like one that is.
APP_STATES_PULSING = ("running",)

# What the container is FOR, matched against its name. A reading aid — nothing
# branches on it, so an unmatched name gets the whale and no harm.
ROLE_EMOJI = (
    ("broker", "\U0001F4E1"),      # message bus
    ("mqtt", "\U0001F4E1"),
    ("maria", "\U0001F5C4"),       # database
    ("sql", "\U0001F5C4"),
    ("postgres", "\U0001F5C4"),
    ("redis", "\U0001F5C4"),
    ("portal", "\U0001F310"),      # something serving a page
    ("apk", "\U0001F310"),
    ("web", "\U0001F310"),
    ("nginx", "\U0001F310"),
    ("registry", "\U0001F9ED"),    # discovery / lookup
    ("discover", "\U0001F9ED"),
    ("nmos", "\U0001F9ED"),
    ("test", "\U0001F9EA"),        # test rig
    ("sandbox", "\U0001F9EA"),
    ("baremetal", "⚙"),       # the node itself
    ("node", "⚙"),
    ("orchestr", "\U0001F3BC"),    # conductor
)
ROLE_DEFAULT = "\U0001F433"

# What separates a stack name from the container own. Docker compose separator
# is `-`; ours have been `_` and `:` at different times, and all three have to
# read the same way here.
GROUP_SEPARATORS = "-_:"

# POD:protocols — THREE CONTAINERS, ONE POD. The pod-root compose file puts
# AES70, EMBER and NMOS in one project (`protocols`); this is the same fact said
# where the grid can see it, because a group here is read off the container NAME
# and these five names share no prefix.
# PREFIXES, NOT SUBSTRINGS: `ember` anywhere in a name would also catch a
# hypothetical `Remember-*`, and `nmos` alone would swallow Plugin-NMOS — which
# is a plugin on the node, not a protocol bench, and is caught by the Plugin-
# rule ABOVE this one. Keep this test after that one.
# A container added to the pod needs its prefix here; the alternative — grouping
# on the compose project — is not available, since group_of() is handed a name
# and nothing else.
PROTOCOL_PREFIXES = ("AES70-", "Ember-", "NMOS-", "APK-NMOS-")
PROTOCOL_GROUP = "Protocols"

# ---------------------------------------------------------------------------
# A COLOUR FOR THE STACK, AND IT IS NOT A STATE. The tones above each mean one
# thing about health, so this ring is confined by rule to the two surfaces no
# state touches — the group HEADING and the card LEFT EDGE. Nothing here is
# saturated enough to read as OK or HOT at a glance either.
# THE COLOUR IS A PROPERTY OF THE NAME, not of the order the bench came back in:
# indexing by position would repaint every stack below one that went dark.
# crc32 rather than hash(), because hash() of a str is salted per process and
# the same bench would come up in different colours after every restart.
# THE PREFERENCE IS PER NAME; THE ASSIGNMENT IS ACROSS THE SET — 12 hues over 9
# stacks put two alphabetically ADJACENT pairs on one colour each, and two
# touching blocks in one colour read as one stack. hues_for() walks the ring
# from each preferred slot to the first free one, so a stack that had to be
# nudged can move when its neighbours come and go and one whose preference was
# free never does.
# ---------------------------------------------------------------------------
GROUP_HUES = (
    "#6fd3ff",  # sky
    "#b39dff",  # violet
    "#ff9ecb",  # pink
    "#ffcf7a",  # sand
    "#7ee0c0",  # mint
    "#d0e06a",  # olive
    "#9ab8ff",  # periwinkle
    "#e8a2ff",  # orchid
    "#ffab8a",  # peach
    "#8fd6a0",  # sage
    "#c9c2a0",  # stone
    "#6ec5d8",  # teal
)


# THE ORDER IS THE RULE, not the dict. `Up 4 minutes (unhealthy)` starts with
# "up", so a first-word match paints the status that most needs its own colour
# the same blue as a container nothing attests to. Health word first, state word
# second; `unhealthy` before `healthy` and `restarting` before `starting`
# because each is a substring of the other — the Tk table this came from had it
# the other way round, so every container in a restart LOOP wore the hourglass.
STATUS_MATCH_ORDER = ("unhealthy", "restarting", "starting", "healthy",
                      "paused", "exited", "dead", "created", "up")


def status_style(status):
    """(emoji, tone, pulse) for a docker status line. Never raises."""
    lowered = (status or "").lower()
    for word in STATUS_MATCH_ORDER:
        if word in lowered:
            return STATUS_STYLES[word]
    return STATUS_UNKNOWN


def is_dead(status):
    """True for a container the sweep would take -- exited, dead or created."""
    return (status or "").lower().startswith(DEAD_PREFIXES)


def role_emoji(name):
    """The glyph for what this container is for. A reading aid, nothing else."""
    lowered = (name or "").lower()
    for hint, emoji in ROLE_EMOJI:
        if hint in lowered:
            return emoji
    return ROLE_DEFAULT


def group_of(name):
    """The stack a container belongs to: everything before the first separator.

    A name with none is its own group of one.
    """
    n = name or ""
    lowered = n.lower()
    # APK-Discovery-Engine belongs in BareMetal
    if "discovery-engine" in lowered:
        return "BareMetal"
    # Discovered devices live in their own Discovered pod
    if lowered.startswith("apk-"):
        return "Discovered"

    # Gateway, Heartbeat, OsApi, WebStatic and BareMetal core/plugins live under BareMetal
    if any(k in lowered for k in ("gateway", "heartbeat", "osapi", "webstatic", "traffic-router")):
        return "BareMetal"
    if any(k in lowered for k in ("broker", "mosquitto", "sqlcapture", "databus")):
        return "DataBus"
    # All plugins belong in their own Plugins pod
    if n.startswith("Plugin-"):
        return "Plugins"
    if n.startswith("Node-") or "baremetal" in lowered:
        return "BareMetal"
    # AFTER the Plugin- test above, never before: Plugin-NMOS and
    # Plugin-NMOS_CONTROL are plugins on the node and must keep going there.
    if n.startswith(PROTOCOL_PREFIXES):
        return PROTOCOL_GROUP
    for index, character in enumerate(n):
        if character in GROUP_SEPARATORS and index:
            grp = n[:index]
            if grp.upper() in ("PORTAL", "API"):
                return "BareMetal"
            if grp.upper() == "APK":
                return "Discovered"
            return grp
    if n.upper() in ("PORTAL", "API"):
        return "BareMetal"
    if n.upper() == "APK":
        return "Discovered"
    return n


def leaf_of(name):
    """The container own half of its name: `Storage-Portal` -> `Portal`.

    The grid draws the stack ONCE as the heading, so the prefix on every card
    is that heading said again per card. A name that IS its group keeps all of
    itself: `mariadb` must not render as an empty card.
    """
    if name == "Portal-Broker":
        return "Portal-Broker"
    # A PROTOCOL CARD KEEPS ALL OF ITS NAME. The rule below strips the first
    # segment because it repeats the heading — true for `Plugin-DANTE` under
    # `BareMetal`, false here: the heading is `Protocols` and the first segment
    # is WHICH protocol. Stripped, AES70-Dev and NMOS-Dev both render as `Dev`.
    if (name or "").startswith(PROTOCOL_PREFIXES):
        return name
    for index, character in enumerate(name or ""):
        if character in GROUP_SEPARATORS and index:
            return (name[index:]).lstrip(GROUP_SEPARATORS) or (name or "")
    return name or ""


def group_hue(label):
    """The hue a stack PREFERS. hues_for() is what decides; this is its seed."""
    if not label:
        return GROUP_HUES[0]
    return GROUP_HUES[zlib.crc32(label.lower().encode("utf-8")) % len(GROUP_HUES)]


def hues_for(labels):
    """{stack: colour} for one bench, no two neighbours alike.

    `labels` is in the order the grid will draw them, because that order is what
    "neighbours" means. Past the twelfth stack the ring repeats — the two most
    recently drawn are held back so the repeat is never adjacent.
    """
    assigned, taken = {}, set()
    for label in labels:
        if len(taken) >= len(GROUP_HUES):
            taken = set(list(assigned.values())[-2:])
        start = GROUP_HUES.index(group_hue(label))
        hue = next(GROUP_HUES[(start + step) % len(GROUP_HUES)]
                   for step in range(len(GROUP_HUES))
                   if GROUP_HUES[(start + step) % len(GROUP_HUES)] not in taken)
        assigned[label] = hue
        taken.add(hue)
    return assigned


def as_json():
    """The whole table, for a client that must not spell a colour of its own."""
    return {
        "accent": ACCENT,
        "tones": TONES,
        "status": {word: {"emoji": emoji, "tone": tone, "pulse": pulse}
                   for word, (emoji, tone, pulse) in STATUS_STYLES.items()},
        "status_order": list(STATUS_MATCH_ORDER),
        "status_unknown": {"emoji": STATUS_UNKNOWN[0], "tone": STATUS_UNKNOWN[1],
                           "pulse": STATUS_UNKNOWN[2]},
        "app_state_tones": APP_STATE_TONES,
        "bus_state_tones": BUS_STATE_TONES,
        "app_state_unknown": APP_STATE_UNKNOWN_COLOUR,
        "app_states_pulsing": list(APP_STATES_PULSING),
        "group_hues": list(GROUP_HUES),
    }
