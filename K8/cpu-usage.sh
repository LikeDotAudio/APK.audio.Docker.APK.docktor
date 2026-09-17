#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 💲 Every running container's CUMULATIVE CPU time — the counter, not the rate.
#   ./cpu-usage.sh
# TAB rows, no header: name, id, started_at (epoch seconds), cpu_ns.
# `cpu_ns` is cpu_stats.cpu_usage.total_usage from the daemon's stats API: the
# nanoseconds of CPU the container has burned since IT STARTED. It resets to 0
# when the container restarts or is recreated, which is why the ledger in
# readers.py adds up DELTAS and reads a drop as a restart, never as a refund.
# NOT stats.sh: that prints a percentage of one core at the instant of the
# sample, and a meter built by summing instants misses everything between them.
# One stats call per container over the daemon socket, one-shot so it does not
# wait the second a streaming sample needs; forty containers is forty short calls.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

python3 - <<'PY'
import calendar
import http.client
import json
import os
import socket
import sys
import time

SOCKET = (os.environ.get("DOCKER_HOST", "") or "unix:///var/run/docker.sock")
SOCKET = SOCKET[len("unix://"):] if SOCKET.startswith("unix://") else "/var/run/docker.sock"


class UnixConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost", timeout=10)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(SOCKET)


def get(path):
    connection = UnixConnection()
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        if response.status != 200:
            return None
        return json.loads(body)
    finally:
        connection.close()


def epoch(stamp):
    # "2026-09-17T06:14:31.186509763Z" — trim the nanoseconds python cannot parse.
    try:
        head = stamp.split(".")[0].rstrip("Z")
        return calendar.timegm(time.strptime(head, "%Y-%m-%dT%H:%M:%S"))   # UTC in, UTC out
    except (ValueError, AttributeError):
        return 0


try:
    containers = get("/containers/json") or []
except OSError as err:
    sys.stderr.write("cpu-usage.sh: docker socket %s: %s\n" % (SOCKET, err))
    sys.exit(1)

for row in containers:
    ident = row.get("Id", "")
    name = (row.get("Names") or ["/?"])[0].lstrip("/")
    try:
        stats = get("/containers/%s/stats?stream=false&one-shot=true" % ident) or {}
        detail = get("/containers/%s/json" % ident) or {}
    except OSError:
        continue
    usage = (stats.get("cpu_stats") or {}).get("cpu_usage", {}).get("total_usage")
    if usage is None:
        continue
    started = epoch((detail.get("State") or {}).get("StartedAt", ""))
    print("\t".join([name, ident[:12], str(started), str(int(usage))]))
PY
