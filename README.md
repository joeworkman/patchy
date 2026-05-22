# Patchy

A patchy little Apache + PHP dev server for macOS.

> Apache was originally a pun on "a patchy server" — it was built from patches on top of NCSA HTTPd.
> Patchy is a patchy little CLI for managing local Apache + mod_php sites on your Mac.

## Why Patchy?

Most modern local PHP dev environments — Laravel Valet, Herd, Lando — run Nginx + PHP-FPM under the hood. That's great for fresh frameworks but rough on anything that leans on `.htaccess`, mod_rewrite, or Apache-specific directives: classic WordPress, Total CMS, Drupal, Symfony with the Apache pack, or legacy intranets that have been running on Apache for a decade.

Patchy gives you the real thing: **Apache 2 + mod_php** with local HTTPS, friendly `.test` hostnames, and one command per site.

## What you get

- Per-site Apache vhost generated in a single command
- Local HTTPS via [mkcert](https://github.com/FiloSottile/mkcert) — no browser warnings
- Friendly hostnames via [hostess](https://github.com/cbednarski/hostess) — `/etc/hosts` managed for you
- Per-site error and access logs
- Painless PHP version switching across installed Homebrew PHPs
- One-shot PECL extension setup (`redis`, `apcu`, `imagick`, `yaml`, `pcov`, `memcached`)
- A plain `httpd.conf` you can read and edit — no black box

## Install

```bash
brew install joeworkman/patchy/patchy
```

That's it — the formula pulls in all dependencies (`httpd`, `php`, `mkcert`, `hostess`, `jq`) and configures Apache to run as your user during install.

### From source

```bash
git clone https://github.com/joeworkman/patchy
cd patchy
sudo ln -s "$PWD/bin/patchy" /usr/local/bin/patchy
patchy install
```

## Quick start

```bash
# Add a site — docroot defaults to ~/Websites/example.test
patchy add example.test

# Open https://example.test in your browser

# When you're done
patchy rm example.test
```

## Commands

| Command | Description |
|---|---|
| `patchy add <domain> [dir]` | Add a new site. Docroot defaults to `~/Websites/<domain>`. |
| `patchy rm <domain>` | Remove a site. |
| `patchy list` | List configured sites. |
| `patchy start` / `stop` / `restart` | Control the Apache service. |
| `patchy status` | Show whether Apache is running. |
| `patchy check` | Verify Apache and PHP config. |
| `patchy info` | Show Apache and PHP version info. |
| `patchy php <version>` | Switch the active PHP version (e.g. `patchy php 8.4`). |
| `patchy pecl` | Install common PECL extensions for the current PHP. |
| `patchy config` | Open `httpd.conf` in your editor. |
| `patchy ini` | Open the active `php.ini` in your editor. |
| `patchy logs` | Tail all Apache logs. |
| `patchy errors [lines]` | Show the last *N* lines of the Apache error log (default 20). |
| `patchy refresh-certs` | Regenerate all local SSL certificates. |
| `patchy install` | Install dependencies (run once). |
| `patchy help` | Print all of the above. |

## Where things live

| | |
|---|---|
| Site docroots | `~/Websites/<domain>` (by convention) |
| Vhost configs | `$(brew --prefix)/etc/httpd/sites/<domain>.conf` |
| SSL certificates | `$(brew --prefix)/etc/httpd/certs/` |
| Per-site logs | `$(brew --prefix)/var/log/httpd/<domain>-{access,error}_log` |
| Main Apache config | `$(brew --prefix)/etc/httpd/httpd.conf` |

## How it compares

|  | **Patchy** | Laravel Valet | Laravel Herd |
|---|---|---|---|
| Web server | **Apache 2 + mod_php** | Nginx + PHP-FPM | Nginx + PHP-FPM |
| `.htaccess` & mod_rewrite | ✅ native | ✗ (needs conversion) | ✗ (needs conversion) |
| Local HTTPS | ✅ mkcert | ✅ | ✅ |
| PHP switching | ✅ | ✅ | ✅ |
| GUI | — | — | ✅ |
| License | MIT | MIT | freemium |

If your stack is a modern PHP framework that targets Nginx + FPM, Valet or Herd will probably serve you better. If your stack is "the way Apache shops have built PHP for the last twenty years," Patchy is for you.

## Requirements

- macOS
- [Homebrew](https://brew.sh)
- `sudo` access — only used to update `/etc/hosts` via `hostess`
- `zsh` (the default shell on modern macOS)

## Uninstall

```bash
# Remove all sites
patchy list | xargs -n1 patchy rm

# Remove the binary
sudo rm /usr/local/bin/patchy

# (Optional) remove the dependencies
brew uninstall httpd php mkcert hostess
```

## Contributing

Issues and pull requests welcome. This is a tool I use every day for real work — improvements that make it more useful or more reliable are gladly accepted. Please run `zsh -n bin/patchy` and `shellcheck bin/patchy` before opening a PR.

## License

MIT — see [LICENSE](LICENSE).
