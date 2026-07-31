#!/usr/bin/env bash
#
# Offline test suite for backup-wp.
#
# ssh and rsync are replaced with stubs, so these tests need no server, no
# network, and no credentials. Everything happens in a temp directory that is
# removed on exit.
#
#   bash test/run-tests.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/backup-wp"

if [ -t 1 ]; then
    GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
    GRN=''; RED=''; DIM=''; RST=''
fi

PASS=0; FAIL=0
ok()    { printf '  %sok%s    %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$1"; FAIL=$((FAIL + 1)); }
group() { printf '\n%s%s%s\n' "$DIM" "$1" "$RST"; }

assert_rc()      { if [ "$RC" -eq "$1" ]; then ok "$2"; else bad "$2 (exit $RC, wanted $1)"; fi; }
assert_has()     { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 (output lacked '$1')" ;; esac; }
assert_file()    { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
assert_dir()     { if [ -d "$1" ]; then ok "$2"; else bad "$2 (missing dir: $1)"; fi; }
assert_eq()      { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', wanted '$2')"; fi; }
assert_gone()    { if [ -e "$1" ]; then bad "$2 (it exists: $1)"; else ok "$2"; fi; }

# `stat` takes different flags on macOS and GNU and CI runs both, so read the
# mode off `ls` instead — the one spelling both agree on. shellcheck's advice
# to use find is about globbing a directory; this is one named file, quoted,
# and find has no portable way to print a mode (-printf is GNU only).
# shellcheck disable=SC2012
modestr() { ls -ld "$1" 2>/dev/null | cut -c1-10; }

# ── hermetic environment ────────────────────────────────────────────────────
# Deliberately outside the repo: the script derives the site name from the git
# top level, so a temp dir nested here would resolve to this repo's name.
# pwd -P normalises twice over: macOS $TMPDIR carries a trailing slash that
# would leave a doubled separator, and /var is itself a symlink to /private/var,
# which the script resolves when it inspects $HOME. Start physical so every
# path we compare against matches what the script computes.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/backup-wp-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

SITE=example-site
SITES="$TMP/Sites"
SITE_DIR="$SITES/$SITE"
UPLOADS="$SITE_DIR/public_html/uploads"
SQL_DIR="$SITE_DIR/sql"
# The space is intentional: it catches quoting bugs in every path we build.
BACKUPS="$TMP/Site Backups"
CONFIG="$TMP/config"
CONF="$CONFIG/backup-wp/$SITE.conf"
STUB="$TMP/bin"

WANT_WP="/home/user/sites/example.com"
WANT_UPLOADS="$WANT_WP/public_html/uploads"

mkdir -p "$UPLOADS" "$SQL_DIR" "$STUB" "$CONFIG"
# A real project has a WordPress marker; without one the script should — and
# now does — refuse to treat the directory as a site at all.
: > "$SITE_DIR/wp-cli.yml"

# ── stubs ───────────────────────────────────────────────────────────────────
# One ssh stub covering all three ways the script calls out:
#   ssh host true            -> connectivity check
#   ssh host bash -s         -> discovery probe (reads a script on stdin)
#   ssh host "wp db export"  -> a gzipped dump on stdout
write_ssh_stub() {
cat > "$STUB/ssh" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    -s)
        cat >/dev/null
        # Two hits sharing one uploads dir, like a project root plus the
        # docroot nested inside it. The script must collapse these to one.
        printf 'OK\t/usr/local/bin/wp\t%s\t%s\n' "$STUB_WP" "$STUB_UPLOADS"
        printf 'OK\t/usr/local/bin/wp\t%s/public_html\t%s\n' "$STUB_WP" "$STUB_UPLOADS"
        exit 0 ;;
esac
# wp-cli calls arrive as one remote command string
case "$last" in
    *"plugin list"*)
        # premium-thing models a licensed plugin: it only reports an update
        # when the checker registers, which needs admin context.
        case "$last" in
            *WP_ADMIN*)
                echo admin >> "$STUB_CTX_LOG"
                if [ -n "${STUB_ADMIN_FAILS:-}" ]; then
                    echo "PHP Fatal error: call to undefined function" >&2
                    exit 1
                fi
                premium="premium-thing,active,5.0,available,5.1" ;;
            *)  echo plain >> "$STUB_CTX_LOG"
                premium="premium-thing,active,5.0,none," ;;
        esac
        echo "name,status,version,update,update_version"
        echo "in-composer,active,1.0,available,1.1"
        echo "server-only,active,2.0,available,2.5"
        echo "up-to-date,active,3.0,none,"
        echo "$premium"
        echo "mu-plugins,must-use,1.0,none,"
        # A slug with a dot in it, for the test that a slug is matched as a
        # name and not as a regular expression.
        if [ -n "${STUB_DOTTED_PLUGIN:-}" ]; then
            echo "wp.rocket,active,1.0,available,1.1"
        fi
        exit 0 ;;
    *"plugin update"*)
        echo "Plugin updated successfully."
        echo "${last##* }" >> "$STUB_UPDATE_LOG"
        exit 0 ;;
    *eval*)   # which plugins the update transient has actually heard from
        printf '%s\n' in-composer server-only up-to-date
        exit 0 ;;
esac
{
    echo "-- MySQL dump 10.13  Distrib 8.0.0"
    echo "CREATE TABLE wp_posts (ID bigint, post_content longtext);"
    i=0
    while [ "$i" -lt 300 ]; do
        echo "INSERT INTO wp_posts VALUES ($i,'0123456789012345678901234567890123456789');"
        i=$((i + 1))
    done
    echo "-- Dump completed on 2026-01-30 09:12:00"
} | gzip -6
EOS
chmod +x "$STUB/ssh"
}
write_ssh_stub

