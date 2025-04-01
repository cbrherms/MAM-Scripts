#!/bin/bash

###################################
# Global Configuration
###################################
MAM_ID="${MAM_ID:-default}"
IPSOURCE="${IPSOURCE:-ifconfigco}"                 # Options: ifconfigco or mam
WORKDIR="${WORKDIR:-/config}"                      # Directory for temp files
COOKIE_FILE="${WORKDIR}/MAM-seedbox.cookie"        # Location of the cookie file

###################################
# Functions
###################################

check_workdir_permissions() {
    if [ ! -w "$WORKDIR" ]; then
        echo "[!] Error: Write permission denied for working directory '$WORKDIR'"
        exit 1
    else
        echo "[*] Working directory '$WORKDIR' is writable."
    fi
}

new_ip() {
    case $IPSOURCE in
        "ifconfigco")
            curl -s -4 ifconfig.co | md5sum | awk '{print "ifconfigco:" $1}'
            ;;
        "mam")
            curl -s https://www.myanonamouse.net/myip.php | md5sum | awk '{print "mam:" $1}'
            ;;
        *)
            echo "[!] Error: Invalid IP retrieval method '$IPSOURCE'. Expected 'ifconfigco' or 'mam'."
            return 1
            ;;
    esac
}

old_ip() {
    [ -f "${WORKDIR}/MAM.ip" ] && cat "${WORKDIR}/MAM.ip"
}

save_ip() {
    printf "%s" "$1" > "${WORKDIR}/MAM.ip"
}

header() {
    if [ -f "$COOKIE_FILE" ]; then
        cat "$COOKIE_FILE"
    else
        printf "mam_id=%s" "$MAM_ID"
    fi
}

update_mam() {
    local ENDPOINT="https://t.myanonamouse.net/json/dynamicSeedbox.php"
    curl -s -b "$(header)" -c "$COOKIE_FILE" "$ENDPOINT" | grep '"Success":true' >/dev/null
}

###################################
# Main Execution
###################################
echo "=============================================="
echo "   MyAnonamouse seedbox API run started at $(date)"
echo "=============================================="
echo

echo "[*] Verifying working directory permissions..."
check_workdir_permissions
echo

if [ "$MAM_ID" = "default" ]; then
    echo "[!] Error: MAM_ID not set in the script."
    exit 1
fi

NEW_IP="$(new_ip)"
if [ $? -ne 0 ] || [ -z "$NEW_IP" ]; then
    echo "[!] Error: Unable to fetch current IP."
    exit 1
fi

if [ "$(old_ip)" != "$NEW_IP" ]; then
    echo "[*] IP change detected. Updating MAM session..."
    if update_mam; then
        save_ip "$NEW_IP"
        echo "[+] Success: MAM IP updated to $NEW_IP."
    else
        echo "[!] Error: MAM IP update failed."
        exit 1
    fi
else
    echo "[*] No IP change detected. No update required."
fi

echo "=============================================="
echo "   Seedbox API IP update run completed."
echo "=============================================="