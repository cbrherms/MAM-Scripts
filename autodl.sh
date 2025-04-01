#!/bin/bash

###################################
# Global Configuration
###################################
MAM_ID="${MAM_ID:-default}"
MAX_DOWNLOADS="${MAX_DOWNLOADS:-45}"               # Maximum torrents to download in one run.
SET_ASIDE="${SET_ASIDE:-10}"                       # Percentage to set aside (unsat buffer).
WORKDIR="${WORKDIR:-/config}"                      # Directory for temp files.
TORRENT_DIR="${TORRENT_DIR:-${WORKDIR}/torrents}"  # Directory to save torrents (default WORKDIR/torrents).
COOKIE_FILE="${WORKDIR}/MAM-autodl.cookie"         # Cookie file for authentication (not overridable).
DRY_RUN="${DRY_RUN:-0}"                            # Set to 1 to perform a dry run.
DEBUG="${DEBUG:-1}"                                # For additional debugging info.

###################################
# Search Configuration
###################################
SORT_CRITERIA="${SORT_CRITERIA:-dateDesc}"         # API sort option.
MAIN_CATEGORY="${MAIN_CATEGORY:-[14,13]}"          # JSON array of main category IDs.
LANGUAGES="${LANGUAGES:-[1]}"                      # JSON array of language IDs.
SEARCH_TYPE="${SEARCH_TYPE:-fl-VIP}"               # Search type (e.g. fl-VIP, all, etc.)

###################################
# Numeric Filter Configuration
###################################
MIN_SIZE="${MIN_SIZE:-2}"                          # Minimum size (in chosen unit).
MAX_SIZE="${MAX_SIZE:-50}"                         # Maximum size (in chosen unit).
UNIT_STR="${UNIT_STR:-MiB}"                        # Units: Bytes, KiB, MiB, GiB.
MIN_SEEDERS="${MIN_SEEDERS:-1}"                    # Minimum seeders required.
MAX_SEEDERS="${MAX_SEEDERS:-5}"                    # Maximum seeders allowed.

###################################
# Internal Global Variables
###################################
BASE_URL="https://www.myanonamouse.net"
unsat_left=0
reject_reason=""

if [[ "${TORRENT_DIR}" != */ ]]; then
    TORRENT_DIR="${TORRENT_DIR}/"
fi

case "$UNIT_STR" in
    "Bytes") UNIT_VAL=1 ;;
    "KiB")   UNIT_VAL=1024 ;;
    "MiB")   UNIT_VAL=1048576 ;;
    "GiB")   UNIT_VAL=1073741824 ;;
    *)       UNIT_VAL=1048576 ;;  # Default to MiB if unknown
esac

declare -a candidate_torrents
declare -A candidate_torrent_info

###################################
# Functions
###################################

# check_workdir_permissions: Checks if the working directory is writable.
check_workdir_permissions() {
    if [ ! -w "$WORKDIR" ]; then
        echo "Error: Write permission denied for working directory '$WORKDIR'"
        exit 1
    else
        echo "Working directory '$WORKDIR' is writable."
    fi
}

# check_cookie_session: Sets up session.
# Also retrieves USER_ID dynamically.
check_cookie_session() {
    echo "Checking existing cookie file..."
    local endpoint="/jsonLoad.php?snatch_summary"
    local url="${BASE_URL}${endpoint}"
    
    USER_RESPONSE=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$url" | tee MAM.json)
    USER_ID=$(echo "$USER_RESPONSE" | jq .uid 2>/dev/null)
    
    if [ "${USER_ID}x" = "x" ]; then
        echo "Session invalid."
        if [ -z "$MAM_ID" ]; then
            echo "Please update the MAM_ID in the script."
            exit 1
        fi
        
        USER_RESPONSE=$(curl -s -b "mam_id=${MAM_ID}" -c "$COOKIE_FILE" "$url" | tee MAM.json)
        USER_ID=$(echo "$USER_RESPONSE" | jq .uid 2>/dev/null)
        
        if [ "${USER_ID}x" = "x" ]; then
            echo " => Cannot create new session!"
            exit 1
        else
            echo " => New Session created"
        fi
    else
        echo " => Existing session valid"
    fi
}

# convert_size: Converts a torrent's reported size (value and unit) into the system unit.
# It first converts the value to bytes, then divides by UNIT_VAL.
convert_size() {
    local value="$1"
    local source_unit="$2"
    local bytes
    case "$source_unit" in
        "Bytes") bytes="$value" ;;
        "KiB")   bytes=$(echo "$value * 1024" | bc -l) ;;
        "MiB")   bytes=$(echo "$value * 1048576" | bc -l) ;;
        "GiB")   bytes=$(echo "$value * 1073741824" | bc -l) ;;
        *)       echo "0" ; return 1 ;;
    esac
    echo "scale=2; $bytes / $UNIT_VAL" | bc -l
}

