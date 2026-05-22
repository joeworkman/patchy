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
| `patchy errors [lines\|-f]` | Show the last *N* lines of the Apache error log (default 20), or follow with `-f`. |
| `patchy refresh-certs` | Regenerate all local SSL certificates. |
| `patchy setup` | One-time setup (Apache user, dirs, vhost include). Auto-run by `brew install`. |
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
- `sudo` access — only used to update `/etc/hosts` via `hostess`
- `zsh` (the default shell on modern macOS)

## Uninstall

```bash
# (Optional) remove sites first — cleans up /etc/hosts entries and certs
patchy list                              # see what's configured
patchy rm <domain>                       # repeat per site

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
