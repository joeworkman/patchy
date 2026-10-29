# Patchy — 'patchy share': a site at a public link through cloudflared.
# Sourced by bin/patchy; uses its globals and helpers.

# Patchy's Cloudflare login, domain and per-site tunnels. These are
# credentials, so they live in the user's config, not Homebrew's prefix.
SHARE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/patchy/share"

# Apache's side of each stable address: a file the site's own :443 vhost
# includes, and the password file of a share run with --auth
SHARE_CONF_DIR="$BREW_PREFIX/etc/httpd/share"

# The username --auth uses when none is given
SHARE_USER="preview"

# Run by 'patchy setup'. The formula depends on cloudflared, so this only
# installs for source installs; sharing is optional, so a failure is a warning.
function ensure_cloudflared() {
    command -v cloudflared >/dev/null 2>&1 && return 0
    echo "Installing cloudflared (used by '$SCRIPT_NAME share')..."
    brew install cloudflared && return 0
    echo "Warning: couldn't install cloudflared. '$SCRIPT_NAME share' needs it: brew install cloudflared"
    return 0
}

# Print a message that ends a share, with any detail lines (a log's last
# lines, say), remembering both for --json's error event.
function share_error() {
    SHARE_ERROR=${1%:}
    SHARE_ERROR_DETAILS=${2:-}
    echo "$1"
    [ -n "${2:-}" ] && echo "$2"
    return 0
}

# With --json, write one event as a JSON line (jq -n arguments) to fd 3, the
# real stdout; see share_run.
function share_event() {
    [ "${PATCHY_JSON:-0}" -eq 1 ] || return 0
    jq -nc "$@" >&3
}

# 'patchy share <site>'. With --json, the output is only JSON events, one per
# line: ready (with the URL and any password) once the link works, then
# stopped, or error with a message and any details. The usual messages are
# dropped, so a caller reading stdout and stderr together still gets clean JSON.
function share_run() {
    if [ "${PATCHY_JSON:-0}" -ne 1 ]; then
        share_site "$@"
        return
    fi
    local result
    SHARE_ERROR="" SHARE_ERROR_DETAILS=""
    { share_site "$@" } 3>&1 >/dev/null 2>&1
    result=$?
    if [ "$result" -eq 0 ]; then
        share_event --arg site "${1:-}" '{event: "stopped", site: $site}' 3>&1
    else
        share_event --arg site "${1:-}" --arg message "${SHARE_ERROR:-patchy share failed}" \
            --arg details "$SHARE_ERROR_DETAILS" \
            '{event: "error", site: $site, message: $message,
              details: (if $details == "" then null else $details end)}' 3>&1
    fi
    return $result
}

# The quick tunnel's public link, as cloudflared logs it. Its log also
# mentions the API host, which is not the link.
function share_url_in() {
    grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$1" | grep -v '^https://api\.' | head -n 1
}

