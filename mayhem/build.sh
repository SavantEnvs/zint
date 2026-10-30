#!/usr/bin/env bash
#
# mayhem/build.sh — build zint's fuzz harnesses (sanitized, libFuzzer + standalone) and its own test
# suite (normal flags). Runs in the commit image as `mayhem` in /mayhem; needs no network.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`): an explicit empty SANITIZER_FLAGS builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The library, sanitized + SanCov-instrumented (fuzzer-no-link, unconditionally, so Mayhem sees
#    edges even with the empty sanitizer off-switch). Static, no PNG/Qt/frontend — as OSS-Fuzz builds it.
#    CMAKE_BUILD_TYPE is empty so cmake adds no -g of its own (it would follow, and could override,
#    -gdwarf-3); `build/` is gitignored upstream.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE= \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
    -DZINT_STATIC=ON -DZINT_SHARED=OFF -DZINT_USE_PNG=OFF -DZINT_USE_QT=OFF -DZINT_FRONTEND=OFF \
    -DZINT_USE_GS1SE=OFF -DZINT_UNINSTALL=OFF
cmake --build build -j"$MAYHEM_JOBS"

# 2) Harnesses (upstream's own backend/tests/fuzz/*.c), each linked twice: libFuzzer engine, and the
#    run-once standalone driver. LeakSanitizer is turned off at build time via lsan_off.cc.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
for h in fuzz_data fuzz_gs1; do
    $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -Ibackend \
        -c "backend/tests/fuzz/$h.c" -o "/tmp/$h.o"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "/tmp/$h.o" /tmp/lsan_off.o \
        build/backend/libzint.a -lm -o "/mayhem/$h"
    $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -Ibackend \
        -c "backend/tests/fuzz/$h.c" -o "/tmp/$h-sa.o"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o "/tmp/$h-sa.o" /tmp/lsan_off.o \
        build/backend/libzint.a -lm -o "/mayhem/$h-standalone"
done

# 3) The project's own test suite (+ the CLI for known-answer probes), NORMAL flags, no sanitizers.
#    Dynamically linked against libzint.so so test.sh's sabotage check can neuter it. `build-tests/`
#    is gitignored upstream (`build-*`).
env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
cmake -S . -B build-tests -G Ninja -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
    -DZINT_SHARED=ON -DZINT_STATIC=OFF -DZINT_TEST=ON -DZINT_USE_PNG=OFF -DZINT_USE_QT=OFF \
    -DZINT_FRONTEND=ON -DZINT_USE_GS1SE=OFF -DZINT_UNINSTALL=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
