# Patchy — Switching PHP versions and installing PECL extensions.
# Sourced by bin/patchy; uses its globals and helpers.

function php_info() {
    echo -e "\033[1mPHP Version Info...\033[0m"
    php -v
}

# Installed Homebrew PHPs as JSON, newest first: [{"version": "8.4",
# "full": "8.4.11", "formula": "php"}, ...].
function php_installed_json() {
    local formulas=($(brew list --formula 2>/dev/null | grep -E '^php(@[0-9.]+)?$'))
    if [ ${#formulas[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi
    brew list --versions "${formulas[@]}" 2>/dev/null | jq -R '
        split(" ") | {formula: .[0], full: (.[-1] | sub("_[0-9]+$"; ""))}
        | .version = (.full | split(".")[0:2] | join("."))' |
        jq -sc 'sort_by(.version | split(".") | map(tonumber? // 0)) | reverse'
}

# Resolve the Homebrew formula for a PHP version: "php" for the latest, "php@X.Y" otherwise
function php_formula_for_version() {
    local version=$1
    local php_formula="php@$version"
    local latest_version
    latest_version=$(brew info php --json=v2 2>/dev/null | jq -r '.formulae[0].versions.stable' | cut -d. -f1,2)
    if [ "$version" = "$latest_version" ]; then
        php_formula="php"
    fi
    echo "$php_formula"
}

# Build the Apache LoadModule line for a PHP version/formula
function php_module_line() {
    local version=$1
    local php_formula=$2
    local major_version="${version%%.*}"
    local module_path="$BREW_PREFIX/opt/$php_formula/lib/httpd/modules"
    if [ "$major_version" -ge 8 ]; then
        echo "LoadModule php_module $module_path/libphp.so"
    else
        echo "LoadModule php7_module $module_path/libphp7.so"
    fi
}

function switch_php_version() {
    if [ -z "${1:-}" ]; then
        fail missing_argument "Please provide a PHP version (e.g., 7.4, 8.1, 8.2, 8.3, 8.4, 8.5)"
        return 1
    fi

    local version=$1
    local php_formula
    php_formula=$(php_formula_for_version "$version")

    if ! brew list --formula 2>/dev/null | grep -E "^${php_formula}\$" >/dev/null; then
        fail php_not_installed "$php_formula is not installed." "Install it with: brew install $php_formula"
        return 1
    fi

    echo "Switching to PHP $version..."
    backup_config

    echo "Unlinking all PHP versions..."
    local formula
    for formula in $(brew list --formula | grep -E '^php(@[0-9.]+)?$'); do
        brew unlink "$formula" >/dev/null 2>&1 || true
    done

    echo "Linking PHP $version..."
    if ! brew link --force --overwrite "$php_formula"; then
        fail php_link_failed "Couldn't link $php_formula."
        return 1
    fi

    echo "Updating Apache configuration..."

    local module_line
    module_line=$(php_module_line "$version" "$php_formula")
    if [ ! -f "${module_line##* }" ]; then
        echo "Warning: PHP module not found at ${module_line##* }"
    fi
    write_patchy_conf "$module_line"
    # Belt-and-suspenders for installs upgraded without re-running setup
    disable_main_conf_listen
    disable_main_conf_php
    ensure_sites_included
    ensure_patchy_included

    restart_server || return 1

    echo ""
    echo "PHP version switched to:"
    php -v | head -1
}

function install_pecl_extensions() {
    echo "Installing PECL extensions for current PHP version..."
    php -v | head -1
    echo ""

    echo "Installing required Homebrew dependencies..."
    brew install libyaml imagemagick libmemcached pkg-config zlib

    local pecl_ext_dir
    pecl_ext_dir=$(php -i | grep "^extension_dir" | head -1 | awk '{print $3}')
    echo "PECL extension directory: $pecl_ext_dir"

    if [ ! -d "$pecl_ext_dir" ]; then
        echo "Creating PECL directory: $pecl_ext_dir"
        mkdir -p "$pecl_ext_dir"
    fi

    local extensions=("redis" "apcu" "imagick" "yaml" "pcov" "memcached")
    local ext
    for ext in "${extensions[@]}"; do
        echo ""
        echo "Installing $ext..."
        case $ext in
            yaml)
                (echo "$(brew --prefix libyaml)"; yes "") | pecl install yaml || true
                ;;
            memcached)
                local zlib_dir
                zlib_dir=$(brew --prefix zlib)
                local libmemcached_dir
                libmemcached_dir=$(brew --prefix libmemcached)
                printf '%s\n' "$libmemcached_dir" "$zlib_dir" "no" "no" "no" "no" "no" "yes" "yes" | pecl install memcached || true
                ;;
            *)
                yes "" | pecl install "$ext" || true
                ;;
        esac
    done

    local ini_file
    ini_file=$(php -n -r "echo php_ini_loaded_file();" 2>/dev/null)
    if [ -z "$ini_file" ]; then
        ini_file="$BREW_PREFIX/etc/php/$(php -n -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/php.ini"
    fi

    echo ""
    echo "Adding extensions to php.ini: $ini_file"

    for ext in "${extensions[@]}"; do
        if ! grep -qE "extension=.?${ext}(\.so)?.?$" "$ini_file"; then
            echo "extension=\"$ext.so\"" >> "$ini_file"
            echo "Added: extension=\"$ext.so\""
        else
            echo "Already configured: $ext"
        fi
    done

    echo ""
    echo "PECL extensions installed and configured."
}
