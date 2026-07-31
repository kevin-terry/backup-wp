# CLAUDE.md

Guidance for working on this repository.

## What this is

A single bash script that pulls a WordPress site's database and uploads down
from production over SSH. `backup-wp` at the repo root is the whole program;
everything else is tests, docs and packaging.

```bash
make test     # offline suite: stubs ssh and rsync, no network, no server
make lint     # shellcheck
make install  # symlink into ~/.local/bin (so a git pull updates the tool)
```

## Invariants

Break any of these and the tool stops being trustworthy:

- **The backup commands never write to the server.** The database streams out
  of `wp-cli` and the uploads come down over rsync. No temp files, no archives
  built remotely, no cleanup to forget. `plugins --update` is the one command
  that changes anything, it is never the default, and it must stay the only one
  — if a second exception seems necessary, that is the moment to split the tool.

  Be precise about `plugins` without `--update`: it changes nothing, but asking
  WordPress about updates makes WordPress refresh its cached `update_plugins`
  transient, which is a database write. Every admin page load does the same and
  WordPress redoes it twice a day regardless. Say "changes nothing" rather than
  "writes nothing", and do not let that precedent grow.
- **No site names, hostnames or docroot names in the code.** Sites are resolved
  from the directory you're standing in; connection details are discovered by
  asking the server and cached per site in `~/.config/backup-wp/<site>.conf`.
  Docroots are recognised by their marker files (`wp-cli.yml`, `wp-config.php`,
  `wp-load.php`), never by name — `public_html`, `httpdocs`, `htdocs` and `web`
  all have to work untouched.
- **Retention is bounded by depth, not just by filename.** Only files at exactly
  `<backup root>/<year>/<month>/<site>/` are eligible for trimming, so anything
  a user files elsewhere under the backup root is untouchable even when the name
  matches. Widening that search is a data-loss bug.

  Which of those files goes first comes from the `-<year>-<month>-<day>-<stamp>`
  the name ends in, never from the name as a whole: `pre-update` and
  `post-update` sit in front of the date, so a plain reverse sort would rank
  every pre- above every post- above every unlabelled snapshot and delete
  today's backup to keep last year's. A name that carries no readable stamp —
  everything written before this scheme — sorts oldest and leaves first, which
  is what it is. Anything that changes the filename has to keep the stamp last.
- **Guessing is always announced.** Where a path can't be derived, the script
  says it guessed and names the setting to correct.
- **What the server says is input, not fact.** The uploads path discovery gets
  back is `wp_upload_dir()`'s basedir, which WordPress reads from the
  `upload_path` option — a row in the database. On a compromised site an
  attacker writes that string, and it lands in a config file this script
  *sources*. So remote paths are held to `safe_remote_path` (absolute, no `..`,
  allowlisted characters) before they are stored, every config value is written
  through `conf_quote`, and both checks run again on the way back in for
  configs older than the checks. The site key gets the same treatment: it is
  a filename in the config directory and the leading half of every retention
  pattern, so a `*` in it would widen `find -name` onto other sites' backups.
- **The mirror never destroys.** `rsync --backup --backup-dir` moves anything
  about to be deleted or overwritten into `rescued-<stamp>/` beside that run's
  archives. Reach for rsync's own facilities before hand-rolling: this needs no
  extra pass and no file list to parse. `--no-rescue` opts out. It is also the
  only command here that deletes, so its destination is checked rather than
  trusted, and `--safe-links` keeps a compromised uploads directory from
  planting a symlink that points out of the tree.
- **The dump is a secret.** It holds every password hash, email address and API
  key on the site. The script runs at `umask 077` so nothing it writes — dumps,
  archives, configs, and the predictably-named `.part` files they are assembled
  in — is readable by anyone else on the machine. `$LOCAL_UPLOADS` is the one
  deliberate exception (public media, and a local web server may need it), and
  it is created in a subshell that restores the caller's umask.

## Constraints worth knowing

**`HOLD_PLUGINS` is the one config value nothing discovers.** `--hold` and
`--unhold` write it, and a human may too, so `setup_site` reads the old config
back before it rewrites the file — a rediscovery that silently drops a hold
list is how a plugin someone pinned on purpose gets updated. `conf_set_hold`
replaces that one line and copies the rest through, comments included, for the
same reason.

The list is parsed inside the `plugins` branch rather than with the config
checks, because a typo in it should stop `plugins` and never stop a backup, and
it is split under `set -f`: an entry is a glob until `safe_plugin_slug` has
vetted it. `--hold` is applied after the listing comes back, not at parse time,
so the name can be checked against what is actually installed — a hold that
holds nothing is the failure the setting exists to prevent — and so the table
prints the list as it now stands.

**Target bash 3.2.** That's what macOS ships as `/bin/bash`, and `#!/usr/bin/env
bash` finds it. No associative arrays, no `${var^^}`, no `mapfile`. Empty-array
expansion under `set -u` needs the `${arr[*]-}` form.

**`set -euo pipefail` is on.** Two traps this repeatedly sets:

- A bare `[ cond ] && cmd` as the last statement in a function, loop body or
  `if` branch aborts the script when the condition is false. Use a full `if`.
- `cmd | head -1` can SIGPIPE the producer, and under `pipefail` the pipeline
  then reports failure even though it succeeded. Capture into a variable
  instead of piping when the exit status matters.

**The remote probe is a heredoc.** `probe_remote` ships a script to the server
over `ssh bash -s`. It never executes locally, so the test suite extracts it by
the `REMOTE` heredoc marker and runs it against synthetic trees. Renaming that
marker silently decouples the tests — one assertion checks the extraction is
non-empty precisely to catch that.

**wp-cli only searches upward** from its working directory for `wp-load.php`.
That's why discovery looks for `wp-load.php` in its own right and why every
candidate is proved by actually running `wp` there rather than by inspecting
paths.

## Testing

The suite is hermetic: a temp directory outside the repo (the script derives
site names from the git top level, so a nested temp dir would resolve to this
repo), stubbed `ssh`/`rsync`/`wp`, and a backup root with a space in the name to
catch quoting bugs.

A `VAR=x run ...` prefix on a *shell function* persists after the call in bash,
unlike on an external command. `run()` clears its overrides for that reason —
without it, one test silently reconfigures the next.

When fixing a bug, verify the new test fails against the old code. Several
tests here were written that way and it's the only thing that proves them.

## Style

shellcheck runs at `-S warning` in CI; the code is currently clean at `-S style`
too, tests included. Every suppression must carry a comment saying why the
warning is wrong; they are all genuine false positives, and a new one that
isn't obviously in that class means the code should change instead.

## Publishing

This repo is public. Nothing in the code, comments, docs or test fixtures should
name a real host, account, domain or site, or use a path convention specific to
one hosting provider. Placeholders are `example-site`, `example-prod`,
`example.com` and `/home/user/...`.
