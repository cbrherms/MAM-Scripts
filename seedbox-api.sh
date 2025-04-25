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
    local ip
    case $IPSOURCE in
        "ifconfigco")
            ip=$(curl -s -4 ifconfig.co)
            ;;
        "mam")
            # IP address has to be extracted from the HTML response of the page
            ip=$(curl -s https://www.myanonamouse.net/myip.php | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
            ;;
        *)
            echo "[!] Error: Invalid IP retrieval method '$IPSOURCE'. Expected 'ifconfigco' or 'mam'."
            return 1
            ;;
    esac
    if [ -z "$ip" ]; then
        return 1
    fi
    echo "$ip"
}

old_ip() {
    if [ -f "${WORKDIR}/MAM.ip" ]; then
        cat "${WORKDIR}/MAM.ip"
    fi
}

save_ip() {
    printf "%s" "$1" > "${WORKDIR}/MAM.ip"
}

validate_cookie() {
    local response
    response=$(curl -s -b "$COOKIE_FILE" "https://www.myanonamouse.net/jsonLoad.php")
    echo "$response" | jq -e '.uid // empty' >/dev/null 2>&1
}

header() {
    if [ -f "$COOKIE_FILE" ] && validate_cookie; then
        cat "$COOKIE_FILE"
    else
        printf "mam_id=%s" "$MAM_ID"
    fi
}

get_new_ip() {
    local max_retries=3
    local attempt=1
    local ip=""
    
    while [ $attempt -le $max_retries ]; do
        ip=$(new_ip)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        else
            echo "[!] Attempt $attempt: Unable to fetch current IP. Retrying in 5 seconds..."
            sleep 5
        fi
        attempt=$((attempt+1))
    done
    return 1
}

update_mam() {
    local ENDPOINT="https://t.myanonamouse.net/json/dynamicSeedbox.php"
    local max_retries=3
    local attempt=1
    local update_exit_code=1

    while [ $attempt -le $max_retries ]; do
        if curl -s -b "$(header)" -c "$COOKIE_FILE" "$ENDPOINT" | grep -q '"Success":true'; then
            update_exit_code=0
            break
        else
            echo "[!] Attempt $attempt failed to update MAM session IP."
            if [ $attempt -lt $max_retries ]; then
                sleep 5
            fi
        fi
        attempt=$((attempt+1))
    done
    return $update_exit_code
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

echo "[*] Checking current IP address..."
NEW_IP=$(get_new_ip) || { echo "[!] Error: Unable to fetch current IP after multiple attempts."; exit 1; }
OLD_IP=$(old_ip)

if [ "$OLD_IP" != "$NEW_IP" ]; then
    echo "[*] IP change detected: Old IP = $OLD_IP | New IP = $NEW_IP"
    echo "[*] Updating MAM session..."
    if update_mam; then
        save_ip "$NEW_IP"
        echo "[+] Success: MAM IP updated to $NEW_IP"
    else
        echo "[!] Error: MAM IP update failed. Exhausted retries."
        exit 1
    fi
else
    echo "[*] No IP change detected. No update required."
fi

echo "=============================================="
echo "   Seedbox API IP update run completed."
echo "=============================================="