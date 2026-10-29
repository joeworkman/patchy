#!/bin/zsh
# Runs what the user picked in the script filter, and prints the text for the
# notification (nothing when opening a site). The arg is one of `open
# <domain>`, `start`, `stop`, `restart` or `php <version>`.
emulate -L zsh
source "${0:A:h}/lib.zsh"

arg=${1:-}

# The last line patchy prints under --json is the result. Only for commands
# that end in a result line: status prints one JSON document over many lines.
function run_patchy() {
    "$PATCHY" "$@" --json 2>/dev/null | tail -n 1
}

# notify_result <result line> <success text> <failure prefix>
function notify_result() {
    if ! print -r -- "$1" | jq -e 'type == "object" and has("ok")' >/dev/null 2>&1; then
        print "Patchy didn't respond as expected. Run it in Terminal to see why."
        return
    fi
    # A warning means it worked but something was left undone, such as
    # /etc/hosts when the password dialog was cancelled.
    print -r -- "$1" | jq -r --arg done "$2" --arg failed "$3" '
        if .ok then
            ((.warnings // [])[0]) as $w
            | if $w == null then $done
              else "\($done), but: \($w.message)"
                   + (if $w.code == "sudo_required" then " Run patchy trust to stop being asked." else "" end)
              end
        else "\($failed): \(.message // .error)" end'
}

if ! patchy_setup; then
    print -r -- "$PATCHY_PROBLEM: $PATCHY_PROBLEM_DETAIL"
    exit 0
fi

case $arg in
    open\ *)
        ${=OPEN_COMMAND:-/usr/bin/open} "https://${arg#open }"
        exit 0
        ;;
    start|stop|restart)
        result=$(run_patchy $arg)
        rm -f "$CACHE_FILE"
        typeset -A past=(start started stop stopped restart restarted)
        notify_result "$result" "Apache $past[$arg]" "Couldn't $arg Apache"
        ;;
    php\ *)
        version=${arg#php }
        current=$("$PATCHY" status --json 2>/dev/null)
        if [ "$(print -r -- "$current" | jq -r '.php.active // empty' 2>/dev/null)" = "$version" ]; then
            print "Already on PHP $version"
            exit 0
        fi
        # Switching PHP restarts Apache, which starts it if it was stopped.
        success="Switched to PHP $version"
        if [ "$(print -r -- "$current" | jq -r '.apache.running' 2>/dev/null)" = false ]; then
            success+=" and started Apache"
        fi
        result=$(run_patchy php "$version")
        rm -f "$CACHE_FILE"
        notify_result "$result" "$success" "Couldn't switch PHP"
        ;;
    *)
        print -r -- "Unknown action: $arg"
        ;;
esac
