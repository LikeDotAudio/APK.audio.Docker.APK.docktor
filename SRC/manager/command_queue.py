# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""📋 The command queue. Every verb the bench is asked to do, in the order asked.

OWNS the order. A verb that arrives while another holds the bench WAITS HERE
and runs when the bench is free — a person's press, a countdown in a tab,
launch.sh at a terminal and anything else that POSTs /api/action all land in
the same line, so what the automation is about to do is visible and cancellable
before it happens.
DOES NOT OWN running a verb, nor what a verb is. `execute` is handed in by
api.py and is the same call a direct press makes; this file never names a
script.
THE LINE IS FIFO AND FAIR: a verb that arrives while something is WAITING queues
behind it even if the bench happens to be free for that instant, or a fast
repeated press could jump a rebuild ordered minutes earlier.
THE SAME ORDER TWICE IS ONE ENTRY. Pressing Remount five times while a rebuild
runs queues one remount, not five.
A STOP EMPTIES THE LINE. `down` and `panic` do not queue — they preempt — and a
remount that fires the moment after a panic is the opposite of what the panic
asked for. drop_all() is how they say so, and every dropped entry is named.
NOTHING HERE PERSISTS: a manager restart empties the line, which is right —
the orders were given to a bench that no longer exists in that shape.
"""

import itertools
import threading
import time
from collections import deque


class CommandQueue:
    """Waiting orders, the one running now, and the last few that finished."""

    HISTORY = 40

    def __init__(self, execute, bench_lock, on_change=None):
        # `execute(entry)` runs one order with `bench_lock` ALREADY HELD by the
        # worker and releases nothing; it returns (exit_code, closing).
        self._execute = execute
        self._bench = bench_lock
        self._on_change = on_change or (lambda snapshot: None)
        self._waiting = deque()
        self._history = deque(maxlen=self.HISTORY)
        self._running = None
        self._ids = itertools.count(1)
        self._cond = threading.Condition()
        self._worker = None

    # ------------------------------------------------------------------ read
    def snapshot(self):
        with self._cond:
            return {"running": dict(self._running) if self._running else None,
                    "waiting": [self._public(e) for e in self._waiting],
                    "recent": [self._public(e) for e in reversed(self._history)]}

    def waiting(self):
        with self._cond:
            return len(self._waiting)

    @staticmethod
    def _public(entry):
        return {k: v for k, v in entry.items() if not k.startswith("_")}

    # ----------------------------------------------------------------- write
    def new_entry(self, key, label, name, scope, extra, ordered_by):
        return {"id": next(self._ids), "key": key, "label": label, "name": name,
                "scope": scope, "extra": list(extra), "ordered_by": ordered_by,
                "queued_at": time.time(), "state": "new"}

    def put(self, entry):
        """Queue one order. Returns (entry, position, was_new)."""
        with self._cond:
            for position, waiting in enumerate(self._waiting, start=1):
                if self._same(waiting, entry):
                    return waiting, position, False
            entry["state"] = "waiting"
            self._waiting.append(entry)
            position = len(self._waiting)
            self._ensure_worker()
            self._cond.notify_all()
        self._changed()
        return entry, position, True

    def cancel(self, entry_id):
        """Take one waiting order out of the line. None if it is not waiting."""
        with self._cond:
            for entry in list(self._waiting):
                if entry["id"] == entry_id:
                    self._waiting.remove(entry)
                    entry.update(state="cancelled", finished_at=time.time())
                    self._history.append(entry)
                    break
            else:
                return None
        self._changed()
        return self._public(entry)

    def drop_all(self, reason):
        """Empty the line. Returns the dropped orders."""
        with self._cond:
            dropped = list(self._waiting)
            self._waiting.clear()
            for entry in dropped:
                entry.update(state="dropped", finished_at=time.time(),
                             closing=f"dropped by {reason}")
                self._history.append(entry)
        if dropped:
            self._changed()
        return [self._public(e) for e in dropped]

    # ------------------------------------------------------ running, any hand
    # A DIRECT PRESS THAT FOUND THE BENCH FREE RUNS IN ITS OWN REQUEST THREAD,
    # not the worker's, so its output still streams to the tab that pressed it.
    # It reports in here all the same: the queue is the record of everything
    # the bench did, not only what had to wait.
    def started(self, entry):
        with self._cond:
            entry.update(state="running", started_at=time.time())
            self._running = self._public(entry)
        self._changed()

    def finished(self, entry, exit_code, closing):
        with self._cond:
            entry.update(state="done" if exit_code == 0 else "failed",
                         exit_code=exit_code, closing=closing,
                         finished_at=time.time())
            self._running = None
            self._history.append(entry)
            self._cond.notify_all()
        self._changed()

    # ---------------------------------------------------------------- worker
    def _ensure_worker(self):
        if self._worker is None or not self._worker.is_alive():
            self._worker = threading.Thread(target=self._drain, daemon=True,
                                            name="docktor-command-queue")
            self._worker.start()

    def _drain(self):
        while True:
            with self._cond:
                while not self._waiting:
                    self._cond.wait()
            # THE BENCH BEFORE THE ENTRY: popping first would take an order out
            # of the line while it still cannot run, and a drop_all() in that
            # gap would miss it.
            if not self._bench.acquire(timeout=1.0):
                continue
            with self._cond:
                entry = self._waiting.popleft() if self._waiting else None
            if entry is None:
                self._bench.release()
                continue
            try:
                self._execute(entry)
            except Exception as err:                        # pragma: no cover
                self.finished(entry, 1, f"❌ {entry['label']} raised: {err}")
            finally:
                self._bench.release()

    def _changed(self):
        try:
            self._on_change(self.snapshot())
        except Exception:
            pass

    @staticmethod
    def _same(a, b):
        return (a["key"], a["name"], a["scope"], a["extra"]) == \
               (b["key"], b["name"], b["scope"], b["extra"])
