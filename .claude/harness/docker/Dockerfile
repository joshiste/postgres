# PostgreSQL master with the shared-detoast series, packaged like the official
# image (same entrypoint, environment variables and init-script directory).
#
#   docker build -t postgres-shared-detoast .claude/harness/docker
#   docker run -d --name pgsd -e POSTGRES_PASSWORD=secret -p 5432:5432 postgres-shared-detoast
#
# Build arguments: PG_REPO / PG_REF select the tree to build (default: the
# series branch on the fork); PG_CONFIGURE adds configure options.

FROM debian:bookworm-slim AS build
ARG PG_REPO=https://github.com/joshiste/postgres.git
ARG PG_REF=shared-detoast
ARG PG_CONFIGURE=""
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential bison flex pkg-config \
        libreadline-dev zlib1g-dev libssl-dev libxml2-dev libxslt1-dev \
        liblz4-dev libzstd-dev libicu-dev uuid-dev \
        llvm-14-dev clang-14 \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${PG_REF}" "${PG_REPO}" /src
WORKDIR /build
RUN /src/configure --prefix=/usr/local/pgsql \
        --with-openssl --with-libxml --with-libxslt --with-lz4 --with-zstd \
        --with-icu --with-uuid=e2fs --with-system-tzdata=/usr/share/zoneinfo \
        --with-llvm LLVM_CONFIG=/usr/lib/llvm-14/bin/llvm-config CLANG=clang-14 \
        ${PG_CONFIGURE} > configure.log \
    && make -s -j"$(nproc)" world-bin \
    && make -s install-world-bin \
    && git -C /src rev-parse HEAD > /usr/local/pgsql/GIT_REVISION \
    && git -C /src log -1 --format=%s >> /usr/local/pgsql/GIT_REVISION \
    && sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/local/pgsql/share/postgresql.conf.sample

FROM debian:bookworm-slim
RUN groupadd -r postgres --gid=999 \
    && useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres \
    && mkdir -p /var/lib/postgresql && chown postgres:postgres /var/lib/postgresql
RUN apt-get update && apt-get install -y --no-install-recommends \
        libreadline8 zlib1g libssl3 libxml2 libxslt1.1 liblz4-1 libzstd1 \
        libicu72 libuuid1 libllvm14 locales tzdata gosu ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
COPY --from=build /usr/local/pgsql /usr/local/pgsql
ENV PATH=/usr/local/pgsql/bin:$PATH \
    LANG=en_US.utf8 \
    PG_MAJOR=20 \
    PGDATA=/var/lib/postgresql/data
RUN mkdir -p /var/run/postgresql && chown postgres:postgres /var/run/postgresql && chmod 3777 /var/run/postgresql \
    && mkdir -p /docker-entrypoint-initdb.d \
    && mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 1777 "$PGDATA"
COPY docker-entrypoint.sh docker-ensure-initdb.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-ensure-initdb.sh \
    && ln -sT docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh
VOLUME /var/lib/postgresql/data
ENTRYPOINT ["docker-entrypoint.sh"]
STOPSIGNAL SIGINT
EXPOSE 5432
CMD ["postgres"]
