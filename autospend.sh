#!/bin/bash

###################################
# Global Configuration
###################################
MAM_ID="${MAM_ID:-default}"
POINTS_BUFFER="${POINTS_BUFFER:-5000}"             # Default buffer; can be overridden from outside.
BUY_VIP="${BUY_VIP:-1}"                            # Set to 1 to enable buying of VIP (overridable).
WEDGEHOURS="${WEDGEHOURS:-0}"                      # Buy a wedge every x hours; 0 disables wedge buying.
WORKDIR="${WORKDIR:-/config}"                      # Directory for temp files.
COOKIE_FILE="${WORKDIR}/MAM-autospend.cookie"      # Location of the cookie file.

###################################
# Internal Global Variables
###################################
POINTSURL='https://www.myanonamouse.net/json/bonusBuy.php/?spendtype=upload&amount='
VIPURL='https://www.myanonamouse.net/json/bonusBuy.php/?spendtype=VIP&duration=max&_='
WEDGEURL='https://www.myanonamouse.net/json/bonusBuy.php/?spendtype=wedges&source=points&_= '
TIMESTAMP=$(date +%s%3N)

###################################
# Functions
###################################

check_workdir_permissions() {
    if [ ! -w "$WORKDIR" ]; then
        echo " => Error: Write permission denied for working directory '$WORKDIR'" >&2
        exit 1
    else
        echo " => Working directory '$WORKDIR' is writable."
    fi
}

check_cookie_session() {
    echo " => Checking existing cookie file..."
    USER_ID=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        https://www.myanonamouse.net/jsonLoad.php | tee "/tmp/MAM.json" | jq .uid 2>/dev/null)
    
    if [ -z "$USER_ID" ] || [ "${USER_ID}x" = "x" ]; then
        echo " => Session no longer valid"
        if [ "$MAM_ID" = "default"  ]; then
            echo " => Please add/update the MAM_ID value." >&2
            exit 1
        fi
        
        echo " => Attempting to create a new session with MAM_ID..."
        USER_ID=$(curl -s -b "mam_id=${MAM_ID}" -c "$COOKIE_FILE" \
            https://www.myanonamouse.net/jsonLoad.php | tee "/tmp/MAM.json" | jq .uid 2>/dev/null)
        
        if [ -z "$USER_ID" ] || [ "${USER_ID}x" = "x" ]; then
            echo " => Cannot create new session!" >&2
            echo " => Check your MAM_ID has been set correctly" >&2
            exit 1
        else
            echo " => New Session created"
        fi
    else
        echo " => Existing session valid"
    fi
}

get_current_points() {
    POINTS=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        https://www.myanonamouse.net/jsonLoad.php?id=${USER_ID} | jq '.seedbonus')
    if [ $? -ne 0 ]; then
        echo " => Failed to get number of bonus points - aborting." >&2
        exit 1
    else
        echo " => Current points: $POINTS"
    fi
}

buy_wedge() {
    WEDGEMINS=$(expr $WEDGEHOURS \* 60 - 10)
    find "${WORKDIR}/wedge.last" -mmin -${WEDGEMINS} 2>/dev/null | grep -i wedge.last > /dev/null 2>/dev/null
    if [ $? -ne 0 ]; then
        echo " => Need to buy a wedge!"
        if [ $POINTS -lt 50000 ]; then
            echo " => Not enough points, skipping."
            return
        fi
        curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$WEDGEURL"
        touch "${WORKDIR}/wedge.last"
        get_current_points
    else
        echo " => Wedge already purchased in the last $WEDGEHOURS hours."
    fi
}

maximize_vip() {
    VIPUNTIL=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" "https://www.myanonamouse.net/jsonLoad.php?id=${USER_ID}" | jq -r .vip_until)
    now=$(date -u +%s)
    VIP_UNTIL_EPOCH=$(date -u -d "$VIPUNTIL" +%s 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo " => Failed to parse the date VIP expires. Proceeding with VIP purchase..."
    else
        DAYS_LEFT=$(( (VIP_UNTIL_EPOCH - now) / 86400 ))
        if [ $DAYS_LEFT -gt 60 ]; then
            echo " => VIP has $DAYS_LEFT days remaining. Skipping VIP purchase until this drops below 60 days."
            return
        fi
    fi

    VIPRESULT=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
        ${VIPURL}${TIMESTAMP} 2>/dev/null | jq .success)
    if [ "x$VIPRESULT" != "xtrue" ]; then
        echo " => VIP purchase failed!" >&2
    else
        echo " => Purchased max VIP with points available"
        get_current_points
    fi
}

spend_upload() {
    for i in 100 20 5 1; do
        UPLOADREQUIRED=$(expr $i \* 500 + ${POINTS_BUFFER})
        while [ $POINTS -gt $UPLOADREQUIRED ]; do
            echo " => Buying ${i}G of upload..."
            NEWPOINTS=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                ${POINTSURL}${i}'&_='${TIMESTAMP} | jq '.seedbonus' | sed -e 's/\..*$//')
            if [ $? -ne 0 ]; then
                echo " => Spend failed - cannot see new Bonus points." >&2
                exit 1
            fi
            if [ $NEWPOINTS -lt $POINTS ]; then
                POINTS=$NEWPOINTS
            else
                echo " => Points did not change - spending failed." >&2
                exit 1
            fi
        done
    done
    get_current_points
}

###################################
# Main execution block
###################################
echo "=============================================="
echo "   MyAnonamouse autospend run started at $(date)"
echo "=============================================="
echo

echo "[*] Verifying working directory permissions..."
check_workdir_permissions
echo

echo "[*] Checking session status..."
check_cookie_session
echo

echo "[*] Retrieving current bonus points..."
get_current_points
STARTING_POINTS=$POINTS
echo

if [ $WEDGEHOURS -gt 0 ]; then
    echo "[*] Checking if wedge purchase is required..."
    buy_wedge
    echo
fi

if [ "x$BUY_VIP" = "x1" ]; then
    echo "[*] Maximizing VIP status..."
    if [ "$POINTS" -lt "$POINTS_BUFFER" ]; then
        echo " => Current points ($POINTS) are below the threshold ($POINTS_BUFFER) - skipping spending."
    else
        maximize_vip
    fi
    echo
fi

echo "[*] Spending remaining bonus points on upload..."
if [ "$POINTS" -lt "$POINTS_BUFFER" ]; then
    echo " => Current points ($POINTS) are below the threshold ($POINTS_BUFFER) - skipping spending."
else
    spend_upload
fi
echo

echo "=============================================="
echo "   Completed spending points"
echo "   Total points spent: $(expr $STARTING_POINTS - $POINTS)"
echo "=============================================="