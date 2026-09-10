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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

docker stats --no-stream --format \
    '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}	{{.MemPerc}}	{{.NetIO}}	{{.BlockIO}}	{{.PIDs}}'
