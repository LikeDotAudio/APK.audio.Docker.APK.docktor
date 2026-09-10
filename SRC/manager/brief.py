# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Free, for everyone, for ever. Full text in LICENSE at the root.
"""📊 A build's output, rendered as emoji and a moving bar.

WHAT THIS MODULE OWNS. One raw line in, zero or more DISPLAY EVENTS out —
`("line", text)` to append, `("bar", text)` to redraw over the live bar,
`("bardone", text)` to redraw it once more and freeze it. Pure: no widget, no
thread, no clock, so a captured build log can be replayed through it by a test.

WHAT IT MUST NOT SWALLOW IS A FAILURE. Anything `runner.is_error_line` claims
goes through verbatim, and so does any line no rule here recognises — a
condenser that eats the one line worth finding is worse than the noise it
removed. Exactly three things are dropped: `runner.BENIGN_NOISE`, the BODY of a
rustc *warning* (its count is reported in its place), and the per-item progress
the bar now carries.

WHAT IS BEING REMOVED IS NUMBERS. `#18 51.09`, a crate version, a byte count and
an ETA are four numbers saying what one bar says. Three things survive a line:
WHICH STEP, WHAT IT IS DOING NOW, and — only where the output states a total —
HOW FAR.
"""

import re

from .runner import is_error_line, is_benign_noise


BAR_WIDTH = 18
FULL, EMPTY = "█", "░"          # █ ░ — both are in DejaVu Sans Mono


# `#18 51.09   Downloaded errno v0.3.14` -> step 18, body `  Downloaded errno…`.
# The elapsed seconds are optional because buildkit's own control lines
# (`#18 DONE 51.1s`, `#8 CACHED`) do not carry one.
BUILDKIT_LINE = re.compile(r'^#(\d+)[ \t]+(?:\d+\.\d+(?:[ \t]|$))?(.*)$')

# `[ 4/12] RUN apt-get …` and `[stage-0 4/12] COPY …`. The fraction is the only
# honest progress a docker build states about ITSELF, so it is the one number
# that becomes a bar rather than being deleted.
BUILDKIT_STEP = re.compile(r'^\[\s*(?:[\w.+-]+\s+)?(\d+)\s*/\s*(\d+)\]\s*(.*)$')
BUILDKIT_INTERNAL = re.compile(r'^\[internal\]\s*(.*)$')

VERB_EMOJI = {
    'FROM': '\U0001F433', 'RUN': '\U0001F527', 'COPY': '\U0001F4C4',
    'ADD': '➕', 'WORKDIR': '\U0001F4C1', 'ENV': '\U0001F524',
    'ARG': '\U0001F524', 'EXPOSE': '\U0001F50C', 'CMD': '▶',
    'ENTRYPOINT': '▶', 'USER': '\U0001F464', 'VOLUME': '\U0001F4BE',
    'LABEL': '\U0001F3F7', 'HEALTHCHECK': '\U0001FA7A', 'SHELL': '\U0001F41A',
}

# A phase is a RUN of same-kind lines collapsed onto one bar. The key groups
# them; the emoji is what the bar wears. Order matters — first match wins, so
# `Downloaded` (cargo) is tested before the looser `Downloading` (pip/docker).
PHASE_RULES = (
    (re.compile(r'^\s*Downloaded\s+(\S+)'),                       'fetch',   '\U0001F4E5'),
    (re.compile(r'^\s*(?:Compiling|Building)\s+(\S+)'),           'compile', '\U0001F980'),
    (re.compile(r'^\s*Collecting\s+([^\s=<>;\[]+)'),              'pip',     '\U0001F40D'),
    (re.compile(r'^\s*(?:Downloading|Using cached)\s+(\S+)'),     'pip',     '\U0001F40D'),
    (re.compile(r'^\s*Get:\d+\s+\S+\s+\S+\s+\S+\s+(\S+)'),        'apt',     '\U0001F4E6'),
    (re.compile(r'^\s*(?:Hit|Ign):\d+\s+(\S+)'),                  'apt',     '\U0001F4E6'),
    (re.compile(r'^\s*(?:Unpacking|Setting up|Preparing to unpack|'
                r'Selecting previously unselected package)\s+([^\s(]+)'),
                                                                  'apt',     '\U0001F4E6'),
    (re.compile(r'^\s*(?:added|reify:|npm http fetch)\s+(\S+)'),  'npm',     '\U0001F4D7'),
    (re.compile(r'^\s*(?:extracting|transferring|sending|exporting|importing|'
                r'preparing|load build context|copying|naming to)\b\s*(\S*)'),
                                                                  'move',    '\U0001F69A'),
)

