# Patchy — Sites and their certificates.
# Sourced by bin/patchy; uses its globals and helpers.

# Offer a www alias on apex adds. Default Yes; non-interactive stdin takes
# the default so scripted adds don't hang. Prompt goes to stderr because
# callers capture stdout. The answer is recorded as a ServerAlias — hosts
# entries, certs, and teardown all derive from that.
function prompt_www_alias() {
    local domain=$1 alias reply
    alias=$(www_alias_for "$domain")
    [ -n "$alias" ] || return 0
    if [ -t 0 ]; then
        printf "Also serve %s? [Y/n] " "$alias" >&2
        read -r reply
        case "$reply" in
            [nN]|[nN][oO]) return 0 ;;
        esac
    fi
    echo "$alias"
}

# Routing a real domain hides its live site on this Mac — make sure that's
# intended. .test is fake by definition and .local never leaves the LAN.
# --yes answers for you; --json can't ask, so it needs --yes.
function confirm_real_domain() {
    local domain=$1 www=${2:-}
    case "${domain##*.}" in
        test|local) return 0 ;;
    esac
    [ "${PATCHY_YES:-0}" -eq 1 ] && return 0
    if [ "${PATCHY_JSON:-0}" -eq 1 ]; then
        fail confirmation_required "$domain looks like a real domain, which would be unreachable on this Mac while routed here. Add --yes to go ahead."
        return 1
    fi
    local names="$domain"
    [ -n "$www" ] && names="$domain (and $www)"
    echo "Routing $names to this Mac. If $domain is a real website, it will be"
    echo "unreachable here until you run '$SCRIPT_NAME rm $domain' or '$SCRIPT_NAME stop'."
    printf "Continue? [y/N] "
    local reply
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) fail cancelled "Aborted."; return 1 ;;
    esac
}

function add_site() {
    local domain=${1:-}
    local docroot=${2:-}
    if [ -z "$domain" ]; then
        fail missing_argument "Please provide a domain."
        return 1
    fi
    [ -z "$docroot" ] && docroot="$DEFAULT_WEBROOT/$domain"

    if site_exists "$domain"; then
        fail site_exists "Site already exists... $domain"
        return 1
    fi

    if [ ! -d "$docroot" ]; then
        echo "Creating document root at $docroot"
        mkdir -p "$docroot"
    fi

    docroot=$(cd "$docroot" && pwd)

    echo "Adding a new site... $domain"

    local www_alias
    www_alias=$(prompt_www_alias "$domain")

    confirm_real_domain "$domain" "$www_alias" || return 1
    # Hosts entry first: a declined sudo aborts before anything is created.
    hosts_sudo_note
    hosts_add "$domain" ${www_alias:+"$www_alias"} || return 1

    echo "Creating SSL certificates..."
    make_cert "$domain" ${www_alias:+"$www_alias"}

    mkdir -p "$VHOSTS_DIR"
    ensure_sites_included

    echo "Creating Apache config file..."
    local conf_file="$VHOSTS_DIR/$domain.conf"
    local alias_line=""
    [ -n "$www_alias" ] && alias_line=$'\n'"    ServerAlias $www_alias"
    cat > "$conf_file" <<EOF
<Directory "$docroot">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

<VirtualHost *:80>
    DocumentRoot "$docroot"
    ServerName $domain$alias_line
    ErrorLog "$LOG_DIR/$domain-error_log"
    CustomLog "$LOG_DIR/$domain-access_log" common
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteRule ^/?(.*) https://%{HTTP_HOST}/\$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot "$docroot"
    ServerName $domain$alias_line
    ErrorLog "$LOG_DIR/$domain-error_log"
    CustomLog "$LOG_DIR/$domain-access_log" common
    SSLEngine on
    SSLCertificateFile "$CERT_DIR/$domain.pem"
    SSLCertificateKeyFile "$CERT_DIR/$domain-key.pem"
</VirtualHost>
EOF

    if ! verify_config; then
        echo "Rolling back site creation..."
        local check
        check=$(apachectl -t 2>&1 | tail -n 5)
        remove_domain "$domain"
        remove_cert "$domain"
        PATCHY_ERROR=config_invalid PATCHY_ERROR_MESSAGE="Apache rejected $domain's config, so the site was rolled back" \
            PATCHY_ERROR_DETAILS=$check
        return 1
    fi

    restart_server
}

function root_cert_exists() {
    local rootdir
    rootdir=$(mkcert -CAROOT)
    [ -f "$rootdir/rootCA.pem" ] && [ -f "$rootdir/rootCA-key.pem" ]
}

