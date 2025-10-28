#!/bin/bash
#
# ------------------------------------------------------------------------------
# Script Name:    jamf_advanced_search_api.sh
# Author:         David Dondero
# Created:        October 23, 2025
#
# Purpose:
#   Automates the creation and updating of Advanced Computer Searches in Jamf Pro
#   based on validated AutoPkg recipes and their associated Extension Attributes.
#
# Overview:
#   This script performs the following tasks:
#     1. Scans all `.jamf.recipe` files in the specified AutoPkg Recipes directory.
#     2. Skips known exceptions and handles special cases (e.g., swiftDialog).
#     3. Extracts the `NAME` field from each recipe.
#     4. Validates that a corresponding Extension Attribute (EA) exists in Jamf Pro.
#     5. Writes validated app names to a text file.
#     6. For each validated app, creates or updates an Advanced Computer Search
#        in Jamf Pro using the EA as a search criterion.
#
# Logging:
#   - Logs are printed to standard output and can be redirected by a launch daemon.
#   - Each run includes a timestamped start and finish marker.
#   - Logs include EA validation results and Jamf API responses.
#
# Requirements:
#   - macOS with:
#       • AutoPkg installed and configured
#       • Jamf Pro API credentials stored in: ~/Library/Preferences/com.github.autopkg.plist
#       • jq (install via Homebrew: `brew install jq`)
#       • xmllint (preinstalled on macOS via libxml2)
#   - Jamf Pro server with:
#       • OAuth credentials for API access
#       • Extension Attributes named in the format: "AutoPkg <AppName> Update Status"
#
# Output:
#   - application_names.txt: A list of validated app names written to:
#       /Users/autopkg/Library/AutoPkg/AutoPkg_Pkgs/application_names.txt
#   - Advanced Computer Searches created or updated in Jamf Pro for each app.
#
# Scheduling:
#   - Recommended to run daily via a launch daemon at 5:00 AM.
#   - Example LaunchDaemon: /Library/LaunchDaemons/com.autopkg.jamfsearchapi.plist
#
# Exit Codes:
#   0 - Success
#   1 - Failed to retrieve Jamf API access token
#
# ------------------------------------------------------------------------------


RECIPE_DIR="/Users/autopkg/Library/AutoPkg/Recipes"
OUTPUT_DIR="/Users/autopkg/Library/AutoPkg/AutoPkg_Pkgs"
TEXT_FILE="$OUTPUT_DIR/application_names.txt"

EXCLUDE_RECIPES=(
    "App_Store_App.jamf.recipe"
    "Sign_AppStoreApps.jamf.recipe"
    "Microsoft_Office_365_Suite.jamf.recipe"
)
SPECIAL_CASE="swiftDialog.jamf.recipe"

mkdir -p "$OUTPUT_DIR"

# Delete the text file if it exists, then recreate it
if [ -f "$TEXT_FILE" ]; then
    rm -f "$TEXT_FILE"
fi
touch "$TEXT_FILE"

# ----------------------------------------------------------------------
# Step 1: Read Jamf API credentials
# ----------------------------------------------------------------------
AUTOPKG_PLIST="/Users/autopkg/Library/Preferences/com.github.autopkg.plist"
API_CLIENT_ID=$(defaults read "$AUTOPKG_PLIST" API_CLIENT_ID)
API_CLIENT_SECRET=$(defaults read "$AUTOPKG_PLIST" API_CLIENT_SECRET)
JSS_URL=$(defaults read "$AUTOPKG_PLIST" JSS_URL)

# ----------------------------------------------------------------------
# Step 2: Start log with formatted timestamp
# ----------------------------------------------------------------------
LOG_DIR="/Users/autopkg/Library/Logs/autopkg"
LOG_FILE="$LOG_DIR/jamf_advanced_search_api.log"

# Create log directory if it doesn't exist
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"