# Starts a share's cloudflared in the background and waits until interrupted.
# A stable share knows its address up front and is ready once cloudflared
# registers a connection; a quick tunnel's address is read from its log.
# Returns 0 when stopped by a signal, 1 if the tunnel quit after it was ready,
# 2 if it quit (or was given up on) before; SHARE_LOG then holds its log.
function run_share_tunnel() {
    local domain=$1 address=$2 notice=$3
    shift 3
    SHARE_LOG=""
    local log
    log=$(mktemp -t patchy-share) || return 2

    echo "Requesting a public link for $domain..."

    # A GUI may signal only this process, so cloudflared is stopped explicitly.
    # The trap is set before launch so an early signal can't orphan it.
    # localtraps puts the caller's trap back on return.
    setopt localoptions localtraps
    local pid="" stopping=0
    trap 'stopping=1; [ -n "$pid" ] && kill -TERM $pid 2>/dev/null' INT TERM HUP

    "$@" >"$log" 2>&1 &
    pid=$!
    [ "$stopping" -eq 1 ] && kill -TERM "$pid" 2>/dev/null

    local url=""
    while [ -z "$url" ] && [ "$stopping" -eq 0 ] && kill -0 "$pid" 2>/dev/null; do
        if [ -n "$address" ]; then
            if grep -q 'Registered tunnel connection' "$log"; then
                url=$address
            elif grep -q 'Tunnel not found' "$log"; then
                # A deleted tunnel never exits on its own; cloudflared just retries.
                kill -TERM "$pid" 2>/dev/null
                break
            fi
        else
            url=$(share_url_in "$log")
        fi
        [ -z "$url" ] && sleep 0.2
    done

    if [ -n "$url" ] && [ "$stopping" -eq 0 ]; then
        # Only for a person at a terminal: a script or app running patchy
        # shouldn't have its user's clipboard replaced.
        local copied=""
        if [ "${PATCHY_JSON:-0}" -ne 1 ] && [ -t 1 ] && printf '%s' "$url" | pbcopy 2>/dev/null; then
            copied=" (copied to the clipboard)"
        fi
        echo "Sharing $domain at $url$copied"
        echo "$notice"
        share_event --arg site "$domain" --arg url "$url" --arg mode "$SHARE_MODE" \
            --arg username "$SHARE_AUTH_USER" --arg password "$SHARE_AUTH_PASSWORD" '{
                event: "ready", site: $site, url: $url, mode: $mode,
                auth: (if $password == "" then null else {username: $username, password: $password} end)
            }'
    fi

    # A trapped signal ends wait early, so keep waiting until cloudflared is gone.
    while kill -0 "$pid" 2>/dev/null; do
        wait "$pid" 2>/dev/null
    done

    local result=0
    if [ "$stopping" -eq 1 ]; then
        echo "Stopped sharing $domain."
    elif [ -z "$url" ]; then
        result=2
    else
        share_error "The link stopped working because cloudflared quit:" \
            "$(tail -n 10 "$log")"
        result=1
    fi
    SHARE_LOG=$(<"$log")
    rm -f "$log"
    return $result
}

# Serve one site at an anonymous trycloudflare.com link. cloudflared sends the
# site's name so Apache picks its vhost, and checks the site's mkcert cert
# against mkcert's root CA.
function share_quick() {
    local domain=$1
    run_share_tunnel "$domain" "" "Anyone with this link can see the site. Press Ctrl-C to stop sharing." \
        cloudflared tunnel --no-autoupdate \
            --url https://localhost:443 \
            --http-host-header "$domain" \
            --origin-server-name "$domain" \
            --origin-ca-pool "$(mkcert -CAROOT)/rootCA.pem"
    local result=$?
    if [ "$result" -eq 2 ]; then
        share_error "cloudflared stopped before the link was ready:" \
            "$(tail -n 10 <<<"$SHARE_LOG")"
        return 1
    fi
    return $result
}