# Extra args become SAN names. Filenames are pinned because mkcert's
# defaults change when a cert has multiple names, and the vhost SSL paths
# must never move.
function make_cert() {
    local domain=$1
    mkdir -p "$CERT_DIR"
    cd "$CERT_DIR" || return 1
    if ! root_cert_exists; then
        mkcert -install
    fi
    mkcert -cert-file "$domain.pem" -key-file "$domain-key.pem" "$@"
}

function remove_cert() {
    local domain=$1
    cd "$CERT_DIR" 2>/dev/null || return 0
    rm -f "$domain.pem" "$domain-key.pem"
}

# Keeps mkcert's root CA (valid for 10 years): replacing it costs two macOS
# password dialogs, and if the second is cancelled every site ends up signed
# by a CA the system doesn't trust. 'mkcert -install' asks only when the CA
# isn't trusted yet, so this repairs trust without prompting otherwise.
function refresh_certs() {
    mkdir -p "$CERT_DIR" && cd "$CERT_DIR" || {
        fail cert_failed "Couldn't open $CERT_DIR."
        return 1
    }
    if ! mkcert -install; then
        fail cert_failed "Couldn't add mkcert's root CA to the system trust store."
        return 1
    fi
    make_cert localhost
    local site failed=0
    for site in $(list_domains); do
        [ "$site" = "localhost" ] && continue
        rm -f "$site.pem" "$site-key.pem"
        if ! make_cert "$site" $(list_site_aliases "$site"); then
            fail cert_failed "Couldn't create a certificate for $site."
            failed=1
        fi
    done
    # Apache keeps serving the old certs from memory until it reloads them
    if is_apache_running; then
        restart_server || return 1
    fi
    [ "$failed" -eq 0 ]
}

function cert_days_left() {
    local cert=$1 end_date end_epoch secs
    end_date=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null) || return 1
    end_date=${end_date#notAfter=}
    # %e not %d: openssl space-pads single-digit days ("Sep  9").
    # LC_ALL=C: openssl always prints English month names, but %b parses
    # them in the user's locale, so a German/French/etc. Mac fails here.
    end_epoch=$(LC_ALL=C date -j -f "%b %e %T %Y %Z" "$end_date" +%s 2>/dev/null) || return 1
    secs=$(( end_epoch - $(date +%s) ))
    echo $(( secs < 0 ? (secs - 86399) / 86400 : secs / 86400 ))
}

function list_domains() {
    [ -d "$VHOSTS_DIR" ] || return 0
    local f
    for f in "$VHOSTS_DIR"/*.conf(N); do
        echo "${f:t:r}"
    done | sort
}

# Apex domains (exactly two labels, not already www.) get a www alias
# offer; subdomain sites never do. Echoes the alias or nothing.
function www_alias_for() {
    local domain=$1
    case "$domain" in
        www.*) ;;
        *.*.*) ;;
        *.*) echo "www.$domain" ;;
    esac
    return 0
}

# ServerAlias values recorded in a site's vhost conf — the durable record
# of the www answer given at add time. Handles multi-name alias lines.
function list_site_aliases() {
    awk '/^[[:space:]]*ServerAlias[[:space:]]/ { for (i = 2; i <= NF; i++) print $i }' \
        "$VHOSTS_DIR/$1.conf" 2>/dev/null | sort -u
    return 0
}

# A site's certificate as "<state> <days left>". state is ok, expiring (30
# days or fewer), expired, invalid or none; days is missing when unreadable.
function site_cert_state() {
    local cert="$CERT_DIR/$1.pem" days
    if [ ! -f "$cert" ]; then
        echo "none"
    elif ! days=$(cert_days_left "$cert"); then
        echo "invalid"
    elif [ "$days" -lt 0 ]; then
        echo "expired $days"
    elif [ "$days" -le 30 ]; then
        echo "expiring $days"
    else
        echo "ok $days"
    fi
}

function site_docroot() {
    sed -n 's/^[[:space:]]*DocumentRoot[[:space:]]*"\(.*\)".*/\1/p' "$VHOSTS_DIR/$1.conf" | head -n1
}

