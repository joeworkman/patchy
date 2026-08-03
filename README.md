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
- Friendly hostnames via `/etc/hosts` — every configured site resolves the instant Patchy adds it, and stops resolving the instant `patchy stop` runs
- Per-site error and access logs
- `$_SERVER['PATCHY']` set for every request, so apps can detect local dev
- Painless PHP version switching across installed Homebrew PHPs
- One-shot PECL extension setup (`redis`, `apcu`, `imagick`, `yaml`, `pcov`, `memcached`)
- A plain `httpd.conf` you can read and edit — no black box

## Install

```bash
brew install joeworkman/patchy/patchy
```

That's it — the formula pulls in all dependencies (`httpd`, `php`, `mkcert`, `jq`) and configures Apache (ports 80/443, required modules, PHP handler) to run as your user during install.

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

## Using a real domain locally

Adding a site under a real TLD (say `patchy add mywebsite.com`) routes **just
that exact domain** to your Mac via a `127.0.0.1 mywebsite.com # patchy` line
in `/etc/hosts` — subdomains and the rest of `.com` stay on public DNS. Patchy
asks for confirmation because the live site becomes unreachable on this Mac
while the route exists. Both adding and removing a real-TLD site edit
`/etc/hosts`, which needs a sudo password — run `patchy trust` once to stop
those prompts (see "Trust: passwordless `/etc/hosts` updates" below).

To get back to the live site, remove the site:

```bash
patchy rm mywebsite.com   # removes the vhost, certs, and the /etc/hosts entry
```

`/etc/hosts` changes take effect the instant they're written — no DNS cache
to flush, no wait. Browsers keep their own DNS caches and connection pools,
though, so a hard reload (or browser restart) can still help right after
switching a domain between local and live.

## Commands

| Command | Description |
|---|---|
| `patchy add <domain> [dir]` | Add a new site. Docroot defaults to `~/Websites/<domain>`. |
| `patchy rm <domain>...` | Remove one or more sites. |
| `patchy list` | List configured sites. |
| `patchy start` / `stop` | Start/stop Apache. `start` routes every configured site to this Mac via `/etc/hosts`; `stop` releases those entries, so real domains resolve normally again immediately. |
| `patchy restart` | Restart Apache and repair `/etc/hosts` routing if any entries went missing. |
| `patchy status` | Show whether Apache is running, how many sites `/etc/hosts` is routing, and whether `trust` is enabled. |
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
| `patchy setup` | One-time setup: Apache user, ports 80/443, required modules, PHP handler, vhost include, `/etc/hosts` routing. Idempotent; auto-run by `brew install`. Re-run it after upgrading from a dnsmasq-based install to migrate away from dnsmasq. |
| `patchy trust` | Install a root-owned helper so `/etc/hosts` updates on `start`/`stop`/`add`/`rm` stop prompting for a password. |
| `patchy untrust` | Remove the passwordless helper; `/etc/hosts` updates prompt for a password again. |
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
- `sudo` access — needed to edit `/etc/hosts` during `patchy setup`, `start`, `stop`, `add`, and `rm`, unless you run `patchy trust` once (see below)
- `zsh` (the default shell on modern macOS)

> **Note:** Apache binds ports 80/443 with a wildcard bind, which needs no root on modern macOS but is reachable from your local network (handy for testing from a phone). The macOS firewall may ask once to allow `httpd`.

> **Upgrading from hostess-based Patchy (≤ v0.3.0) or dnsmasq-based Patchy (≤ v0.9.x)?** Run `patchy setup` once after upgrading. It migrates any old `/etc/hosts` entries and, if it finds a dnsmasq-based install, removes the dnsmasq resolver files and Patchy's dnsmasq config, stops the dnsmasq service, and tells you it's safe to `brew uninstall dnsmasq` (dnsmasq itself is left installed — removing software is your call). One sudo prompt covers the whole migration. Until you do, sites keep working the old way, but DNS won't stop with `patchy stop`.

### How routing works

Every configured site — `.test`, `.local`, and real TLDs alike — gets a
`127.0.0.1 <domain> # patchy` line in `/etc/hosts`. `patchy add` writes the
line before creating the vhost; `patchy start` (re)writes the line for every
configured site, self-healing any that were manually deleted; `patchy stop`
removes every `# patchy` line. Only the exact domain is routed — subdomains
and unregistered names are not, and aren't wildcard-matched the way an old
`/etc/resolver` entry would.

Because `/etc/hosts` is a plain file mDNSResponder watches directly, changes
take effect the instant they're written — no daemon, no cache to flush, no
stale TTLs. This also means `patchy stop` releases real-TLD domains back to
public DNS immediately: a site like `mywebsite.com` starts loading its live,
production version again as soon as Apache stops, and a `stop` → `start`
cycle can't leave a site pinned to a stale answer.

The tradeoff for this simplicity is that editing `/etc/hosts` needs root, so
`start`/`stop`/`add`/`rm` all touch sudo. Run `patchy trust` once to remove
the prompts.

### Trust: passwordless `/etc/hosts` updates

`patchy trust` installs two small, root-owned pieces so day-to-day commands
stop asking for your password:

- `/usr/local/libexec/patchy-hosts` — a minimal root-owned helper script
  that does exactly one thing: rewrite the `# patchy`-marked lines of
  `/etc/hosts` to match the domain list it's given. It validates every
  argument as a bare hostname and refuses anything else.
- `/etc/sudoers.d/patchy` — a `NOPASSWD` rule scoped to that helper only,
  validated with `visudo -cf` before it's installed.

Sudoers is never pointed at `bin/patchy` itself — the script is a plain file
you (or anyone) can edit, so trusting it with passwordless root would let any
edit run as root unattended. The helper is the only thing sudoers whitelists,
it's root-owned so you can't modify it without sudo, and it can't be talked
into doing anything beyond rewriting Patchy's own `/etc/hosts` lines.

Run `patchy untrust` to remove both files; password prompts return.

**`.local` sites are special.** macOS reserves `.local` for Bonjour/mDNS
(printers, AirDrop, other Macs), which is why `.local` sites have always
used `/etc/hosts` rather than DNS — that behavior is now simply how every
site works.

## Uninstall

```bash
# (Optional) remove sites first — cleans up certs and /etc/hosts entries
patchy list                              # see what's configured
patchy rm <domain> [<domain>...]         # remove one or more sites

# Stop Apache and release any remaining /etc/hosts entries
patchy stop

# If you ran 'patchy trust', remove the passwordless helper
patchy untrust

# Remove any patchy-managed /etc/hosts entries that are still present
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
