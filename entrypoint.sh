#!/bin/bash
set -euo pipefail

: "${PG_PASSWORD:?Falta PG_PASSWORD}"
: "${MINIO_ROOT_USER:?Falta MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?Falta MINIO_ROOT_PASSWORD}"
: "${S3_BUCKET:=instant-bucket}"
: "${CONNECTION_POOL_SIZE:=20}"
: "${WAL_HISTORY_STORAGE:=pg}"

PGDATA=/data/pg
PGBIN=/usr/lib/postgresql/17/bin

# ---- Diagnóstico SSL a /data/logs/ssl-diag.txt (legible vía CLI) ----
mkdir -p /data/logs
{
  echo "== SSL DIAG $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  echo "JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS"
  echo "JAVA_OPTS=$JAVA_OPTS"
  echo "--- cacerts encontrados ---"
  find / -name "cacerts" -type f 2>/dev/null | while read f; do
    echo "$f ($(stat -c %s "$f" 2>/dev/null || echo '?') bytes)"
  done
  echo "--- bundle Debian ---"
  echo "/etc/ssl/certs/ca-certificates.crt: $(stat -c %s /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'no existe') bytes"
  echo "/etc/ssl/certs/java/cacerts: $(stat -c %s /etc/ssl/certs/java/cacerts 2>/dev/null || echo 'no existe') bytes"
} > /data/logs/ssl-diag.txt 2>&1

# ---- Reverse proxy (nginx): files.* -> MinIO :9000, resto -> motor :8888 ----
# Primera instrucción: el puerto 8080 debe escuchar en <1s para que el health
# check de la plataforma (que corre al arrancar el contenedor) no reporte "down".
nginx -g 'daemon off;' &
NGINX_PID=$!
echo "nginx en :8080 (pid $NGINX_PID)"

echo "== 1/5 PostgreSQL =="

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "initdb inicial..."
  chown -R postgres:postgres /data
  su postgres -c "$PGBIN/initdb -D $PGDATA -E UTF8 --auth-local=trust --auth-host=scram-sha-256"
fi

# Config idempotente: garantiza las claves en cada arranque
CONF="$PGDATA/postgresql.conf"
touch "$CONF"
ensure_conf() {
  if ! grep -qE "^$1\s*=" "$CONF"; then
    echo "$1 = '$2'" >> "$CONF"
  fi
}
ensure_conf "listen_addresses" "127.0.0.1"
ensure_conf "wal_level" "logical"
ensure_conf "max_replication_slots" "10"
ensure_conf "max_wal_senders" "10"
ensure_conf "output_plugin_libraries" "wal2json"

chown -R postgres:postgres /data/pg

if su postgres -c "$PGBIN/pg_ctl -D $PGDATA status" >/dev/null 2>&1; then
  echo "Postgres ya estaba corriendo"
else
  rm -f "$PGDATA/postmaster.pid"
  su postgres -c "$PGBIN/pg_ctl -D $PGDATA -l /data/pg.log start -w"
fi

su postgres -c "psql -qAt -c \"ALTER USER postgres PASSWORD '$PG_PASSWORD';\""
su postgres -c "psql -qAt -c \"SELECT 1 FROM pg_database WHERE datname='instant'\"" | grep -q 1 || \
  su postgres -c "psql -c 'CREATE DATABASE instant;'"

echo "== 2/5 MinIO =="

mkdir -p /data/minio
minio server /data/minio --address ":9000" --console-address ":9001" &
MINIO_PID=$!

for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null && break
  [ "$i" = 60 ] && { echo "MinIO no levantó"; exit 1; }
  sleep 1
done

echo "== 3/5 Buckets =="

mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing "local/$S3_BUCKET"
mc mb --ignore-existing "local/daabase-backups"

# ---- Restore drill: una vez por ciclo de contenedor (B1 / gate D2b) ----
/app/restore-drill.sh &
RESTORE_PID=$!

# ---- Backups programados: pg_dump cada 6h + copia a bucket + retención 48h ----
(
  sleep 90
  while true; do
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p /data/backups
    if su postgres -c "$PGBIN/pg_dump -Fc instant" > "/data/backups/instant-$ts.dump" 2>/dev/null \
       && [ -s "/data/backups/instant-$ts.dump" ]; then
      mc cp -q "/data/backups/instant-$ts.dump" "local/daabase-backups/" >/dev/null 2>&1 || true
      echo "backup ok: instant-$ts.dump"
    fi
    ls -1t /data/backups/*.dump 2>/dev/null | tail -n +9 | xargs -r rm -f
    mc rm --force --older-than 48h "local/daabase-backups/" >/dev/null 2>&1 || true
    sleep 21600
  done
) &

# ---- Quota enforcement: chequeo cada 5 min, toggle active/read-only ----
[ -f /app/quota/plans.yaml ] && [ ! -f /data/plans.yaml ] && cp /app/quota/plans.yaml /data/plans.yaml
(
  sleep 300  # esperar 5 min a que el motor llene triples_size_aggregate
  mkdir -p /data/logs
  while true; do
    /app/quota/quota-check.sh >> /data/logs/quota.log 2>&1
    sleep 300
  done
) &

echo "== 4/5 Motor InstantDB (bootstrap + migraciones automáticas) =="

export DATABASE_URL="postgresql://postgres:${PG_PASSWORD}@127.0.0.1:5432/instant?sslmode=disable"
export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export S3_ENDPOINT="http://127.0.0.1:9000"
export S3_PUBLIC_ENDPOINT="${S3_PUBLIC_ENDPOINT:-}"
export JAVA_OPTS="${JAVA_OPTS:--Xmx1500m}"
# El motor lee PORT del entorno; la plataforma inyecta PORT=<puerto contenedor> (8080),
# pero 8080 lo usa nginx. Forzamos el motor a 8888 (nginx enruta api.* -> 8888).
export PORT=8888

cd /app

echo "== 5/5 Arrancando servidor en :8888 =="

trap 'kill $NGINX_PID 2>/dev/null || true; kill $MINIO_PID 2>/dev/null || true; su postgres -c "$PGBIN/pg_ctl -D $PGDATA stop -m fast" || true' TERM INT
exec /app/start.sh