# The checks every share needs, then a share on your own domain or an
# anonymous one.
function share_site() {
    local domain=$1
    shift
    local temp=0 anonymous=0 name="" auth=0 user=$SHARE_USER password=""
    while [ $# -gt 0 ]; do
        case $1 in
            --temp) temp=1 ;;
            --anonymous) anonymous=1 ;;
            --name)
                name=${2:-}
                if [ -z "$name" ]; then
                    share_error "Please provide a name after --name."
                    return 1
                fi
                shift
                ;;
            --auth)
                auth=1
                # Optional user:pass; the password may itself contain colons.
                if [ -n "${2:-}" ] && [[ $2 != -* ]]; then
                    if [[ $2 != ?*:?* ]]; then
                        share_error "Use --auth user:password, or --auth alone for a generated password."
                        return 1
                    fi
                    user=${2%%:*}
                    password=${2#*:}
                    shift
                fi
                ;;
            *)
                share_error "Unknown option: $1"
                return 1
                ;;
        esac
        shift
    done
    if [ "$temp" -eq 1 ] && [ -n "$name" ]; then
        share_error "--temp makes up its own name, so it can't be combined with --name."
        return 1
    fi
    if [ "$anonymous" -eq 1 ] && { [ -n "$name" ] || [ "$auth" -eq 1 ]; }; then
        share_error "--anonymous links can't have a --name or --auth."
        return 1
    fi

    if ! site_exists "$domain"; then
        share_error "Site does not exist... $domain"
        return 1
    fi
    if ! is_apache_running; then
        share_error "Apache isn't running. Start it with: $SCRIPT_NAME start"
        return 1
    fi
    if ! command -v cloudflared >/dev/null 2>&1; then
        share_error "cloudflared is required: brew install cloudflared"
        return 1
    fi

    # Without a domain of your own, every share is an anonymous one.
    if [ "$anonymous" -eq 1 ] || ! share_ready; then
        if [ -n "$name" ] || [ "$auth" -eq 1 ]; then
            share_error "--name and --auth need your own domain: $SCRIPT_NAME share setup <domain>"
            return 1
        fi
        SHARE_MODE=anonymous SHARE_AUTH_USER="" SHARE_AUTH_PASSWORD=""
        share_quick "$domain"
        return
    fi

    local dir="$SHARE_DIR/sites/$domain" host
    if [ -f "$dir/pid" ] && kill -0 "$(<"$dir/pid")" 2>/dev/null; then
        share_error "$domain is already being shared. Stop that share first."
        return 1
    fi
    share_prepare "$domain" "$name" "$temp" || return 1
    if [ "$temp" -eq 1 ]; then
        host="$(share_random_name).$(share_domain)"
    else
        host=$(share_host "$domain")
    fi
    # Open unless this share asks for a password. Nothing is kept: a generated
    # password is new every share, and the password file goes when it stops.
    if [ "$auth" -eq 1 ]; then
        [ -z "$password" ] && password=$(make_share_password)
        write_share_htpasswd "$domain" "$user" "$password" || return 1
    else
        user="" password=""
        rm -f "$SHARE_CONF_DIR/$domain.htpasswd"
    fi
    write_tunnel_config "$domain" "$host"
    apply_share_conf "$domain" "$host" || return 1
    SHARE_MODE=stable SHARE_AUTH_USER=$user SHARE_AUTH_PASSWORD=$password
    [ "$temp" -eq 1 ] && SHARE_MODE=temp
    share_stable "$domain" "$host" "$user" "$password"
}

function share_domain() {
    cat "$SHARE_DIR/domain" 2>/dev/null
}

# True once 'patchy share setup' has connected a domain.
function share_ready() {
    [ -s "$SHARE_DIR/cert.pem" ] && [ -s "$SHARE_DIR/domain" ]
}

# cloudflared's tunnel commands, using Patchy's login rather than ~/.cloudflared.
function cf_tunnel() {
    cloudflared tunnel --origincert "$SHARE_DIR/cert.pem" "$@"
}

# A field of the token inside a Cloudflare login cert: the zone's ID and an API
# token, the same one cloudflared uses to create DNS records.
function cert_token_field() {
    sed -n '/BEGIN ARGO TUNNEL TOKEN/,/END ARGO TUNNEL TOKEN/{/-----/d;p;}' "$1" \
        | tr -d '\n' | base64 --decode 2>/dev/null | jq -r ".$2 // empty" 2>/dev/null
}

# Cloudflare's API for the login cert's zone: cf_api <cert> <method> <path>
function cf_api() {
    local cert=$1 method=$2 endpoint=$3 zone_id api_token
    zone_id=$(cert_token_field "$cert" zoneID)
    api_token=$(cert_token_field "$cert" apiToken)
    [ -n "$zone_id" ] && [ -n "$api_token" ] || return 1
    curl -fsS -X "$method" -H "Authorization: Bearer $api_token" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id$endpoint" 2>/dev/null
}

# The domain a Cloudflare login approved.
function cert_zone_name() {
    cf_api "$1" GET "" | jq -r '.result.name // empty'
}

