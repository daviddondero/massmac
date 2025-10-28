#!/bin/bash

#09_19_2025 _ORG
####################################################################################################
#
# AutoPkg – Nightly Run (Production-ready, LaunchAgent-compatible, Bash 3.x)
#
# Description:
#   Automates nightly execution of AutoPkg recipes for the 'autopkg' user.
#   Fully compatible with Bash 3.x, designed for LaunchAgent or manual runs.
#
####################################################################################################

# -------------------------------
# VARIABLES
# -------------------------------
autopkg_user="autopkg"
autopkg_home=$(/usr/bin/dscl . -read /Users/"$autopkg_user" NFSHomeDirectory | awk '{print $2}')
recipe_list="$autopkg_home/Library/Application Support/AutoPkgr/recipe_list.txt"
log_dir="$autopkg_home/Library/Logs/autopkg"
daily_log_file="$log_dir/autopkg_daily_run.log"
daily_log_file_verbose="$log_dir/autopkg_daily_run_verbose.log"
last_daily_log_file="$log_dir/autopkg_last_daily_run.log"
update_repos="yes"
trust_recipes="yes"
JSS_URL=$(defaults read "$AUTOPKG_PLIST" JSS_URL)

# ANSI color codes
header='\033[1;36m'
green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
nc='\033[0m'

# Arrays
trusted_recipes=()
skipped_recipes=()
failed_recipes=()
timedout_recipes=()
repo_updated_repos=()
repo_uptodate_repos=()
repo_failed_repos=()
repo_timeout_repos=()

# Network
MAX_RETRIES=30
RETRY_INTERVAL=10
NETWORK_READY=false
NETWORK_TIMEOUT=$((MAX_RETRIES * RETRY_INTERVAL))
REPO_TIMEOUT=300
RECIPE_TIMEOUT=600

