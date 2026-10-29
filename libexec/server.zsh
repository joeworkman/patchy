# Patchy — Running Apache: start, stop, restart, status and logs.
# Sourced by bin/patchy; uses its globals and helpers.

function start_server() {
    check_php_module || return 1
    echo "Starting Apache server..."
    brew services start httpd
    sync_hosts_entries
    legacy_dns_hint
    if ! wait_for_apache; then
        diagnose_startup_failure
        fail "$STARTUP_ERROR" "Warning: Apache did not start." "$STARTUP_DETAILS"
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
# Sets STARTUP_ERROR (apache_start_failed, port_in_use or service_stuck) and
# STARTUP_DETAILS, the explanation for people.
function diagnose_startup_failure() {
    local details code
    details=$(diagnose_startup_details)
    code=$(sed -n 's/^@//p' <<<"$details" | tail -n1)
    STARTUP_ERROR=${code:-apache_start_failed}
    STARTUP_DETAILS=$(grep -v '^@' <<<"$details")
}

function diagnose_startup_details() {
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
        echo "@service_stuck"
        echo "Apache starts fine when run directly — the launchd service is stuck."
        echo "Run '$SCRIPT_NAME stop' and then '$SCRIPT_NAME start' to reset it."
    elif [ -s "$out" ]; then
        wait "$pid" 2>/dev/null
        echo "Apache's startup error:"
        sed 's/^/  /' "$out"
        if grep -q "Address already in use" "$out"; then
            echo "@port_in_use"
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
    if [ -n "${1:-}" ]; then
        fail invalid_argument "'stop' no longer takes options — DNS is managed via /etc/hosts automatically."
        return 1
    fi
    echo "Stopping Apache server..."
    brew services stop httpd
    if hosts_active; then
        hosts_sudo_note
        if hosts_sync; then
            echo "Released site domains back to public DNS."
        else
            warn "${PATCHY_ERROR:-hosts_update_failed}" "/etc/hosts entries were not removed, so site domains still resolve to this Mac."
            PATCHY_ERROR=""
            echo "Warning: /etc/hosts entries were not removed; site domains still" >&2
            echo "resolve to this Mac. Run '$SCRIPT_NAME stop' again to retry." >&2
        fi
    fi
}

function is_apache_running() {
    brew services info httpd --json | jq -e '.[0].running' >/dev/null 2>&1
}

function restart_server() {
    check_php_module || return 1
    echo "Restarting Apache server..."
    brew services restart httpd
    sync_hosts_entries
    wait_for_apache && return 0
    diagnose_startup_failure
    fail "$STARTUP_ERROR" "Warning: Apache did not come back up after restart." "$STARTUP_DETAILS"
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

# 'patchy errors [site] [lines|-f]': the last lines of Apache's error log, or
# of one site's. Sites added before per-site logs share Apache's main log.
# With --json: {"site": ..., "log": <path>, "lines": [...]}; following the
# log (-f) has no JSON form.
function show_errors() {
    local site="" log="$LOG_DIR/error_log" arg
    if [ -n "${1:-}" ] && [[ $1 != (<1->|-f) ]]; then
        site=$1
        shift
        if ! site_exists "$site"; then
            fail site_not_found "Site does not exist... $site" >/dev/null
        else
            log=$(site_log "$site" error)
        fi
    fi
    arg=${1:-20}
    if [ -z "$PATCHY_ERROR" ] && [[ $arg != (<1->|-f) ]]; then
        fail invalid_argument "errors takes a number of lines or -f, not $arg" >/dev/null
    elif [ -z "$PATCHY_ERROR" ] && [ "$arg" = -f ] && [ "${PATCHY_JSON:-0}" -eq 1 ]; then
        fail invalid_argument "errors -f follows the log, so it has no JSON form. Give a number of lines." >/dev/null
    fi
    if [ -n "$PATCHY_ERROR" ]; then
        if [ "${PATCHY_JSON:-0}" -eq 1 ]; then
            json_failure
        else
            echo "$PATCHY_ERROR_MESSAGE"
        fi
        return 1
    fi
    if [ "${PATCHY_JSON:-0}" -eq 1 ]; then
        local lines="[]"
        [ -f "$log" ] && lines=$(tail -n "$arg" "$log" | jq -R . | jq -sc .)
        json_doc --arg site "$site" --arg log "$log" --argjson lines "$lines" \
            '{site: (if $site == "" then null else $site end), log: $log, lines: $lines}'
    else
        errors "$log" "$arg"
    fi
}

function errors() {
    local log=$1 arg=$2
    echo "Error log... $log"
    if [ "$arg" = "-f" ]; then
        tail -f "$log"
    else
        tail -n "$arg" "$log"
    fi
}

# Apache's missing-DocumentRoot warnings (AH00112) are dropped: they name a
# folder but not the site, so 'check' reports those itself, per site.
function verify_config() {
    local out
    check_php_module || return 1
    if out=$(apachectl -t 2>&1); then
        print -r -- "$out" | grep -v AH00112
        echo "Apache configuration is valid."
    else
        fail config_invalid "Apache configuration is invalid." "$out"
        return 1
    fi
    if out=$(php --ini 2>&1 >/dev/null); then
        echo "PHP configuration is valid."
    else
        fail config_invalid "PHP configuration is invalid." "$out"
        return 1
    fi
}

# 'patchy check': the Apache and PHP configuration, then each site's folder.
function check_config() {
    verify_config || return 1
    local domain docroot
    for domain in $(list_domains); do
        docroot=$(site_docroot "$domain")
        [ -d "$docroot" ] && continue
        warn docroot_missing "$domain's folder $docroot is missing" "$domain"
        echo "Warning: $domain's folder ${docroot/#$HOME/~} is missing. Create it again, or run '$SCRIPT_NAME rm $domain'."
    done
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

# 'patchy info --json': Apache's and PHP's versions, and PHP's php.ini.
function info_json() {
    local apache
    apache=$(apachectl -V 2>/dev/null)
    json_doc --arg apache "$(print -r -- "$apache" | sed -n 's|^Server version: *Apache/\([^ ]*\).*|\1|p')" \
        --arg mpm "$(print -r -- "$apache" | sed -n 's/^Server MPM: *//p')" \
        --arg built "$(print -r -- "$apache" | sed -n 's/^Server built: *//p')" \
        --arg php "$(php -r 'echo PHP_VERSION;' 2>/dev/null)" \
        --arg ini "$(php -r 'echo php_ini_loaded_file() ?: "";' 2>/dev/null)" '
        def nul: if . == "" then null else . end;
        {
            apache: {version: ($apache | nul), mpm: ($mpm | nul), built: ($built | nul)},
            php: {version: ($php | nul), ini: ($ini | nul)}
        }'
}

# 'patchy status --json': Apache, PHP, /etc/hosts routing, the trust helper,
# mkcert's certificate authority, sharing and the main paths. trust is
# enabled, outdated or off.
function server_status_json() {
    local running=false trust=off d domains=($(list_hosts_names)) missing=()
    is_apache_running && running=true
    for d in "${domains[@]}"; do
        hosts_entry_exists "$d" || missing+=("$d")
    done
    if trust_active; then
        trust=enabled
    elif trust_installed; then
        trust=outdated
    fi
    local ca_exists=false ca_trusted=false cloudflared=false
    root_cert_exists 2>/dev/null && ca_exists=true
    [ "$ca_exists" = true ] && ca_trusted && ca_trusted=true
    command -v cloudflared >/dev/null 2>&1 && cloudflared=true
    json_doc --argjson running "$running" --argjson names "${#domains[@]}" \
        --argjson missing "$(print -rl -- "${missing[@]}" | jq -R 'select(. != "")' | jq -sc .)" \
        --arg trust "$trust" --arg share_domain "$(share_ready && share_domain)" \
        --arg php_active "$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)" \
        --argjson php_installed "$(php_installed_json)" \
        --argjson ca_exists "$ca_exists" --argjson ca_trusted "$ca_trusted" \
        --argjson cloudflared "$cloudflared" \
        --arg error_log "$LOG_DIR/error_log" --arg httpd_conf "$APACHE_CONFIG" \
        --arg php_ini "$(php -r 'echo php_ini_loaded_file() ?: "";' 2>/dev/null)" '
        def nul: if . == "" then null else . end;
        {
            apache: {running: $running},
            php: {active: ($php_active | nul), installed: $php_installed},
            hosts: {names: $names, routed: ($names - ($missing | length)), missing: $missing},
            trust: $trust,
            certificate_authority: {exists: $ca_exists, trusted: $ca_trusted},
            share: {domain: ($share_domain | nul), cloudflared: $cloudflared},
            paths: {error_log: $error_log, httpd_conf: $httpd_conf, php_ini: ($php_ini | nul)}
        }'
}
