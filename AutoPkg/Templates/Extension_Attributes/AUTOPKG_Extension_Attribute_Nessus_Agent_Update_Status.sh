#!/bin/bash
##########################################################################
# Jamf Extension Attribute: AutoPkg Nessus Agent Update Status
#
# Purpose:
#   Checks whether Nessus Agent is installed and up-to-date.
#   Compares the installed version against AutoPkg latest version (%version%).
#
# Functionality:
#   1. Checks /Library/NessusAgent/run/sbin/nessuscli for installation.
#   2. Reads the installed version.
#   3. Compares the installed version with the latest version.
#   4. Returns one of three EA results:
#        - <result>Not Installed</result>
#        - <result>Needs Update</result>
#        - <result>Up-to-date</result>
#   5. Removes all existing JSON files for the app before writing the new one.
#   6. Logs timestamps, installed version, latest version, status, and cleanup actions.
#   7. Only creates JSON files if status is "Needs Update".
##########################################################################

APP_NAME="Nessus Agent"
LATEST_VERSION="%version%" # AutoPkg will replace this
APP_PATH="/Library/NessusAgent/run/sbin/nessuscli"
=""
STATUS="Not Installed"
JSON_DIR="/usr/local/autopkg/AutoPkg_App_Updates"
mkdir -p "$JSON_DIR"

# ----------------------------------------------------------------------
# Function to get a Jamf-safe timestamp
# ----------------------------------------------------------------------
current_timestamp() {
    local RAW_DATE
    RAW_DATE=$(date '+%Y-%m-%d %H:%M')
    local YEAR=${RAW_DATE:0:4}
    local MONTH=${RAW_DATE:5:2}
    local DAY=${RAW_DATE:8:2}
    local HOUR24=${RAW_DATE:11:2}
    local MINUTE=${RAW_DATE:14:2}
    local AMPM HOUR12

    if [ "$HOUR24" -ge 12 ]; then
        AMPM="PM"
        HOUR12=$((HOUR24 % 12))
        [ "$HOUR12" -eq 0 ] && HOUR12=12
    else
        AMPM="AM"
        HOUR12=$HOUR24
    fi

    echo "$MONTH-$DAY-$YEAR $HOUR12:$MINUTE$AMPM"
}

# ----------------------------------------------------------------------
# Logging function
# ----------------------------------------------------------------------
log() {
    echo "$(current_timestamp) - $1"
}

# ----------------------------------------------------------------------
# Version comparison helper
# ----------------------------------------------------------------------
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -V | head -n1)" = "$1" ]
}

# ----------------------------------------------------------------------
# Check if Nessus Agent is installed and log the path
# ----------------------------------------------------------------------
if [ -x "$APP_PATH" ]; then
    log "Found $APP_NAME at $APP_PATH"
else
    log "$APP_NAME not found at $APP_PATH"
fi

# ----------------------------------------------------------------------
# Determine update status
# ----------------------------------------------------------------------
if [ -x "$APP_PATH" ]; then
    INSTALLED_VERSION=$("$APP_PATH" --version 2>&1 | awk 'NR==1{print $4}' | sed 's/^ //')
    if [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; then
        STATUS="Needs Update"
    else
        STATUS="Up-to-date"
    fi
fi

# Output EA result
echo "<result>$STATUS</result>"

# Log app info
log "$APP_NAME installed version: ${INSTALLED_VERSION:-N/A}"
log "$APP_NAME latest version: $LATEST_VERSION"
log "$APP_NAME status: $STATUS"

# ----------------------------------------------------------------------
# Safely remove old JSON files for this app
# ----------------------------------------------------------------------
OLD_FILES=$(ls "$JSON_DIR" 2>/dev/null | grep -F "${APP_NAME}-")
if [ -n "$OLD_FILES" ]; then
    log "Removing old JSON files for $APP_NAME..."
    echo "$OLD_FILES" | while IFS= read -r file; do
        FILE_PATH="$JSON_DIR/$file"
        rm -f "$FILE_PATH"
        log "Deleted: $FILE_PATH"
    done
else
    log "No old JSON files found for $APP_NAME."
fi

# ----------------------------------------------------------------------
# Create JSON file if update is needed AND installed version is known
# ----------------------------------------------------------------------
if [ "$STATUS" = "Needs Update" ] && [ -n "$INSTALLED_VERSION" ]; then
    JSON_FILE="$JSON_DIR/${APP_NAME}-${LATEST_VERSION}.json"
    cat <<EOF > "$JSON_FILE"
{
  "name": "$APP_NAME",
  "status": "$STATUS",
  "installed_version": "$INSTALLED_VERSION",
  "latest_version": "$LATEST_VERSION",
  "install_trigger": "install_${APP_NAME}_AUTOPKG_SILENT_UPDATE_QUIT",
  "date": "$(current_timestamp)"
}
EOF
    log "JSON file created: $JSON_FILE"
else
    log "Status is '$STATUS' or installed version unknown. Skipping JSON creation."
fi

exit 0