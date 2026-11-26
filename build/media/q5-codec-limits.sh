#!/system/bin/sh
# Android 7 init has no per-service rlimit option. Raise only media.codec's
# MEMLOCK limit so the MT6582 M4U backend can lock its DMA working buffers.
# Called by init after every service start; never accepts a caller-supplied PID.
for q5_attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    q5_pid="$(/system/bin/pidof media.codec)"
    case "$q5_pid" in
        ''|*[!0-9]*) sleep 0.05; continue ;;
    esac
    if [ "$(readlink /proc/$q5_pid/exe)" = /system/bin/mediacodec ] &&
       grep -q '^Uid:[[:space:]]*1046[[:space:]]' /proc/$q5_pid/status; then
        exec /system/bin/prlimit "$q5_pid" 8 33554432 33554432
    fi
    sleep 0.05
done
exit 1
