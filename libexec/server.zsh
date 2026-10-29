# Patchy — Running Apache: start, stop, restart, status and logs.
# Sourced by bin/patchy; uses its globals and helpers.

function start_server() {
    echo "Starting Apache server..."
    brew services start httpd
    sync_hosts_entries
    legacy_dns_hint
    if ! wait_for_apache; then
        echo "Warning: Apache did not start."
        diagnose_startup_failure
        return 1
    fi
}

# brew services returns 0 even if launchd fails to bring the process up.
# Give it a moment and verify.
function wait_for_apache() {
    local i
    for i in 1 2 3; do
        sleep 1
        is_apache_running && return 0
    done
    return 1
}

# The httpd LaunchAgent discards stderr, and Apache startup errors raised
# before the error log is opened (ports already taken, unwritable log dir)
# only ever go to stderr — so this whole class of failure leaves no trace
# in 'patchy errors'. Re-run httpd attached to a pipe to surface the real
# error; if it comes up fine that way, the launchd job itself is wedged.
function diagnose_startup_failure() {
    local httpd_bin="$BREW_PREFIX/opt/httpd/bin/httpd"
    local out pid i
    if [ ! -x "$httpd_bin" ] || ! out=$(mktemp); then
        echo "Run '$SCRIPT_NAME errors' to see what went wrong."
        return 0
    fi
    "$httpd_bin" -D FOREGROUND >"$out" 2>&1 &
    pid=$!
    for i in 1 2 3; do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
    done
    if kill -0 "$pid" 2>/dev/null; then
        # Survived: Apache itself is fine, so the launchd job is stuck
        # (loaded but dead — bootstrapping it again fails with error 5).
        # A stop boots the job out; the next start reloads it clean.
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "Apache starts fine when run directly — the launchd service is stuck."
        echo "Run '$SCRIPT_NAME stop' and then '$SCRIPT_NAME start' to reset it."
    elif [ -s "$out" ]; then
        wait "$pid" 2>/dev/null
        echo "Apache's startup error:"
        sed 's/^/  /' "$out"
        if grep -q "Address already in use" "$out"; then
            # One line per listening process name — prefork spawns dozens of
            # identical workers and listing them all buries the answer.
            local holders
            holders=$(lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN 2>/dev/null | awk 'NR == 1 || !seen[$1]++')
            if [ -n "$holders" ]; then
                echo "Something else is listening on port 80/443:"
                echo "$holders" | sed 's/^/  /'
            else
                echo "Run 'sudo lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN' to see"
                echo "what is holding ports 80/443."
            fi
        fi
    else
        wait "$pid" 2>/dev/null
        echo "Run '$SCRIPT_NAME errors' to see what went wrong."
    fi
    rm -f "$out"
}

function stop_server() {
    echo "Stopping Apache server..."
    brew services stop httpd
    if hosts_active; then
        hosts_sudo_note
        if hosts_sync; then
            echo "Released site domains back to public DNS."
        else
            echo "Warning: /etc/hosts entries were not removed; site domains still" >&2
            echo "resolve to this Mac. Run '$SCRIPT_NAME stop' again to retry." >&2
        fi
    fi
}

function is_apache_running() {
    brew services info httpd --json | jq -e '.[0].running' >/dev/null 2>&1
}

function restart_server() {
    echo "Restarting Apache server..."
    brew services restart httpd
    sync_hosts_entries
    wait_for_apache && return 0
    echo "Warning: Apache did not come back up after restart."
    diagnose_startup_failure
    return 1
}

function open_in_editor() {
    local file=$1
    # Honor $VISUAL, then $EDITOR, falling back to `nano` (preinstalled on macOS).
    local editor="${VISUAL:-${EDITOR:-nano}}"
    if ! command -v "${editor%% *}" >/dev/null 2>&1; then
        echo "Editor '$editor' not found. Set \$VISUAL or \$EDITOR to your preferred editor." >&2
        return 1
    fi
    $editor "$file"
}

function config_apache() {
    echo "Editing configuration for Apache server..."
    echo "$APACHE_CONFIG"
    open_in_editor "$APACHE_CONFIG"
}

function config_php() {
    echo "Editing configuration for PHP..."
    local ini_file
    ini_file=$(php --ini | grep "Loaded Configuration File" | awk '{print $4}' | sed 's/"//g')
    echo "$ini_file"
    open_in_editor "$ini_file"
}

function tail_logs() {
    echo "Tailing logs for Apache server... $LOG_DIR"
    tail -f "$LOG_DIR"/*
}

function errors() {
    local arg=$1
    local log="$LOG_DIR/error_log"
    echo "Error log... $log"
    if [ "$arg" = "-f" ]; then
        tail -f "$log"
    else
        tail -n "$arg" "$log"
    fi
}

function verify_config() {
    if apachectl -t; then
        echo "Apache configuration is valid."
    else
        echo "Apache configuration is invalid."
        return 1
    fi
    if php --ini >/dev/null; then
        echo "PHP configuration is valid."
    else
        echo "PHP configuration is invalid."
        return 1
    fi
}

function server_status() {
    if is_apache_running; then
        echo "Apache: Running"
    else
        echo "Apache: Stopped"
    fi
    local d domains=($(list_hosts_names)) missing=()
    for d in "${domains[@]}"; do
        hosts_entry_exists "$d" || missing+=("$d")
    done
    if [ ${#domains[@]} -eq 0 ]; then
        echo "Hosts:  No sites configured"
    elif [ ${#missing[@]} -eq 0 ]; then
        echo "Hosts:  Routing ${#domains[@]} name(s) to this Mac"
    elif [ ${#missing[@]} -eq ${#domains[@]} ]; then
        echo "Hosts:  Not routing (run '$SCRIPT_NAME start' to serve sites locally)"
    else
        echo "Hosts:  Routing $(( ${#domains[@]} - ${#missing[@]} )) of ${#domains[@]} name(s) — run '$SCRIPT_NAME start' to repair"
    fi
    if trust_active; then
        echo "Trust:  Passwordless /etc/hosts updates enabled"
    elif trust_installed; then
        echo "Trust:  Helper is out of date — run '$SCRIPT_NAME trust' to update it"
    fi
    if share_ready; then
        echo "Share:  Addresses on $(share_domain)"
    else
        echo "Share:  Temporary links (run '$SCRIPT_NAME share setup <domain>' to use your own)"
    fi
}

function server_info() {
    echo -e "\033[1mApache Server Info...\033[0m"
    apachectl -V | grep -E 'Server version|Server MPM|Server built'
}
