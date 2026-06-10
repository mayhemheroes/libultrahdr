#!/usr/bin/env bash
#
# libultrahdr/mayhem/build.sh — build google/libultrahdr's OSS-Fuzz fuzz harnesses as sanitized
# libFuzzer targets (+ standalone run-once reproducers), AND a self-contained round-trip
# known-answer test for mayhem/test.sh. libultrahdr's own code AND its bundled libjpeg-turbo
# dependency are compiled with $SANITIZER_FLAGS so the fuzzed surface is fully instrumented.
#
# Fuzzed surface (matching OSS-Fuzz's fuzzer/ossfuzz.sh):
#   ultrahdr_dec_fuzzer    — UltraHDR (JPEG_R) DECODE path.
#   ultrahdr_enc_fuzzer    — UltraHDR (JPEG_R) ENCODE path.
#   ultrahdr_legacy_fuzzer — Legacy API encode/decode path (jpegr.h).
#
# Build contract from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). libultrahdr's CMake already links each fuzzer against $ENV{LIB_FUZZING_ENGINE}
# when UHDR_BUILD_FUZZERS=1, so we drive it with two configures sharing the source tree:
#   pass 1: LIB_FUZZING_ENGINE=-fsanitize=fuzzer    -> /mayhem/<fuzzer>            (libFuzzer)
#   pass 2: LIB_FUZZING_ENGINE=<standalone main .o> -> /mayhem/<fuzzer>-standalone (run-once)
# NB: with UHDR_BUILD_FUZZERS=1 the CMake force-enables UHDR_BUILD_DEPS=TRUE (it clones + builds
# libjpeg-turbo from source so the dep is instrumented too); network is available at build time.
# UHDR_MAX_DIMENSION=1280 caps allocations (matches OSS-Fuzz's fuzzer/ossfuzz.sh).
#
# Idempotent + air-gapped re-run (§6.5 / SPEC §6.2 item 9):
#   Build directories are NOT wiped on entry — cmake handles incremental builds. This means a
#   re-run inside the already-built image (network disabled) skips ExternalProject downloads
#   (stamps still present) and just re-links if needed. Never use `rm -rf $BUILD_DIR` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: DWARF-3 symbols for Mayhem triage (clang-19 default is DWARF-5; §6.2 item 10).
# Override via: DEBUG_FLAGS="-g -gdwarf-4" (or empty to suppress).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX MAYHEM_JOBS

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRC
cd "$SRC"

FUZZERS=(ultrahdr_dec_fuzzer ultrahdr_enc_fuzzer ultrahdr_legacy_fuzzer)

# ── Sync harness source files into upstream fuzzer/ (provenance copy in mayhem/harnesses/) ─────
for FUZZER in "${FUZZERS[@]}"; do
  cp "$SRC/mayhem/harnesses/${FUZZER}.cpp" "$SRC/fuzzer/${FUZZER}.cpp"
done

# Flags threaded into all fuzz/harness/standalone compiles and links:
#   $SANITIZER_FLAGS then $DEBUG_FLAGS (DWARF-3 symbols for Mayhem triage).
ALL_COMPILE_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DUHDR_BUILD_FUZZERS=1
  -DUHDR_BUILD_TESTS=0
  -DUHDR_BUILD_BENCHMARK=0
  -DUHDR_BUILD_EXAMPLES=0
  -DUHDR_ENABLE_INSTALL=0
  -DUHDR_MAX_DIMENSION=1280
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_C_FLAGS="$ALL_COMPILE_FLAGS"
  -DCMAKE_CXX_FLAGS="$ALL_COMPILE_FLAGS"
  # UHDR_BUILD_FUZZERS instruments every object (incl. the libimage_io dep) with
  # -fsanitize=fuzzer-no-link (SanitizerCoverage); make sure the sancov runtime is on every exe
  # link line regardless of SANITIZER_FLAGS, so an empty-SANITIZER_FLAGS (sanitizer-off) build links.
  -DCMAKE_EXE_LINKER_FLAGS=-fsanitize=fuzzer-no-link
)

# ── pass 1: libFuzzer targets ────────────────────────────────────────────────────────────────────
export LIB_FUZZING_ENGINE="-fsanitize=fuzzer"
BUILD_FUZZ="$SRC/mayhem-build-fuzz"
# Idempotent: only configure+build; never rm -rf the dir so ExternalProject stamps are preserved
# for air-gapped re-runs.
mkdir -p "$BUILD_FUZZ"
cmake -S "$SRC" -B "$BUILD_FUZZ" "${CMAKE_COMMON[@]}"
cmake --build "$BUILD_FUZZ" \
  --target ultrahdr_dec_fuzzer --target ultrahdr_enc_fuzzer --target ultrahdr_legacy_fuzzer \
  --parallel "$MAYHEM_JOBS"