# rsync stub: honours -n by reporting deletions instead of performing them, and
# honours --backup-dir by moving local-only files there the way real rsync does.
cat > "$STUB/rsync" <<'EOS'
#!/usr/bin/env bash
if [ -n "${STUB_RSYNC_LOG:-}" ]; then printf '%s\n' "$*" >> "$STUB_RSYNC_LOG"; fi
dry=0; backup_dir=""
for a in "$@"; do
    [ "$a" = "-n" ] && dry=1
    case "$a" in --backup-dir=*) backup_dir="${a#--backup-dir=}" ;; esac
    dest="$a"
done
if [ "$dry" -eq 1 ]; then
    echo "deleting 2020/01/local-only.jpg"
    echo "Number of files: 3"
    exit 0
fi
# anything already in dest that we are not about to write is "local only"
if [ -n "$backup_dir" ]; then
    dest="${dest%/}"          # the destination arrives with a trailing slash
    while IFS= read -r f; do
        rel="${f#"$dest"/}"
        case "$rel" in 2026/01/hero.jpg|2026/01/logo.png) continue ;; esac
        mkdir -p "$backup_dir/$(dirname "$rel")"
        mv "$f" "$backup_dir/$rel"
    done < <(find "$dest" -type f 2>/dev/null)
fi
mkdir -p "$dest/2026/01"
echo hero > "$dest/2026/01/hero.jpg"
echo logo > "$dest/2026/01/logo.png"
echo "Number of files: 2"
EOS
chmod +x "$STUB/rsync"

run() {   # run <args...> — sandboxed; override RUN_DIR / STUB_WP / STUB_UPLOADS
    # RUN_HOME exists so a test can point $HOME somewhere disposable. The only
    # tests that need it are the ones checking that the mirror refuses to run
    # over a home directory — if that guard ever regresses, the damage has to
    # land in the temp tree and not in the home directory of whoever ran this.
    OUT="$(cd "${RUN_DIR:-$SITE_DIR}" && env \
        PATH="$STUB:$PATH" \
        HOME="${RUN_HOME:-$HOME}" \
        XDG_CONFIG_HOME="$CONFIG" \
        SITES_DIR="$SITES" \
        BACKUP_ROOT="$BACKUPS" \
        RSYNC="$STUB/rsync" \
        KEEP="${KEEP:-10}" \
        KEEP_SQL="${KEEP_SQL:-3}" \
        STUB_WP="${STUB_WP:-$WANT_WP}" \
        STUB_UPLOADS="${STUB_UPLOADS:-$WANT_UPLOADS}" \
        STUB_UPDATE_LOG="$TMP/updated.log" \
        STUB_CTX_LOG="$TMP/context.log" \
        STUB_RSYNC_LOG="${STUB_RSYNC_LOG:-}" \
        STUB_ADMIN_FAILS="${STUB_ADMIN_FAILS:-}" \
        STUB_DOTTED_PLUGIN="${STUB_DOTTED_PLUGIN:-}" \
        bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
    # A `VAR=x run ...` prefix on a *function* persists after the call in bash,
    # unlike on an external command. Clear the overrides so each call is
    # independent and one test cannot silently reconfigure the next.
    unset RUN_DIR RUN_HOME STUB_WP STUB_UPLOADS KEEP KEEP_SQL STUB_ADMIN_FAILS
    unset STUB_RSYNC_LOG STUB_DOTTED_PLUGIN
}

# read a value out of the generated config without sourcing it
conf_get() { grep "^$1=" "$CONF" | cut -d'"' -f2; }

DEST="$BACKUPS/$(date +%Y)/$(date +%m)/$SITE"
parts() { find "$BACKUPS" "$SQL_DIR" -name '*.part' 2>/dev/null | wc -l | tr -d ' '; }
managed() { find "$DEST" -maxdepth 1 -type f -name "$SITE-db-*.sql.gz" 2>/dev/null | wc -l | tr -d ' '; }

# ── argument handling ───────────────────────────────────────────────────────
group "argument handling"

run --help;              assert_rc 0 "--help exits 0"
                         assert_has "usage: backup-wp" "--help prints usage"
run --list;              assert_rc 1 "--list with nothing configured fails"
run pre post;            assert_rc 1 "two actions rejected"
                         assert_has "more than one action" "...with a clear reason"
run nope-not-a-site db;  assert_rc 1 "unknown site key rejected"
run --badflag;           assert_rc 1 "unknown flag rejected"

OUT="$(cd "$TMP" && env PATH="$STUB:$PATH" XDG_CONFIG_HOME="$CONFIG" \
        bash "$SCRIPT" pre 2>&1)"; RC=$?
assert_rc 1 "refuses to run outside a WordPress project"
assert_has "does not look like a WordPress project" "...with a clear reason"

# ── discovery ───────────────────────────────────────────────────────────────
group "discovery and setup"

run db --host stub-host
assert_rc 0 "setup via --host needs no terminal"
assert_file "$CONF" "writes a per-site config"
assert_eq "$(conf_get SSH_HOST)"      "stub-host"     "stores the ssh alias, not a hostname"
assert_eq "$(conf_get REMOTE_WP)"     "$WANT_WP"      "keeps the project root, not the docroot"
assert_eq "$(conf_get REMOTE_UPLOADS)" "$WANT_UPLOADS" "records the remote uploads dir"
assert_eq "$(conf_get LOCAL_UPLOADS)" "$UPLOADS"      "derives the local mirror path"

run --list;              assert_rc 0 "--list works once a site exists"
                         assert_has "$SITE" "--list names the site"

# ── layouts this script has never heard of ──────────────────────────────────
group "alternative docroot layouts"

# A project whose docroot is called httpdocs, with no wp-cli.yml at the root.
ALT="$SITES/alt-site"
mkdir -p "$ALT/httpdocs/wp-content/uploads"
: > "$ALT/httpdocs/wp-config.php"

ALT_WP="/var/www/alt/httpdocs"
RUN_DIR="$ALT" STUB_WP="$ALT_WP" STUB_UPLOADS="$ALT_WP/wp-content/uploads" \
    run db --host stub-host
