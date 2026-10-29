# Patchy — 'patchy setup' and the httpd.conf edits it makes.
# Sourced by bin/patchy; uses its globals and helpers.

# Path of the most recent httpd.conf backup (set by backup_config)
LAST_BACKUP=""

# Line number of the first ACTIVE (uncommented) line containing the needle
function active_line_no() {
    local needle=$1 file=$2
    grep -nF -- "$needle" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Ensure httpd.conf wildcard-includes the per-site config directory.
# Strips any legacy per-site Include lines on first run.
function ensure_sites_included() {
    local include_line="IncludeOptional $VHOSTS_DIR/*.conf"
    local has_wildcard=0
    local has_legacy=0

    [ -n "$(active_line_no "$include_line" "$APACHE_CONFIG")" ] && has_wildcard=1
    grep -qF -- "Include $VHOSTS_DIR/" "$APACHE_CONFIG" && has_legacy=1

    if [ "$has_wildcard" -eq 1 ] && [ "$has_legacy" -eq 0 ]; then
        return 0
    fi

    backup_config

    if [ "$has_legacy" -eq 1 ]; then
        local tmp="$APACHE_CONFIG.tmp"
        grep -vF -- "Include $VHOSTS_DIR/" "$APACHE_CONFIG" > "$tmp"
        if [ -s "$tmp" ]; then
            mv "$tmp" "$APACHE_CONFIG"
        else
            rm -f "$tmp"
        fi
    fi

    if [ "$has_wildcard" -eq 0 ]; then
        echo "$include_line" >> "$APACHE_CONFIG"
        echo "Configured Apache to include sites from $VHOSTS_DIR"
    fi
}

# patchy.conf owns Listen — comment out httpd.conf's own Listen lines
# (duplicate Listen directives for the same port are a fatal startup error)
function disable_main_conf_listen() {
    if grep -q '^Listen ' "$APACHE_CONFIG"; then
        sed -i '' 's/^Listen /#Listen /' "$APACHE_CONFIG"
        echo "Commented out Listen lines in httpd.conf (now set in patchy.conf)"
    fi
}

# patchy.conf owns mod_php — comment out httpd.conf's LoadModule php lines,
# including duplicates accumulated by older 'patchy php' runs
function disable_main_conf_php() {
    if grep -q '^LoadModule php' "$APACHE_CONFIG"; then
        sed -i '' 's/^LoadModule php/#LoadModule php/' "$APACHE_CONFIG"
        echo "Commented out LoadModule php lines in httpd.conf (now set in patchy.conf)"
    fi
}

# Ensure httpd.conf includes patchy.conf BEFORE the per-site vhosts: Apache
# parses sequentially, and vhost directives like RewriteEngine error at parse
# time if their module loads later.
function ensure_patchy_included() {
    local include_line="Include $PATCHY_CONF"
    local sites_line="IncludeOptional $VHOSTS_DIR/*.conf"
    local inc_no sites_no
    inc_no=$(active_line_no "$include_line" "$APACHE_CONFIG")
    sites_no=$(active_line_no "$sites_line" "$APACHE_CONFIG")

    if [ -n "$inc_no" ] && { [ -z "$sites_no" ] || [ "$inc_no" -lt "$sites_no" ]; }; then
        return 0
    fi

    local tmp="$APACHE_CONFIG.tmp"
    if [ -n "$sites_no" ]; then
        grep -vF -- "$include_line" "$APACHE_CONFIG" | \
            awk -v inc="$include_line" -v sites="$sites_line" '
                { line = $0; sub(/^[[:space:]]+/, "", line) }
                index(line, sites) == 1 && !done { print inc; done = 1 }
                { print }
            ' > "$tmp"
    else
        grep -vF -- "$include_line" "$APACHE_CONFIG" > "$tmp"
        echo "$include_line" >> "$tmp"
    fi
    if [ -s "$tmp" ] && grep -qF -- "$include_line" "$tmp"; then
        mv "$tmp" "$APACHE_CONFIG"
        echo "Configured httpd.conf to include $PATCHY_CONF"
    else
        rm -f "$tmp"
        echo "Error: failed to update $APACHE_CONFIG; no changes made." >&2
        return 1
    fi
}

function backup_config() {
    # Remove backups older than 30 days
    find "$BREW_PREFIX/etc/httpd" -name "httpd.conf.bkp-*" -mtime +30 -exec rm {} \;
    # Create a fresh backup, remembering the path for restore-on-failure
    LAST_BACKUP="$APACHE_CONFIG.bkp-$(date +%Y%m%d%H%M%S)"
    cp "$APACHE_CONFIG" "$LAST_BACKUP"
}

# Rewrite the patchy-managed Apache include in full.
# <IfModule !…> guards avoid double-loading modules the user's httpd.conf
# already enables. Listen lives here exclusively: duplicate Listen directives
# are a fatal startup error, so httpd.conf's own Listen lines get commented
# out (see disable_main_conf_listen).
function write_patchy_conf() {
    local php_line=$1
    local php_guard="php_module"
    case "$php_line" in
        *php7_module*) php_guard="php7_module" ;;
    esac
    cat > "$PATCHY_CONF" <<EOF
# Managed by Patchy — do not edit.
# Rewritten in full by 'patchy setup' and 'patchy php <version>'.

Listen 80
Listen 443

<IfModule !socache_shmcb_module>
LoadModule socache_shmcb_module lib/httpd/modules/mod_socache_shmcb.so
</IfModule>
<IfModule !ssl_module>
LoadModule ssl_module lib/httpd/modules/mod_ssl.so
</IfModule>
<IfModule !rewrite_module>
LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so
</IfModule>

$php_line

<IfModule dir_module>
    DirectoryIndex index.php index.html
</IfModule>

<IfModule $php_guard>
    <FilesMatch \.php\$>
        SetHandler application/x-httpd-php
    </FilesMatch>
</IfModule>

# Lets sites detect Patchy: \$_SERVER['PATCHY'] in PHP
<IfModule env_module>
    SetEnv PATCHY true
</IfModule>
EOF
    echo "Wrote $PATCHY_CONF"
}

