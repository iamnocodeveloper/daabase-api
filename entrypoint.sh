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

echo "== 1/5 PostgreSQL =="

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "initdb inicial..."
  chown -R postgres:postgres /data
  su postgres -c "$PGBIN/initdb -D $PGDATA -E UTF8 --auth-local=trust --auth-host=scram-sha-256"
  cat >> "$PGDATA/postgresql.conf" <<CONF
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
listen_addresses = '127.0.0.1'
CONF
fi

chown -R postgres:postgres /data/pg
su postgres -c "$PGBIN/pg_ctl -D $PGDATA -l /data/pg.log start -w"

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

echo "== 3/5 Bucket =="

mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing "local/$S3_BUCKET"

echo "== 4/5 Motor InstantDB (bootstrap + migraciones automáticas) =="

export DATABASE_URL="postgresql://postgres:${PG_PASSWORD}@127.0.0.1:5432/instant?sslmode=disable"
export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export S3_ENDPOINT="http://127.0.0.1:9000"
export S3_PUBLIC_ENDPOINT="${S3_PUBLIC_ENDPOINT:-}"
export JAVA_OPTS="${JAVA_OPTS:--Xmx1500m}"

cd /app

echo "== 5/5 Arrancando servidor en :8888 =="

trap 'kill $MINIO_PID 2>/dev/null || true; su postgres -c "$PGBIN/pg_ctl -D $PGDATA stop -m fast" || true' TERM INT
exec /app/start.sh
