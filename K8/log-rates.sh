#!/usr/bin/env bash
# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
# 📊 Log size and growth rate (bytes/sec) per container, over a sample window.
#   ./log-rates.sh [sample_duration_seconds]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

sample_sec="${1:-2}"
if ! [[ "$sample_sec" =~ ^[0-9]+$ ]]; then
    sample_sec=2
fi

ids="$(docker ps -qa)"
if [ -z "$ids" ]; then
    log_info "No containers found on this host."
    exit 0
fi

container_info="$(docker inspect --format '{{.Name}}	{{.LogPath}}' $ids 2>/dev/null)"
if [ -z "$container_info" ]; then
    log_info "Could not inspect container log paths."
    exit 0
fi

format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f GB", b/1073741824}')"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f MB", b/1048576}')"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(awk -v b="$bytes" 'BEGIN {printf "%.2f KB", b/1024}')"
    else
        echo "${bytes} B"
    fi
}

get_file_size() {
    local path="$1"
    if [ -f "$path" ]; then
        stat -c%s "$path" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

declare -A path_map
declare -A size_t0

names=()
while IFS=$'\t' read -r raw_name log_path; do
    [ -z "$raw_name" ] && continue
    name="${raw_name#/}"
    names+=("$name")
    path_map["$name"]="$log_path"
    size_t0["$name"]=$(get_file_size "$log_path")
done <<< "$container_info"

log_info "Sampling log growth over ${sample_sec}s..."
sleep "$sample_sec"

printf "%-25s %-15s %-18s %-15s\n" "CONTAINER NAME" "LOG SIZE" "LOG RATE" "STATUS"
printf "%-25s %-15s %-18s %-15s\n" "-------------------------" "---------------" "------------------" "---------------"

for name in "${names[@]}"; do
    log_path="${path_map["$name"]}"
    s0="${size_t0["$name"]}"
    s1=$(get_file_size "$log_path")
    
    diff=$((s1 - s0))
    if [ "$diff" -lt 0 ]; then diff=0; fi
    
    rate_bps=$(awk -v d="$diff" -v t="$sample_sec" 'BEGIN {printf "%.0f", d/t}')
    
    size_str=$(format_bytes "$s1")
    rate_str=$(format_bytes "$rate_bps")/s
    
    if [ "$rate_bps" -gt 1048576 ]; then
        status="🚨 CRITICAL SPAM"
    elif [ "$rate_bps" -gt 102400 ]; then
        status="⚠️ HIGH LOG RATE"
    elif [ "$rate_bps" -gt 1024 ]; then
        status="⚡ ACTIVE LOGS"
    else
        status="OK (Quiet)"
    fi
    
    printf "%-25s %-15s %-18s %-15s\n" "$name" "$size_str" "+$rate_str" "$status"
done
