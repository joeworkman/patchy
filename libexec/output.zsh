# Patchy — --json output: one result line for most commands, events for
# share, and stable error codes so callers never match English text.
# Sourced by bin/patchy; uses its globals and helpers.

PATCHY_ERROR="" PATCHY_ERROR_MESSAGE="" PATCHY_ERROR_DETAILS=""
PATCHY_WARNINGS=()

# Bumped when a --json shape changes in a way that could break a caller.
PATCHY_SCHEMA=1

# Every sudo in patchy goes through here. With SUDO_ASKPASS set, sudo asks
# for the password through that program (an app's own dialog), so patchy
# never sees it and needs no terminal. Otherwise --json can't ask at all, so
# sudo fails rather than waits.
function sudo() {
    if [ -n "${SUDO_ASKPASS:-}" ]; then
        command sudo -A "$@"
    elif [ "${PATCHY_JSON:-0}" -eq 1 ]; then
        command sudo -n "$@"
    else
        command sudo "$@"
    fi
}

# Print one JSON document (from jq -n arguments) with the schema version.
function json_doc() {
    jq -n --argjson schema "$PATCHY_SCHEMA" "${@[1,-2]}" "{schema: \$schema} + (${@[-1]})"
}

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
    json_doc -c "$@" >&3
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
# "details": ..., "warnings": [...]}. Nothing can prompt in the terminal:
# stdin is closed, and sudo asks through SUDO_ASKPASS or not at all, so a
# missing 'patchy trust' is an error (sudo_required) rather than a hang.
function json_result() {
    if [ "${PATCHY_JSON:-0}" -ne 1 ]; then
        "$@"
        return
    fi
    local result
    { "$@" } 3>&1 >/dev/null 2>&1 </dev/null
    result=$?
    if [ "$result" -eq 0 ]; then
        json_event --argjson warnings "$(json_warnings)" '{ok: true, warnings: $warnings}' 3>&1
    else
        json_failure
    fi
    return $result
}

# The {"ok": false, ...} line for the last failure. Also used by commands
# whose success under --json is a document rather than a result line.
function json_failure() {
    json_error_args
    json_doc -c "${reply[@]}" --argjson warnings "$(json_warnings)" '{
        ok: false, error: $error, message: $message,
        details: (if $details == "" then null else $details end),
        warnings: $warnings
    }'
}

# sudo for a step that must not prompt under --json: fails with sudo_required
# when a password would be needed and there's no SUDO_ASKPASS to ask with.
# The second argument replaces the default hint about 'patchy trust'.
function require_sudo() {
    [ "${PATCHY_JSON:-0}" -eq 1 ] || return 0
    [ -n "${SUDO_ASKPASS:-}" ] && return 0
    command sudo -n true 2>/dev/null && return 0
    fail sudo_required "$1 needs your password. ${2:-Run '$SCRIPT_NAME trust' once in Terminal to allow it without one.}"
    return 1
}
