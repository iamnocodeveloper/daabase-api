#!/bin/bash
# daabase restore drill — one-shot per container lifecycle
# Validates that the latest pg_dump backup can actually be restored.
# Runs once (marker /data/.restore-drill-done), logs to /data/logs/restore-drill.log.
# B1 / gate D2b.

MARKER=/data/.restore-drill-done
LOG=/data/logs/restore-drill.log

[ -f "$MARKER" ] && exit 0

mkdir -p /data/logs

{
  echo "=== RESTORE DRILL $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  LATEST=$(ls -1t /data/backups/*.dump 2>/dev/null | head -n1)
  if [ -z "$LATEST" ]; then
    echo "SKIP: no backups found in /data/backups"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP no-backups" > "$MARKER"
    exit 0
  fi

  SIZE=$(stat -c%s "$LATEST" 2>/dev/null || echo "?")
  echo "backup: $(basename "$LATEST") ($SIZE bytes)"

  # 1) Validate dump integrity without restoring
  if ! su postgres -c "pg_restore --list '$LATEST'" >/dev/null 2>&1; then
    echo "FAIL: pg_restore --list returned error for $LATEST"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL list-error" > "$MARKER"
    exit 1
  fi
  echo "OK: dump list is valid"

  # 2) Full restore into scratch database
  su postgres -c "dropdb --if-exists instant_restore_test" >/dev/null 2>&1
  if ! su postgres -c "createdb instant_restore_test" >/dev/null 2>&1; then
    echo "FAIL: could not create scratch db"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL createdb" > "$MARKER"
    exit 1
  fi

  if su postgres -c "pg_restore -d instant_restore_test -j 2 '$LATEST'" >/dev/null 2>&1; then
    SRC_APPS=$(su postgres -c "psql -tA -d instant -c 'SELECT count(*) FROM apps'" 2>/dev/null | xargs)
    DST_APPS=$(su postgres -c "psql -tA -d instant_restore_test -c 'SELECT count(*) FROM apps'" 2>/dev/null | xargs)
    SRC_TRIPLES=$(su postgres -c "psql -tA -d instant -c 'SELECT count(*) FROM triples'" 2>/dev/null | xargs)
    DST_TRIPLES=$(su postgres -c "psql -tA -d instant_restore_test -c 'SELECT count(*) FROM triples'" 2>/dev/null | xargs)
    echo "apps:     source=$SRC_APPS restored=$DST_APPS"
    echo "triples:  source=$SRC_TRIPLES restored=$DST_TRIPLES"
    if [ "$SRC_APPS" = "$DST_APPS" ] && [ "$SRC_TRIPLES" = "$DST_TRIPLES" ]; then
      echo "PASS: restore verified (apps=$DST_APPS triples=$DST_TRIPLES)"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) PASS apps=$DST_APPS triples=$DST_TRIPLES backup=$(basename "$LATEST")" > "$MARKER"
    else
      echo "FAIL: row count mismatch"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL mismatch apps=$SRC_APPS/$DST_APPS triples=$SRC_TRIPLES/$DST_TRIPLES" > "$MARKER"
    fi
  else
    echo "FAIL: pg_restore returned error"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL restore-error" > "$MARKER"
  fi

  su postgres -c "dropdb --if-exists instant_restore_test" >/dev/null 2>&1
} >> "$LOG" 2>&1

exit 0