function list_sites() {
    if [ ! -d "$VHOSTS_DIR" ] || [ -z "$(list_domains)" ]; then
        echo "No sites configured."
        return 0
    fi
    local domain docroot https state days needs_attention=0 missing_docroot=0
    local orange="" red="" reset=""
    if [ -t 1 ]; then
        orange=$'\e[38;5;208m'
        red=$'\e[31m'
        reset=$'\e[0m'
    fi
    local dwidth=6
    while IFS= read -r domain; do
        (( ${#domain} > dwidth )) && dwidth=${#domain}
    done < <(list_domains)
    (( dwidth += 3 ))
    printf "%-${dwidth}s %-8s %s\n" "DOMAIN" "HTTPS" "DOCROOT"
    while IFS= read -r domain; do
        docroot=$(site_docroot "$domain")
        local docroot_note=""
        if [ ! -d "$docroot" ]; then
            docroot_note=" ${red}(missing)${reset}"
            missing_docroot=1
        fi
        docroot="${docroot/#$HOME/~}"
        local color=""
        read -r state days <<<"$(site_cert_state "$domain")"
        case $state in
            none) https="no" ;;
            invalid) https="invalid"; color=$red; needs_attention=1 ;;
            expired) https="expired"; color=$red; needs_attention=1 ;;
            expiring) https="${days}d"; color=$orange; needs_attention=1 ;;
            *) https="${days}d" ;;
        esac
        # color applied outside the padding so escape codes don't skew column width
        printf "%-${dwidth}s ${color}%-8s${reset} %s%s\n" "$domain" "$https" "$docroot" "$docroot_note"
    done < <(list_domains)
    if share_ready; then
        local share first=1
        for share in "$SHARE_DIR"/sites/*(N/); do
            if [ "$first" -eq 1 ]; then
                echo ""
                echo "Share addresses:"
                first=0
            fi
            printf "%-${dwidth}s https://%s.%s\n" "${share:t}" "$(<"$share/name")" "$(share_domain)"
        done
    fi
    if [ "$needs_attention" -eq 1 ]; then
        echo ""
        echo "Some certificates expire soon or are invalid. Run 'patchy refresh-certs' to regenerate them."
    fi
    if [ "$missing_docroot" -eq 1 ]; then
        echo ""
        echo "Some sites' folders are missing. Create the folder again, or remove the site with '$SCRIPT_NAME rm <domain>'."
    fi
}

function site_exists() {
    local domain=$1
    [ -f "$VHOSTS_DIR/$domain.conf" ]
}

function remove_site() {
    local domain=$1

    if ! site_exists "$domain"; then
        fail site_not_found "Site does not exist... $domain"
        return 1
    fi

    remove_domain "$domain" || return 1
    remove_cert "$domain"
    share_forget_site "$domain"
}

# 'patchy rm <domain>...': each site is removed even if another fails, then
# Apache restarts once. Fails if any site couldn't be removed.
function remove_sites() {
    if [ $# -eq 0 ]; then
        fail missing_argument "Please provide one or more domains."
        return 1
    fi
    local domain removed=0 failed=0
    for domain in "$@"; do
        if remove_site "$domain"; then
            removed=1
        else
            failed=1
        fi
    done
    if [ "$removed" -eq 1 ]; then
        restart_server || return 1
    fi
    [ "$failed" -eq 0 ]
}

# Hosts teardown runs FIRST: a declined sudo leaves the site fully intact
# rather than half-removed. While stopped there are no patchy lines, so
# there is nothing to remove — and syncing then would wrongly resurrect
# the other sites' entries.
function remove_domain() {
    local domain=$1
    if hosts_active; then
        echo "Updating /etc/hosts..."
        hosts_remove "$domain" || return 1
    fi
    echo "Removing Apache config file..."
    rm -f "$VHOSTS_DIR/$domain.conf"
}

# 'patchy list --json': {"sites": [...]}, one object per site with its folder
# (and whether it exists), aliases, certificate and, once shared on your own
# domain, its stable address.
function list_sites_json() {
    local domain docroot state days address
    list_domains | while IFS= read -r domain; do
        docroot=$(site_docroot "$domain")
        read -r state days <<<"$(site_cert_state "$domain")"
        address=""
        if share_ready && [ -f "$SHARE_DIR/sites/$domain/name" ]; then
            address="https://$(share_host "$domain")"
        fi
        jq -nc --arg domain "$domain" --arg docroot "$docroot" \
            --argjson docroot_exists "$([ -d "$docroot" ] && echo true || echo false)" \
            --argjson aliases "$(list_site_aliases "$domain" | jq -R . | jq -sc .)" \
            --arg state "$state" --arg days "$days" --arg address "$address" '{
                domain: $domain,
                docroot: $docroot,
                docroot_exists: $docroot_exists,
                aliases: $aliases,
                certificate: {state: $state, days_left: ($days | if . == "" then null else tonumber end)},
                share_address: (if $address == "" then null else $address end)
            }'
    done | jq -s '{sites: .}'
}
