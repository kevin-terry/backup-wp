# backup-wp

Quickly pull down and archive WordPress databases and uploads over SSH.

```bash
backup-wp             # database snapshot + uploads mirror
backup-wp --archive   # database snapshot + uploads mirror + .tar.zst archive of uploads
```

Backups never write to the server. The database streams out of `wp-cli`; the
uploads come down as an rsync delta, so repeat runs only move what changed.

## Requirements

- **Local:** `bash`, `rsync`, `gzip`, `tar`, `zstd`, configured SSH key.
- **Remote:** `wp-cli` on the `PATH` and `mysqldump`.

Works on most hosts with SSH access. Untested on managed hosts like WP Engine.

## Install

```bash
git clone https://github.com/kevin-terry/backup-wp.git
cd backup-wp
make install                  # symlinks into ~/.local/bin
```

Add `~/.local/bin` to your `PATH` if it isn't there. Elsewhere:
`make install PREFIX=/usr/local`. Remove with `make uninstall`.

Because it's a symlink, `git pull` updates the tool.

## First run

Run it inside a project. It asks one question — which SSH host — then discovers
the rest by asking the server, and saves the answers per site.

```console
$ cd ~/Sites/example-site
$ backup-wp pre

==> Setting up example-site
    SSH hosts in ~/.ssh/config:
       1) example-prod
       2) other-prod

    Which host serves example-site? (number, or user@host) 1
==> Saved ~/.config/backup-wp/example-site.conf
```

Skip the question with `backup-wp --host example-prod`.

## Commands

```bash
backup-wp                      # DB + uploads mirror (the default)
backup-wp --archive            # DB + uploads mirror + .tar.zst archive of uploads

backup-wp pre                  # DB only, tagged "pre" (pre update)
backup-wp post                 # DB + uploads mirror + .tar.zst, tagged "post" (post update)
backup-wp post --no-archive    # ...without the .tar.zst

backup-wp db                   # DB only

backup-wp uploads              # uploads only
backup-wp uploads --archive    # uploads + .tar.zst archive of uploads

backup-wp plugins              # lists pending plugin updates on remote
backup-wp plugins --update     # applys the remote server-managed updates
```

TIP: The site comes from the directory you're in. To work from anywhere add the site name:
`backup-wp example-site pre`.

| Flag             | Effect                                                  |
| ---------------- | ------------------------------------------------------- |
| `-a, --archive`  | also build a dated `.tar.zst` of the uploads            |
| `--no-archive`   | skip that archive where it is the default (`post`)      |
| `-n, --dry-run`  | show what would happen; transfer nothing                |
| `-f, --force`    | skip the first-run confirmation before `rsync --delete` |
| `--no-prune`     | keep every old snapshot instead of trimming             |
| `--no-rescue`    | delete outright instead of moving replaced files aside  |
| `--update`       | with `plugins`, apply every server-managed update       |
| `--update=a,b`   | ...or only the plugins named                            |
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

Import with `wp db import sql/latest.sql`.

Database dumps are created readable only by you. The uploads mirror keeps your usual umask.

Docroot names are never assumed — `public_html`, `httpdocs`, `htdocs`, `web`
all work untouched. WordPress is found by its marker files and the uploads path
comes from `wp_upload_dir()`.

## What gets deleted

- **The uploads mirror is exact** — `rsync --delete` removes local files
  production doesn't have. They're moved to `rescued-<stamp>/` first, with
  paths preserved, not deleted. `--no-rescue` opts out. The first mirror into a
  non-empty folder asks before proceeding; `--dry-run` shows the list.
  Symlinks arriving from the server that point out of the uploads tree are
  dropped rather than recreated locally.
- **Retention is narrow.** Old snapshots trim to the newest `$KEEP` (default
  10), but only files sitting exactly at
  `<root>/<year>/<month>/<site>/<site>-db-*.sql.gz` (or `-uploads-*.tar.zst`).
  Anything filed elsewhere under the backup root is never touched.
  `--no-prune` skips trimming.
- **Nothing on the server is touched** by any backup command. The one exception
  is `plugins --update`.

## Plugin updates

```bash
backup-wp plugins                       # what has updates, and who owns each
backup-wp plugins --update              # apply every server-managed one
backup-wp plugins --update=some-plugin  # ...or just the one you specify
```

```console
$ backup-wp plugins
==> Plugins
    contact-form              1.2.0     → 1.3.1     composer
    file-manager              6.2.6     → 6.3.7     server
    some-premium-plugin       6.32                  no updater
```

- `composer` — owned by your `composer.json`; update locally and deploy.
  `--update` skips these, since the next deploy reverts them.
- `server` — what `--update` acts on.
- `no updater` — WordPress has never heard from it. Not the same as current;
  check those by hand.

Back up first. It's `wp plugin update` underneath, and these backups cover the
database and uploads, not plugin files.

## Configuration

Per-site answers live in `~/.config/backup-wp/<site>.conf` — plain shell
variables, safe to edit. The file is sourced, so the two remote paths are
checked before use: each must be absolute, free of `..`, and free of anything
a shell would act on. Set them to something else and the run stops rather than
passing it along.

```bash
SITE_DIR="/home/user/Sites/example-site"
SSH_HOST="example-prod"                 # an ~/.ssh/config alias
REMOTE_WP="/home/user/sites/example.com"
REMOTE_WP_BIN="/usr/local/bin/wp"
REMOTE_UPLOADS="/home/user/sites/example.com/public_html/uploads"
LOCAL_UPLOADS="/home/user/Sites/example-site/public_html/uploads"
```

Environment overrides:

| Variable      | Default                                |
| ------------- | -------------------------------------- |
| `BACKUP_ROOT` | `~/Site Backups`                       |
| `SITES_DIR`   | `~/Sites`                              |
| `KEEP`        | `10` snapshots per type, per site      |
| `KEEP_SQL`    | `3` plain `.sql` copies in the project |
| `RSYNC`       | first `rsync` on `PATH`                |

## Troubleshooting

- **`found no working WordPress install`** — deeper than 5 levels below the
  remote `$HOME`, or outside it. Set `REMOTE_WP` and `REMOTE_UPLOADS` by hand.
- **`does not look like a WordPress project`** — wrong directory, or nested
  deeper than 3 levels. Naming the site skips the check.
- **`the mirror path is a guess`** — uploads live outside the remote project
  root. Set `LOCAL_UPLOADS`.
- **`cannot reach <host> over ssh`** — check `ssh <alias>` works on its own;
  hosts sometimes retire a `HostName` while your user, key and port stay valid.
- **`no terminal to confirm on`** — run interactively, or pass `--host` /
  `--force`.
- **`will not put in a shell command`** — a remote path holds `..` or a
  character a shell would act on. WordPress takes the uploads path from the
  `upload_path` row in the database, so an unexpected one is worth a look
  before you set `REMOTE_UPLOADS` by hand.

Asked for a passphrase every run? That's ssh. On macOS:
`ssh-add --apple-use-keychain ~/.ssh/your-key`.

## Development

```bash
make test     # offline suite — stubs ssh and rsync, no server needed
make lint     # shellcheck
```

## License

MIT
