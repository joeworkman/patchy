# Shared by the workflow's scripts. Everything here talks to Patchy through
# `patchy … --json` only; the workflow never reads Patchy's files.

ALFRED_DIR=${${(%):-%x}:A:h}
CACHE_FILE="${alfred_workflow_cache:-${TMPDIR:-/tmp}/patchy-alfred}/state.json"
PATCHY=""
PATCHY_PROBLEM=""
PATCHY_PROBLEM_DETAIL=""

# The CLI features the workflow relies on. Both shipped in v1.3.0.
REQUIRED_FEATURES=(json askpass)

# Alfred runs scripts without the user's shell PATH, so find patchy and brew
# ourselves. patchy runs `brew --prefix` as it starts, and a from-source
# patchy may not sit next to brew, so both directories go on PATH.
function patchy_setup() {
    local dir brew_dir=""
    if [ -n "${patchy_path:-}" ]; then
        if [ ! -x "$patchy_path" ]; then
            PATCHY_PROBLEM="Patchy not found"
            PATCHY_PROBLEM_DETAIL="No patchy at $patchy_path. Fix it in the workflow's configuration."
            return 1
        fi
        PATCHY=$patchy_path
    else
        for dir in /opt/homebrew/bin /usr/local/bin; do
            if [ -x "$dir/patchy" ]; then
                PATCHY=$dir/patchy
                break
            fi
        done
    fi
    if [ -z "$PATCHY" ]; then
        PATCHY_PROBLEM="Patchy isn't installed"
        PATCHY_PROBLEM_DETAIL="brew install joeworkman/patchy/patchy"
        return 1
    fi
    for dir in /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$dir/brew" ]; then
            brew_dir=$dir
            break
        fi
    done
    export PATH="${PATCHY:h}${brew_dir:+:$brew_dir}:/usr/bin:/bin:/usr/sbin:/sbin"
    # sudo -A shows our dialog instead of waiting on a terminal nobody sees.
    export SUDO_ASKPASS="$ALFRED_DIR/askpass.zsh"
    return 0
}

function patchy_check_features() {
    local version
    version=$("$PATCHY" version --json 2>/dev/null)
    if ! print -r -- "$version" |
            jq -e --args '(.features // []) as $have | ($ARGS.positional - $have | length) == 0' \
                "${REQUIRED_FEATURES[@]}" >/dev/null 2>&1; then
        PATCHY_PROBLEM="Please upgrade Patchy"
        PATCHY_PROBLEM_DETAIL="brew upgrade patchy"
        return 1
    fi
    return 0
}

# alfred_items <jq filter> [jq args…]: the filter builds the items array.
function alfred_items() {
    local filter=$1
    shift
    jq -n "$@" "{items: ($filter)}"
}

function problem_items() {
    alfred_items '[{title: $t, subtitle: $s, valid: false}]' \
        --arg t "$PATCHY_PROBLEM" --arg s "$PATCHY_PROBLEM_DETAIL"
}
