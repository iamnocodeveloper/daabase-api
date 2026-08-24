# KooDB API — todo-en-uno: Postgres 17 (wal_level=logical) + MinIO + motor InstantDB oficial
# Réplica fiel de self-hosting pero en un solo contenedor para PaaS sin compose propio.

FROM ghcr.io/instantdb/server:latest AS instant

FROM debian:bookworm-slim

# JVM Corretto 26 desde la imagen oficial del servidor
COPY --from=instant /usr/lib/jvm /usr/lib/jvm
ENV JAVA_HOME=/usr/lib/jvm/java-26-amazon-corretto
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Motor completo: jar, migraciones, resources y start.sh oficial (bootstrap OSS incluido)
COPY --from=instant /app /app
COPY --from=instant /usr/local/bin/migrate /usr/local/bin/migrate

# Object storage: binarios estáticos Go, corren en cualquier distro
COPY --from=minio/minio:latest /usr/bin/minio /usr/bin/minio
COPY --from=minio/mc /usr/bin/mc /usr/bin/mc

# Postgres 17 oficial (PGDG) con extensión lógica habilitada por config
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg supervisor procps \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.gpg \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-17 \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /data/pg /data/minio && chown -R postgres:postgres /data/pg

EXPOSE 8888

CMD ["/entrypoint.sh"]
