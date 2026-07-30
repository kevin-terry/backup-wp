# backup-wp

Pull a WordPress site's **database and uploads** down from production with one
command. No control panel, no zipping things up on the server, no downloading
archives by hand.

```bash
backup-wp pre     # database snapshot, before you deploy
backup-wp post    # database snapshot + uploads mirror, after
```

The backup commands never write to the server. The database streams out of
`wp-cli` already compressed; the uploads come down as an rsync delta transfer,
so the second run only moves what changed.

There is one command that does write — `plugins --update` — and it is never the
default.

## Why

To help streamline a specific regular maintenance workflow. I prefer to avoid installing
bulky over complicated plugins so this is what I came up with. It works well for me.
It might work for you too.

This should work well on most hosting servers if you have ssh access and `wp-cli` installed.
I haven't tested this on managed WordPress hosts like WP Engine.

Reports from other hosts are welcome, but treat this as "here, try it"
rather than something I'll be supporting.

## Requirements

**Local:** `bash`, `rsync`, `gzip`, `tar`, `zstd`, and an SSH key that gets you
into the server.

**Remote:** `wp-cli` on the `PATH`, and `mysqldump` (which `wp db export` uses).
Most shared hosts with SSH access have both.

## Install

```bash
git clone https://github.com/kevin-terry/backup-wp.git
cd backup-wp
make install          # symlinks backup-wp into ~/.local/bin
```

`make install` only creates a symlink, so `git pull` updates the tool
immediately. `make uninstall` removes the link. If `~/.local/bin` isn't on your
`PATH`, add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Prefer somewhere else? `make install PREFIX=/usr/local`.

## First run

Run it inside a project and it asks one question — which SSH host — then works
out everything else by asking the server directly:

```console
$ cd ~/Sites/example-site
$ backup-wp pre

==> Setting up example-site
    project  /home/user/Sites/example-site

    SSH hosts in ~/.ssh/config:
       1) example-prod
       2) other-prod

    Which host serves example-site? (number, or user@host) 1
==> Checking example-prod
==> Looking for WordPress on example-prod
==> Saved ~/.config/backup-wp/example-site.conf
```

It finds WordPress by locating `wp-cli.yml`, `wp-config.php` or `wp-load.php`
under the remote `$HOME`, confirms each candidate by actually running
`wp core version` there, and asks WordPress itself where uploads live
(`wp_upload_dir()`) rather than guessing. If exactly one install checks out, it
doesn't even ask.

No particular one of those files has to exist. `wp-load.php` is in the list so
the WordPress root is found directly, which matters when `wp-config.php` has
been moved a level above it.

The answers are saved per site, so it never asks twice. To skip the question
entirely — handy for scripting — pass the alias:

```bash
backup-wp --host example-prod
```

## Everyday use

```bash
backup-wp pre                  # DB only, tagged "pre"
backup-wp post                 # DB tagged "post" + uploads mirror
backup-wp post --archive       # ...and a dated .tar.zst of the uploads
backup-wp db                   # DB only, untagged
backup-wp uploads              # uploads only
backup-wp plugins              # list pending plugin updates
backup-wp plugins --update     # apply the server-managed ones
backup-wp                      # DB + uploads
```

The site is taken from whichever project directory you're standing in. To work
on another site from anywhere, name it:

```bash
backup-wp example-site pre
```

Options:

| Flag             | Effect                                                  |
| ---------------- | ------------------------------------------------------- |
| `-a, --archive`  | also build a dated `.tar.zst` of the uploads            |
| `-n, --dry-run`  | show what would happen; transfer nothing                |
| `-f, --force`    | skip the first-run confirmation before `rsync --delete` |
| `--no-prune`     | keep every old snapshot instead of trimming             |
| `--no-rescue`    | delete outright instead of moving replaced files aside  |
| `--update`       | with `plugins`, actually apply the updates              |
| `--setup`        | re-run discovery and rewrite this site's config         |
| `--host <alias>` | set up against an SSH alias without asking              |
| `--list`         | show every configured site                              |

## Where things land