PHASE_NOUN = {'fetch': 'crates', 'compile': 'crates', 'pip': 'wheels',
              'apt': 'packages', 'npm': 'modules', 'move': 'layers',
              'warn': 'warnings'}

# A byte pair the source actually stated a TOTAL for. Only these become a
# proportional bar; everything else gets the sweeping one, because a bar that
# looks like a percentage without being one is a lie you read a hundred times.
BYTE_PAIR = re.compile(
    r'(\d+(?:\.\d+)?)\s*([kKMGT]i?B)?\s*/\s*(\d+(?:\.\d+)?)\s*([kKMGT]i?B)')
BYTE_SCALE = {'B': 1, 'KB': 1e3, 'KIB': 1024, 'MB': 1e6, 'MIB': 1024**2,
              'GB': 1e9, 'GIB': 1024**3, 'TB': 1e12, 'TIB': 1024**4}

# The rustc diagnostic BODY: the `-->` locator, the gutter, the `= note:` tail
# and the quoted source line. Every one of these is indented or begins with a
# keyword, which is what lets a warning be folded to a count without a parser.
DIAG_HEAD = re.compile(r'^(warning|error)(\[[A-Z]?\d+\])?:\s*(.*)$')
DIAG_BODY = re.compile(r'^(?:\s*$|\s+|-->|\d+\s*\||note:|help:|\.\.\.)')
# `warning: `apkaudio-midi` (lib) generated 16 warnings (run `cargo fix` …)`
DIAG_TALLY = re.compile(r'^warning:\s*`([^`]+)`.*generated\s+(\d+)\s+warning')


def _scale(value, unit):
    return float(value) * BYTE_SCALE.get((unit or 'B').upper(), 1)


def _short(name, limit=30):
    """A package's name without its version, its wheel tags or its path."""
    name = name.strip().strip(',"\'()[]').rstrip(':')
    if name.startswith('/') or name.startswith('http'):
        name = name.rsplit('/', 1)[-1]
    if name.endswith('.whl') or '-cp3' in name or '-py3' in name:
        name = name.split('-')[0]
    return name[:limit]