assert_rc 0 "accepts a docroot named httpdocs"
ALT_CONF="$CONFIG/backup-wp/alt-site.conf"
assert_file "$ALT_CONF" "sets up the alternative layout"
assert_eq "$(grep '^LOCAL_UPLOADS=' "$ALT_CONF" | cut -d'"' -f2)" \
          "$ALT/wp-content/uploads" \
          "derives the mirror path without knowing the docroot name"

# A directory with nothing WordPress-ish in it must still be refused.
mkdir -p "$SITES/not-a-site/src"
OUT="$(cd "$SITES/not-a-site" && env PATH="$STUB:$PATH" XDG_CONFIG_HOME="$CONFIG" \
        bash "$SCRIPT" pre 2>&1)"; RC=$?
assert_rc 1 "still refuses a directory with no WordPress in it"

# Uploads living outside the remote project root cannot be derived, so the
# script must guess *and say so* rather than quietly inventing a path.
DET="$SITES/detached-site"
mkdir -p "$DET/web/app/uploads"
: > "$DET/wp-cli.yml"
RUN_DIR="$DET" STUB_WP="/srv/app/current" STUB_UPLOADS="/srv/shared/uploads" \
    run db --host stub-host
assert_rc 0 "handles uploads stored outside the project root"
assert_has "is a guess" "warns that the mirror path was guessed"
assert_has "LOCAL_UPLOADS" "...and names the setting to correct"
assert_eq "$(grep '^LOCAL_UPLOADS=' "$CONFIG/backup-wp/detached-site.conf" | cut -d'"' -f2)" \
          "$DET/web/app/uploads" \
          "finds an existing uploads dir whatever it is nested under"

# ── the probe that runs on the server ───────────────────────────────────────
group "remote discovery"

# The probe is a heredoc inside backup-wp that normally executes over ssh.
# Extract it and run it here against synthetic trees, with a wp stub that
# reproduces the one behaviour that decides everything: wp-cli only ever
# searches UPWARD for wp-load.php, optionally redirected by a wp-cli.yml path.
PROBE="$TMP/probe.sh"
awk '/<<.REMOTE./{f=1;next} /^REMOTE$/{f=0} f' "$SCRIPT" > "$PROBE"
if [ -s "$PROBE" ]; then
    ok "extracted the remote probe from the script"
else
    bad "extracted the remote probe from the script (heredoc marker changed?)"
fi

cat > "$STUB/wp" <<'EOS'
#!/usr/bin/env bash
resolve_root() {
    local d="$PWD" p
    while :; do
        if [ -f "$d/wp-cli.yml" ]; then
            p="$(sed -n 's/^path:[[:space:]]*//p' "$d/wp-cli.yml" | head -1)"
            if [ -n "$p" ] && [ -e "$d/$p/wp-load.php" ]; then echo "$d/$p"; return 0; fi
        fi
        if [ -e "$d/wp-load.php" ]; then echo "$d"; return 0; fi
        if [ "$d" = "/" ]; then return 1; fi
        d="$(dirname "$d")"
    done
}
root="$(resolve_root)" || {
    echo "Error: This does not seem to be a WordPress installation." >&2; exit 1; }
case "${1:-}" in
    core) echo "6.9.4" ;;
    eval) echo "$root/wp-content/uploads" ;;
    *)    exit 1 ;;
esac
EOS
chmod +x "$STUB/wp"

HOMES="$TMP/homes"
# A: ordinary install, no wp-cli.yml anywhere
mkdir -p "$HOMES/a/public_html/wp-content/uploads"
: > "$HOMES/a/public_html/wp-config.php"; : > "$HOMES/a/public_html/wp-load.php"
# B: wp-config.php moved one level ABOVE the WordPress root (WordPress supports
#    this and it is widely recommended; searching for wp-config.php alone lands
#    on a directory wp-cli can do nothing with)
mkdir -p "$HOMES/b/public_html/wp-content/uploads"
: > "$HOMES/b/wp-config.php"; : > "$HOMES/b/public_html/wp-load.php"
# C: project root with wp-cli.yml pointing at core nested below the docroot
mkdir -p "$HOMES/c/public_html/wordpress/wp-content/uploads"
printf 'path: public_html/wordpress\n' > "$HOMES/c/wp-cli.yml"
: > "$HOMES/c/public_html/wp-config.php"; : > "$HOMES/c/public_html/wordpress/wp-load.php"

probe()      { OUT="$(HOME="$1" PATH="$STUB:$PATH" bash "$PROBE" 2>&1)"; }
probe_dirs() { printf '%s\n' "$OUT" | awk -F'\t' '/^OK/{print $3}'; }
probe_has()  { probe_dirs | grep -qx "$1"; }

probe "$HOMES/a"
assert_eq "$(probe_dirs)" "$HOMES/a/public_html" \
          "finds a plain install with no wp-cli.yml"

probe "$HOMES/b"
if probe_has "$HOMES/b/public_html"; then
    ok "finds the root when wp-config.php sits above it"
else
    bad "finds the root when wp-config.php sits above it (got: $(probe_dirs | tr '\n' ' '))"
fi

probe "$HOMES/c"
if probe_has "$HOMES/c"; then
    ok "offers the project root when wp-cli.yml points at nested core"
else
    bad "offers the project root when wp-cli.yml points at nested core"
fi

# A directory with no WordPress in it must yield nothing at all.
mkdir -p "$HOMES/empty/notes"
probe "$HOMES/empty"
assert_eq "$(probe_dirs)" "" "reports nothing when there is no WordPress"

# ── database ────────────────────────────────────────────────────────────────
group "database"

