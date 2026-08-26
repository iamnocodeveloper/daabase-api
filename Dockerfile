# daabase API — todo-en-uno: Postgres 17 (wal_level=logical) + MinIO + motor InstantDB oficial + quota enforcement
# Réplica fiel de self-hosting pero en un solo contenedor para PaaS sin compose propio.

FROM ghcr.io/instantdb/server:latest AS instant

FROM debian:bookworm-slim

# JVM Corretto 26 desde la imagen oficial del servidor — detección automática del binario
COPY --from=instant /usr/lib/jvm /usr/lib/jvm
RUN set -eux; \
    JB="$(find /usr/lib/jvm -type f -name java -executable | head -n1)"; \
    test -n "$JB"; \
    JB_BIN="$(dirname "$JB")"; \
    for c in java keytool jar javac jcmd jstack; do \
      [ -f "$JB_BIN/$c" ] && ln -sf "$JB_BIN/$c" "/usr/local/bin/$c" || true; \
    done; \
    JAVA_HOME_REAL="$(dirname "$JB_BIN")"; \
    ln -sfn "$JAVA_HOME_REAL" /usr/lib/jvm/detected; \
    java -version

# Motor completo: jar, migraciones, resources y start.sh oficial (bootstrap OSS incluido)
COPY --from=instant /app /app
COPY --from=instant /usr/local/bin/migrate /usr/local/bin/migrate

# Object storage: binarios estáticos Go, corren en cualquier distro
COPY --from=minio/minio:latest /usr/bin/minio /usr/bin/minio
COPY --from=minio/mc /usr/bin/mc /usr/bin/mc

# Postgres 17 oficial (PGDG) con extensión lógica habilitada por config
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg supervisor procps nginx \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.gpg \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-17 postgresql-17-wal2json \
 && rm -rf /var/lib/apt/lists/* \
 && update-ca-certificates

COPY entrypoint.sh /entrypoint.sh
COPY quota/ /app/quota/
COPY restore-drill.sh /app/restore-drill.sh
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod +x /entrypoint.sh /app/quota/quota-check.sh /app/restore-drill.sh \
    && mkdir -p /data/pg /data/minio /data/logs /var/log/nginx \
    && chown -R postgres:postgres /data/pg

EXPOSE 8080 8888

CMD ["/entrypoint.sh"]