```text
~/Site Backups/<year>/<month>/<site>/
    <site>-db-20260130-091200-pre.sql.gz
    <site>-db-20260130-104300-post.sql.gz
    <site>-uploads-20260130-104300.tar.zst
    rescued-20260130-104300/            <- anything the mirror replaced

~/Sites/<site>/public_html/uploads/     <- mirror of production
~/Sites/<site>/sql/latest.sql           <- newest dump, uncompressed
```

The uploads sync into your project so your local site has the real media. The
compressed copies go somewhere central you can push off-machine.

Because the newest dump is also dropped in the project as plain SQL, importing
is one command:

```bash
wp db import sql/latest.sql
```

## What gets deleted

Worth reading once, since this is the only part that removes anything.

**The uploads mirror is exact, but nothing is destroyed.** It runs
`rsync --delete`, so a file that exists locally but not on production is taken
out of the mirror — that's what makes it a faithful copy. Before that happens,
anything about to be deleted _or overwritten_ is moved into a dated folder
beside that run's archives:

```text
~/Site Backups/<year>/<month>/<site>/rescued-20260130-104300/
    2025/08/a-file-only-you-had.pdf
```

Original paths are preserved, so putting something back is a `cp`. Rescue
folders sit outside the path retention looks at, so they're never trimmed —
they accumulate until you clear them out, which is the intended trade.

The first time it mirrors into a non-empty folder it still counts what would go
and asks, since a surprising number usually means the wrong directory rather
than the wrong files. After that it never asks again for that site. To see the
list without touching anything:

```bash
backup-wp uploads --dry-run
```

`--no-rescue` skips the safety net and deletes outright.

**Retention is narrow on purpose.** Old snapshots are trimmed to the newest
`$KEEP` (default 10), but only files sitting _exactly_ here:

```text
<backup root>/<year>/<month>/<site>/<site>-db-*.sql.gz
<backup root>/<year>/<month>/<site>/<site>-uploads-*.tar.zst
```

Anything you file anywhere else under the backup root is invisible to it —
even if the name matches. A `manual/` folder, loose files at the root, notes,
exports under their own names: all safe indefinitely. `--no-prune` skips
trimming entirely.

**No backup command creates, modifies or deletes anything on the server.** The
sole exception is `plugins --update`, which is opt-in twice over: a command you
have to name, and a flag you have to add.

## Plugin updates

```bash
backup-wp plugins            # what has updates, and who owns each one
backup-wp plugins --update   # apply the ones the server owns
```

```console
$ backup-wp plugins
==> Plugins
    contact-form              1.2.0     → 1.3.1     composer
    file-manager              6.2.6     → 6.3.7     server
    some-premium-plugin       6.32                  no updater
    composer ones belong to `composer update` locally, then deploy —
    updating them here is undone by the next deploy
    "no updater" means WordPress has never heard from that plugin, not
    that it is current — premium updaters do not register under wp-cli.
    Check those by hand; --update cannot see an update for them either.
    run with --update to update the server-managed one(s)
```

Ownership is read from your project's `composer.json`: the half of `vendor/name`
after the slash is the directory Composer installs into. Updating a
Composer-managed plugin on the server is worse than pointless — the next deploy
reverts it, and until then production quietly disagrees with your lockfile. So
`--update` skips them and tells you why. On a site with no `composer.json`,
nothing is Composer-managed and everything is fair game.

**This works even when the admin can't.** `DISALLOW_FILE_MODS` is enforced in
`map_meta_cap()`, which rewrites `update_plugins` to `do_not_allow` — a
_capability_ check, binding only on code that asks whether the current user may
act. That is the admin UI. wp-cli runs with no user and never asks. So a site
deliberately locked down so its editors cannot install or update anything is
still updatable by you over SSH, with no config change.

The corollary is worth stating: that lockdown does not protect you from
yourself. wp-cli ignores it for `plugin delete` too.

**"no updater" is not "up to date".** `wp plugin list` reports `none` both for a
plugin that is current and for one nothing ever asked about. Premium plugins
usually register their update checks on admin-only hooks, and wp-cli never loads
admin context, so they are absent from WordPress's update data entirely — and
`none` then reads as reassurance it has not earned. This command asks WordPress
which plugins it has actually heard from and labels the rest `no updater`, so a
licensed plugin quietly sitting three versions behind gets named instead of
blending in. Those still need checking by hand; `--update` can't fetch an update
nobody reported.

