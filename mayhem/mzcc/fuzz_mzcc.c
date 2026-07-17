/*
 * mayhem/mzcc/fuzz_mzcc.c — in-process libFuzzer harness for MazuCC.
 *
 * MazuCC's CLI (`mzcc file.c`) reads the source from stdin (main.c freopen's the file onto
 * stdin), parses it into an AST via read_toplevels(), and emits x86-64 assembly to `outfp`.
 * The archived original Mayhem target fuzzed that whole file->parse->codegen path. We reproduce
 * exactly that code path in-process (SAME functions: read_toplevels + emit_data_section +
 * emit_toplevel), which is what lets Mayhem's libFuzzer engine collect edge coverage — the raw
 * CLI target recorded 0 edges because Mayhem's "compatible analysis" for a plain sanitizer binary
 * runs no coverage tracer (SPEC.md item 11).
 *
 * Two upstream design facts make a naive in-process call impossible, handled additively here
 * (NO upstream edits):
 *   1. On ANY lex/parse error (and every assert), util.h's errorf() calls exit(1). In-process that
 *      would end the whole fuzzer on input #0. We intercept exit at LINK time (-Wl,--wrap=exit):
 *      __wrap_exit longjmp()s back into the harness while a run is active, and defers to the real
 *      exit otherwise (so libFuzzer/sanitizer shutdown still works).
 *   2. The lexer reads via getc(stdin). We point stdin at an fmemopen() stream over the fuzz bytes
 *      for the duration of the run, then restore it.
 * Codegen output is sent to /dev/null (we fuzz the compiler, not its stdout).
 *
 * The harness arms no timer of any kind: hangs are the runner's job (libFuzzer's own -timeout /
 * Mayhem's per-test timeout), so no verdict depends on host speed or load. What it does add is a
 * DETERMINISTIC work budget (counts reads, not time) for one known, trivially reachable upstream
 * hang, so the campaign is not stalled by it over and over: skip_block_comment()
 * (lexer.c) never checks for EOF, so any unterminated block comment — two bytes, "/" then "*" —
 * spins on getc() == EOF forever (the raw upstream CLI hangs on it too). The fuzzer reaches it within
 * seconds, and every hit would stall a libFuzzer worker until the runner's timeout kills it. So:
 *   3. getc() is wrapped at LINK time (-Wl,--wrap=getc, lexer.c is the only caller; no upstream
 *      edit). __wrap_getc counts how many times the lexer has been handed EOF for the current input;
 *      a real parse sees EOF a handful of times, so past EOF_READ_BUDGET reads the lexer can only be
 *      looping at end of input. It then rejects the input through upstream's OWN error path
 *      (error() -> errorf() -> exit(1), bounced back here by __wrap_exit) — the same "premature end
 *      of input" outcome as a fixed lexer. It counts reads, never time; hangs that do not keep
 *      reading EOF are still left to libFuzzer's -timeout.
 */
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mzcc.h"

extern FILE *outfp; /* codegen_x64.c */

/* --wrap=exit: bounce exit() back into the harness while a run is active. */
extern void __real_exit(int status) __attribute__((noreturn));
static jmp_buf g_jb;
static volatile int g_active = 0;

void __wrap_exit(int status)
{
    if (g_active) {
        g_active = 0;
        longjmp(g_jb, status ? status : 1);
    }
    __real_exit(status);
}

/* --wrap=getc: deterministic budget on reads past EOF (see item 3 above). */
extern int __real_getc(FILE *stream);
#define EOF_READ_BUDGET 65536UL
static unsigned long g_eof_reads;

int __wrap_getc(FILE *stream)
{
    int c = __real_getc(stream);
    if (c == EOF && g_active && ++g_eof_reads > EOF_READ_BUDGET)
        error("harness: lexer read past end of input %lu times (unterminated comment?)",
              EOF_READ_BUDGET);
    return c;
}

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size)
{
    FILE *in = fmemopen((void *) Data, Size, "r");
    if (!in)
        return 0;
    FILE *devnull = fopen("/dev/null", "w");

    FILE *saved_stdin = stdin;
    stdin = in;
    outfp = devnull ? devnull : stderr;

    g_eof_reads = 0;
    g_active = 1;
    if (setjmp(g_jb) == 0) {
        List *toplevels = read_toplevels();
        emit_data_section();
        for (Iter i = list_iter(toplevels); !iter_end(i);) {
            Ast *v = iter_next(&i);
            emit_toplevel(v);
        }
    }
    g_active = 0;

    stdin = saved_stdin;
    fclose(in);
    if (devnull)
        fclose(devnull);
    return 0;
}
