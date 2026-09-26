#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📊 One `docker stats` sample. Not a stream.
#   ./stats.sh
# TAB rows, no header: NAME CPU% MEM_USAGE MEM% NET_IO BLOCK_IO PIDS
# --no-stream is the whole point: the streaming form never exits, and every
# reader here wants ONE reading that ends.
# Stopped containers are absent by design — a zero row for a stopped container
# is a number that looks like telemetry. Join against ps.sh for every container.
# NO _common.sh, ON PURPOSE (PLAN-3319.01). Nothing below reads a variable or
# calls a function from it, and sourcing it cost ~60 ms of CPU — more than the
# work itself — on a script the manager runs on a clock: the cost meter every
# 30 s, the resource sampler every minute, the live meters every 5 s. Source
# it again the day this script needs something from it.

docker stats --no-stream --format \
    '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}	{{.MemPerc}}	{{.NetIO}}	{{.BlockIO}}	{{.PIDs}}'