run pre
assert_rc 0 "pre run succeeds"
GZ="$(find "$BACKUPS" -type f -name "$SITE-db-pre-update-*.sql.gz" 2>/dev/null | head -1)"
if [ -n "$GZ" ]; then
    ok "writes a labelled .sql.gz"
    if gzip -t "$GZ" 2>/dev/null; then ok "the gzip is valid"; else bad "the gzip is valid"; fi
    assert_eq "$(dirname "$GZ")" "$DEST" "lands in <root>/<year>/<month>/<site>"
else
    bad "writes a labelled .sql.gz"
fi
assert_file "$SQL_DIR/latest.sql" "drops latest.sql in the project"
assert_eq "$(tail -1 "$SQL_DIR/latest.sql" | cut -c1-17)" "-- Dump completed" \
          "latest.sql holds a complete dump"

BEFORE="$(find "$BACKUPS" -type f | wc -l | tr -d ' ')"
run db -n
assert_rc 0 "dry run succeeds"
assert_eq "$(find "$BACKUPS" -type f | wc -l | tr -d ' ')" "$BEFORE" "dry run writes nothing"

# a short dump must be refused rather than saved as a good backup
printf '#!/usr/bin/env bash\necho tiny | gzip\n' > "$STUB/ssh"; chmod +x "$STUB/ssh"
run db
assert_rc 1 "a truncated dump is refused"
assert_has "treating that as a failure" "...with a clear reason"
assert_eq "$(parts)" "0" "no .part files left behind"
write_ssh_stub

# ── uploads ─────────────────────────────────────────────────────────────────
group "uploads"

run uploads
assert_rc 0 "first sync into an empty folder needs no confirmation"
assert_file "$UPLOADS/2026/01/hero.jpg" "pulls files down"
assert_file "$CONFIG/backup-wp/$SITE.mirrored" "records that the mirror exists"

rm -f "$CONFIG/backup-wp/$SITE.mirrored"
run uploads
assert_rc 1 "without the marker, deletions need confirming"
assert_has "no terminal to confirm on" "...and says so cleanly"
assert_has "--force" "...and points at the way forward"

run uploads --force
assert_rc 0 "--force proceeds without asking"

# A local-only file must be moved aside, not destroyed, when the mirror runs.
mkdir -p "$UPLOADS/2019/09"
echo "irreplaceable" > "$UPLOADS/2019/09/local-only.jpg"
run uploads
assert_rc 0 "sync with a local-only file succeeds"
assert_has "moved aside" "reports what it moved aside"
RESCUED="$(find "$BACKUPS" -type d -name 'rescued-*' | head -1)"
if [ -n "$RESCUED" ] && [ -f "$RESCUED/2019/09/local-only.jpg" ]; then
    ok "rescues the local-only file, preserving its path"
else
    bad "rescues the local-only file, preserving its path"
fi
assert_eq "$(cat "$RESCUED/2019/09/local-only.jpg" 2>/dev/null)" "irreplaceable" \
          "the rescued copy still has its contents"
assert_eq "$(find "$UPLOADS" -name local-only.jpg | wc -l | tr -d ' ')" "0" \
          "and the mirror itself is exact afterwards"

# --no-rescue means what it says
mkdir -p "$UPLOADS/2019/09"
echo "expendable" > "$UPLOADS/2019/09/local-only.jpg"
before_rescues="$(find "$BACKUPS" -type d -name 'rescued-*' | wc -l | tr -d ' ')"
run uploads --no-rescue
assert_rc 0 "--no-rescue succeeds"
assert_eq "$(find "$BACKUPS" -type d -name 'rescued-*' | wc -l | tr -d ' ')" \
          "$before_rescues" "--no-rescue creates no rescue folder"

# rescued files must be immune to retention, whatever they are called
mkdir -p "$RESCUED"
: > "$RESCUED/$SITE-db-2020-01-01-000000.sql.gz"
KEEP=1 run db
assert_file "$RESCUED/$SITE-db-2020-01-01-000000.sql.gz" \
            "retention cannot reach inside a rescue folder"

run uploads --archive
assert_rc 0 "archive run succeeds"
TAR="$(find "$BACKUPS" -type f -name "$SITE-uploads-*.tar.zst" 2>/dev/null | head -1)"
if [ -n "$TAR" ]; then
    ok "builds a .tar.zst"
    if zstd -t "$TAR" >/dev/null 2>&1; then ok "the archive verifies"; else bad "the archive verifies"; fi
    if zstd -dc "$TAR" 2>/dev/null | tar -tf - 2>/dev/null | grep -q "uploads/2026/01/hero.jpg"; then
        ok "the archive contains the media"
    else
        bad "the archive contains the media"
    fi
else
    bad "builds a .tar.zst"
fi

# `post` is the one action that archives without being asked, and --no-archive
# has to win over that default whichever side of the action it is given on.
run post -n
assert_has ".tar.zst" "post archives without --archive"

for args in "post -n --no-archive" "--no-archive post -n"; do
    # shellcheck disable=SC2086  # deliberate word splitting: these are argv
    run $args
    # The exit status matters here: without it a run that died on "unknown
    # option: --no-archive" would pass this by printing no archive at all.
    assert_rc 0 "--no-archive is accepted ($args)"
    case "$OUT" in
        *.tar.zst*) bad "--no-archive turns post's archive back off ($args)" ;;
        *)          ok  "--no-archive turns post's archive back off ($args)" ;;
    esac
done

run uploads -n
case "$OUT" in
    *.tar.zst*) bad "the other actions still archive only on request" ;;
    *)          ok  "the other actions still archive only on request" ;;
esac

# ── plugins ─────────────────────────────────────────────────────────────────
group "plugins"

# composer.json owns "in-composer"; "server-only" is nobody's but the server's
cat > "$SITE_DIR/composer.json" <<'EOS'
{
  "require": {
    "php": ">=8.2",
    "wpackagist-plugin/in-composer": "^1.0",
    "vendor/unrelated-library": "^2.0"
  }
}
EOS

