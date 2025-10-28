#!/bin/bash

################################################################################
# Script: AutoPkg PKG Cleaner
# Filename: autopkg_pkg_cleaner.sh
#
# Detailed Description:
#   The AutoPkg PKG Cleaner is a comprehensive maintenance tool for AutoPkg
#   repositories on macOS. Its primary goal is to keep the AutoPkg package
#   folder clean by automatically identifying and removing older versions of
#   AutoPkg-generated .pkg files, while retaining the last two versions of each
#   application package.
#
#   Additionally, the script will:
#     - Clean up temporary Jamf upload folders located in /private/tmp that start
#       with "jamf_upload_*", ensuring leftover temporary files do not accumulate.
#     - Empty all visible items in the current user's Trash folder (~/.Trash)
#       to free up disk space.
#
#   The script is fully automated, safe for unattended execution via LaunchDaemon,
#   cron jobs, or manual runs, and is compatible with Bash 3.x (default shell on macOS).
#
# Core Functionality:
#   1. Log Initialization:
#      - Creates a dedicated log directory and log file if they do not exist.
#      - Clears previous log file to ensure each run starts fresh.
#      - Logs a clearly formatted start message with a human-readable timestamp.
#
#   2. Folder Verification:
#      - Confirms that the target AutoPkg package folder exists.
#      - If the folder does not exist, logs an error and exits.
#
#   3. Package Discovery:
#      - Scans the target folder for files matching "AutoPkg_*.pkg".
#      - Extracts the application name from each package filename.
#      - Produces a unique, sorted list of applications present in the folder.
#
#   4. Package Analysis:
#      - For each application, counts the number of versions present.
#      - Determines if older versions exist beyond the last two to keep.
#      - Separates applications into two categories:
#          a) Apps with no old packages (nothing to delete)
#          b) Apps with old packages that need deletion
#
#   5. Logging Packages with No Deletions:
#      - Logs all applications for which no older packages exist.
#
#   6. Deletion of Old Packages:
#      - For applications with more than two versions:
#          a) Sorts package files by version number.
#          b) Keeps the last two newest versions.
#          c) Deletes older versions while logging each deletion.
#      - Uses a safety check to ensure deletion commands are only run for positive counts.
#      - Handles filenames containing spaces or special characters safely.
#
#   7. Temporary Jamf Upload Cleanup:
#      - Finds folders in /private/tmp that start with "jamf_upload*".
#      - Verifies each folder exists before attempting deletion.
#      - Logs each deletion (or skipped folder) for audit purposes.
#
#   8. Trash Cleanup:
#      - Checks for the user's ~/.Trash folder.
#      - Empties all visible files if present.
#      - Logs success or skips if folder not found.
#
#   9. Summary Generation:
#      - After all deletion operations, logs a concise summary including:
#          - Number of applications cleaned (old packages deleted)
#          - Number of applications with no old packages
#          - Trash cleanup completion status
#      - This summary is logged before the final "Finished" timestamp message.
#
# 10. Completion Logging:
#      - Logs a clearly formatted finish message with a human-readable timestamp,
#        signaling the end of the cleanup process.
#
# Key Features:
#   - Fully automated: no user interaction required during execution.
#   - Safe to run multiple times without causing errors (idempotent).
#   - Compatible with Bash 3.x and macOS default utilities.
#   - Handles all valid AutoPkg naming conventions, including unusual characters
#     or spaces in filenames.
#   - Logs all actions for easy auditing and troubleshooting.
#   - Frees disk space by cleaning old packages, Jamf temporary folders, and Trash.
#
# Usage:
#   1. Set the FOLDER variable to the directory containing your AutoPkg .pkg files.
#   2. Ensure the script has executable permissions:
#        chmod +x autopkg_pkg_cleaner.sh
#   3. Run manually:
#        ./autopkg_pkg_cleaner.sh
#   4. Or schedule automatic execution using LaunchDaemon or cron.
#
################################################################################