# Connect a Cloudflare domain for stable share addresses. cloudflared's login
# always writes ~/.cloudflared/cert.pem, so any existing one is set aside and
# always put back, and the new one moves to Patchy's folder. The login runs in
# the background so a signal to this process alone (a GUI's Cancel) ends it.
function share_setup() {
    local domain=${1:-}
    if [ -z "$domain" ]; then
        echo "Please provide your domain, e.g. $SCRIPT_NAME share setup example.com"
        return 1
    fi
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "cloudflared is required: brew install cloudflared"
        return 1
    fi

    local cf_dir="$HOME/.cloudflared" saved="" login_pid="" interrupted=0
    trap 'interrupted=1; [ -n "$login_pid" ] && kill -TERM $login_pid 2>/dev/null' INT TERM HUP
    mkdir -p "$cf_dir"
    if [ -f "$cf_dir/cert.pem" ]; then
        if ! saved=$(mktemp -t patchy-cert 2>/dev/null) || ! mv "$cf_dir/cert.pem" "$saved"; then
            [ -n "$saved" ] && rm -f "$saved"
            trap - INT TERM HUP
            echo "Couldn't set your existing ~/.cloudflared/cert.pem aside, so nothing was changed."
            return 1
        fi
    fi

    local approved="" result=1
    if [ "$interrupted" -eq 0 ]; then
        echo "Opening Cloudflare in your browser. Choose $domain and click Authorize..."
        cloudflared tunnel login &
        login_pid=$!
        while kill -0 "$login_pid" 2>/dev/null; do
            wait "$login_pid" 2>/dev/null
        done
    fi
    if [ "$interrupted" -eq 0 ] && [ -f "$cf_dir/cert.pem" ]; then
        approved=$(cert_zone_name "$cf_dir/cert.pem")
    fi

    if [ "$interrupted" -eq 1 ] || [ ! -f "$cf_dir/cert.pem" ]; then
        echo "No domain was connected. $SCRIPT_NAME share will keep giving temporary links."
    elif [ "$approved" != "$domain" ]; then
        if [ -n "$approved" ]; then
            echo "You approved $approved in the browser, not $domain. Run '$SCRIPT_NAME share setup $domain' again and choose $domain."
        else
            echo "Couldn't check which domain Cloudflare approved, so nothing was changed."
        fi
    else
        if share_ready && [ "$(share_domain)" != "$domain" ]; then
            echo "Switching from $(share_domain) to $domain..."
            share_forget_all
        fi
        mkdir -p "$SHARE_DIR" && chmod 700 "$SHARE_DIR"
        mv "$cf_dir/cert.pem" "$SHARE_DIR/cert.pem" && chmod 600 "$SHARE_DIR/cert.pem"
        echo "$domain" > "$SHARE_DIR/domain"
        echo "Connected. $SCRIPT_NAME share will now give each site an address on $domain."
        result=0
    fi
    rm -f "$cf_dir/cert.pem"
    [ -n "$saved" ] && mv "$saved" "$cf_dir/cert.pem"
    trap - INT TERM HUP
    return $result
}