# PHP LoadModule line for setup: keep whatever patchy.conf already has
# (setup must not undo a 'patchy php' switch); otherwise preserve whatever
# mod_php the existing httpd.conf still actively loads (a migration case);
# otherwise derive it from the currently linked PHP; otherwise fall back to
# the default 'php' formula. Both preservation branches skip a stale line
# whose module file no longer exists (e.g. the formula was uninstalled),
# so the next precedence step can self-heal it.
function detect_php_line() {
    local line version
    line=$(grep -m1 '^LoadModule php' "$PATCHY_CONF" 2>/dev/null)
    if [ -n "$line" ] && [ -f "${line##* }" ]; then
        # A php@X.Y that the php formula provides is only an alias, gone at
        # the next upgrade: load it through php instead.
        version=$(sed -n 's|.*/opt/php@\([0-9.]*\)/.*|\1|p' <<<"${line##* }")
        if [ -n "$version" ] && [ "$version" = "$(php_main_version)" ]; then
            php_module_line "$version" php
            return 0
        fi
        echo "$line"
        return 0
    fi
    # Migration case: preserve whatever mod_php the existing httpd.conf still
    # actively loads (detect runs before disable_main_conf_php comments it out)
    line=$(grep -m1 '^LoadModule php' "$APACHE_CONFIG" 2>/dev/null)
    if [ -n "$line" ] && [ -f "${line##* }" ]; then
        echo "$line"
        return 0
    fi
    local version
    version=$(php -n -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
    if [ -n "$version" ]; then
        php_module_line "$version" "$(php_formula_for_version "$version")"
    else
        echo "LoadModule php_module $BREW_PREFIX/opt/php/lib/httpd/modules/libphp.so"
    fi
}

function run_setup() {
    echo "Configuring Patchy..."
    backup_config
    local backup="$LAST_BACKUP"

    set_apache_user
    mkdir -p "$VHOSTS_DIR" "$CERT_DIR" "$LOG_DIR"

    local php_line
    php_line=$(detect_php_line)
    local module_file="${php_line##* }"
    if [ ! -f "$module_file" ]; then
        echo "Warning: PHP module not found at $module_file"
    fi
    write_patchy_conf "$php_line"

    disable_main_conf_listen
    disable_main_conf_php
    ensure_sites_included
    ensure_patchy_included

    if ! apachectl -t; then
        echo "Apache config check failed — restoring httpd.conf from $backup"
        cp "$backup" "$APACHE_CONFIG"
        return 1
    fi

    setup_hosts || return 1
    ensure_cloudflared

    echo "Patchy configured successfully. Backup of httpd.conf: $backup"
    echo "Run '$SCRIPT_NAME restart' to apply any changes."
    echo "Run '$SCRIPT_NAME help' to see available commands."
}

function set_apache_user() {
    local user
    user=$(whoami)
    echo "Setting Apache user to $user..."
    sed -i '' "s/^User .*/User $user/" "$APACHE_CONFIG"
    sed -i '' "s/^Group .*/Group $(id -gn)/" "$APACHE_CONFIG"
}
