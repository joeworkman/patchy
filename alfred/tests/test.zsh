#!/bin/zsh
# Tests for the Alfred workflow. A stub patchy prints canned JSON, so nothing
# here touches the real server. Run: zsh alfred/tests/test.zsh
emulate -L zsh
TESTS=${0:A:h}
ALFRED=${TESTS:h}
FAILURES=0

# Each test gets its own fixture set, cache folder and call log.
function fresh() {
    export STUB_DIR=$TESTS/fixtures/${1:-default}
    export patchy_path=$TESTS/stub/patchy
    export alfred_workflow_cache=$(mktemp -d)
    export STUB_LOG=$alfred_workflow_cache/calls.log
}

function report() {
    if [ "$2" -eq 0 ]; then
        print "ok    $1"
    else
        print "FAIL  $1"
        print -r -- "      got: ${3[1,400]}"
        (( FAILURES++ ))
    fi
}

# check <name> <jq assertion> <output>
function check() {
    print -r -- "$3" | jq -e "$2" >/dev/null 2>&1
    report "$1" $? "$3"
}

# check_eq <name> <expected> <output>
function check_eq() {
    [ "$2" = "$3" ]
    report "$1" $? "$3"
}

# Run a snippet with lib.zsh loaded.
function lib() {
    zsh -c "source ${(q)ALFRED}/lib.zsh; $1"
}

# --- lib.zsh ---------------------------------------------------------------

fresh
check_eq finds_stub "$TESTS/stub/patchy" "$(lib 'patchy_setup && print -r -- $PATCHY')"

fresh; patchy_path=/nope/patchy
check bad_patchy_path '(.items | length == 1) and (.items[0].subtitle | contains("/nope/patchy"))' \
    "$(lib 'patchy_setup || problem_items')"

fresh old
check old_cli '.items[0].title | ascii_downcase | contains("upgrade")' \
    "$(lib 'patchy_setup && { patchy_check_features || problem_items }')"

fresh
check escaping '.items[0].title == "a\"b"' "$(lib "alfred_items '[{title: \$t}]' --arg t 'a\"b'")"

# --- filter.zsh ------------------------------------------------------------

function filter() {
    zsh "$ALFRED/filter.zsh" "${1:-}"
}

fresh
out=$(filter)
check server_row_running '(.items[0].title == "Apache is running") and (.items[1].arg == "restart") and (.items[2].arg == "stop") and ([.items[].arg] | index("start") == null)' "$out"
check site_rows 'any(.items[]; .title == "alpha.test" and .arg == "open alpha.test" and .subtitle == "/Users/me/Sites/alpha")' "$out"
check site_flags 'any(.items[]; .title == "beta.test" and (.subtitle | contains("folder missing")) and (.subtitle | contains("certificate expired")) and .valid != false)' "$out"

fresh stopped
check server_row_stopped '(.items[0].title == "Apache is stopped") and ([.items[].arg | select(. == "start" or . == "stop" or . == "restart")] == ["start"])' "$(filter)"

fresh
check query_filters '[.items[] | select(.arg != null) | .arg] == ["open alpha.test"]' "$(filter alp)"

fresh
check php_rows '([.items[].arg] == ["php 8.5", "php 8.4"]) and (.items[0].subtitle | contains("active"))' "$(filter php)"

fresh no_sites
check no_sites 'any(.items[]; .title == "No sites yet" and (.subtitle | contains("patchy add")))' "$(filter)"

fresh cli_failure
check cli_failure '(.items | length == 1) and (.items[0].subtitle == "Run patchy setup first.")' "$(filter)"

fresh
filter >/dev/null
touch -t 202001010000 "$alfred_workflow_cache/state.json"
STUB_DIR=$TESTS/fixtures/no_sites
check cache_used 'any(.items[]; .title == "alpha.test") and (.rerun != null)' "$(filter)"

# A Patchy that starts failing must not hide behind a warm cache.
fresh
filter >/dev/null
touch -t 202001010000 "$alfred_workflow_cache/state.json"
STUB_DIR=$TESTS/fixtures/cli_failure
filter >/dev/null
for i in {1..50}; do [ -d "$alfred_workflow_cache/state.json.lock" ] || break; sleep 0.1; done
check failure_replaces_cache '(.items | length == 1) and (.items[0].subtitle == "Run patchy setup first.")' "$(filter)"

fresh
print 'not json' > "$alfred_workflow_cache/state.json"
check bad_cache 'any(.items[]; .title == "alpha.test")' "$(filter)"

# --- action.zsh ------------------------------------------------------------

# OPEN_COMMAND lets the test see what would be opened.
function action() {
    OPEN_COMMAND="print -r -- OPENED" zsh "$ALFRED/action.zsh" "$1"
}

fresh
check_eq open_site "OPENED https://alpha.test" "$(action 'open alpha.test')"

fresh
print '{}' > "$alfred_workflow_cache/state.json"
out=$(action stop)
check_eq stop_ok "Apache stopped" "$out"
check_eq stop_called "stop --json" "$(<$STUB_LOG)"
check_eq stop_clears_cache "gone" "$([ -e $alfred_workflow_cache/state.json ] && print here || print gone)"

fresh warn_sudo
check_eq stop_warn "Apache stopped, but: Couldn't update /etc/hosts without your password. Run patchy trust to stop being asked." "$(action stop)"

fresh fail_port
check_eq start_fail "Couldn't start Apache: Port 443 is already in use." "$(action start)"

fresh
check_eq php_switch "Switched to PHP 8.4" "$(action 'php 8.4')"

fresh stopped
check_eq php_switch_stopped "Switched to PHP 8.4 and started Apache" "$(action 'php 8.4')"

fresh
check_eq php_already_active "Already on PHP 8.5" "$(action 'php 8.5')"
check_eq php_already_no_call "" "$(grep '^php' $STUB_LOG)"

# --- build.zsh -------------------------------------------------------------

out=$(mktemp -d)
zsh "$ALFRED/build.zsh" 9.8.7 "$out/Patchy.alfredworkflow" >/dev/null 2>&1
mkdir "$out/x" && (cd "$out/x" && unzip -q ../Patchy.alfredworkflow 2>/dev/null)
check_eq build_files "action.zsh askpass.zsh filter.zsh icon.png info.plist lib.zsh" \
    "$(cd "$out/x" 2>/dev/null && print -r -- *(N))"
check_eq build_version "9.8.7" "$(plutil -extract version raw "$out/x/info.plist" 2>/dev/null)"
check_eq build_lint "ok" "$(plutil -lint -s "$out/x/info.plist" 2>/dev/null && print ok)"
check_eq build_source_untouched "ok" "$(plutil -extract version raw "$ALFRED/info.plist" 2>/dev/null | grep -qv 9.8.7 && print ok)"
check_eq build_missing_fails "fails" "$(zsh "$ALFRED/build.zsh" 1.0 /nonexistent/dir/x.alfredworkflow >/dev/null 2>&1 || print fails)"

print
if [ $FAILURES -eq 0 ]; then print "all passed"; else print "$FAILURES failed"; fi
exit $FAILURES