for FUZZER in "${FUZZERS[@]}"; do
  bin="$(find "$BUILD_FUZZ" -maxdepth 3 -type f -name "$FUZZER" | head -1)"
  cp "$bin" "/mayhem/$FUZZER"
  echo "built libFuzzer target /mayhem/$FUZZER"
done

# ── pass 2: standalone reproducers ───────────────────────────────────────────────────────────────
# Re-link the SAME harnesses against the run-once standalone main (compiled as a C object) instead
# of libFuzzer, by pointing LIB_FUZZING_ENGINE at the object.
SA_OBJ="$SRC/mayhem-standalone-main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_OBJ"
# The standalone main replaces libFuzzer; the sancov runtime needed by the project's
# -fsanitize=fuzzer-no-link instrumentation comes from CMAKE_EXE_LINKER_FLAGS (set above), so
# LIB_FUZZING_ENGINE is just the object.
export LIB_FUZZING_ENGINE="$SA_OBJ"
BUILD_SA="$SRC/mayhem-build-standalone"
mkdir -p "$BUILD_SA"
cmake -S "$SRC" -B "$BUILD_SA" "${CMAKE_COMMON[@]}"
cmake --build "$BUILD_SA" \
  --target ultrahdr_dec_fuzzer --target ultrahdr_enc_fuzzer --target ultrahdr_legacy_fuzzer \
  --parallel "$MAYHEM_JOBS"
for FUZZER in "${FUZZERS[@]}"; do
  bin="$(find "$BUILD_SA" -maxdepth 3 -type f -name "$FUZZER" | head -1)"
  cp "$bin" "/mayhem/$FUZZER-standalone"
  echo "built standalone reproducer /mayhem/$FUZZER-standalone"
done

# ── test suite: build libultrahdr + the self-contained round-trip golden test with NORMAL flags ───
# (no sanitizers / no fuzzer instrumentation) so mayhem/test.sh is an honest PATCH oracle that only
# RUNS the prebuilt binary. Uses system libjpeg-dev (UHDR_BUILD_DEPS=0) so this build is
# air-gapped from the first run. Separate clean tree.
TBUILD="$SRC/mayhem-tests"
mkdir -p "$TBUILD"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TBUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DUHDR_BUILD_FUZZERS=0 \
    -DUHDR_BUILD_TESTS=0 \
    -DUHDR_BUILD_BENCHMARK=0 \
    -DUHDR_BUILD_EXAMPLES=0 \
    -DUHDR_ENABLE_INSTALL=0 \
    -DUHDR_BUILD_DEPS=1 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TBUILD" --target uhdr --parallel "$MAYHEM_JOBS"

# Locate the static libuhdr archive plus the bundled libjpeg-turbo archive (built from source under
# the tree when UHDR_BUILD_DEPS=1) — combine_static_libs does NOT fold the external jpeg .a into
# libuhdr.a, so the test must link both.
LIBUHDR="$(find "$TBUILD" -name 'libuhdr.a' | head -1)"
[ -f "$LIBUHDR" ] || { echo "ERROR: libuhdr.a not found in $TBUILD" >&2; exit 1; }
LIBJPEG="$(find "$TBUILD" -name 'libjpeg.a' -path '*turbojpeg*' | head -1)"
[ -n "$LIBJPEG" ] || LIBJPEG="$(find "$TBUILD" -name 'libjpeg.a' | head -1)"
[ -f "$LIBJPEG" ] || { echo "ERROR: libjpeg.a not found in $TBUILD" >&2; exit 1; }
echo "test libs: $LIBUHDR | $LIBJPEG"

env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX -O2 -std=c++17 -I"$SRC" \
    "$SRC/mayhem/harnesses/roundtrip_test.cpp" \
    "$LIBUHDR" "$LIBJPEG" -lm -lpthread \
    -o "$TBUILD/roundtrip_test"
echo "built round-trip golden test -> $TBUILD/roundtrip_test"

echo "build.sh complete:"
for FUZZER in "${FUZZERS[@]}"; do
  ls -la "/mayhem/$FUZZER" "/mayhem/$FUZZER-standalone" 2>&1 || true
done