class LogBrief:
    """Fold a build's output down to emoji, bars, and the lines that matter."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.step = None            # buildkit step id of the line in hand
        self.step_names = {}        # step id -> what that step is doing
        self.plumbing = set()       # step ids whose ✅ is not worth a line
        self.step_done = 0
        self.step_total = 0
        self.phase = None           # (key, emoji)
        self.phase_count = 0
        self.phase_item = ''
        self.pulse = 0              # sweep position for the indeterminate bar
        self.diag = None            # 'warning' while a rustc warning body runs

    # -- bars ---------------------------------------------------------------

    def _bar(self, fraction=None):
        if fraction is None:
            # Ping-pong, not a percentage. It says WORKING; a filling bar with
            # no total behind it would say ALMOST DONE and be wrong every time.
            span = max(1, BAR_WIDTH * 2 - 2)
            spot = self.pulse % span
            if spot >= BAR_WIDTH:
                spot = span - spot
            cells = [EMPTY] * BAR_WIDTH
            for index in range(max(0, spot - 1), min(BAR_WIDTH, spot + 2)):
                cells[index] = FULL
            return ''.join(cells)
        filled = max(0, min(BAR_WIDTH, int(round(fraction * BAR_WIDTH))))
        return FULL * filled + EMPTY * (BAR_WIDTH - filled)

    def _phase_bar(self):
        emoji = self.phase[1]
        return f"{emoji} {self._bar()} {self.phase_item}".rstrip()

    def _close_phase(self):
        """Freeze the live bar into a full one carrying the only count kept."""
        if not self.phase:
            return []
        key, emoji = self.phase
        count, self.phase = self.phase_count, None
        noun = PHASE_NOUN.get(key, 'items')
        return [("bardone", f"{emoji} {self._bar(1.0)} ×{count} {noun} ✅")]

    def _in_phase(self, key, emoji, item):
        events = []
        if self.phase and self.phase[0] != key:
            events += self._close_phase()
        if not self.phase:
            self.phase, self.phase_count, self.pulse = (key, emoji), 0, 0
        self.phase_count += 1
        self.pulse += 1
        self.phase_item = item
        events.append(("bar", self._phase_bar()))
        return events

    def _plain(self, text):
        return self._close_phase() + [("line", text)]

    # -- the sieve ----------------------------------------------------------

    def feed(self, raw):
        """One raw output line -> the display events it should produce."""
        text = raw.rstrip('\n').rstrip()
        match = BUILDKIT_LINE.match(text)
        if match:
            self.step, body = match.group(1), match.group(2)
        else:
            body = text

        if is_benign_noise(body):
            return []

        # A step that never announced itself is still named by its first line,
        # so its `DONE` has something to say besides a tick.
        if self.step and self.step not in self.step_names and body.strip():
            self.step_names[self.step] = _short(body, 60)

        # A rustc warning is a fifteen-line block that says one thing. Its head
        # is counted, its body is dropped, and its per-crate tally line is the
        # summary. An ERROR block is never folded: it is the whole reason you
        # opened the log.
        if self.diag and not self._interrupts_diagnostic(body):
            if DIAG_BODY.match(body) and not DIAG_HEAD.match(body):
                return [] if self.diag == 'warning' else [("line", body)]
        self.diag = None if self.diag and not DIAG_BODY.match(body) else self.diag

        tally = DIAG_TALLY.match(body)
        if tally:
            crate, count = tally.group(1), tally.group(2)
            return self._plain(f"⚠️ {crate} ×{count}")

        head = DIAG_HEAD.match(body)
        if head and head.group(1) == 'warning':
            self.diag = 'warning'
            return self._in_phase('warn', '⚠️',
                                  _short(head.group(3), 44))
        if head and head.group(1) == 'error':
            self.diag = 'error'
            return self._plain(body)

        events = self._buildkit_control(body)
        if events is not None:
            return events

        for pattern, key, emoji in PHASE_RULES:
            hit = pattern.match(body)
            if hit:
                return self._in_phase(key, emoji, _short(hit.group(1) or ''))

        pair = BYTE_PAIR.search(body)
        if pair and not is_error_line(body):
            done = _scale(pair.group(1), pair.group(2) or pair.group(4))
            total = _scale(pair.group(3), pair.group(4))
            fraction = min(1.0, done / total) if total else None
            self.phase = self.phase or ('move', '\U0001F69A')
            return [("bar", f"{self.phase[1]} {self._bar(fraction)} "
                            f"{self.phase_item}".rstrip())]

        if not body.strip():
            return []
        return self._plain(body)

    def _interrupts_diagnostic(self, body):
        """True for a line that ends a rustc block by being something else."""
        if BUILDKIT_STEP.match(body) or body[:5] in ('DONE ', 'CACHE', 'ERROR'):
            return True
        return any(pattern.match(body) for pattern, _, _ in PHASE_RULES)

    def _buildkit_control(self, body):
        """buildkit's own vocabulary. None if this line is not one of them."""
        named = self.step_names.get(self.step, '')
        if body.startswith('DONE'):
            if self.step in self.plumbing:
                return self._close_phase()
            return self._close_phase() + [("line", f"✅ {named}".rstrip())]
        if body.startswith('CACHED'):
            return self._close_phase() + [("line", f"⚡ {named}".rstrip())]
        if body.startswith('ERROR'):
            return self._plain(f"❌ {body}")

        step = BUILDKIT_STEP.match(body)
        if step:
            self.step_done, self.step_total = int(step.group(1)), int(step.group(2))
            command = step.group(3).strip()
            verb = command.split(' ', 1)[0].upper()
            emoji = VERB_EMOJI.get(verb, '\U0001F528')
            if verb in VERB_EMOJI:
                command = command[len(verb):].strip()
            self.step_names[self.step] = _short(command, 60)
            bar = self._bar(self.step_done / self.step_total if self.step_total else None)
            return self._close_phase() + [("line", f"{emoji} {bar} "
                                                  f"{self.step_names[self.step]}")]

        internal = BUILDKIT_INTERNAL.match(body)
        if internal:
            self.plumbing.add(self.step)
            self.step_names[self.step] = _short(internal.group(1), 60)
            return self._close_phase() + [("line", f"\U0001F4CB "
                                                  f"{self.step_names[self.step]}")]
        return None
