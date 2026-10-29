# Patchy — --json output: one result line for most commands, events for
# share, and stable error codes so callers never match English text.
# Sourced by bin/patchy; uses its globals and helpers.

PATCHY_ERROR="" PATCHY_ERROR_MESSAGE="" PATCHY_ERROR_DETAILS=""
PATCHY_WARNINGS=()

# Record why a command is failing, as a stable code for --json and a message
# for people, and print the message with any detail lines (a log's last
# lines, say).
function fail() {
    PATCHY_ERROR=$1
    PATCHY_ERROR_MESSAGE=${2%:}
    PATCHY_ERROR_DETAILS=${3:-}
    echo "$2"
    [ -n "${3:-}" ] && echo "$3"
    return 0
}

# Record a problem that doesn't stop the command, for --json's warnings, with
# the site it's about when there is one. The caller prints its own message for
# people.
function warn() {
    PATCHY_WARNINGS+=("$(jq -nc --arg code "$1" --arg message "$2" --arg site "${3:-}" \
        '{code: $code, message: $message} + (if $site == "" then {} else {site: $site} end)')")
}

# Under --json, write one JSON line (from jq -n arguments) to fd 3, the real
# stdout while json_result or share_run is running.
function json_event() {
    [ "${PATCHY_JSON:-0}" -eq 1 ] || return 0
    jq -nc "$@" >&3
}

function json_warnings() {
    print -rl -- "${PATCHY_WARNINGS[@]}" | jq -sc '[.[] | select(. != null)]'
}

# jq arguments carrying the last failure: $error, $message, $details.
function json_error_args() {
    reply=(--arg error "${PATCHY_ERROR:-failed}" --arg message "${PATCHY_ERROR_MESSAGE:-$SCRIPT_NAME failed}"
        --arg details "$PATCHY_ERROR_DETAILS")
}

# Run a command. Under --json its only output is one line: {"ok": true,
# "warnings": [...]}, or {"ok": false, "error": <code>, "message": ...,
# "details": ..., "warnings": [...]}. Nothing can prompt: stdin is closed and
# sudo never asks for a password, so a missing 'patchy trust' is an error
# (sudo_required) rather than a hang.
function json_result() {
    if [ "${PATCHY_JSON:-0}" -ne 1 ]; then
        "$@"
        return
    fi
    local result
    function sudo() { command sudo -n "$@" }
    { "$@" } 3>&1 >/dev/null 2>&1 </dev/null
    result=$?
    if [ "$result" -eq 0 ]; then
        json_event --argjson warnings "$(json_warnings)" '{ok: true, warnings: $warnings}' 3>&1
    else
        json_error_args
        json_event "${reply[@]}" --argjson warnings "$(json_warnings)" '{
            ok: false, error: $error, message: $message,
            details: (if $details == "" then null else $details end),
            warnings: $warnings
        }' 3>&1
    fi
    return $result
}

# sudo for a step that must not prompt under --json: fails with sudo_required
# when a password would be needed. The second argument replaces the default
# hint about 'patchy trust'.
function require_sudo() {
    [ "${PATCHY_JSON:-0}" -eq 1 ] || return 0
    command sudo -n true 2>/dev/null && return 0
    fail sudo_required "$1 needs your password. ${2:-Run '$SCRIPT_NAME trust' once in Terminal to allow it without one.}"
    return 1
}
