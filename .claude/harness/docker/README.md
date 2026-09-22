# Docker image of the shared-detoast build

Builds the `shared-detoast` branch of the fork from source (Debian bookworm,
`make world-bin`, so contrib extensions such as `pg_stat_statements` are
included; `--with-llvm` against LLVM 14, so `jit = on` works) and packages it with the official image's `docker-entrypoint.sh`,
so the usual environment variables and conventions apply: `POSTGRES_PASSWORD`,
`POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_INITDB_ARGS`, scripts in
`/docker-entrypoint-initdb.d/`, data volume at `/var/lib/postgresql/data`.

    docker build -t postgres-shared-detoast .claude/harness/docker
    docker run -d --name pgsd -e POSTGRES_PASSWORD=secret -p 5432:5432 postgres-shared-detoast
    psql "postgresql://postgres:secret@localhost:5432/postgres" -c 'SHOW shared_detoast'

`cat /usr/local/pgsql/GIT_REVISION` inside the container names the commit the
image was built from.  `--build-arg PG_REF=<branch-or-tag>` builds another ref
of the fork; `--build-arg PG_CONFIGURE="--enable-cassert --enable-debug"`
builds an assertion-enabled server for debugging (slower).

JIT is compiled in (LLVM 14) but this master branch defaults to `jit = off`
(upstream commit 7f8c88c2b87, September 2026), so switch it on per server
(`-c jit=on` after the image name), per database, or per session with
`SET jit = on`.  `EXPLAIN (ANALYZE)` prints a `JIT:` block only with costs shown.

The server is a development snapshot of PostgreSQL 20devel: no upgrade path,
no compatibility promise for data directories across rebuilds.  Switch the
feature off for A/B comparisons with `SET shared_detoast = off` or
`-c shared_detoast=off` on the container command line.