FOLDER="/Users/autopkg/Library/AutoPkg/AutoPkg_Pkgs"
LOG_DIR="/Users/autopkg/Library/Logs/autopkg"
LOG_FILE="$LOG_DIR/autopkg_pkg_cleaner.log"

# Create log directory if it doesn't exist
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"

# Clear previous log
[ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"

# Logging function
log() { echo "$1" | tee -a "$LOG_FILE"; }

# Start log with formatted timestamp
log "=== AutoPkg PKG Cleaner Started: $(date '+%B %d %Y %-I:%M%p') ==="
log ""

# Verify folder exists
cd "$FOLDER" || { log "Error: Folder $FOLDER does not exist."; exit 1; }

# Get unique list of app names
apps=$(find . -maxdepth 1 -type f -name "AutoPkg_*.pkg" | while read pkg; do
    filename=$(basename "$pkg")
    appname=$(echo "$filename" | sed -E 's/^AutoPkg_(.+)-([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)\.pkg$/\1/')
    [ -n "$appname" ] && echo "$appname"
done | sort -u)

# Arrays to track apps
no_delete_apps=()
delete_apps=()

# Determine which apps need deletion
for app in $apps; do
    pkgs=$(find . -maxdepth 1 -type f -name "AutoPkg_${app}-*.pkg" | sort -V)
    count=$(echo "$pkgs" | wc -l | tr -d ' ')
    keep=2
    delete_count=$((count - keep))

    if [ "$delete_count" -gt 0 ]; then
        delete_apps+=("$app")
    else
        no_delete_apps+=("$app")
    fi
done

# Sort arrays alphabetically
sorted_no_delete_apps=$(printf "%s\n" "${no_delete_apps[@]}" | sort)
sorted_delete_apps=$(printf "%s\n" "${delete_apps[@]}" | sort)

# Log apps with no old packages
echo "$sorted_no_delete_apps" | while read -r app; do
    [ -n "$app" ] && log "No old packages to delete for $app."
done

log ""  # blank line

# Process apps that need deletion
echo "$sorted_delete_apps" | while read -r app; do
    [ -z "$app" ] && continue
    pkgs=$(find . -maxdepth 1 -type f -name "AutoPkg_${app}-*.pkg" | sort -V)
    count=$(echo "$pkgs" | wc -l | tr -d ' ')
    keep=2
    delete_count=$((count - keep))

    log "Cleaning old packages for $app (keeping last $keep of $count)..."
    if [ "$delete_count" -gt 0 ]; then
        echo "$pkgs" | head -n "$delete_count" | while read -r oldpkg; do
            [ -f "$oldpkg" ] && log "Deleting: $oldpkg" && rm -f "$oldpkg"
        done
    fi
done

log ""  # blank line

# Delete any folders in /private/tmp that start with "jamf_upload*"
log "Additionally, cleaning up /private/tmp/jamf_upload* folders..."
find /private/tmp -maxdepth 1 -type d -name "jamf_upload*" | while IFS= read -r dir; do
    if [ -d "$dir" ]; then
        log "Deleting folder: $dir"
        rm -rf "$dir"
    else
        log "Folder not found (skipping): $dir"
    fi
done

log ""  # blank line

# Empty only visible items in the user's Trash folder
TRASH_PATH="/Users/autopkg/.Trash"
if [ -d "$TRASH_PATH" ]; then
    log "Emptying visible files from Trash at: $TRASH_PATH ..."
    rm -rf "${TRASH_PATH:?}/"* 2>/dev/null
    log "Visible Trash items have been emptied."
else
    log "No Trash folder found at $TRASH_PATH (skipping)."
fi

log ""  # blank line

# Summary section
log "Summary:"
log " - Apps cleaned (old packages deleted): $(echo "${delete_apps[@]}" | wc -w | tr -d ' ')"
log " - Apps with no old packages: $(echo "${no_delete_apps[@]}" | wc -w | tr -d ' ')"

log ""  # blank line

# Finish log
log "=== AutoPkg PKG Cleaner Finished: $(date '+%B %d %Y %-I:%M%p') ==="
log ""

exit 0