#!/usr/bin/env bash
#
# libultrahdr/mayhem/test.sh — RUN libultrahdr's self-contained round-trip golden test (built by
# mayhem/build.sh with NORMAL flags) and emit a CTRF summary. exit 0 iff the test passed.
#
# PATCH-grade oracle: mayhem/harnesses/roundtrip_test.cpp synthesizes a 1280x720 10-bit P010 HDR
# image, encodes it to an UltraHDR (JPEG_R) stream through libultrahdr's real encode path, then
# decodes it back and asserts the recovered base dimensions equal 1280x720, that the stream is
# recognized as UltraHDR, and that a non-zero-sized gain map is present. A no-op / exit(0) /
# "always succeed without encoding" patch cannot produce the correct dimensions or a valid gain
# map, so it fails. This script RUNS the prebuilt binary AND checks its stdout for the
# known-answer output line "roundtrip OK: base=1280x720 gainmap=..." — a neutered exit(0) binary
# produces no output and fails this grep.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TBUILD="$SRC/mayhem-tests"
BIN="$TBUILD/roundtrip_test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  emit_ctrf "libultrahdr-roundtrip" 0 1 0; exit 2
fi

echo "=== running $BIN ==="
OUT="$("$BIN" 2>&1)"
rc=$?
echo "$OUT"

# Behavioral oracle: the program must print the known-answer line "roundtrip OK: base=1280x720"
# to confirm it actually encoded + decoded a real image. A neutered binary (exit 0, no output)
# will NOT produce this line and will therefore fail this check even if exit code is 0.
if [ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "roundtrip OK: base=1280x720"; then
  emit_ctrf "libultrahdr-roundtrip" 1 0 0
else
  if [ "$rc" -ne 0 ]; then
    echo "round-trip test failed (exit $rc)" >&2
  else
    echo "round-trip test: expected 'roundtrip OK: base=1280x720' in output but got: $OUT" >&2
  fi
  emit_ctrf "libultrahdr-roundtrip" 0 1 0; exit 1
fi