: > "$TMP/updated.log"
run plugins
assert_rc 0 "plugins lists without touching anything"
assert_has "in-composer" "shows a plugin Composer owns"
assert_has "composer"    "...labelled as Composer's"
assert_has "server-only" "shows a plugin the server owns"
assert_has "--update"    "says how to apply them"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" \
          "listing updates nothing"
case "$OUT" in
    *up-to-date*) bad "hides plugins that are genuinely current" ;;
    *)            ok  "hides plugins that are genuinely current" ;;
esac

# Licensed plugins register their update checker inside is_admin(), so the
# listing has to run with WP_ADMIN defined or their updates stay invisible.
assert_eq "$(head -1 "$TMP/context.log")" "admin" "asks in admin context first"
assert_has "premium-thing" "finds a licensed plugin's update"
assert_has "5.1"           "...with the version it would move to"
case "$OUT" in
    *mu-plugins*) bad "ignores the must-use pseudo-entry" ;;
    *)            ok  "ignores the must-use pseudo-entry" ;;
esac

: > "$TMP/updated.log"
run plugins --update
assert_eq "$(sort "$TMP/updated.log" | tr '\n' ' ')" "premium-thing server-only " \
          "--update covers the licensed plugin too"

# --update=<name> narrows to one plugin, leaving the rest alone
: > "$TMP/updated.log"
run plugins --update=server-only
assert_rc 0 "--update=<name> succeeds"
assert_eq "$(cat "$TMP/updated.log")" "server-only" "...updating only that plugin"

: > "$TMP/updated.log"
run plugins --update=server-only,premium-thing
assert_rc 0 "--update accepts a comma-separated list"
assert_eq "$(sort "$TMP/updated.log" | tr '\n' ' ')" "premium-thing server-only " \
          "...updating each one named"

# A typo must stop the run, not silently update nothing and look successful
: > "$TMP/updated.log"
run plugins --update=no-such-plugin
assert_rc 1 "an unknown plugin name is refused"
assert_has "not a server-managed plugin" "...with a clear reason"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...having updated nothing"

: > "$TMP/updated.log"
run plugins --update=in-composer
assert_rc 1 "naming a Composer-managed plugin is refused"
assert_has "Composer-managed" "...explaining who owns it"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...having updated nothing"

# If admin context cannot be loaded, fall back rather than fail — and say so,
# because the fallback is exactly the case that hides licensed updates.
: > "$TMP/context.log"
STUB_ADMIN_FAILS=1 run plugins
assert_rc 0 "survives admin context failing"
assert_eq "$(sort -u "$TMP/context.log" | tr '\n' ' ')" "admin plain " \
          "...by retrying without it"
assert_has "could not load admin context" "...and warns that updates may be hidden"
assert_has "no updater" "...marking the licensed plugin as unreported"

: > "$TMP/updated.log"
run plugins --update -n
assert_rc 0 "plugins --update -n succeeds"
assert_has "would update server-only" "dry run names what it would do"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" \
          "dry run updates nothing"

: > "$TMP/updated.log"
run plugins --update
assert_rc 0 "plugins --update succeeds"
assert_eq "$(sort "$TMP/updated.log" | tr '\n' ' ')" "premium-thing server-only " \
          "updates only the plugins Composer does not own"

# With no composer.json, nothing is Composer's and everything is fair game
mv "$SITE_DIR/composer.json" "$TMP/composer.json.bak"
: > "$TMP/updated.log"
run plugins --update
assert_rc 0 "works on a site with no composer.json"
assert_eq "$(sort "$TMP/updated.log" | tr '\n' ' ')" "in-composer premium-thing server-only " \
          "...where every pending update is fair game"
mv "$TMP/composer.json.bak" "$SITE_DIR/composer.json"

# ── held plugins ────────────────────────────────────────────────────────────
group "held plugins"

# Rewrite HOLD_PLUGINS in place, the way a human editing the config would.
# Under the same umask the script uses, or this leaves a world-readable config
# behind and the later check that dumps and configs stay private fails on the
# harness's doing rather than the script's.
set_hold() {
    ( umask 077; grep -v '^HOLD_PLUGINS=' "$CONF" > "$CONF.new" ) || true
    printf 'HOLD_PLUGINS="%s"\n' "$1" >> "$CONF.new"
    mv "$CONF.new" "$CONF"
}

if grep -q '^HOLD_PLUGINS=' "$CONF"; then
    ok "setup writes HOLD_PLUGINS into the config"
else
    bad "setup writes HOLD_PLUGINS into the config"
fi

set_hold "server-only"
: > "$TMP/updated.log"
run plugins
assert_rc 0 "plugins lists with a plugin held"
assert_has "held" "a held plugin with an update says so"
assert_has "HOLD_PLUGINS" "...and names the setting that holds it"

: > "$TMP/updated.log"
run plugins --update
assert_rc 0 "--update runs with a plugin held"
assert_eq "$(sort "$TMP/updated.log" | tr '\n' ' ')" "premium-thing " \
          "...passing over the held one"

# Naming a held plugin explicitly must not override the hold: silently
# updating it would make the setting worthless, and silently skipping it would
# look like success.
: > "$TMP/updated.log"
run plugins --update=server-only
assert_rc 1 "naming a held plugin is refused"
assert_has "is held on $SITE" "...saying what holds it"
assert_has "--unhold=server-only" "...and how to release it"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...having updated nothing"

# Commas, because --update=a,b takes them
set_hold "server-only,premium-thing"
: > "$TMP/updated.log"
run plugins --update
assert_rc 0 "a comma-separated hold list parses"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...holding both plugins"
assert_has "everything with a pending update is held" \
          "...and says why nothing was updated"

# A held plugin nobody has heard from must not be nagged about: "no updater"
# exists to send you off to update by hand, which is not advice to give about
# a plugin you have said to leave alone.
set_hold "premium-thing"
STUB_ADMIN_FAILS=1 run plugins
assert_rc 0 "listing survives with a silent plugin held"
case "$OUT" in
    *"no updater"*) bad "a held plugin is not reported as unchecked" ;;
    *)              ok  "a held plugin is not reported as unchecked" ;;
