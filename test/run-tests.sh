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

# ── hermetic environment ────────────────────────────────────────────────────
# Deliberately outside the repo: the script derives the site name from the git
# top level, so a temp dir nested here would resolve to this repo's name.
# cd/pwd normalises the path: macOS $TMPDIR carries a trailing slash, which
# would otherwise leave a doubled separator that the script quietly collapses.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/backup-wp-test.XXXXXX")" && pwd)"
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

# rsync stub: honours -n by reporting deletions instead of performing them.
cat > "$STUB/rsync" <<'EOS'
#!/usr/bin/env bash
dry=0
for a in "$@"; do
    [ "$a" = "-n" ] && dry=1
    dest="$a"
done
if [ "$dry" -eq 1 ]; then
    echo "deleting 2020/01/local-only.jpg"
    echo "Number of files: 3"
    exit 0
fi
mkdir -p "$dest/2026/01"
echo hero > "$dest/2026/01/hero.jpg"
echo logo > "$dest/2026/01/logo.png"
echo "Number of files: 2"
EOS
chmod +x "$STUB/rsync"

run() {   # run <args...> — sandboxed; override RUN_DIR / STUB_WP / STUB_UPLOADS
    OUT="$(cd "${RUN_DIR:-$SITE_DIR}" && env \
        PATH="$STUB:$PATH" \
        XDG_CONFIG_HOME="$CONFIG" \
        SITES_DIR="$SITES" \
        BACKUP_ROOT="$BACKUPS" \
        RSYNC="$STUB/rsync" \
        KEEP="${KEEP:-10}" \
        KEEP_SQL="${KEEP_SQL:-3}" \
        STUB_WP="${STUB_WP:-$WANT_WP}" \
        STUB_UPLOADS="${STUB_UPLOADS:-$WANT_UPLOADS}" \
        bash "$SCRIPT" "$@" 2>&1)"
    RC=$?
    # A `VAR=x run ...` prefix on a *function* persists after the call in bash,
    # unlike on an external command. Clear the overrides so each call is
    # independent and one test cannot silently reconfigure the next.
    unset RUN_DIR STUB_WP STUB_UPLOADS KEEP KEEP_SQL
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

# ── database ────────────────────────────────────────────────────────────────
group "database"

run pre
assert_rc 0 "pre run succeeds"
GZ="$(find "$BACKUPS" -type f -name "$SITE-db-*-pre.sql.gz" 2>/dev/null | head -1)"
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

# ── retention ───────────────────────────────────────────────────────────────
group "retention"

rm -f "$DEST"/*.sql.gz
for s in 20200101 20200102 20200103 20200104; do
    : > "$DEST/$SITE-db-$s-000000.sql.gz"
done

# decoys: matching names in the wrong place, plus a directory and a foreign name
mkdir -p "$BACKUPS/manual" "$BACKUPS/keep/deep" "$DEST/$SITE-db-20190104-000000.sql.gz"
: > "$BACKUPS/manual/$SITE-db-20190101-000000.sql.gz"
: > "$BACKUPS/keep/deep/$SITE-db-20190102-000000.sql.gz"
: > "$BACKUPS/$SITE-db-20190103-000000.sql.gz"
: > "$DEST/notes.txt"
: > "$DEST/manual-export.sql.gz"

KEEP=2 run db
assert_rc 0 "run with KEEP=2 succeeds"
assert_eq "$(managed)" "2" "trims managed snapshots to KEEP"
assert_file "$BACKUPS/manual/$SITE-db-20190101-000000.sql.gz"    "spares a manual/ subfolder"
assert_file "$BACKUPS/keep/deep/$SITE-db-20190102-000000.sql.gz" "spares a nested folder"
assert_file "$BACKUPS/$SITE-db-20190103-000000.sql.gz"           "spares the backup root"
assert_file "$DEST/notes.txt"                                    "spares unrelated files"
assert_file "$DEST/manual-export.sql.gz"                         "spares foreign names"
assert_dir  "$DEST/$SITE-db-20190104-000000.sql.gz"              "spares matching directories"

# --no-prune must leave even the oldest alone
for s in 20200101 20200102 20200103 20200104; do
    : > "$DEST/$SITE-db-$s-000000.sql.gz"
done
KEEP=2 run db --no-prune
assert_rc 0 "--no-prune succeeds"
assert_file "$DEST/$SITE-db-20200101-000000.sql.gz" "--no-prune spares the oldest"

# ── result ──────────────────────────────────────────────────────────────────
printf '\n%s%d passed%s' "$GRN" "$PASS" "$RST"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAIL" "$RST"
printf '\n'
[ "$FAIL" -eq 0 ]
