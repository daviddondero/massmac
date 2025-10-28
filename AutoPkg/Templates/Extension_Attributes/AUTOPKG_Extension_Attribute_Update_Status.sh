#!/bin/bash

##########################################################################
# Jamf Extension Attribute: AutoPkg App Update Status
#
# Purpose:
#   This script determines whether a specified macOS application is installed
#   and whether it is up-to-date. It is designed to integrate with AutoPkg
#   by using placeholder variables (%NAME% and %version%) that are replaced
#   during recipe execution.
#
# Detailed Functionality:
#   1. Define Variables:
#        - APP_NAME: The application name, provided by AutoPkg (%NAME%).
#        - LATEST_VERSION: The latest available version, provided by AutoPkg (%version%).
#        - APP_PATH: Will store the discovered app path if installed.
#        - INSTALLED_VERSION: Will store the current installed version of the app.
#        - STATUS: Holds the update status ("Not Installed", "Needs Update", "Up-to-date", "Unknown Version").
#        - JSON_DIR: Directory where JSON update files are stored (/usr/local/autopkg/AutoPkg_App_Updates).
#        - LOG_FILE: Log file path (/usr/local/autopkg/Logs/advanced_computer_search.log).
#
#   2. Version Comparison Utility:
#        - Function version_lt(): Robust version comparison using LC_ALL=C sort -V.
#
#   3. Timestamp Utility:
#        - Function current_timestamp() generates a Jamf-safe timestamp in MM-DD-YYYY H:MMAM/PM format.
#
#   4. Logging Utility:
#        - Function log() prepends timestamps to log messages.
#        - Logs are written to /usr/local/autopkg/Logs/advanced_computer_search.log.
#
#   5. Locate Installed Application:
#        - Searches standard locations for the app bundle.
#
#   6. Determine Update Status:
#        - Compares installed version with latest version.
#        - Handles missing version info with "Unknown Version" status.
#
#   7. Output EA Result:
#        - Prints <result> tag for Jamf EA.
#
#   8. Cleanup Old JSON Files:
#        - Deletes outdated JSON files for the app.
#
#   9. Create JSON File (Conditional):
#        - Only created if update is needed and version is known.
#        - Sanitizes app name for safe use in install_trigger.
#
# Usage:
#   - Designed for AutoPkg EA integration.
#   - Output can be consumed by Jamf policies or other scripts.
#
# Compatibility:
#   - Bash 3.x (macOS default shell)
#   - Requires PlistBuddy, jq, and standard macOS utilities
##########################################################################

APP_NAME="%NAME%"               # AutoPkg will replace this
LATEST_VERSION="%version%"      # AutoPkg will replace this
APP_PATH=""
INSTALLED_VERSION=""
STATUS="Not Installed"
JSON_DIR="/usr/local/autopkg/AutoPkg_App_Updates"
LOG_FILE="/usr/local/autopkg/Logs/advanced_computer_search.log"

mkdir -p "$JSON_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
> "$LOG_FILE"

# ----------------------------------------------------------------------
# Version comparison function (robust for multi-digit versions)
# ----------------------------------------------------------------------
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -V | head -n1)" = "$1" ]
}

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
    echo "$(current_timestamp) - $1" | tee -a "$LOG_FILE"
}

# ----------------------------------------------------------------------
# Locate installed app
# ----------------------------------------------------------------------
POSSIBLE_PATHS=(
    "/Applications/${APP_NAME}.app"
    "/Applications/Utilities/${APP_NAME}.app"
)

for p in "${POSSIBLE_PATHS[@]}"; do
    if [ -d "$p" ]; then
        APP_PATH="$p"
        log "Found $APP_NAME at $APP_PATH"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    log "$APP_NAME not found in standard locations."
fi

# ----------------------------------------------------------------------
# Determine update status
# ----------------------------------------------------------------------
if [ -n "$APP_PATH" ]; then
    INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
    if [ -z "$INSTALLED_VERSION" ]; then
        STATUS="Unknown Version"
    elif version_lt "$INSTALLED_VERSION" "$LATEST_VERSION"; then
        STATUS="Needs Update"
    else
        STATUS="Up-to-date"
    fi
fi

# ----------------------------------------------------------------------
# Output EA result
# ----------------------------------------------------------------------
echo "<result>$STATUS</result>"

# Log version info
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
    TRIGGER_SAFE=$(echo "$APP_NAME" | tr '[:space:]' '_' | tr -cd '[:alnum:]_')
    JSON_FILE="$JSON_DIR/${APP_NAME}-${LATEST_VERSION}.json"
    cat <<EOF > "$JSON_FILE"
{
  "name": "$APP_NAME",
  "status": "$STATUS",
  "installed_version": "$INSTALLED_VERSION",
  "latest_version": "$LATEST_VERSION",
  "install_trigger": "install_${TRIGGER_SAFE}_AUTOPKG_SILENT_UPDATE_QUIT",
  "date": "$(current_timestamp)"
}
EOF
    log "JSON file created: $JSON_FILE"
else
    log "Status is '$STATUS' or installed version unknown. Skipping JSON creation."
fi

exit 0