#!/bin/bash
# Build two VPATH builds of ~/pg/src: perf (no cassert) and debug (cassert).
#   build.sh [perf|debug|all]
set -eu
cd ~/pg
what=${1:-all}
build_one() {
    name=$1; shift
    mkdir -p build-$name
    (cd build-$name && ../src/configure --prefix=$HOME/pg/inst-$name --enable-debug \
        --enable-injection-points --enable-tap-tests --enable-depend --with-lz4 --without-icu "$@" \
        > configure.log 2>&1)
    make -s -C build-$name -j8 > build-$name/make.log 2>&1
    make -s -C build-$name install > build-$name/install.log 2>&1
    make -s -C build-$name/contrib/pg_stat_statements install >> build-$name/install.log 2>&1
    make -s -C build-$name/src/test/modules/injection_points install >> build-$name/install.log 2>&1
    echo "$name: $(inst-$name/bin/postgres --version) built at $(date -Is)"
}
case $what in
    perf)  build_one perf ;;
    debug) build_one debug --enable-cassert ;;
    all)   build_one perf; build_one debug --enable-cassert ;;
esac
