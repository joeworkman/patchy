# Patchy

A patchy little PHP dev server for macOS (running Apache).

> Apache was originally a pun on "a patchy server" — it was built from patches on top of NCSA HTTPd.
> Patchy is a patchy little CLI for managing local Apache + mod_php sites on your Mac.

## Why Patchy?

Most local PHP dev environments — Valet, Herd, Lando — happen to default to Nginx. That's a great fit for some stacks; it's the wrong fit for others. If your production runs on Apache, or your app expects `.htaccess` to Just Work — [Total CMS](https://github.com/totalcms/cms), WordPress, Drupal, Symfony with the Apache pack, or any of the countless PHP apps that target Apache — you want a local dev environment that matches.

Patchy is that environment: **Apache 2 + mod_php**, local HTTPS, friendly `.test` hostnames, one command per site.

## What you get

- Per-site Apache vhost generated in a single command
- Local HTTPS via [mkcert](https://github.com/FiloSottile/mkcert) — no browser warnings
- Friendly hostnames via a local [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) resolver — `*.test` resolves only while Patchy runs
- Per-site error and access logs
- `$_SERVER['PATCHY']` set for every request, so apps can detect local dev
- Painless PHP version switching across installed Homebrew PHPs
- One-shot PECL extension setup (`redis`, `apcu`, `imagick`, `yaml`, `pcov`, `memcached`)
- A plain `httpd.conf` you can read and edit — no black box

## Install

```bash
brew install joeworkman/patchy/patchy
```

That's it — the formula pulls in all dependencies (`httpd`, `php`, `mkcert`, `dnsmasq`, `jq`) and configures Apache (ports 80/443, required modules, PHP handler) to run as your user during install.

### From source

```bash
git clone https://github.com/joeworkman/patchy
cd patchy
sudo ln -s "$PWD/bin/patchy" /usr/local/bin/patchy
patchy setup
```

## Quick start

```bash
# Add a site — docroot defaults to ~/Websites/example.test
patchy add example.test

# Add a site — provide path to site docroot
patchy add example.test developer/example.test

# Open https://example.test in your browser

# When you're done
patchy rm example.test
```

## Commands

| Command | Description |
|---|---|
| `patchy add <domain> [dir]` | Add a new site. Docroot defaults to `~/Websites/<domain>`. |
| `patchy rm <domain>...` | Remove one or more sites. |
| `patchy list` | List configured sites. |
| `patchy start` / `stop` | Start/stop Apache and the DNS resolver together. |
| `patchy restart` | Restart Apache (DNS keeps running). |
| `patchy status` | Show whether Apache and DNS are running. |
| `patchy check` | Verify Apache and PHP config. |
| `patchy info` | Show Apache and PHP version info. |
| `patchy version` | Show the Patchy version. |
| `patchy php <version>` | Switch the active PHP version (e.g. `patchy php 8.4`). |
| `patchy pecl` | Install common PECL extensions for the current PHP. |
| `patchy config` | Open `httpd.conf` in your editor. |
| `patchy ini` | Open the active `php.ini` in your editor. |
| `patchy logs` | Tail all Apache logs. |
| `patchy errors [lines\|-f]` | Show the last *N* lines of the Apache error log (default 20), or follow with `-f`. |
| `patchy refresh-certs` | Regenerate all local SSL certificates. |
| `patchy setup` | One-time setup: Apache user, ports 80/443, required modules, PHP handler, vhost include, DNS resolver. Idempotent; auto-run by `brew install`. |
| `patchy help` | Print all of the above. |

### Editor

`config` and `ini` open files in `$VISUAL`, then `$EDITOR`, falling back to `nano` (preinstalled on macOS).

To use a different editor, add this to your shell profile (e.g. `~/.zshrc` or `~/.bashrc`):

```bash
export EDITOR=vim # or nvim, subl, cursor, etc.
# or, to wait for the editor to close before returning:
export VISUAL="code -w"
```

## Where things live

| | |
|---|---|
| Site docroots | `~/Websites/<domain>` (by convention) |
| Vhost configs | `$(brew --prefix)/etc/httpd/sites/<domain>.conf` |
| SSL certificates | `$(brew --prefix)/etc/httpd/certs/` |
| Per-site logs | `$(brew --prefix)/var/log/httpd/<domain>-{access,error}_log` |
| Main Apache config | `$(brew --prefix)/etc/httpd/httpd.conf` |
| Patchy-managed Apache config | `$(brew --prefix)/etc/httpd/patchy.conf` |

## How it compares

|  | **Patchy** | Laravel Valet | Laravel Herd |
|---|---|---|---|
| Web server | **Apache 2 + mod_php** | Nginx + PHP-FPM | Nginx + PHP-FPM |
| `.htaccess` & mod_rewrite | ✅ native | ✗ (needs conversion) | ✗ (needs conversion) |
| Local HTTPS | ✅ mkcert | ✅ | ✅ |
| PHP switching | ✅ | ✅ | ✅ |
| GUI | — | — | ✅ |
| License | MIT | MIT | freemium |

If your stack targets Nginx + FPM, Valet or Herd will probably serve you better. If your stack targets Apache — or you just prefer Apache — Patchy is for you.

## Requirements

- macOS
- [Homebrew](https://brew.sh)
- `sudo` access — used once during `patchy setup` (writes `/etc/resolver/test`, migrates old `/etc/hosts` entries), once per additional TLD, and on `add`/`rm`/`start`/`stop` only if you use `.local` sites
- `zsh` (the default shell on modern macOS)

> **Note:** Apache binds ports 80/443 with a wildcard bind, which needs no root on modern macOS but is reachable from your local network (handy for testing from a phone). The macOS firewall may ask once to allow `httpd`.

> **Upgrading from hostess-based Patchy (≤ v0.3.0)?** Run `patchy setup` once after upgrading. It configures dnsmasq, writes `/etc/resolver/<tld>` files for your existing sites, and removes the old `/etc/hosts` entries (one sudo prompt). Until you do, sites keep working the old way but DNS won't stop with `patchy stop`.

### How DNS works

Patchy runs [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) as a user-level Homebrew service on port 53535, answering `*.test` (and any other TLD you add) with `127.0.0.1`. macOS routes those TLDs to it via `/etc/resolver/<tld>` files. Because resolution comes from a running service instead of `/etc/hosts`, your `.test` domains stop resolving the moment you run `patchy stop` — and nothing needs sudo day-to-day. Adding a site under a brand-new TLD prompts once: a resolver file captures the *entire* TLD, so stick to made-up TLDs like `.test`.

**`.local` sites are special.** macOS reserves `.local` for Bonjour/mDNS (printers, AirDrop, other Macs), so Patchy never routes it through dnsmasq. Instead, `.local` sites get exact entries in `/etc/hosts` tagged `# patchy` — added on `patchy start`, removed on `patchy stop`, so stop/start behavior matches every other site. The tradeoff: `.local` sites need a sudo password on `add`/`rm`/`start`/`stop`. Patchy tells you when a prompt is due to `.local` sites; moving them to `.test` removes the prompts entirely.

## Uninstall

```bash
# (Optional) remove sites first — cleans up certs
patchy list                              # see what's configured
patchy rm <domain> [<domain>...]         # remove one or more sites

# Stop services
patchy stop

# Remove the macOS resolver files patchy created (one per TLD)
sudo rm /etc/resolver/test               # plus any other TLDs you added

# Remove patchy-managed .local entries (only if you used .local sites)
sudo sed -i '' '/# patchy$/d' /etc/hosts

# Uninstall Patchy
brew uninstall joeworkman/patchy/patchy

# (Optional) remove Homebrew dependencies nothing else is using
brew autoremove

# (Optional) untap the formula
brew untap joeworkman/patchy
```

If you installed from source: `sudo rm /usr/local/bin/patchy`.

## Contributing

Issues and pull requests welcome. This is a tool I use every day for real work — improvements that make it more useful or more reliable are gladly accepted. Please run `zsh -n bin/patchy` and `shellcheck bin/patchy` before opening a PR.

## License

MIT — see [LICENSE](LICENSE).
