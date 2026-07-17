#!/usr/bin/env bash
#
# mayhem/build.sh — build the MazuCC fuzz target and the functional oracle.
#
# MazuCC is a minimalist single-binary C compiler: `mzcc <file.c>` reads the source (via stdin)
# and emits x86-64 AT&T assembly. We build it two ways from the upstream sources:
#   build/mzcc         sanitized + libFuzzer  -> the Mayhem target (in-process harness over the
#                                                SAME read_toplevels+emit code path as the CLI)
#   build-oracle/mzcc  normal flags           -> the mayhem/test.sh functional oracle (real CLI)
# The archived original fuzzed the raw `mzcc file.c` CLI, but a plain sanitizer CLI records 0 edges
# in Mayhem (no coverage tracer for "compatible analysis" — SPEC.md item 11), so the fuzz target is
# now an in-process libFuzzer harness (mayhem/mzcc/fuzz_mzcc.c) driving the identical parse+codegen
# path. Everything comes from the upstream .c files; no network, no upstream edits.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (base image exports the defaults); fall back for a bare run.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

# The compiler library is these four translation units (upstream OBJS). main.c is EXCLUDED from the
# fuzz target — it owns main()/argv handling, which the libFuzzer engine and the harness replace.
LIBSRCS="lexer.c codegen_x64.c parser.c verbose.c"
# The full CLI (with main.c) for the clean functional oracle.
CLISRCS="$LIBSRCS main.c"
HARNESS="mayhem/mzcc/fuzz_mzcc.c"
# -std=gnu99 matches upstream's Makefile. We drop upstream's -Wall -Werror (those keep upstream
# CI honest; clang-19 flags benign warnings in this code as errors) and its -no-pie (needed only
# to LINK mzcc's GENERATED programs, not to run the compiler itself — and ASan prefers PIE).

# Overlay-only: build-time LeakSanitizer off-switch (__lsan_is_turned_off, SPEC §6 item 15) for the
# leaky compiler (a batch tool that never frees its AST/type allocations), linked into the sanitized
# target ONLY. ASan and UBSan stay fully on; no runtime sanitizer option is set (Mayhem owns those).
# The clean oracle never sees it.
LSAN_OFF_SRC="mayhem/lsan_off.c"

# 1) Sanitized libFuzzer target — the compiler ITSELF is instrumented so ASan/UBSan see bugs inside
#    lexer/parser/codegen, and libFuzzer supplies edge coverage (SanitizerCoverage) so Mayhem gets
#    real feedback. The harness drives read_toplevels()+emit over the fuzz input (see fuzz_mzcc.c).
#    -Wl,--wrap=exit lets the harness survive mzcc's exit()-on-parse-error; -Wl,--wrap=getc feeds
#    the harness's deterministic reads-past-EOF budget for the known unterminated-block-comment hang
#    (counts work, never time — see fuzz_mzcc.c). -O1 keeps frames readable for triage;
#    $DEBUG_FLAGS after the sanitizer flags so -gdwarf-3 wins (DWARF < 4).
mkdir -p build
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $DEBUG_FLAGS -O1 -std=gnu99 -I. \
    -Wl,--wrap=exit -Wl,--wrap=getc $LIBSRCS "$HARNESS" "$LSAN_OFF_SRC" -o build/mzcc

# 2) Clean oracle build (NO sanitizers) so mayhem/test.sh is an honest functional oracle that won't
#    false-fail on benign UB. $COVERAGE_FLAGS is empty by default (a coverage build appends it here).
mkdir -p build-oracle
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -std=gnu99 -I. $CLISRCS -o build-oracle/mzcc

echo "build.sh: built build/mzcc (sanitized libFuzzer harness) and build-oracle/mzcc (CLI oracle)"
