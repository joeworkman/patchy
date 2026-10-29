# Patchy — /etc/hosts routing, the passwordless trust helper, and the
# migration away from the old dnsmasq setup.
# Sourced by bin/patchy; uses its globals and helpers.

# Legacy dnsmasq installs (pre-hosts migration) — referenced only by
# migrate_dnsmasq/legacy_dns_hint so 'setup' can clean them up.
DNSMASQ_PORT=53535
DNSMASQ_DIR="$BREW_PREFIX/etc/dnsmasq.d"
PATCHY_DNS_CONF="$DNSMASQ_DIR/patchy.conf"
RESOLVER_DIR="/etc/resolver"

# 'patchy trust' installs a root-owned helper + sudoers NOPASSWD rule so
# /etc/hosts edits stop prompting for a password. Never point sudoers at
# patchy itself — this script is user-writable, the helper is not.
HELPER_PATH="/usr/local/libexec/patchy-hosts"
SUDOERS_FILE="/etc/sudoers.d/patchy"

# Bumped whenever write_hosts_helper changes what it writes. An installed
# helper predates the change unless 'check' echoes this exact string, and a
# stale helper would keep writing the old entries while patchy assumed the
# new ones — so a mismatch falls back to inline sudo until 'trust' reinstalls.
HELPER_VERSION="2"

# /etc/hosts is the DNS layer: one marked line per configured site, applied
# by macOS immediately — no daemon, no cache flush, no stale TTLs.
function sync_hosts_entries() {
    [ -n "$(list_domains)" ] || return 0
    hosts_sudo_note
    if ! hosts_sync $(list_hosts_names); then
        warn "${PATCHY_ERROR:-hosts_update_failed}" "/etc/hosts was not updated, so sites won't resolve locally."
        PATCHY_ERROR=""
        echo "Warning: /etc/hosts was not updated — sites will not resolve locally." >&2
        echo "Run '$SCRIPT_NAME start' again to retry." >&2
        return 1
    fi
}