Back up first — `backup-wp pre` — and it's a normal `wp plugin update` behind
the scenes, so anything it can't do, wp-cli couldn't either.

## Configuration

Per-site answers live in `~/.config/backup-wp/<site>.conf` — plain shell
variables, safe to edit by hand:

```bash
SITE_DIR="/home/user/Sites/example-site"
SSH_HOST="example-prod"                 # an ~/.ssh/config alias
REMOTE_WP="/home/user/sites/example.com"
REMOTE_WP_BIN="/usr/local/bin/wp"
REMOTE_UPLOADS="/home/user/sites/example.com/public_html/uploads"
LOCAL_UPLOADS="/home/user/Sites/example-site/public_html/uploads"
```

Storing the SSH _alias_ rather than a hostname means a host change only needs
fixing in `~/.ssh/config`.

A sibling `<site>.mirrored` marker appears after the first successful uploads
sync; it's what suppresses the deletion confirmation on later runs. Delete it
to get that one-time check back.

Environment overrides:

| Variable      | Default                                |
| ------------- | -------------------------------------- |
| `BACKUP_ROOT` | `~/Site Backups`                       |
| `SITES_DIR`   | `~/Sites`                              |
| `KEEP`        | `10` snapshots per type, per site      |
| `KEEP_SQL`    | `3` plain `.sql` copies in the project |
| `RSYNC`       | first `rsync` on `PATH`                |

## Directory names are never assumed

Nothing here has a list of docroot names in it. `public_html`, `httpdocs`,
`htdocs`, `web`, `public` — all work without configuration, because both sides
are worked out by structure:

- **Remote:** WordPress is found by its marker files — `wp-cli.yml`,
  `wp-config.php` or `wp-load.php`, any one will do — and the uploads path comes
  from WordPress itself via `wp_upload_dir()`. Whatever your host calls its
  folders is irrelevant.
- **Local:** the mirror path is derived from where the uploads sit _relative to_
  the remote project root, then applied to your project. A docroot called
  `httpdocs` lands at `httpdocs/...` locally without anything being named.
- **Is this a project at all?** Decided by looking for `wp-cli.yml`,
  `wp-config.php` or `wp-load.php`, not by directory name.

The one case that can't be derived is uploads stored _outside_ the remote
project root — a shared or symlinked media directory. Then the script looks for
an existing `uploads` folder in your project and **tells you it guessed**, so
you can correct `LOCAL_UPLOADS` before the first sync.

Every discovered value is a plain variable in the site's `.conf`. If any of it
is wrong for your setup, edit it — nothing is baked into the script.

## Troubleshooting

**"found no working WordPress install"** — the search covers 5 levels below the
remote `$HOME`. If the install is deeper, or lives outside `$HOME`, set
`REMOTE_WP` and `REMOTE_UPLOADS` by hand in the site's `.conf`.

**"does not look like a WordPress project"** — the directory has no
`wp-cli.yml`, `wp-config.php` or `wp-load.php` within three levels. Either
you're in the wrong directory, or the project is nested unusually deep; naming
the site (`backup-wp <site>`) skips the check.

**"the mirror path is a guess"** — your uploads live outside the remote project
root, so there was nothing to derive the local path from. Set `LOCAL_UPLOADS`
in the site's `.conf` to wherever the mirror belongs.

**"cannot reach &lt;host&gt; over ssh"** — check the alias resolves and connects on
its own first: `ssh <alias>`. Shared hosts sometimes retire hostnames while
your user, key, and port stay valid; only `HostName` needs updating.

**It asks for a passphrase every run** — that's ssh, not this tool. On macOS,
`ssh-add --apple-use-keychain ~/.ssh/your-key` stores it once. A single
connection is reused for the whole run, so you'll never be asked twice.

**"no terminal to confirm on"** — a prompt was needed but stdin isn't a
terminal. Run it interactively, or pass `--host` / `--force` as the message
suggests.

## Development

```bash
make test     # offline test suite — stubs ssh and rsync, no server needed
make lint     # shellcheck
```

The tests fake the network, so they run anywhere and never touch a real host.

## License

MIT
