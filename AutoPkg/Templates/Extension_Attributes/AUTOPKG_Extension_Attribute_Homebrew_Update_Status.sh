#!/bin/bash
##########################################################################
# Jamf Extension Attribute: AutoPkg Homebrew Update Status
#
# Purpose:
#   Checks whether Homebrew is installed and up-to-date.
#   Compares the installed version against AutoPkg latest version (%version%).
#
# Functionality:
#   1. Detects Homebrew binary path (/usr/local/bin/brew or /opt/homebrew/bin/brew).
#   2. Reads the installed version reliably.
#   3. Compares installed version with the latest version.
#   4. Returns one of three EA results:
#        - <result>Not Installed</result>
#        - <result>Needs Update</result>
#        - <result>Up-to-date</result>
#   5. Logs the exact path where Homebrew was found or the reason it couldn't be read.
#   6. Safely removes any old JSON files for Homebrew.
#   7. Creates a JSON file only if status is "Needs Update" and installed version was successfully read.
#   8. Logs timestamps, installed version, latest version, status, and cleanup actions.
##########################################################################

APP_NAME="Homebrew"
LATEST_VERSION="%version%" # AutoPkg will replace this
APP_PATH=""
INSTALLED_VERSION=""
STATUS="Not Installed"
JSON_DIR="/usr/local/autopkg/AutoPkg_App_Updates"
mkdir -p "$JSON_DIR"

# ----------------------------------------------------------------------
#  Version comparison function (robust for multi-digit versions)
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
    echo "$(current_timestamp) - $1"
}

# ----------------------------------------------------------------------
# Locate Homebrew binary and log path
# ----------------------------------------------------------------------
if [ -x "/opt/homebrew/bin/brew" ]; then
    APP_PATH="/opt/homebrew/bin/brew"
    log "Homebrew binary found at $APP_PATH"
elif [ -x "/usr/local/bin/brew" ]; then
    APP_PATH="/usr/local/bin/brew"
    log "Homebrew binary found at $APP_PATH"
else
    log "Homebrew binary not found at /opt/homebrew/bin/brew or /usr/local/bin/brew"
fi

# ----------------------------------------------------------------------
# Determine update status
# ----------------------------------------------------------------------
if [ -n "$APP_PATH" ]; then
    VERSION_OUTPUT=$("$APP_PATH" --version 2>/dev/null | head -n1)
    INSTALLED_VERSION=$(echo "$VERSION_OUTPUT" | awk '{print $2}' | sed 's/^[^0-9]*//')
    if [ -n "$INSTALLED_VERSION" ]; then
        if version_lt "$INSTALLED_VERSION" "$LATEST_VERSION"; then
            STATUS="Needs Update"
        else
            STATUS="Up-to-date"
        fi
        log "Successfully read Homebrew version: $INSTALLED_VERSION"
    else
        log "Homebrew binary exists but version could not be read from $APP_PATH"
    fi
fi

# ----------------------------------------------------------------------
# Output EA result
# ----------------------------------------------------------------------
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