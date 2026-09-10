# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""🎨 What a state MEANS, and what it is drawn as. One table, served to the client.

WHAT THIS MODULE OWNS. The reading of a docker status word, the reading of an
app-plane state word, the role glyph, and the five colours all three draw from.
It reads no docker, runs no script and renders nothing — every function here
takes a string and returns data.

WHY IT IS PYTHON AND NOT CSS. These tables came out of the Tkinter card widget,
where they were the only copy; moving the front end into a browser would have
made them a second copy in a stylesheet, and a colour learnt from the card grid
that disagrees with the colour in the detail pane is the exact defect the
original table's own header spends a paragraph on. So the tables stay here, the
API serves them at `/api/palette`, and the client writes them into CSS custom
properties at boot. There is no colour literal in `web/manager.css` for a state.

THE ACCENT IS NOT HERE EITHER. It is `paths.ACCENT`, read out of
contracts/tokens/brand.json, and this module imports it for the same reason
everything else does: a default would be a second spelling of the brand.
"""

import zlib

from .paths import ACCENT


# ---------------------------------------------------------------------------
# THE PALETTE MEANS SOMETHING. Five colours, each with ONE reading, used the
# same way on every surface -- the dot, the status words, the meters and the
# app rows all draw from this table, so a colour learnt in one place is already
# learnt in the others.
#
# Green was doing all of this on its own: `Up 4 minutes` and `Up 4 minutes
# (healthy)` painted identically, which made a container with NO healthcheck
# look like one that had passed its own.
# ---------------------------------------------------------------------------
OK = "#00e676"      # up, and it says so itself -- a healthcheck passed
LIVE = "#29b6f6"    # up, with nothing attesting to it. Running != healthy.
WARM = "#ffc400"    # starting, restarting, working hard
HOT = "#ff5252"     # unhealthy, exited, dead, out of headroom
IDLE = "#78909c"    # created, paused, or simply nobody measuring
# THE SIXTH, AND IT IS NOT A CONTAINER STATE -- which is exactly why it needed
# its own colour rather than a borrowed one. Every tone above answers "how is
# this container doing"; a stale image is a container doing FINE and running
# code the repository has moved past, so it can be `ok` and this at the same
# moment. Painting it warm or hot would have said the container was struggling,
# which is false and is the kind of false that teaches a reader to discount the
# colour. Violet is off the green-amber-red axis on purpose: it reads as a
# different QUESTION, not a worse answer, and it is far enough from LIVE's cyan
# to survive the ~8% of people the STATUS_STYLES header is written for.
STALE = "#b388ff"   # the image is older than the code it was built from

TONES = {"ok": OK, "live": LIVE, "warm": WARM, "hot": HOT, "idle": IDLE,
         "stale": STALE, "accent": ACCENT}

# ---------------------------------------------------------------------------
# WHAT THE STATUS WORD MEANS, keyed on the first word docker prints. The emoji
# is small and carries the state a second time -- a card read at arm's length
# is a shape before it is a sentence, and colour alone fails the ~8% of people
# who cannot separate the green from the amber.
#
# `pulse` is "ALIVE", and it is the one thing on a card that no still frame can
# fake: a stopped browser tab and a stopped container look identical until
# something moves. Only the states that are genuinely running carry it.
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

# The three words remove-dead-containers.sh sweeps on, and `restarting` is
# deliberately not among them: a container whose restart policy is working is
# not rubbish, and offering to remove it invites a click that races it.
DEAD_PREFIXES = ("exited", "dead", "created")

# ---------------------------------------------------------------------------
# WHAT AN APP'S STATE LOOKS LIKE. Keyed on the words apps.sh prints, and the
# state word is drawn BESIDE the dot rather than replacing it: colour alone is
# not a reading, and `disabled` and `idle` are the two this exists to tell
# apart -- both are "not running" and only one of them is news.
#
# A state this table does not know is drawn grey WITH ITS OWN WORD, so a state
# added to apps.sh appears unstyled rather than not at all.
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
# WHAT A TOPIC'S STATE LOOKS LIKE. Keyed on the three words topics.sh prints.
#
# `live` AND `retained` ARE NOT THE SAME NEWS, and telling them apart is the
# only reason this table is separate from the one above. A retained topic is
# durable state the broker handed over on subscribe: it says something WAS
# published, possibly hours ago, by a publisher that may be gone. A live one
# arrived with the retain flag clear inside the window — that is traffic, now.
# Painting both green would make a silent bench look like a busy one, which is
# the same mistake as painting a periodic agent red.
#
# `departed` IS HOT AND NOT GREY. An empty retained payload is MQTT's only way
# of saying a topic has been withdrawn, and a topic that has gone is the one an
# operator most needs to notice went.
# ---------------------------------------------------------------------------
BUS_STATE_TONES = {
    "live":     "ok",
    "retained": "warm",
    "departed": "hot",
}
# Only `running` breathes, for the same reason the container dot does: a state
# that is not moving must not look like one that is.
APP_STATES_PULSING = ("running",)

# What the container is FOR, matched against its name. Purely a reading aid --
# nothing branches on it -- so an unmatched name gets the whale and no harm.
ROLE_EMOJI = (
    ("broker", "\U0001F4E1"),      # message bus
    ("mqtt", "\U0001F4E1"),
    ("maria", "\U0001F5C4"),       # database
    ("sql", "\U0001F5C4"),
    ("postgres", "\U0001F5C4"),
    ("redis", "\U0001F5C4"),
    ("portal", "\U0001F310"),      # something serving a page
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

# What separates a stack's name from the container's own. `Storage-Broker` and
# `Storage-MariaDB` are one stack; `NMOS-Registry` and `NMOS-Node` are another.
# Docker's own compose separator is `-`, ours have been `_` and `:` at
# different times, and all three have to read the same way here.
GROUP_SEPARATORS = "-_:"

# ---------------------------------------------------------------------------
# A COLOUR FOR THE STACK, AND IT IS NOT A STATE. The five tones above each mean
# one thing about health, and a hue that meant "Netbox" would break that if it
# were ever drawn where a state is drawn. So this ring is confined by rule to
# the two surfaces no state ever touches -- the group HEADING and the card's
# LEFT EDGE -- and the dot, the status words, the meters and the app rows keep
# the five tones to themselves. Nothing here is saturated enough to read as OK
# or HOT at a glance either; that is deliberate, not taste.
#
# THE COLOUR IS A PROPERTY OF THE NAME, not of the order the bench came back
# in. Indexing by position would repaint every stack below one that went dark,
# so a colour learnt on Monday would be somebody else's on Tuesday. crc32 is
# used rather than hash() because hash() of a str is salted per process: the
# same bench would come up in different colours after every restart.
#
# THE PREFERENCE IS PER NAME; THE ASSIGNMENT IS ACROSS THE SET, and it has to
# be, because the preference alone is not good enough on the bench it was
# written for: 12 hues over 9 stacks put `APK` and `Broker` on one orchid and
# `NMOS` and `Node` on one sage, and both pairs are alphabetically ADJACENT --
# two touching blocks in the same colour is worse than no colour at all, since
# it reads as one stack. So hues_for() walks the ring from each stack's
# preferred slot to the first free one. A stack that had to be nudged can move
# when its neighbours come and go; a stack whose preference was free never
# does, which on this bench is seven of the nine.
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


# THE ORDER IS THE RULE, not the dict's. `Up 4 minutes (unhealthy)` starts
# with "up" and is not a healthy container, so a first-word match alone paints
# the one status that most needs its own colour in the same blue as a container
# nothing is attesting to. Health word first, state word second; and `unhealthy`
# before `healthy` because the second is a substring of the first -- and
# `restarting` before `starting` for the same reason, which the Tk table this
# came from had the other way round: every container in a restart LOOP wore the
# hourglass of one whose healthcheck had simply not decided yet.
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

    A name with none is its own group of one, which is what `mariadb` and
    `portainer` should look like beside a stack of four.
    """
    for index, character in enumerate(name or ""):
        if character in GROUP_SEPARATORS and index:
            return name[:index]
    return name or ""


def leaf_of(name):
    """The container's own half of its name: `Storage-Portal` -> `Portal`.

    The grid draws the stack ONCE, as the heading over its cards, so the prefix
    on every card under it is that heading said again per card -- five cards of
    `Netbox-` under a row that already reads NETBOX. A name that IS its group
    keeps all of itself: `mariadb` must not render as an empty card.
    """
    group = group_of(name)
    return (name or "")[len(group):].lstrip(GROUP_SEPARATORS) or (name or "")


def group_hue(label):
    """The hue a stack PREFERS. hues_for() is what decides; this is its seed."""
    if not label:
        return GROUP_HUES[0]
    return GROUP_HUES[zlib.crc32(label.lower().encode("utf-8")) % len(GROUP_HUES)]


def hues_for(labels):
    """{stack: colour} for one bench, no two neighbours alike.

    `labels` is taken in the order the grid will draw them, because that order
    is what "neighbours" means. Past the twelfth stack the ring must repeat --
    the two most recently drawn are held back so the repeat is never adjacent.
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