# -------------------------------
# LOGGING SETUP
# -------------------------------
# Ensure log directory exists
[[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
chown "$autopkg_user" "$log_dir"
chmod 755 "$log_dir"

# Delete only the AutoPkg nightly run logs
rm -f "$log_dir"/autopkg_daily_run.log \
      "$log_dir"/autopkg_daily_run_verbose.log \
      "$log_dir"/autopkg_last_daily_run.log \
      "$log_dir"/autopkg_codesign_extract.log

# Create fresh, empty log files for the current run
: > "$daily_log_file"
: > "$daily_log_file_verbose"
: > "$last_daily_log_file"
: > "$log_dir/autopkg_codesign_extract.log"

# Set ownership and permissions
chown "$autopkg_user" "$daily_log_file" "$daily_log_file_verbose" "$last_daily_log_file" "$log_dir/autopkg_codesign_extract.log"
chmod 644 "$daily_log_file" "$daily_log_file_verbose" "$last_daily_log_file" "$log_dir/autopkg_codesign_extract.log"

# Redirect stdout/stderr for verbose logging
exec > >(tee >(sed 's/\x1B\[[0-9;]*[JKmsu]//g' >> "$daily_log_file_verbose")) 2>&1

# -------------------------------
# LOGGING FUNCTIONS
# -------------------------------
log_message() {
    local msg="$1" color="$2"
    if [[ -n "$color" ]]; then
        echo -e "${color}${msg}${nc}"
    else
        echo "$msg"
    fi
    echo "$msg" >> "$daily_log_file"
    logger -t "autopkg" "$msg"
}

log_section() {
    local title="$1"
    local timestamp
    timestamp=$(date "+%B %d %Y %l:%M%p")
    echo ""  
    echo "" >> "$daily_log_file"
    echo -e "${header}=== ${title}: ${timestamp} ===${nc}"
    echo "=== ${title}: ${timestamp} ===" >> "$daily_log_file"
}

print_list() {
    local title="$1" color="$2"
    shift 2
    local arr=("$@")
    [[ ${#arr[@]} -eq 0 ]] && return
    echo ""  
    echo "" >> "$daily_log_file"
    log_message "$title" "$color"
    for i in "${arr[@]}"; do
        log_message " - $i" "$color"
    done
}

noop() { :; }

run_section() {
    local title="$1"
    local func="$2"
    log_section "$title"
    $func
}

run_with_timeout() {
    local timeout=$1; shift
    "$@" &
    local pid=$!
    (
        sleep "$timeout"
        if kill -0 "$pid" 2>/dev/null; then
            log_message "⏱ Process timed out after $timeout seconds. Killing..." "$red"
            pkill -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        fi
    ) &
    local watchdog_pid=$!
    wait "$pid"
    local status=$?
    kill "$watchdog_pid" 2>/dev/null
    return $status
}

# -------------------------------
# CORE FUNCTIONS
# -------------------------------
check_prereqs() {
    if [[ $(id -u) -eq 0 ]]; then
        log_message "Do NOT run this script as root." "$red"
        exit 1
    elif [[ ! -x /usr/local/bin/autopkg ]]; then
        log_message "AutoPkg not installed." "$red"
        exit 1
    elif [[ ! -r "$recipe_list" ]]; then
        log_message "Recipe list missing." "$red"
        exit 1
    elif [[ ! -s "$recipe_list" ]]; then
        log_message "Recipe list is empty." "$yellow"
        exit 1
    fi
}

wait_for_network() {
    log_message "Checking network connectivity..."
    local elapsed=0 ip_addr dns_test
    while [[ $elapsed -lt $NETWORK_TIMEOUT ]]; do
        if curl -s --head --fail https://www.google.com >/dev/null 2>&1; then
            NETWORK_READY=true
            log_message "✅ Network is up after $elapsed seconds." "$green"
            ip_addr=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')
            dns_test=$(dig +short www.google.com @8.8.8.8)
            log_message "IP Address: $ip_addr" "$green"
            log_message "DNS Test: $dns_test" "$green"
            break
        else
            log_message "⏳ Waiting for network… ($elapsed seconds elapsed)" "$yellow"
            sleep "$RETRY_INTERVAL"
            elapsed=$((elapsed + RETRY_INTERVAL))
        fi
    done
    [[ "$NETWORK_READY" != true ]] && log_message "❌ Network did not become available after $elapsed seconds. Exiting." "$red" && exit 1
}

jamf_upload_check() {
    if [[ -n "$JSS_URL" ]]; then
        log_message "Jamf Upload is enabled. Jamf Pro server URL: $JSS_URL" "$green"
    else
        log_message "Jamf Upload not configured. Recipes will run locally only." "$yellow"
    fi
}

clear_autopkg_cache() {
    local cache_dir="$autopkg_home/Library/AutoPkg/Cache"
    if [[ -d "$cache_dir" && -n "$(ls -A "$cache_dir")" ]]; then
        rm -rf "$cache_dir"/*
        log_message "🧹 Cleared AutoPkg cache: $cache_dir" "$green"
    else
        log_message "ℹ AutoPkg cache empty or missing: $cache_dir" "$yellow"
    fi
}

update_repos_func() {
    [[ "$update_repos" != "yes" ]] && return
    log_message "Starting AutoPkg repo updates..." "$header"
    local json_output status
    json_output=$(run_with_timeout $REPO_TIMEOUT /usr/local/bin/autopkg repo-update all --json 2>&1)
    status=$?

    repo_updated_repos=()
    repo_uptodate_repos=()
    repo_failed_repos=()
    repo_timeout_repos=()

    [[ $status -eq 137 ]] && { log_message "❌ Repo update timed out." "$red"; repo_timeout_repos=("all_repos"); }

    if command -v /usr/local/bin/jq >/dev/null 2>&1; then
        repo_updated_repos=($(echo "$json_output" | /usr/local/bin/jq -r '.[] | select(.status=="updated") | .repo_name' 2>/dev/null))
        repo_uptodate_repos=($(echo "$json_output" | /usr/local/bin/jq -r '.[] | select(.status=="up-to-date") | .repo_name' 2>/dev/null))
        repo_failed_repos=($(echo "$json_output" | /usr/local/bin/jq -r '.[] | select(.status=="error" or .status=="failed") | .repo_name' 2>/dev/null))

        [[ ${#repo_failed_repos[@]} -gt 0 ]] && log_message "❌ Repo update errors: ${repo_failed_repos[*]}" "$yellow"
    else
        log_message "⚠ jq not found, skipping detailed repo parsing." "$yellow"
        [[ $status -ne 0 ]] && log_message "❌ Repo update may have failed." "$yellow"
    fi

    print_list "Updated Repos:" "$green" "${repo_updated_repos[@]}"
    print_list "Already Up To Date Repos:" "$yellow" "${repo_uptodate_repos[@]}"
    print_list "Failed Repos:" "$red" "${repo_failed_repos[@]}"
    print_list "Timed Out Repos:" "$red" "${repo_timeout_repos[@]}"
}

trust_recipes_func() {
    [[ ! -s "$recipe_list" ]] && { log_message "Recipe list missing/empty. No recipes to process." "$yellow"; return; }
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -z "${r// }" ]] && continue
        if [[ "$trust_recipes" == "yes" ]]; then
            if /usr/local/bin/autopkg update-trust-info "$r" >> "$daily_log_file" 2>&1; then
                trusted_recipes+=("$r")
            else
                skipped_recipes+=("$r")
                log_message "Skipping untrusted recipe: $r" "$yellow"
            fi
        else
            trusted_recipes+=("$r")
        fi
    done < "$recipe_list"
    log_message "Total trusted recipes: ${#trusted_recipes[@]}" "$green"
    log_message "Total skipped recipes due to trust issues: ${#skipped_recipes[@]}" "$yellow"
}

run_recipes() {
    [[ ${#trusted_recipes[@]} -eq 0 ]] && { log_message "No trusted recipes to run." "$yellow"; return; }
    failed_recipes=()
    timedout_recipes=()
    local recipe ts_start ts_end
    local total=${#trusted_recipes[@]}
    local count=0
    local codesign_log="$log_dir/autopkg_codesign_extract.log"

    ts_start=$(date "+%B %d %Y %l:%M%p")
    echo "=== CodeSignatureVerifier Started: $ts_start ===" >> "$codesign_log"

    for recipe in "${trusted_recipes[@]}"; do
        count=$((count + 1))
        ts_start=$(date "+%B %d %Y %l:%M%p")
        log_message "$ts_start Running recipe: $recipe"

        tmp_output=$(mktemp)
        /usr/local/bin/autopkg run -v "$recipe" &> "$tmp_output"
        local status=$?

        while IFS= read -r line; do
            echo "$line" >> "$daily_log_file_verbose"
            [[ "$line" =~ ^CodeSignatureVerifier ]] && {
                echo "$line" >> "$daily_log_file"
                echo "$line" >> "$codesign_log"
            }
        done < "$tmp_output"
        rm -f "$tmp_output"

        ts_end=$(date "+%B %d %Y %l:%M%p")
        if [[ $status -eq 137 ]]; then
            timedout_recipes+=("$recipe")
            log_message "$ts_end Recipe timed out: $recipe" "$red"
        elif [[ $status -ne 0 ]]; then
            failed_recipes+=("$recipe")
            log_message "$ts_end Recipe failed: $recipe" "$red"
        else
            log_message "$ts_end Recipe completed: $recipe" "$green"
        fi
        [[ $count -lt $total ]] && echo "" >> "$daily_log_file"
    done

    ts_end=$(date "+%B %d %Y %l:%M%p")
    echo "" >> "$codesign_log"
    echo "=== CodeSignatureVerifier Finished: $ts_end ===" >> "$codesign_log"

    chown "$autopkg_user" "$codesign_log"
    chmod 644 "$codesign_log"
}

generate_summary() {
    local total=$(grep -cve '^\s*$' "$recipe_list")
    log_message "Total recipes in list: $total"
    log_message "Trusted recipes run: ${#trusted_recipes[@]}" "$green"
    log_message "Skipped due to trust issues: ${#skipped_recipes[@]}" "$yellow"
    log_message "Failed recipes: ${#failed_recipes[@]}" "$red"
    log_message "Timed out recipes: ${#timedout_recipes[@]}" "$red"

    [[ ${#repo_failed_repos[@]} -eq 0 && ${#repo_timeout_repos[@]} -eq 0 ]] \
        && log_message "✅ All repositories updated successfully." "$green" \
        || log_message "❌ Some repositories failed or timed out. Check above details." "$red"

    [[ ${#failed_recipes[@]} -eq 0 && ${#timedout_recipes[@]} -eq 0 ]] \
        && log_message "✅ All recipes completed successfully." "$green" \
        || log_message "❌ Some recipes failed or timed out. Check above details." "$red"
}

# -------------------------------
# MAIN
# -------------------------------
check_prereqs
clear_previous_failures() { failed_recipes=(); timedout_recipes=(); skipped_recipes=(); trusted_recipes=(); repo_updated_repos=(); repo_uptodate_repos=(); repo_failed_repos=(); repo_timeout_repos=(); }
run_section "AutoPkg Nightly Run Started" noop
run_section "Network Check" wait_for_network
run_section "Jamf Upload Check" jamf_upload_check
run_section "AutoPkg Cache Cleanup" clear_autopkg_cache
run_section "Repo Updates" update_repos_func
run_section "Recipe Trust Verification" trust_recipes_func
run_section "Recipe Run" run_recipes
run_section "Final Summary" generate_summary
run_section "AutoPkg Nightly Run Finished" noop

# -------------------------------
# Create filtered 'autopkg_last_daily_run.log'
# -------------------------------
{
    grep -v -e '=== Repo Updates: ' \
           -e 'Starting AutoPkg repo updates...' \
           -e '✅ All repositories updated successfully.' \
           -e '^CodeSignatureVerifier' "$daily_log_file" \
    | awk 'NF{blank=0} !NF{blank++} blank<2'
} > "$last_daily_log_file"

chown "$autopkg_user" "$last_daily_log_file"
chmod 644 "$last_daily_log_file"
touch "$last_daily_log_file"

exit 0