# get_file_name: Extracts the filename from the header file.
# Also removes extraneous characters (quotes, brackets and carriage returns).
get_file_name() {
    local header_file="$1"
    local file_name
    file_name=$(grep -i "content-disposition:" "$header_file" | sed -E 's/.*filename=//I' | tr -d '"[]' | tr -d '\r')
    echo "$file_name"
}

update_mam_id() {
    local header_file="$1"
    new_mam_id=$(grep -i "set-cookie:" "$header_file" | grep -oE 'mam_id=[^;]+' | cut -d'=' -f2)
    if [ -n "$new_mam_id" ]; then
        echo "$new_mam_id" > "$COOKIE_FILE"
        MAM_ID="$new_mam_id"
    fi
}

request_manager() {
    local url="$1" method="$2" query="$3" json_payload="$4"
    local header_file cookie_header http_response http_code response
    header_file=$(mktemp)
    cookie_header="mam_id=${MAM_ID}"

    if [ "$method" == "get" ]; then
        http_response=$(curl -s -w "\n%{http_code}" -G -D "$header_file" -H "cookie: $cookie_header" --data "$query" "$url")
    elif [ "$method" == "post" ]; then
        http_response=$(curl -s -w "\n%{http_code}" -D "$header_file" -X POST -H "cookie: $cookie_header" \
             -H "Content-Type: application/json" -d "$json_payload" "$url")
    fi

    http_code=$(echo "$http_response" | tail -n1)
    response=$(echo "$http_response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo "Error communicating with API. HTTP status code: $http_code" >&2
        rm "$header_file"
        exit 1
    fi

    update_mam_id "$header_file"
    echo "$response"
    rm "$header_file"
}

get_user_data() {
    local endpoint="/jsonLoad.php"
    local url="${BASE_URL}${endpoint}"
    local query="id=${USER_ID}&notif=true&pretty=true&snatch_summary=true"
    user_data_json=$(request_manager "$url" "get" "$query" "")
    echo "$user_data_json"
}

get_unsat_data() {
    local user_json unsat_limit_unsat unsat_count_unsat
    user_json=$(get_user_data)
    unsat_limit_unsat=$(echo "$user_json" | jq -r '.unsat.limit')
    unsat_count_unsat=$(echo "$user_json" | jq -r '.unsat.count')
    unsat_limit=$(printf "%.0f" "${unsat_limit_unsat}")
    unsat_count=$(printf "%.0f" "${unsat_count_unsat}")
    unsat_left=$(echo "$unsat_limit $unsat_count $SET_ASIDE" | awk '{printf "%.0f", $1 - $2 - (($3/100)*$1)}')
    echo "You can autodownload ${unsat_left} torrents."
}

# check_for_non_candidate_torrent: Converts the torrent's reported size into the chosen unit (UNIT_STR), then compares it with MIN_SIZE and MAX_SIZE.
# Also checks seeder counts.
check_for_non_candidate_torrent() {
    reject_reason=""
    local torrent_json="$1"
    local my_snatched size_str size_value size_unit converted_size seeders

    my_snatched=$(echo "$torrent_json" | jq '.my_snatched')
    if [ "$my_snatched" -eq 1 ]; then
        reject_reason="Already snatched"
        return 1
    fi

    # Clean up the size string to remove carriage returns and extra spaces
    size_str=$(echo "$torrent_json" | jq -r '.size' | tr -d '\r' | xargs)
    size_value=$(echo "$size_str" | awk '{print $1}' | tr -d ',')
    size_unit=$(echo "$size_str" | awk '{print $2}')
    if [ -z "$size_value" ] || [ -z "$size_unit" ]; then
        reject_reason="Missing size information"
        return 1
    fi

    converted_size=$(convert_size "$size_value" "$size_unit")
    if [ -z "$converted_size" ] || (( $(echo "$converted_size == 0" | bc -l) )); then
        reject_reason="Invalid converted size"
        return 1
    fi

    if (( $(echo "$converted_size < $MIN_SIZE" | bc -l) )); then
        reject_reason="Size below minimum ($converted_size < $MIN_SIZE)"
        return 1
    elif (( $(echo "$converted_size > $MAX_SIZE" | bc -l) )); then
        reject_reason="Size above maximum ($converted_size > $MAX_SIZE)"
        return 1
    fi

    seeders=$(echo "$torrent_json" | jq '.seeders')
    if (( seeders < MIN_SEEDERS )); then
        reject_reason="Seeder count below minimum ($seeders < $MIN_SEEDERS)"
        return 1
    elif (( seeders > MAX_SEEDERS )); then
        reject_reason="Seeder count above maximum ($seeders > $MAX_SEEDERS)"
        return 1
    fi

    return 0
}

candidate_torrents_search() {
    local perpage=100
    get_unsat_data
    local endpoint="/tor/js/loadSearchJSONbasic.php"
    local url="${BASE_URL}${endpoint}"
    local start_number=0
    local found
    while [ "$unsat_left" -gt 0 ]; do
        json_payload=$(jq -n \
            --argjson main_cat "$MAIN_CATEGORY" \
            --arg sort "$SORT_CRITERIA" \
            --arg search "$SEARCH_TYPE" \
            --argjson startNumber "$start_number" \
            --argjson perpage "$perpage" \
            --argjson minSize "$MIN_SIZE" \
            --argjson maxSize "$MAX_SIZE" \
            --argjson unit "$UNIT_VAL" \
            --argjson minSeeders "$MIN_SEEDERS" \
            --argjson maxSeeders "$MAX_SEEDERS" \
            --argjson browse_lang "$LANGUAGES" \
            '{
                perpage: $perpage,
                tor: {
                    main_cat: $main_cat,
                    searchType: $search,
                    startNumber: $startNumber,
                    sortType: $sort,
                    minSize: $minSize,
                    maxSize: $maxSize,
                    unit: $unit,
                    minSeeders: $minSeeders,
                    maxSeeders: $maxSeeders,
                    browse_lang: $browse_lang
                }
            }')
        torrent_response=$(request_manager "$url" "post" "" "$json_payload")
        found=$(echo "$torrent_response" | jq -r '.found' )
        for row in $(echo "$torrent_response" | jq -r '.data[] | @base64'); do
            _decode() {
                echo "$row" | base64 --decode
            }
            candidate_id=$(_decode | jq -r '.id')
            candidate_size=$(_decode | jq -r '.size')
            candidate_seeders=$(_decode | jq -r '.seeders')
            if check_for_non_candidate_torrent "$(_decode)" ; then
                accepted="ACCEPTED"
                candidate_torrents+=("$candidate_id")
                candidate_torrent_info["$candidate_id"]="Size: ${candidate_size}; Seeders: ${candidate_seeders}"
                unsat_left=$((unsat_left - 1))
            else
                accepted="REJECTED"
            fi

            if [ "$DEBUG" -eq 1 ]; then
                if [ "$accepted" = "REJECTED" ]; then
                    echo "Torrent ID: ${candidate_id} | Size: ${candidate_size} | Seeders: ${candidate_seeders} => ${accepted}: ${reject_reason}"
                else
                    echo "Torrent ID: ${candidate_id} | Size: ${candidate_size} | Seeders: ${candidate_seeders} => ${accepted}"
                fi
            fi

            if [ "${#candidate_torrents[@]}" -ge "$MAX_DOWNLOADS" ]; then
                break 2
            fi
        done

        start_number=$((start_number + perpage))
        if [ "$start_number" -ge "$found" ]; then
            break
        fi
    done
    echo "${#candidate_torrents[@]} candidate torrents identified."
}

download_candidate_torrents() {
    candidate_torrents_search
    if [ "$DRY_RUN" -eq 1 ]; then
        for torrent_id in "${candidate_torrents[@]}"; do
            echo "${BASE_URL}/t/${torrent_id}"
        done
    else
        local endpoint="/tor/download.php"
        local url="${BASE_URL}${endpoint}"
        local torrent_info
        for torrent_id in "${candidate_torrents[@]}"; do
            sleep 2
            header_file=$(mktemp)
            body_file=$(mktemp)
            cookie_header="mam_id=${MAM_ID}"
            
            # Retry logic for curl command
            local retry=0
            local max_retries=3
            local curl_response http_code
            while [ $retry -lt $max_retries ]; do
                curl_response=$(curl -s -w "\n%{http_code}" -G -D "$header_file" \
                              -H "cookie: $cookie_header" --data "tid=${torrent_id}" "$url" \
                              -o "$body_file")
                http_code=$(echo "$curl_response" | tail -n1)
                if [ "$http_code" -eq 200 ]; then
                    break
                else
                    echo "Error downloading torrent ID ${torrent_id}, HTTP code: $http_code. Retrying..."
                    sleep 5
                    retry=$((retry+1))
                fi
            done
            
            if [ "$http_code" -ne 200 ]; then
                echo "Failed to download torrent ID ${torrent_id} after ${max_retries} attempts. Skipping..."
                rm "$header_file" "$body_file"
                continue
            fi

            update_mam_id "$header_file"
            file_name=$(get_file_name "$header_file")
            # Fallback to torrent_id.torrent if file_name is empty
            if [ -z "$file_name" ]; then
                file_name="${torrent_id}.torrent"
            fi
            # Save downloaded file (file name cleaned by get_file_name includes removal of undesired chars)
            cat "$body_file" > "${TORRENT_DIR}${file_name}"
            torrent_info="${candidate_torrent_info[$torrent_id]}"
            echo "Downloaded torrent ID ${torrent_id} as ${file_name} (${torrent_info})"
            rm "$header_file" "$body_file"
        done
    fi
}

###################################
# Main Execution
###################################
echo "=============================================="
echo "   MyAnonamouse autodownload run started at $(date)"
echo "=============================================="
echo

echo "[*] Verifying working directory permissions..."
check_workdir_permissions
echo

echo "[*] Checking session status..."
check_cookie_session
echo

echo "[*] Downloading candidate torrents..."
download_candidate_torrents
echo

echo "=============================================="
echo "   Completed processing ${#candidate_torrents[@]} torrents."
echo "=============================================="