esac

# A `*` would otherwise be split into a glob and hold the working directory's
# contents, so it has to be refused rather than obeyed.
set_hold "*"
: > "$TMP/updated.log"
run plugins --update
assert_rc 1 "a hold entry that is not a plugin name is refused"
assert_has "not a plugin name" "...with a clear reason"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...having updated nothing"

# ...but it is only the plugins command's business. A backup must not stop
# because of a typo in a setting it never reads.
run db
assert_rc 0 "a broken hold list does not stop a backup"

# The list is hand-written, so rediscovery has to carry it over
set_hold "server-only premium-thing"
run --setup --host stub-host
assert_rc 0 "--setup succeeds with plugins held"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only premium-thing" \
          "--setup keeps the hold list it did not discover"

set_hold ""

# ── --hold / --unhold ───────────────────────────────────────────────────────
group "holding from the command line"

: > "$TMP/updated.log"
run plugins --hold=server-only
assert_rc 0 "--hold succeeds"
assert_has "holding server-only" "...saying what it did"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only" "...and writing it to the config"
assert_has "held" "the listing already shows the new hold"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" "...updating nothing on the way"

# The whole point of the flag over hand-editing: a name that is not installed
# would sit in the config holding nothing at all.
run plugins --hold=no-such-plugin
assert_rc 1 "holding a plugin that is not installed is refused"
assert_has "no plugin named no-such-plugin" "...with a clear reason"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only" "...leaving the list as it was"

run plugins --hold=server-only
assert_rc 0 "holding an already-held plugin is not an error"
assert_has "already held" "...but says so"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only" "...without listing it twice"

# Adding one must not drop the other
run plugins --hold=premium-thing
assert_rc 0 "a second --hold succeeds"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only premium-thing" "...and joins the first"

run plugins --unhold=server-only
assert_rc 0 "--unhold succeeds"
assert_has "released server-only" "...saying what it did"
assert_eq "$(conf_get HOLD_PLUGINS)" "premium-thing" "...leaving the other held"

run plugins --unhold=server-only
assert_rc 1 "releasing a plugin that is not held is refused"
assert_has "is not held" "...rather than quietly doing nothing"

: > "$TMP/updated.log"
run plugins --hold=server-only -n
assert_rc 0 "--hold -n succeeds"
assert_has "would save" "dry run says what it would write"
assert_eq "$(conf_get HOLD_PLUGINS)" "premium-thing" "dry run writes no config"

# Held in the same run it updates: the hold has to land before the update does
: > "$TMP/updated.log"
run plugins --hold=server-only --update
assert_rc 0 "--hold and --update together succeed"
assert_eq "$(wc -l < "$TMP/updated.log" | tr -d ' ')" "0" \
          "...holding the plugin before --update reaches it"

run plugins --unhold=server-only,premium-thing
assert_rc 0 "--unhold takes a comma-separated list"
assert_eq "$(conf_get HOLD_PLUGINS)" "" "...releasing every name in it"

# The rest of the file has to survive being rewritten
assert_eq "$(conf_get SSH_HOST)" "stub-host" "editing the hold list leaves the config intact"
if grep -q '^# backup-wp — ' "$CONF"; then
    ok "...comments included"
else
    bad "...comments included"
fi

# Naming a plugin to hold is not a reason to run a backup
run db --hold=server-only
assert_rc 1 "--hold with another action is refused"
assert_has "belong to \`plugins\`" "...saying where it belongs"
run --hold
assert_rc 1 "a bare --hold is refused"
assert_has "takes the name with it" "...pointing at the right spelling"

# ...but with no action word at all, --hold implies `plugins` and stops there.
# Falling through to the `all` default would dump a database and mirror the
# uploads as a side effect of changing one setting.
#
# Counting files in the backup tree would not prove this: by now it is at its
# retention cap, so a stray snapshot is written and immediately trimmed back to
# the same number. Watch for the work itself instead — the step the dump prints
# and a call reaching the rsync stub, neither of which `plugins` ever produces.
: > "$TMP/hold-rsync.log"
STUB_RSYNC_LOG="$TMP/hold-rsync.log" run --hold=server-only
assert_rc 0 "--hold with no action given succeeds"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only" "...saving the hold"
case "$OUT" in
    *"==> Database"*) bad "...and dumping no database while it is at it" ;;
    *)                ok  "...and dumping no database while it is at it" ;;
esac
assert_eq "$(wc -l < "$TMP/hold-rsync.log" | tr -d ' ')" "0" "...and mirroring nothing"
run --unhold=server-only
assert_rc 0 "--unhold with no action given succeeds"
assert_eq "$(conf_get HOLD_PLUGINS)" "" "...releasing it again"

# A config too old to have the line still gets one
( umask 077; grep -v '^HOLD_PLUGINS=' "$CONF" > "$CONF.old" ) && mv "$CONF.old" "$CONF"
run plugins --hold=server-only
assert_rc 0 "--hold works on a config written before the setting existed"
assert_eq "$(conf_get HOLD_PLUGINS)" "server-only" "...adding the line"

# The rewrite replaces the file, so it is a fresh chance to leak a config full
# of hostnames and paths to everyone on the machine.
assert_eq "$(modestr "$CONF")" "-rw-------" "a rewritten config is still private"
run plugins --unhold=server-only

# ── retention ───────────────────────────────────────────────────────────────
group "retention"

