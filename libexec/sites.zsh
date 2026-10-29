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
function confirm_real_domain() {
    local domain=$1 www=${2:-}
    case "${domain##*.}" in
        test|local) return 0 ;;
    esac
    local names="$domain"
    [ -n "$www" ] && names="$domain (and $www)"
    echo "Routing $names to this Mac. If $domain is a real website, it will be"
    echo "unreachable here until you run '$SCRIPT_NAME rm $domain' or '$SCRIPT_NAME stop'."
    printf "Continue? [y/N] "
    local reply
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; return 1 ;;
    esac
}

function add_site() {
    local domain=$1
    local docroot=${2:-}
    [ -z "$docroot" ] && docroot="$DEFAULT_WEBROOT/$domain"

    if site_exists "$domain"; then
        echo "Site already exists... $domain"
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
        remove_domain "$domain"
        remove_cert "$domain"
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

function remove_root_certs() {
    mkcert -uninstall
    local rootdir
    rootdir=$(mkcert -CAROOT)
    rm -f "$rootdir/rootCA.pem" "$rootdir/rootCA-key.pem"
}

function remove_cert() {
    local domain=$1
    cd "$CERT_DIR" 2>/dev/null || return 0
    rm -f "$domain.pem" "$domain-key.pem"
}

function refresh_certs() {
    cd "$CERT_DIR" || return 1
    remove_root_certs
    make_cert localhost
    local site
    for site in $(list_domains); do
        [ "$site" = "localhost" ] && continue
        rm -f "$site.pem" "$site-key.pem"
        make_cert "$site" $(list_site_aliases "$site")
    done
    # Apache keeps serving the old certs from memory until it reloads them
    if is_apache_running; then
        restart_server
    fi
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
    local domain docroot https state days needs_attention=0
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
        printf "%-${dwidth}s ${color}%-8s${reset} %s\n" "$domain" "$https" "$docroot"
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
}

function site_exists() {
    local domain=$1
    [ -f "$VHOSTS_DIR/$domain.conf" ]
}

function remove_site() {
    local domain=$1

    if ! site_exists "$domain"; then
        echo "Site does not exist... $domain"
        return 1
    fi

    remove_domain "$domain" || return 1
    remove_cert "$domain"
    share_forget_site "$domain"
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

# 'patchy list --json': {"sites": [...]}, one object per site with its folder,
# aliases, certificate and, once shared on your own domain, its stable address.
function list_sites_json() {
    local domain state days address
    list_domains | while IFS= read -r domain; do
        read -r state days <<<"$(site_cert_state "$domain")"
        address=""
        if share_ready && [ -f "$SHARE_DIR/sites/$domain/name" ]; then
            address="https://$(share_host "$domain")"
        fi
        jq -nc --arg domain "$domain" --arg docroot "$(site_docroot "$domain")" \
            --argjson aliases "$(list_site_aliases "$domain" | jq -R . | jq -sc .)" \
            --arg state "$state" --arg days "$days" --arg address "$address" '{
                domain: $domain,
                docroot: $docroot,
                aliases: $aliases,
                certificate: {state: $state, days_left: ($days | if . == "" then null else tonumber end)},
                share_address: (if $address == "" then null else $address end)
            }'
    done | jq -s '{sites: .}'
}
