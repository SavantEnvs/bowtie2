#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
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

# Upstream's own functional suite, as its CI (.github/workflows/simple-tests.yml) runs it:
# `python -m pytest scripts/test` over the oracle binaries build.sh built in the tree (`make allall`,
# upstream's normal flags). The tests assert alignments, SAM fields, index contents and summaries.
# Not run: `make simple-test` (its perl-deps prerequisite downloads cpanm from the network at test time).
for b in bowtie2-align-s bowtie2-align-l bowtie2-build-s bowtie2-build-l bowtie2-inspect-s bowtie2-inspect-l; do
  [ -x "$SRC/$b" ] || { echo "FATAL: $SRC/$b missing (build.sh should have built it)" >&2; emit_ctrf pytest 0 1; exit 1; }
done
python3 -c 'import pytest' || { echo "FATAL: pytest missing from the image (mayhem/Dockerfile installs python3-pytest)" >&2; emit_ctrf pytest 0 1; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export BOWTIE2_BIN_DIR="$SRC"
# -p no:cacheprovider keeps .pytest_cache out of the tree; scratch indexes go under $W.
python3 -m pytest scripts/test -q -rs -p no:cacheprovider --basetemp="$W/tmp" --junitxml="$W/junit.xml"
rc=$?
if [ ! -s "$W/junit.xml" ]; then
  echo "FATAL: pytest wrote no report (exit $rc)" >&2; emit_ctrf pytest 0 1; exit 1
fi
read -r tests failures errors skipped < <(python3 -I - "$W/junit.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
s = r if r.tag == 'testsuite' else r.find('testsuite')
print(s.get('tests'), s.get('failures'), s.get('errors'), s.get('skipped'))
PY
)
failed=$(( failures + errors ))
skip=$skipped
passed=$(( tests - failed - skip ))
# A pytest crash/collection error with no failing test case still has to fail the oracle.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$tests" -eq 0 ]; then echo "FATAL: pytest collected no tests" >&2; failed=1; fi
emit_ctrf pytest "$passed" "$failed" "$skip"