rm -f "$DEST"/*.sql.gz
for s in 2020-01-01 2020-01-02 2020-01-03 2020-01-04; do
    : > "$DEST/$SITE-db-$s-000000.sql.gz"
done

# decoys: matching names in the wrong place, plus a directory and a foreign name
mkdir -p "$BACKUPS/manual" "$BACKUPS/keep/deep" "$DEST/$SITE-db-2019-01-04-000000.sql.gz"
: > "$BACKUPS/manual/$SITE-db-2019-01-01-000000.sql.gz"
: > "$BACKUPS/keep/deep/$SITE-db-2019-01-02-000000.sql.gz"
: > "$BACKUPS/$SITE-db-2019-01-03-000000.sql.gz"
: > "$DEST/notes.txt"
: > "$DEST/manual-export.sql.gz"

KEEP=2 run db
assert_rc 0 "run with KEEP=2 succeeds"
assert_eq "$(managed)" "2" "trims managed snapshots to KEEP"
assert_file "$BACKUPS/manual/$SITE-db-2019-01-01-000000.sql.gz"    "spares a manual/ subfolder"
assert_file "$BACKUPS/keep/deep/$SITE-db-2019-01-02-000000.sql.gz" "spares a nested folder"
assert_file "$BACKUPS/$SITE-db-2019-01-03-000000.sql.gz"           "spares the backup root"
assert_file "$DEST/notes.txt"                                      "spares unrelated files"
assert_file "$DEST/manual-export.sql.gz"                           "spares foreign names"
assert_dir  "$DEST/$SITE-db-2019-01-04-000000.sql.gz"              "spares matching directories"

# The label sits in front of the date, so sorting on the whole name would rank
# every pre-update snapshot above every unlabelled one and trim the newest
# backups to keep years-old ones. Age comes from the stamp on the end.
find "$DEST" -maxdepth 1 -type f -name '*.sql.gz' -exec rm -f {} +
: > "$DEST/$SITE-db-pre-update-2020-01-01-000000.sql.gz"
: > "$DEST/$SITE-db-post-update-2020-01-02-000000.sql.gz"
: > "$DEST/$SITE-db-2021-01-01-000000.sql.gz"
KEEP=2 run db
assert_eq "$(managed)" "2" "trims a mix of labelled and unlabelled to KEEP"
assert_file "$DEST/$SITE-db-2021-01-01-000000.sql.gz" \
            "keeps the newest snapshot whatever it is labelled"
assert_gone "$DEST/$SITE-db-pre-update-2020-01-01-000000.sql.gz" \
            "...and drops the oldest, label or no label"

# Names written before the rename carry no readable stamp. They must still be
# reachable by retention, and they are the oldest thing here.
find "$DEST" -maxdepth 1 -type f -name '*.sql.gz' -exec rm -f {} +
: > "$DEST/$SITE-db-20200101-000000-pre.sql.gz"
: > "$DEST/$SITE-db-2021-01-01-000000.sql.gz"
KEEP=2 run db
assert_gone "$DEST/$SITE-db-20200101-000000-pre.sql.gz" "trims an old-style name first"
assert_file "$DEST/$SITE-db-2021-01-01-000000.sql.gz"   "...before anything newer"

# --no-prune must leave even the oldest alone
for s in 2020-01-01 2020-01-02 2020-01-03 2020-01-04; do
    : > "$DEST/$SITE-db-$s-000000.sql.gz"
done
KEEP=2 run db --no-prune
assert_rc 0 "--no-prune succeeds"
assert_file "$DEST/$SITE-db-2020-01-01-000000.sql.gz" "--no-prune spares the oldest"

# ── what it refuses ─────────────────────────────────────────────────────────
# Discovery believes what the server tells it, and the uploads path it hears
# back is wp_upload_dir()'s basedir — which WordPress reads from the
# `upload_path` option, a row in the database. On a site that has been got at,
# that string is the attacker's to write, and it used to be copied verbatim
# into a config file this script sources on every later run.
group "trust boundaries"

HOSTILE="$SITES/hostile-site"
mkdir -p "$HOSTILE/public_html/uploads"
: > "$HOSTILE/wp-cli.yml"
HOSTILE_CONF="$CONFIG/backup-wp/hostile-site.conf"

PWNED="$TMP/pwned-by-server"
rm -f "$PWNED"
RUN_DIR="$HOSTILE" STUB_WP="/home/user/wp" \
    STUB_UPLOADS="/home/user/wp/uploads\"; touch \"$PWNED\"; :\"" \
    run db --host stub-host
assert_rc 1 "refuses a remote path that would break out of the config file"
assert_gone "$HOSTILE_CONF" "...writing no config at all"
# The payload fires when the config is sourced, so run again without --host:
# whatever setup left behind is what a later run would read.
RUN_DIR="$HOSTILE" run db
assert_gone "$PWNED" "...so nothing the server sent ever runs on this machine"

# The same answer aimed at the mirror instead: `..` in the remote uploads path
# is subtracted from the local one, which would point `rsync --delete` at some
# ancestor of the project.
RUN_DIR="$HOSTILE" STUB_WP="/home/user/wp" \
    STUB_UPLOADS="/home/user/wp/wp-content/uploads/../../../../.." \
    run uploads --host stub-host
assert_rc 1 "refuses a remote uploads path that climbs out with .."
# Assert the reason too: without a terminal this run stops at the first-mirror
# confirmation anyway, and would otherwise look like a pass on either code.
assert_has "will not put in a shell command" "...for that reason and not the prompt"
assert_gone "$HOSTILE_CONF" "...writing no config for it either"

# ssh and rsync both read a leading dash as an option, and -oProxyCommand runs
# a command of the caller's choosing.
RUN_DIR="$HOSTILE" run db --host "-oProxyCommand=touch $TMP/proxied"
assert_rc 1 "refuses an ssh host that ssh would read as an option"
assert_has "not a usable ssh target" "...saying what it wanted instead"

# Local paths get no allowlist — a directory on this machine may legitimately
# be called anything — so they have to come back out of the config intact.
# shellcheck disable=SC2016  # not expanding here is the entire point: these
# have to reach the config as literal characters in a directory name
ODD='odd $(id) "site" `hostname`'
mkdir -p "$SITES/$ODD"
: > "$SITES/$ODD/wp-cli.yml"
run "$ODD" db --host stub-host
assert_rc 0 "sets up a project whose path is full of shell metacharacters"
ODD_BACK="$(bash -c '. "$1"; printf %s "$SITE_DIR"' _ "$CONFIG/backup-wp/$ODD.conf" 2>/dev/null)"
assert_eq "$ODD_BACK" "$SITES/$ODD" "...and that path survives the config unchanged"

# The site key is a filename in the config directory and the leading half of
# every retention pattern: `*` there widens `find -name` until it matches other
# sites' snapshots, and `..` writes the config outside the config directory.
mkdir -p "$SITES/"'*' "$TMP/outside"
run '*' db
assert_rc 1 "a site key of * is refused"
assert_has "cannot contain" "...naming the characters it will not take"
run ../outside db --host stub-host   # --host, or it stops at the setup prompt
assert_rc 1 "a site key that walks up out of the config directory is refused"
assert_gone "$CONFIG/backup-wp/../outside.conf" "...leaving nothing behind where it pointed"

# A config written before any of these checks existed has never been vetted.
# Sourcing it has already happened by the time we look, but the rsync it aims
# is still ours to refuse.
cat > "$CONFIG/backup-wp/legacy.conf" <<EOF
SITE_DIR="$SITE_DIR"
SSH_HOST="stub-host"
REMOTE_WP="/home/user/wp"
REMOTE_UPLOADS="/home/user/wp/uploads/../../.."
LOCAL_UPLOADS="$UPLOADS"
EOF
run legacy uploads
assert_rc 1 "refuses a stale config whose remote path climbs out"
assert_has "will not put in a shell command" "...before it gets anywhere near rsync"

# The mirror is the one command here that deletes, so its destination is
# checked rather than trusted.
sed 's|^REMOTE_UPLOADS=.*|REMOTE_UPLOADS="/home/user/wp/uploads"|; s|^LOCAL_UPLOADS=.*|LOCAL_UPLOADS=""|' \
    "$CONFIG/backup-wp/legacy.conf" > "$CONFIG/backup-wp/nodest.conf"
run nodest uploads
assert_rc 1 "refuses to mirror when the config names no destination"
assert_has "no destination" "...saying which setting is missing"

mkdir -p "$TMP/fakehome"
sed "s|^LOCAL_UPLOADS=.*|LOCAL_UPLOADS=\"$TMP/fakehome\"|" \
    "$CONFIG/backup-wp/nodest.conf" > "$CONFIG/backup-wp/homedest.conf"
RUN_HOME="$TMP/fakehome" run homedest uploads
assert_rc 1 "refuses to mirror straight over a home directory"

# A symlink arriving from the server that points out of the tree is dropped,
# not recreated here. wp-content/uploads is the most routinely compromised
# corner of a WordPress site and this is a pull onto a laptop.
: > "$TMP/rsync-args.log"
STUB_RSYNC_LOG="$TMP/rsync-args.log" run uploads --force
if grep -q -- '--safe-links' "$TMP/rsync-args.log"; then
    ok "the mirror will not follow a symlink out of the uploads tree"
else
    bad "the mirror will not follow a symlink out of the uploads tree"
fi

# ── file modes ──────────────────────────────────────────────────────────────
group "what the dump is readable by"

# A dump is every password hash, email address and API key the site holds. The
# default umask would hand it to anyone else with an account on this machine,
# and the .part it is assembled in has an entirely predictable name.
run db
# unlabelled names only: `db` writes one of those, and a `pre-update-` name
# would sort above every one of them.
LAST_GZ="$(find "$DEST" -maxdepth 1 -type f -name "$SITE-db-[0-9]*.sql.gz" | sort | tail -1)"
assert_eq "$(modestr "$LAST_GZ")" "-rw-------" "the compressed dump is readable only by its owner"
assert_eq "$(modestr "$SQL_DIR/$(basename "$LAST_GZ" .sql.gz).sql")" "-rw-------" \
          "...and so is the plain .sql beside the project"
assert_eq "$(modestr "$CONF")" "-rw-------" "the config is private"
assert_eq "$(modestr "$CONFIG/backup-wp")" "drwx------" "...as is the directory holding every site's"

# The mirror is the deliberate exception: it is public website media, and a
# local web server may need to read it.
FRESH="$SITES/fresh-mirror"
mkdir -p "$FRESH/public_html"
: > "$FRESH/wp-cli.yml"
( umask 022
  RUN_DIR="$FRESH" STUB_WP="/home/user/fresh" \
      STUB_UPLOADS="/home/user/fresh/public_html/uploads" \
      run uploads --host stub-host --force )
assert_eq "$(modestr "$FRESH/public_html/uploads")" "drwxr-xr-x" \
          "the mirror keeps the umask you already had"

# ── plugin names are names, not patterns ────────────────────────────────────
group "plugin name matching"

# `.` is legal in a plugin directory name. Matched as a regular expression,
# `wp.rocket` matches the Composer package `wp-rocket` — so a server-managed
# plugin gets filed as Composer's and is then never updated.
cp "$SITE_DIR/composer.json" "$TMP/composer.json.keep"
cat > "$SITE_DIR/composer.json" <<'EOS'
{ "require": { "wpackagist-plugin/wp-rocket": "^3.0" } }
EOS
: > "$TMP/updated.log"
STUB_DOTTED_PLUGIN=1 run plugins --update
assert_rc 0 "a plugin whose slug holds a dot is handled"
if grep -Fqx 'wp.rocket' "$TMP/updated.log"; then
    ok "...and is not mistaken for the Composer package it resembles"
else
    bad "...and is not mistaken for the Composer package it resembles"
fi
mv "$TMP/composer.json.keep" "$SITE_DIR/composer.json"

# ── result ──────────────────────────────────────────────────────────────────
printf '\n%s%d passed%s' "$GRN" "$PASS" "$RST"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAIL" "$RST"
printf '\n'
[ "$FAIL" -eq 0 ]
