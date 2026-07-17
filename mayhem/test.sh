#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for MazuCC. RUNS the project's ENTIRE existing test suite against
# the prebuilt clean compiler (build-oracle/mzcc from build.sh); it never rebuilds the compiler. The
# point is regression protection: a patch that breaks any compiler functionality fails here.
#
#   1. upstream tests/*.c  — self-checking programs (each asserts via expect() and exit(1) on mismatch).
#                            Compiled with mzcc, assembled+linked with cc -no-pie, then run (exit 0 = ok).
#   2. sample/nqueen.c     — larger end-to-end program; must compile, link and run.
#   3. tests/driver.sh     — upstream AST-dump tests (mzcc --dump-ast known-answer + must-fail cases).
#                            driver.sh exits 0 even on failure, so we gate on its output text.
#
# A neutered compiler (exit(0)/no codegen) produces no working binary and wrong AST dumps, so every
# item FAILS — this is both the regression guard and the anti-reward-hack (§6.3) behavioral check.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

MZCC=build-oracle/mzcc
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mazucc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

check() { if [ "$2" -eq 0 ]; then echo "  ok   - $1"; passed=$((passed+1)); else echo "  FAIL - $1"; failed=$((failed+1)); fi; }

emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}"; local tests=$(( p + f + s ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": 0, "skipped": $s, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$p" "$f" "$s"
  [ "$f" -eq 0 ]
}

if [ ! -x "$MZCC" ]; then
  echo "test.sh: $MZCC missing — build.sh must build it (not rebuilding here)" >&2
  emit_ctrf mazucc 0 1; exit 1
fi

# 1) + 2) upstream self-checking test programs and the nqueen sample.
srcs=(tests/*.c)
[ -f sample/nqueen.c ] && srcs+=(sample/nqueen.c)
for c in "${srcs[@]}"; do
  [ -f "$c" ] || continue
  n="$(basename "$c" .c)"
  if "$MZCC" -o "$WORK/$n.s" "$c" 2>"$WORK/$n.cerr" \
     && cc -no-pie -o "$WORK/$n.bin" "$WORK/$n.s" 2>"$WORK/$n.lerr" \
     && "$WORK/$n.bin" >"$WORK/$n.out" 2>&1; then
    check "compile+run $c" 0
  else
    check "compile+run $c" 1
  fi
done

# 3) upstream AST-dump tests. driver.sh uses ./mzcc from cwd and exits 0 even on failure, so run it in a
# writable dir with mzcc symlinked in and require the success sentinel with no failure markers.
if [ -f tests/driver.sh ]; then
  ln -sf "$SRC/$MZCC" "$WORK/mzcc"
  printf 'CBUILD="cc -no-pie"\n' > "$WORK/.cbuild"
  ( cd "$WORK" && bash "$SRC/tests/driver.sh" ) > "$WORK/driver.out" 2>&1 || true
  if grep -q 'All tests passed' "$WORK/driver.out" \
     && ! grep -qE 'Test failed|Failed to compile|Should fail|GCC failed' "$WORK/driver.out"; then
    check "tests/driver.sh AST tests" 0
  else
    echo "    driver.sh: $(grep -m1 -E 'Test failed|Failed to compile|Should fail|GCC failed' "$WORK/driver.out" || true)"
    check "tests/driver.sh AST tests" 1
  fi
fi

echo "test.sh: passed=$passed failed=$failed"
emit_ctrf mazucc "$passed" "$failed"
