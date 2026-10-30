#!/usr/bin/env bash
#
# mayhem/test.sh — RUN zint's own test suite (built by mayhem/build.sh into build-tests/) and assert
# known-answer barcodes through the CLI. exit 0 = pass.
#
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


BT="$SRC/build-tests"
export LD_LIBRARY_PATH="$BT/backend${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$BT/frontend:$PATH"

passed=0 failed=0 skipped=0

# Each upstream test binary prints "Total N tests (...), all passed." / "Total N tests, S skipped." /
# "Total N tests, F **fails**: ..." — parse that line rather than trusting the exit code. A neutered
# or missing binary prints nothing, which counts as a failure.
run_suite() {
  local dir="$1" src="$2" bin out line n s f wd
  for bin in "$dir"/test_*; do
    [ -f "$bin" ] && [ -x "$bin" ] || continue
    case "$(basename "$bin")" in test_perf) continue ;; esac   # benchmark, asserts nothing
    # Fresh scratch cwd per binary: the tests write files (out.gif, ...) relative to cwd and some assert
    # their absence, so leftovers from an earlier run would make a re-run fail.
    wd=$(mktemp -d "${TMPDIR:-/tmp}/zint-test.XXXXXX")
    out=$(cd "$wd" && CMAKE_CURRENT_SOURCE_DIR="$src" timeout 600 "$bin" 2>&1 | tr -d '\000')
    rm -rf "$wd"
    line=$(printf '%s\n' "$out" | grep -E '^Total [0-9]+ tests' | tail -1)
    if [ -z "$line" ]; then echo "FAIL $(basename "$bin"): no summary line"; failed=$((failed+1)); continue; fi
    n=$(printf '%s' "$line" | sed -E 's/^Total ([0-9]+) tests.*/\1/')
    s=$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) skipped.*/\1/p'); s=${s:-0}
    f=$(printf '%s' "$line" | sed -nE 's/.* ([0-9]+) \*\*fails\*\*.*/\1/p'); f=${f:-0}
    if [ "$f" -gt 0 ] || { [ "$f" -eq 0 ] && ! printf '%s' "$line" | grep -qE 'all passed|skipped'; }; then
      echo "FAIL $(basename "$bin"): $line"; failed=$((failed + (f>0 ? f : 1))); continue
    fi
    passed=$((passed + n - s)); skipped=$((skipped + s))
  done
}
run_suite "$BT/backend/tests" "$SRC/backend/tests"
run_suite "$BT/frontend/tests" "$SRC/frontend/tests"

# Known-answer probes through the built CLI (dynamically linked, so a neutered binary cannot pass).
kat() {
  local want="$1" got; shift
  got=$(zint "$@" --dump 2>&1 | tr '\n' ' ' | sed 's/ *$//')
  if [ "$got" = "$want" ]; then passed=$((passed+1)); else echo "FAIL zint $*: got '$got', want '$want'"; failed=$((failed+1)); fi
}
kat 'D2 14 62 2C 63 AC' -b 20 -d 'A'                  # Code 128 "A"
kat 'A4 DE 9D 62 14 8A A4 74 E5 9B 64 8A' -b 13 -d '123456789012'   # EAN-13 (check digit 8)
kat 'FE EB F8 82 0A 08 BA 6A E8 BA B2 E8 BA 5A E8 82 7A 08 FE AB F8 00 38 00 2E 84 48 D9 A3 78 82 75 78 FC B7 D0 C2 91 20 00 DA 30 FE 04 98 82 92 38 BA C4 A8 BA 0D 50 BA F5 68 82 1B D0 FE 43 78' -b 58 -d 'Hi'  # QR Code "Hi"

# At least the bulk of the upstream suite must have run.
[ "$passed" -ge 400 ] || { echo "FAIL only $passed tests passed (expected >= 400)"; failed=$((failed+1)); }

emit_ctrf "zint-tests" "$passed" "$failed" "$skipped"