# Clear previous log
[ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"

#log() {
    #echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
#}

# Logging function
log() { echo "$1" | tee -a "$LOG_FILE"; }

log "=== AutoPkg Jamf Advanced Serach API Started: $(date '+%B %d %Y %-I:%M%p') ==="
log ""

# ----------------------------------------------------------------------
# Step 3: Get access token
# ----------------------------------------------------------------------
log "Requesting access token..."
TOKEN_RESPONSE=$(curl -s -X POST "$JSS_URL/api/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$API_CLIENT_ID&client_secret=$API_CLIENT_SECRET")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | /usr/bin/jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    log "Failed to retrieve access token."
    exit 1
fi

log "Access token retrieved."

# ----------------------------------------------------------------------
# Step 4: Scan recipes and write validated app names to text file
# ----------------------------------------------------------------------
find "$RECIPE_DIR" -type f -name "*.jamf.recipe" | while read -r recipe; do
    filename=$(basename "$recipe")

    # Skip excluded recipes
    if [[ " ${EXCLUDE_RECIPES[*]} " =~ " $filename " ]]; then
        continue
    fi

    # Handle special case
    if [[ "$filename" == "$SPECIAL_CASE" ]]; then
        APP_NAME="swiftDialog"
    else
        APP_NAME=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "$recipe" 2>/dev/null)
    fi

    # Skip if empty
    if [[ -z "$APP_NAME" ]]; then
        continue
    fi

    EA_NAME="AutoPkg ${APP_NAME} Update Status"

    # Validate EA exists in Jamf
    EA_EXISTS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$JSS_URL/JSSResource/computerextensionattributes" \
        -H 'accept: application/xml' | xmllint --xpath "boolean(//computer_extension_attribute/name[text()='${EA_NAME}'])" - 2>/dev/null)

    if [[ "$EA_EXISTS" == "true" ]]; then
        echo "$APP_NAME" >> "$TEXT_FILE"
        log "✔ EA found for '$APP_NAME' — added to list."
    else
        log "❌ EA missing for '$APP_NAME' — skipped."
    fi
done

# ----------------------------------------------------------------------
# Step 5: Loop through validated app names and update Jamf searches
# ----------------------------------------------------------------------
log ""  # blank line

while read -r APP_NAME; do
    log "Processing: $APP_NAME"

    SEARCH_NAME="AutoPkg ${APP_NAME} - Needs Update"
    EA_NAME="AutoPkg ${APP_NAME} Update Status"

    # Check if search exists
    SEARCH_ID=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$JSS_URL/JSSResource/advancedcomputersearches" \
        -H 'accept: application/xml' | xmllint --xpath "string(//advanced_computer_search[name='$SEARCH_NAME']/id)" - 2>/dev/null)

    if [[ -n "$SEARCH_ID" ]]; then
        log "Search exists. Updating ID $SEARCH_ID..."
        ENDPOINT="$JSS_URL/JSSResource/advancedcomputersearches/id/$SEARCH_ID"
        METHOD="PUT"
    else
        log "Search does not exist. Creating new..."
        ENDPOINT="$JSS_URL/JSSResource/advancedcomputersearches/id/0"
        METHOD="POST"
    fi

    # Build XML payload
    SEARCH_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<advanced_computer_search>
  <name>${SEARCH_NAME}</name>
  <criteria>
    <criterion>
      <name>${EA_NAME}</name>
      <and_or>and</and_or>
      <search_type>is</search_type>
      <value>Needs Update</value>
    </criterion>
  </criteria>
  <display_fields>
    <display_field><name>Last Check-in</name></display_field>
    <display_field><name>Full Name</name></display_field>
    <display_field><name>User Last Logged in - Computer timestamp</name></display_field>
    <display_field><name>Last Inventory Update</name></display_field>
    <display_field><name>${EA_NAME}</name></display_field>
    <display_field><name>Email Address</name></display_field>
  </display_fields>
</advanced_computer_search>"

    # Send request
    RESPONSE=$(curl -s -X "$METHOD" "$ENDPOINT" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/xml" \
        -d "$SEARCH_XML")

    log "Advanced Search ${METHOD} response:"
    log "$RESPONSE"
    log ""  # blank line
done < "$TEXT_FILE"

log ""  # blank line

# Finish log
log "=== AutoPkg Jamf Advanced Serach API Started Finished: $(date '+%B %d %Y %-I:%M%p') ==="
log ""

exit 0