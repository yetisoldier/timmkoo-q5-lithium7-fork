#!/system/bin/sh
# A per-device fallback only; never modify the vendor NVRAM/calibration files.
set -eu
directory=/data/misc/wifi
address=$directory/q5-stable-mac
temporary=$directory/.q5-stable-mac.$$
valid_address() {
    [ -f "$address" ] && [ ! -L "$address" ] &&
        [ "$(wc -c < "$address" | tr -d ' ')" = 6 ] &&
        [ "$(od -An -tx1 -N1 "$address" | tr -d ' \n')" = 02 ]
}
if [ -e "$address" ] || [ -L "$address" ]; then
    if valid_address; then exit 0; fi
    log -p e -t Q5WiFi 'Invalid persistent fallback address; retaining file'
    exit 1
fi
if [ ! -d "$directory" ]; then
    mkdir -p "$directory"
    chown system:wifi "$directory"
    chmod 0770 "$directory"
fi
trap 'rm -f "$temporary"' EXIT
random=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
[ "${#random}" = 32 ]
case "$random" in *[!0-9a-f]*) exit 1;; esac
# Fixed 02 prefix means locally administered unicast; remaining 40 bits vary.
escaped='\x02'
for column in 1-2 3-4 5-6 7-8 9-10; do
    escaped="$escaped\x$(printf '%s' "$random" | cut -c "$column")"
done
(umask 077; set -C; printf '%b' "$escaped" > "$temporary")
[ "$(wc -c < "$temporary" | tr -d ' ')" = 6 ]
chown system:wifi "$temporary"
chmod 0640 "$temporary"
restorecon "$temporary"
sync
# Hard-link publication is atomic and cannot replace an existing identity.
ln "$temporary" "$address"
restorecon "$address"
sync
log -p i -t Q5WiFi 'Persistent fallback address initialized'
