#!/system/bin/sh
# Recover a saved WPA-PSK startup connection without a resident monitor.
# Never enables Wi-Fi, enables a disabled profile, or changes credentials.
set -eu
active() {
    [ "$(getprop init.svc.p2p_supplicant)" = running ] ||
        [ "$(getprop init.svc.wpa_supplicant)" = running ]
}
psk_profiles() {
    networks=$(wpa_cli -i wlan0 list_networks 2>/dev/null) || return 1
    found=0
    while IFS="$(printf '\t')" read -r id name bssid flags; do
        case "$id" in ''|*[!0-9]*) continue;; esac
        case "$flags" in *DISABLED*) continue;; esac
        auth=$(wpa_cli -i wlan0 get_network "$id" key_mgmt 2>/dev/null) || return 1
        case "$auth" in
            *EAP*|*IEEE8021X*|*WPS*) return 1;; # Leave enterprise/WPS auth alone.
            *WPA-PSK*) found=1;;
        esac
    done <<EOF
$networks
EOF
    [ "$found" = 1 ]
}
poll=0
attempts=0
checked=0
while [ "$poll" -lt 30 ] && active; do
    status=$(wpa_cli -i wlan0 status 2>/dev/null) || status=''
    if printf '%s\n' "$status" | grep -q '^wpa_state=COMPLETED$'; then
        if [ "$attempts" -gt 0 ]; then
            log -p i -t Q5WiFi 'Startup association recovered; exiting'
        fi
        exit 0
    fi
    if [ -n "$status" ] && [ "$checked" = 0 ]; then
        psk_profiles || exit 0
        checked=1
    fi
    if [ "$checked" = 1 ] && { [ "$poll" = 10 ] || [ "$poll" = 20 ]; }; then
        # WPS can legitimately take longer. Leave its protocol alone.
        wps=$(wpa_cli -i wlan0 wps_get_status 2>/dev/null) || wps=''
        case "$wps" in *'PBC Status: Active'*) exit 0;; esac
        # Recheck connection and profile state immediately before retrying.
        status=$(wpa_cli -i wlan0 status 2>/dev/null) || status=''
        if printf '%s\n' "$status" | grep -q '^wpa_state=COMPLETED$'; then exit 0; fi
        active && psk_profiles || exit 0
        attempts=$((attempts + 1))
        log -p i -t Q5WiFi "Startup association stalled; retry $attempts of 2"
        wpa_cli -i wlan0 reassociate >/dev/null 2>&1 || true
    fi
    poll=$((poll + 1))
    sleep 2
done
if [ "$attempts" -gt 0 ]; then
    log -p w -t Q5WiFi 'Startup recovery limit reached; leaving Android in control'
fi