# Forget every site's stable address.
function share_forget_all() {
    local dir
    for dir in "$SHARE_DIR"/sites/*(N/); do
        share_forget_site "${dir:t}"
    done
}

function share_reset() {
    if ! share_ready; then
        echo "No sharing domain is set up. $SCRIPT_NAME share gives temporary links."
        return 0
    fi
    local domain
    domain=$(share_domain)
    share_forget_all
    rm -rf "$SHARE_DIR" "$SHARE_CONF_DIR"
    is_apache_running && apachectl -k graceful >/dev/null 2>&1
    echo "Disconnected $domain. $SCRIPT_NAME share will give temporary links again."
}

# Remove a site's tunnel from Cloudflare, with any DNS record a share
# couldn't clean up, and its sharing files from this Mac.
function share_forget_site() {
    local domain=$1 dir="$SHARE_DIR/sites/$1"
    [ -f "$dir/tunnel" ] || return 0
    share_sweep "$domain"
    if ! cf_tunnel delete -f "$(<"$dir/tunnel")" >/dev/null 2>&1; then
        echo "Couldn't delete the tunnel $(<"$dir/tunnel") on Cloudflare. Delete it in the Cloudflare dashboard (Networks › Tunnels)."
    fi
    rm -rf "$dir"
    rm -f "$SHARE_CONF_DIR/$domain.conf" "$SHARE_CONF_DIR/$domain.htpasswd"
    echo "Removed $domain's sharing setup from Cloudflare."
}

# harbor.test → harbor, shop.northwind.test → shop-northwind
function share_default_name() {
    local base=${1%.*}
    echo "${base//./-}"
}

# One DNS label: Cloudflare's free certificates cover one level under the domain.
function valid_share_name() {
    local label='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
    [[ $1 =~ $label ]]
}

# 12 characters in groups of 4, without look-alikes (0/O, 1/l/I), to read out to a client.
function make_share_password() {
    local chars="abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789" pw="" i n
    for i in {1..12}; do
        n=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        pw+=${chars[$(( n % ${#chars} + 1 ))]}
        (( i % 4 == 0 && i < 12 )) && pw+="-"
    done
    echo "$pw"
}

# Apache's password file for one share. The password goes to htpasswd on
# stdin, so it never shows in the process list.
function write_share_htpasswd() {
    mkdir -p "$SHARE_CONF_DIR"
    if ! htpasswd -iBc "$SHARE_CONF_DIR/$1.htpasswd" "$2" <<<"$3" >/dev/null 2>&1; then
        share_error "Couldn't set the password for $1."
        return 1
    fi
    chmod 600 "$SHARE_CONF_DIR/$1.htpasswd"
}

function share_host() {
    echo "$(<"$SHARE_DIR/sites/$1/name").$(share_domain)"
}

function share_tunnel_id() {
    jq -r '.TunnelID // empty' "$SHARE_DIR/sites/$1/tunnel.json" 2>/dev/null
}

# A temporary share's name: 8 random letters and digits.
function share_random_name() {
    LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8
}

# Create this share's DNS record. A name already in use belongs to someone
# else (Patchy's own records are swept before a share), so it is never replaced.
function share_route() {
    local domain=$1 host=$2 log
    log=$(mktemp -t patchy-share-route) || return 1
    if cf_tunnel route dns "$(<"$SHARE_DIR/sites/$domain/tunnel")" "$host" >"$log" 2>&1; then
        rm -f "$log"
        return 0
    fi
    if grep -qi 'already exists' "$log"; then
        share_error "$host is already used on $(share_domain). Choose another name with --name."
    else
        share_error "Couldn't create $host on Cloudflare:" \
            "$(tail -n 5 "$log")"
    fi
    rm -f "$log"
    return 1
}

# Delete every DNS record pointing at the site's tunnel. Records only exist
# while a share runs, so one found any other time was left by a share that
# was killed outright. A record pointing anywhere else is never touched.
function share_sweep() {
    local domain=$1 tunnel_id records record_id name
    tunnel_id=$(share_tunnel_id "$domain")
    [ -n "$tunnel_id" ] || return 0
    if ! records=$(cf_api "$SHARE_DIR/cert.pem" GET "/dns_records?type=CNAME&content=$tunnel_id.cfargotunnel.com&per_page=100"); then
        echo "Couldn't reach Cloudflare to remove $domain's DNS records. Delete any left in the Cloudflare dashboard (DNS)."
        return 1
    fi
    jq -r '.result[]? | "\(.id) \(.name)"' <<<"$records" | while read -r record_id name; do
        cf_api "$SHARE_DIR/cert.pem" DELETE "/dns_records/$record_id" >/dev/null \
            || echo "Couldn't remove $name on Cloudflare. Delete its DNS record in the Cloudflare dashboard (DNS)."
    done
}

function write_tunnel_config() {
    local domain=$1 host=$2 dir="$SHARE_DIR/sites/$1"
    cat > "$dir/tunnel.yml" <<EOF
# Managed by Patchy.
tunnel: $(jq -r '.TunnelID' "$dir/tunnel.json")
credentials-file: "$dir/tunnel.json"
ingress:
  - hostname: $host
    service: https://localhost:443
    originRequest:
      originServerName: $domain
      caPool: "$(mkcert -CAROOT)/rootCA.pem"
  - service: http_status:404
EOF
}

# The line in a site's own :443 vhost that pulls in its stable address.
# Optional, so it stays harmless once the address is forgotten.
function share_include_line() {
    echo "IncludeOptional \"$SHARE_CONF_DIR/$1.conf\""
}

# Adds the include line to the site's vhost, once, before its :443 block closes.
function ensure_share_hook() {
    local domain=$1 conf="$VHOSTS_DIR/$1.conf" line
    line=$(share_include_line "$domain")
    [ -n "$(active_line_no "$line" "$conf")" ] && return 0
    if ! awk -v line="    $line" '
        /^[[:space:]]*<VirtualHost[[:space:]].*:443>/ { in443 = 1 }
        in443 && /^[[:space:]]*<\/VirtualHost>/ { print line; in443 = 0; done = 1 }
        { print }
        END { exit !done }
    ' "$conf" > "$conf.tmp"; then
        rm -f "$conf.tmp"
        share_error "$conf has no <VirtualHost *:443> block, so $domain can't get a stable address."
        return 1
    fi
    mv "$conf.tmp" "$conf"
}

# A share's address is an alias of the site's own vhost, so the public site is
# the local site. cloudflared passes the visitor's Host through, so only
# visitors at that address are asked for the password; the local domain never is.
function write_share_conf() {
    local domain=$1 host=$2 auth=""
    if [ -f "$SHARE_CONF_DIR/$domain.htpasswd" ]; then
        auth="
<If \"tolower(%{HTTP_HOST}) == '$host'\">
    AuthType Basic
    AuthName \"Preview\"
    AuthUserFile \"$SHARE_CONF_DIR/$domain.htpasswd\"
    Require valid-user
</If>"
    fi
    mkdir -p "$SHARE_CONF_DIR"
    cat > "$SHARE_CONF_DIR/$domain.conf" <<EOF
# Managed by Patchy — $domain's share address.
ServerAlias $host$auth
EOF
}

# Hooks the site's vhost and writes its share include. If either changed,
# checks Apache's config and reloads without dropping connections. If Apache
# rejects it, the include is removed and nothing is reloaded.
function apply_share_conf() {
    local domain=$1 host=$2 file="$SHARE_CONF_DIR/$1.conf" site="$VHOSTS_DIR/$1.conf" before="" site_before
    [ -f "$file" ] && before=$(<"$file")
    site_before=$(<"$site")
    ensure_share_hook "$domain" || return 1
    write_share_conf "$domain" "$host"
    if [ "$(<"$file")" = "$before" ] && [ "$(<"$site")" = "$site_before" ]; then
        return 0
    fi
    if ! apachectl -t >/dev/null 2>&1; then
        share_error "Apache rejected the sharing setup for $domain, so it was removed:" \
            "$(apachectl -t 2>&1 | tail -n 5)"
        rm -f "$file"
        return 1
    fi
    is_apache_running && apachectl -k graceful >/dev/null 2>&1
    return 0
}

# A tunnel name that is this Mac's own: two Macs on one Cloudflare account
# can each share a site with the same local name.
function share_tunnel_name() {
    local mac
    mac=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')
    echo "patchy-$mac-${1//./-}"
}

# Create the site's tunnel. Its name is this Mac's and this site's alone, so
# one left over (by a first share cut short, say) is replaced.
function share_create_tunnel() {
    local domain=$1 dir="$SHARE_DIR/sites/$1" tunnel log
    tunnel=$(share_tunnel_name "$domain")
    log=$(mktemp -t patchy-share-tunnel) || return 1
    rm -f "$dir/tunnel.json"
    if ! cf_tunnel create --credentials-file "$dir/tunnel.json" "$tunnel" >"$log" 2>&1; then
        if ! grep -qi 'already exists' "$log" \
            || ! cf_tunnel delete -f "$tunnel" >/dev/null 2>&1 \
            || ! cf_tunnel create --credentials-file "$dir/tunnel.json" "$tunnel" >"$log" 2>&1; then
            share_error "Couldn't create a tunnel on Cloudflare:" \
                "$(tail -n 5 "$log")"
            rm -f "$log" "$dir/tunnel.json"
            return 1
        fi
    fi
    rm -f "$log"
    chmod 600 "$dir/tunnel.json"
    echo "$tunnel" > "$dir/tunnel"
}

# Make sure a site has a tunnel, a vhost that can take its alias and, unless
# this is a temporary share, a name. The tunnel is created on the first share
# and kept until rm or share reset; it is invisible and free. DNS records only
# exist while a share runs.
function share_prepare() {
    local domain=$1 want=$2 temp=$3 dir="$SHARE_DIR/sites/$1" name
    name=$want
    [ -z "$name" ] && [ -f "$dir/name" ] && name=$(<"$dir/name")
    [ -z "$name" ] && name=$(share_default_name "$domain")
    if ! valid_share_name "$name"; then
        share_error "\"$name\" can't be used in a web address. Use lowercase letters, numbers and hyphens."
        return 1
    fi

    if [ ! -f "$dir/tunnel.json" ]; then
        # Check everything local before creating anything on Cloudflare.
        if [ ! -f "$CERT_DIR/$domain.pem" ] || [ ! -f "$CERT_DIR/$domain-key.pem" ]; then
            share_error "$domain has no certificate yet. Run '$SCRIPT_NAME refresh-certs' first."
            return 1
        fi
        ensure_share_hook "$domain" || return 1
        if ! apachectl -t >/dev/null 2>&1; then
            share_error "Apache's configuration check failed, so nothing was set up for $domain:" \
                "$(apachectl -t 2>&1 | tail -n 5)"
            return 1
        fi
        echo "Setting up sharing for $domain (first share only)..."
        mkdir -p "$dir" && chmod 700 "$SHARE_DIR" "$dir"
        share_create_tunnel "$domain" || return 1
    else
        share_check_tunnel "$domain" || return 1
    fi
    [ "$temp" -eq 1 ] || echo "$name" > "$dir/name"
}

# Recreate the site's tunnel if it was deleted in the Cloudflare dashboard,
# along with any DNS record still pointing at it. If Cloudflare can't be
# asked, the share goes ahead and cloudflared reports the problem.
function share_check_tunnel() {
    local domain=$1 list
    list=$(cf_tunnel list --id "$(share_tunnel_id "$domain")" -o json 2>/dev/null) || return 0
    jq -e 'length > 0' <<<"$list" >/dev/null 2>&1 && return 0
    echo "The tunnel for $domain was deleted on Cloudflare. Creating it again..."
    share_sweep "$domain"
    share_create_tunnel "$domain"
}

# Share a site at host on your own domain until interrupted. Its DNS record is
# created for this share and deleted when it stops, however it stops. A share
# killed outright leaves the record, which the next share or rm sweeps away.
function share_stable() {
    local domain=$1 host=$2 user=$3 password=$4 dir="$SHARE_DIR/sites/$1" notice result=1 stopping=0
    if [ -n "$password" ]; then
        notice="Username: $user   Password: $password"$'\n'"Anyone with the address and password can see the site. Press Ctrl-C to stop sharing."
    else
        notice="Anyone with the address can see the site (add --auth to require a password).\nPress Ctrl-C to stop sharing..."
    fi

    echo $$ > "$dir/pid"
    trap 'stopping=1' INT TERM HUP
    share_sweep "$domain"
    if ! share_route "$domain" "$host"; then
        :
    elif [ "$stopping" -eq 1 ]; then
        echo "Stopped sharing $domain."
        result=0
    else
        run_share_tunnel "$domain" "https://$host" "$notice" \
            cloudflared tunnel --no-autoupdate --origincert "$SHARE_DIR/cert.pem" --config "$dir/tunnel.yml" run
        result=$?
        if [ "$result" -eq 2 ]; then
            result=1
            if grep -q 'Tunnel not found' <<<"$SHARE_LOG"; then
                share_error "The tunnel for $domain was deleted on Cloudflare. Share again to recreate it."
            elif grep -qiE 'origin cert|unauthori[sz]ed|authentication' <<<"$SHARE_LOG"; then
                share_error "Your Cloudflare login has expired. Run '$SCRIPT_NAME share setup $(share_domain)' again."
            else
                share_error "cloudflared stopped before the link was ready:" \
                    "$(tail -n 10 <<<"$SHARE_LOG")"
            fi
        fi
    fi

    # A second Ctrl-C must not cut the cleanup short.
    trap '' INT TERM HUP
    share_sweep "$domain"
    rm -f "$SHARE_CONF_DIR/$domain.htpasswd" "$dir/pid"
    trap - INT TERM HUP
    return $result
}