# Old installs routed DNS through dnsmasq via /etc/resolver files on our
# port. /etc/hosts wins for configured names, but leftovers break other
# lookups under those TLDs/domains — setup cleans them up.
function legacy_dns_hint() {
    local f
    for f in "$RESOLVER_DIR"/*(N); do
        if grep -qE "^port[[:space:]]+$DNSMASQ_PORT\$" "$f" 2>/dev/null; then
            echo "Note: legacy dnsmasq resolver files found in $RESOLVER_DIR — run"
            echo "'$SCRIPT_NAME setup' to finish migrating to /etc/hosts routing."
            return 0
        fi
    done
    return 0
}

# macOS caches DNS answers with their original TTLs; a routing change
# (resolver file added or removed) doesn't purge them, so a just-added
# domain can keep resolving to its live IP for minutes without this.
function flush_dns_cache() {
    echo "Flushing macOS DNS cache..."
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder
}

# Every site lives in /etc/hosts as an exact name with a trailing "# patchy"
# marker, so patchy can rewrite its own entries without touching anything
# else. (.local names are Bonjour-safe here — exact hosts entries don't
# capture the TLD the way a resolver file would.)
#
# Both an IPv4 and an IPv6 line, always. Browsers resolve with AF_UNSPEC and
# wait for the A *and* AAAA answers before connecting. A .local name with only
# a 127.0.0.1 line answers the A leg from here but leaves the AAAA leg to
# mDNSResponder, which multicasts it to the LAN and waits out the full 5s
# Bonjour timeout — a flat 5s added to every request. The ::1 line answers
# that leg locally so it never reaches multicast.
function hosts_entry_exists() {
    local escaped="${1//./\\.}"
    grep -qE "^127\.0\.0\.1[[:space:]]+${escaped}[[:space:]]*# patchy\$" /etc/hosts &&
        grep -qE "^::1[[:space:]]+${escaped}[[:space:]]*# patchy\$" /etc/hosts
}

function hosts_active() {
    grep -qE '# patchy$' /etc/hosts
}

# Passwordless mode is usable only if the helper exists AND sudo lets us run
# it without a password ('patchy trust' installs both).
function trust_active() {
    [ -x "$HELPER_PATH" ] || return 1
    [ "$(sudo -n "$HELPER_PATH" check 2>/dev/null)" = "$HELPER_VERSION" ]
}

# Installed and callable, but not necessarily the current version. Used to
# tell "never trusted" apart from "trusted, but the helper needs updating".
function trust_installed() {
    [ -x "$HELPER_PATH" ] && sudo -n "$HELPER_PATH" check >/dev/null 2>&1
}

function hosts_sudo_note() {
    trust_active && return 0
    if trust_installed; then
        echo "Password prompt ahead: the patchy-hosts helper is out of date."
        echo "Run '$SCRIPT_NAME trust' once to update it and stop these prompts."
        return 0
    fi
    echo "Password prompt ahead: patchy routes domains via /etc/hosts, which needs"
    echo "sudo. Run '$SCRIPT_NAME trust' once to stop these prompts."
}

# The single /etc/hosts writer: make the "# patchy" lines match exactly the
# given domains. Desired-state (not add/remove deltas) so every caller
# regenerates from the same source of truth. Tries the trust helper first;
# falls back to inline sudo with a normal password prompt.
function hosts_sync() {
    if trust_active && sudo -n "$HELPER_PATH" sync "$@"; then
        return 0
    fi
    hosts_sync_inline "$@"
}

# Inline fallback: rebuild to a temp file, then atomically install over
# /etc/hosts (never truncate-in-place — a half-written hosts file kills all
# name resolution).
function hosts_sync_inline() {
    local domain tmp
    require_sudo "Updating /etc/hosts" || return 1
    tmp=$(mktemp) || return 1
    {
        grep -v '# patchy$' /etc/hosts
        for domain in "$@"; do
            echo "127.0.0.1 $domain # patchy"
            echo "::1 $domain # patchy"
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    sudo /usr/bin/install -m 644 -o root -g wheel "$tmp" /etc/hosts
    local rc=$?
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || fail hosts_update_failed "Couldn't update /etc/hosts." >&2
    return $rc
}

# Sync the configured names ± one site — used by add/rm, where the vhost
# file for the site in question doesn't exist yet / still exists. add
# passes the new domain plus any accepted alias explicitly.
function hosts_add() {
    hosts_sync $(list_hosts_names) "$@"
}

function hosts_remove() {
    local domain=$1 name keep=() drop
    drop=$(echo "$domain"; list_site_aliases "$domain")
    for name in $(list_hosts_names); do
        echo "$drop" | grep -qxF "$name" || keep+=("$name")
    done
    hosts_sync "${keep[@]}"
}

# The helper is the ONLY thing sudoers whitelists, so it must be minimal,
# root-owned, and impossible to talk into editing anything but our marked
# lines. Emitted here so patchy stays a single distributable file.
function write_hosts_helper() {
    # Shebang and version printed separately so HELPER_VERSION interpolates;
    # the body stays in a quoted heredoc so its own $vars reach the helper
    # verbatim rather than being expanded here.
    printf '#!/bin/sh\n'
    printf "# patchy-hosts — installed root-owned by 'patchy trust'.\n"
    printf '# Rewrites the "# patchy" marked lines of /etc/hosts and nothing else.\n'
    printf 'PATCHY_HELPER_VERSION=%s\n' "$HELPER_VERSION"
    cat <<'EOF'
set -eu

[ "$(id -u)" -eq 0 ] || { echo "patchy-hosts must run as root (via sudo)" >&2; exit 1; }

case "${1:-}" in
    check) echo "$PATCHY_HELPER_VERSION"; exit 0 ;;
    sync) shift ;;
    *) echo "usage: patchy-hosts sync [domain ...]" >&2; exit 64 ;;
esac

for domain in "$@"; do
    case "$domain" in
        ''|*[!a-zA-Z0-9.-]*|-*|.*|*-|*.|*..*)
            echo "patchy-hosts: invalid domain: $domain" >&2
            exit 64
            ;;
    esac
done

# Same filesystem as /etc/hosts so mv is atomic — a half-written hosts
# file would kill all name resolution.
tmp=$(mktemp /etc/hosts.patchy.XXXXXX)
trap 'rm -f "$tmp"' EXIT
grep -v '# patchy$' /etc/hosts > "$tmp" || true
for domain in "$@"; do
    printf '127.0.0.1 %s # patchy\n' "$domain" >> "$tmp"
    printf '::1 %s # patchy\n' "$domain" >> "$tmp"
done
chmod 644 "$tmp"
chown root:wheel "$tmp"
mv "$tmp" /etc/hosts
trap - EXIT
EOF
}

# The sudoers rule installed by trust_patchy grants passwordless root to
# whoever can produce the file at $HELPER_PATH, so every directory in that
# path must be root-controlled — otherwise a non-root owner of an ancestor
# directory (e.g. a user/admin-writable /usr/local on Intel Homebrew) could
# swap in their own "helper" and the sudoers rule would run it as root.
function assert_root_owned_path() {
    local dir=$1 info uid perm group_bit other_bit
    info=$(stat -f '%u %Lp' "$dir" 2>/dev/null) || {
        fail unsafe_path "Error: cannot stat $dir; trust cannot be safely installed." >&2
        return 1
    }
    uid=${info%% *}
    perm=${info##* }
    group_bit=${perm[-2]}
    other_bit=${perm[-1]}
    if [ "$uid" -ne 0 ] || (( (group_bit & 2) || (other_bit & 2) )); then
        fail unsafe_path "Error: $dir is owned by uid $uid with mode $perm — writable by" \
            "non-root, so trust cannot be safely installed. The sudoers rule
trusts the path $HELPER_PATH, and anyone able to write to $dir
could substitute their own helper and gain passwordless root.
Normal sudo-prompt mode (without 'trust') still works fine." >&2
        return 1
    fi
}

function trust_patchy() {
    if [ "${PATCHY_JSON:-0}" -eq 1 ]; then
        require_sudo "Installing trust" "Run '$SCRIPT_NAME trust' in Terminal." || return 1
    elif [ ! -t 0 ] && [ -z "${SUDO_ASKPASS:-}" ]; then
        fail terminal_required "Run '$SCRIPT_NAME trust' in an interactive terminal (needs sudo)." >&2
        return 1
    fi

    local ancestor
    for ancestor in /usr /usr/local "${HELPER_PATH:h}"; do
        [ -d "$ancestor" ] || continue
        assert_root_owned_path "$ancestor" || return 1
    done

    echo "Installing the patchy-hosts helper and sudoers rule (requires sudo)."
    echo "Afterwards patchy can update /etc/hosts without a password prompt."

    local user tmp_helper tmp_sudoers
    user=$(whoami)
    tmp_helper=$(mktemp) || return 1
    write_hosts_helper > "$tmp_helper" || { rm -f "$tmp_helper"; return 1; }
    if [ ! -s "$tmp_helper" ]; then
        fail trust_failed "Error: generated helper script is empty; nothing installed." >&2
        rm -f "$tmp_helper"
        return 1
    fi
    tmp_sudoers=$(mktemp) || { rm -f "$tmp_helper"; return 1; }
    printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$HELPER_PATH" > "$tmp_sudoers"

    # A malformed sudoers.d file can break sudo entirely — validate before
    # anything is installed.
    if ! visudo -cf "$tmp_sudoers" >/dev/null; then
        fail trust_failed "Error: generated sudoers rule failed validation; nothing installed." >&2
        rm -f "$tmp_helper" "$tmp_sudoers"
        return 1
    fi

    sudo /usr/bin/install -d -m 755 -o root -g wheel "${HELPER_PATH:h}" &&
        sudo /usr/bin/install -m 755 -o root -g wheel "$tmp_helper" "$HELPER_PATH" &&
        sudo /usr/bin/install -m 440 -o root -g wheel "$tmp_sudoers" "$SUDOERS_FILE"
    local rc=$?
    rm -f "$tmp_helper" "$tmp_sudoers"
    if [ "$rc" -ne 0 ]; then
        fail trust_failed "Trust setup failed — run '$SCRIPT_NAME untrust' to remove any partial install." >&2
        return 1
    fi
    echo "Done. start/stop/add/rm will no longer prompt for a password."
}

function untrust_patchy() {
    if [ ! -f "$SUDOERS_FILE" ] && [ ! -f "$HELPER_PATH" ]; then
        echo "Trust is not installed."
        return 0
    fi
    require_sudo "Removing trust" "Run '$SCRIPT_NAME untrust' in Terminal." || return 1
    echo "Removing the sudoers rule and helper (requires sudo)..."
    if ! sudo rm -f "$SUDOERS_FILE" "$HELPER_PATH"; then
        fail trust_failed "Couldn't remove the sudoers rule and helper."
        return 1
    fi
    echo "Done. /etc/hosts updates will prompt for your password again."
}

# Migrate hostess-era /etc/hosts entries. hostess consolidates every name
# onto one "127.0.0.1 localhost a b c…" line, so domains are matched as
# whitespace-delimited tokens and removed token-wise — never line-wise.
function migrate_hosts_entries() {
    local domain escaped stale=()
    local unmarked
    unmarked=$(grep -E '^[[:space:]]*127\.0\.0\.1[[:space:]]' /etc/hosts | grep -v '# patchy$')
    for domain in $(list_domains); do
        [ "$domain" = "localhost" ] && continue
        escaped="${domain//./\\.}"
        if echo "$unmarked" | grep -qE "[[:space:]]$escaped([[:space:]]|\$)"; then
            stale+=("$domain")
        fi
    done
    [ ${#stale[@]} -eq 0 ] && return 0
    echo "Migrating stale /etc/hosts entries..."
    local args=()
    for domain in "${stale[@]}"; do
        escaped="${domain//./\\.}"
        args+=(-e "/^[[:space:]]*127\.0\.0\.1[[:space:]]/{" \
               -e "/# patchy\$/!s/[[:space:]]+($escaped)([[:space:]]|\$)/\\2/g" \
               -e "}")
    done
    sudo sed -i '' -E "${args[@]}" /etc/hosts || return 1
}

# Tear down the pre-v0.9 dnsmasq DNS layer. Patchy-owned resolver files are
# identified by our port — other tools' files are never touched. dnsmasq
# itself stays installed; uninstalling software is the user's call.
function migrate_dnsmasq() {
    local f found=0
    for f in "$RESOLVER_DIR"/*(N); do
        grep -qE "^port[[:space:]]+$DNSMASQ_PORT\$" "$f" 2>/dev/null || continue
        found=1
        echo "Removing legacy resolver file $f (requires sudo)..."
        sudo rm -f "$f" || echo "Warning: could not remove $f — re-run '$SCRIPT_NAME setup' to retry." >&2
    done
    if [ -f "$PATCHY_DNS_CONF" ]; then
        found=1
        rm -f "$PATCHY_DNS_CONF"
        echo "Removed $PATCHY_DNS_CONF"
    fi
    [ "$found" -eq 1 ] || return 0
    if [ -d "$BREW_PREFIX/opt/dnsmasq" ]; then
        echo "Stopping dnsmasq (no longer used by patchy)..."
        brew services stop dnsmasq
        echo "To remove it entirely: brew uninstall dnsmasq"
    fi
    # Answers cached from the dnsmasq era keep their TTLs; flush once so
    # sites cut over to /etc/hosts immediately.
    flush_dns_cache
}

function setup_hosts() {
    if [ ! -t 0 ] && [ -z "${SUDO_ASKPASS:-}" ]; then
        echo "Skipping /etc/hosts configuration (no interactive terminal for sudo)."
        echo "Run '$SCRIPT_NAME setup' in a terminal to finish."
        return 0
    fi
    echo "Configuring /etc/hosts routing (requires sudo)..."
    echo "Backup: /etc/hosts.patchy-bkp"
    sudo cp /etc/hosts /etc/hosts.patchy-bkp || return 1
    migrate_dnsmasq
    migrate_hosts_entries || return 1
    hosts_sync $(list_hosts_names) || return 1
}

# Every name that must resolve locally: each site plus its aliases. Feeding
# the hosts sync from here means start/stop/rm need no www-specific code.
function list_hosts_names() {
    local domain
    for domain in $(list_domains); do
        echo "$domain"
        list_site_aliases "$domain"
    done | sort -u
    return 0
}
