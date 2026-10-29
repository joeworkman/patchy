#!/bin/zsh
# Alfred script filter: the server's state and actions, the PHP versions, and
# the user's sites, as Alfred JSON. Each actionable item's arg is one of
# `open <domain>`, `start`, `stop`, `restart` or `php <version>`; action.zsh
# parses exactly these.
emulate -L zsh
source "${0:A:h}/lib.zsh"

query=${1:-}

# list and status each take a second or more with a few dozen sites, so the
# last result is cached: shown at once, then refreshed in the background.
# Refresh only when the cache is older than this, or a rerun would refresh
# again forever.
REFRESH_AFTER=5s

# {list, status} from the CLI. A command that prints something other than
# JSON comes back as null, so the caller can say so.
function fetch_state() {
    local dir
    dir=$(mktemp -d) || return 1
    "$PATCHY" list --json >"$dir/list" 2>/dev/null &
    "$PATCHY" status --json >"$dir/status" 2>/dev/null &
    wait
    jq -n --rawfile l "$dir/list" --rawfile s "$dir/status" \
        '{list: ($l | try fromjson catch null), status: ($s | try fromjson catch null)}'
    rm -rf "$dir"
}

function state_ok() {
    jq -e '(.list.sites | type == "array") and (.status.apache | type == "object")' >/dev/null 2>&1
}

# Write through a temporary file, so a reader never sees half a cache.
function save_state() {
    local tmp
    mkdir -p "${CACHE_FILE:h}"
    tmp=$(mktemp "$CACHE_FILE.XXXXXX") || return 1
    print -r -- "$1" >"$tmp" && mv -f "$tmp" "$CACHE_FILE"
}

function older_than() {
    [ -n "$(find "$1" -maxdepth 0 -mtime +$2 2>/dev/null)" ]
}

# The refresh must not hold Alfred's stdout open, or Alfred waits for it.
function refresh_in_background() {
    local lock=$CACHE_FILE.lock
    if [ -d "$lock" ] && older_than "$lock" 30s; then
        rmdir "$lock" 2>/dev/null
    fi
    mkdir "$lock" 2>/dev/null || return 0
    {
        local fresh
        fresh=$(fetch_state)
        # A failing Patchy must not hide behind the last good list: drop the
        # cache, so the next run asks Patchy and shows the problem.
        if print -r -- "$fresh" | state_ok; then
            save_state "$fresh"
        else
            rm -f "$CACHE_FILE"
        fi
        rmdir "$lock"
    } </dev/null >/dev/null 2>&1 &!
}

if ! patchy_setup || ! patchy_check_features; then
    problem_items
    exit 0
fi

state=""
rerun=false
if [ -f "$CACHE_FILE" ] && state_ok <"$CACHE_FILE"; then
    state=$(<"$CACHE_FILE")
    if older_than "$CACHE_FILE" $REFRESH_AFTER; then
        refresh_in_background
    fi
    [ -d "$CACHE_FILE.lock" ] && rerun=true
else
    state=$(fetch_state)
    if print -r -- "$state" | state_ok; then
        save_state "$state"
    fi
fi

print -r -- "$state" | jq --arg query "$query" --argjson rerun $rerun '
    def matches($q; $text): $q == "" or ($text | ascii_downcase | contains($q));

    def problem:
        [.list, .status] as $docs
        | if any($docs[]; . == null) then
              [{title: "Patchy didn'"'"'t respond as expected",
                subtitle: "Run patchy status in Terminal to see why.", valid: false}]
          elif any($docs[]; .ok == false) then
              [first($docs[] | select(.ok == false)) |
               {title: "Patchy reported a problem", subtitle: .message, valid: false}]
          else null end;

    def php_items($q):
        .status.php.active as $active
        | [.status.php.installed[]
           | select(matches($q; .version))
           | {title: "PHP \(.version)",
              subtitle: (if .version == $active then "Currently active"
                         else "Switch to PHP \(.version)" end),
              arg: "php \(.version)"}];

    def server_items($q):
        (.status.apache.running) as $running
        | [{title: (if $running then "Apache is running" else "Apache is stopped" end),
            subtitle: "PHP \(.status.php.active // "?")", valid: false}]
          + (if $running then
                 [{title: "Restart Apache", arg: "restart"}, {title: "Stop Apache", arg: "stop"}]
             else
                 [{title: "Start Apache", arg: "start"}]
             end)
          + [{title: "Switch PHP version", subtitle: "Pick from the installed versions",
              autocomplete: "php ", valid: false}]
        | map(select(matches($q; "\(.title) apache server")));

    def site_items($q):
        if (.list.sites | length) == 0 then
            [{title: "No sites yet", subtitle: "Add one in Terminal: patchy add <domain>", valid: false}]
        else
            [.list.sites[]
             | select(matches($q; .domain))
             | {title: .domain,
                subtitle: ([.docroot]
                           + (if .docroot_exists == false then ["folder missing"] else [] end)
                           + (if (.certificate.state // "ok") != "ok"
                              then ["certificate \(.certificate.state)"] else [] end)
                           | join(" · ")),
                arg: "open \(.domain)",
                quicklookurl: "https://\(.domain)",
                text: {copy: "https://\(.domain)"}}]
        end;

    ($query | ascii_downcase | sub("^ +"; "")) as $raw
    | (problem // (
          if $raw | test("^php( |$)") then
              php_items($raw | sub("^php *"; ""))
          else
              server_items($raw) + site_items($raw)
          end)) as $items
    | {items: $items} + (if $rerun then {rerun: 0.5} else {} end)
'
