#!/usr/bin/env bash
#
# iverilog/mayhem/test.sh — golden parser oracle over the SAME code path the
# fuzzer drives (pform_parse). iverilog's full regression suite (ivtest) is a
# large external Perl harness that runs the whole compile+simulate pipeline and
# is not self-contained, so instead we run a focused two-property oracle built
# by mayhem/build.sh (mayhem/oracle/iverilog_parser_oracle):
#
#   1. mayhem/oracle/good.v MUST parse with zero errors  (positive property)
#   2. mayhem/oracle/bad.v  MUST be rejected (error_count > 0)  (negative property)
#
# Because it asserts BOTH directions, a no-op / "always succeed" / "always fail"
# patch to the parser cannot pass. Emits a CTRF (ctrf.io) summary; exit 0 iff
# both properties hold.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${OUT:=/mayhem}"
cd "$SRC"

ORACLE="$OUT/iverilog_parser_oracle"
GOOD="$SRC/mayhem/oracle/good.v"
BAD="$SRC/mayhem/oracle/bad.v"

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests, "passed": $passed, "failed": $failed,
      "pending": 0, "skipped": $skipped, "other": 0
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "iverilog-parser-oracle" 0 1 0; exit 2
fi
if [ ! -f "$GOOD" ] || [ ! -f "$BAD" ]; then
  echo "missing oracle fixtures ($GOOD / $BAD)" >&2
  emit_ctrf "iverilog-parser-oracle" 0 1 0; exit 2
fi

echo "=== running iverilog parser oracle ==="
# UBSan halting is on in the fuzz target; the oracle inputs are clean Verilog so
# they don't trip it. detect_leaks=0: the parser intentionally accumulates pform
# globals across the two parses (it never tears them down), which is expected.
out="$(ASAN_OPTIONS=detect_leaks=0 "$ORACLE" "$GOOD" "$BAD" 2>&1)"; rc=$?
echo "$out"

# Assert BEHAVIOR (not just exit code):
#   - oracle must emit "oracle: good_errs=0" (good.v parsed cleanly)
#   - oracle must emit "bad_errs=" followed by a NON-zero number (bad.v was rejected)
# A neutered binary (exit(0) with no output) fails both grep checks even though rc=0.
passed=0; failed=0

if echo "$out" | grep -qE 'oracle: good_errs=0'; then
  passed=$(( passed + 1 ))
else
  echo "FAIL: good.v did not parse cleanly (expected 'oracle: good_errs=0' in output)" >&2
  failed=$(( failed + 1 ))
fi

if echo "$out" | grep -qE 'bad_errs=[1-9][0-9]*'; then
  passed=$(( passed + 1 ))
else
  echo "FAIL: bad.v was not rejected (expected 'bad_errs=<nonzero>' in output)" >&2
  failed=$(( failed + 1 ))
fi

emit_ctrf "iverilog-parser-oracle" "$passed" "$failed" 0
