/* mayhem/lsan_off.c — build-time LeakSanitizer off-switch for the fuzz binary (SPEC §6 item 15).
 *
 * MazuCC is a batch compiler that allocates AST/type/codegen nodes and simply exits without
 * freeing them, so exit-time leak reports would flood every run with non-actionable "defects" and
 * drown out the real memory-safety / UB bugs. -fsanitize=address always bundles LSan, so this TU
 * (compiled with $SANITIZER_FLAGS and linked into build/mzcc by mayhem/build.sh) turns ONLY leak
 * detection off; ASan's memory-corruption checks and UBSan stay fully active. No runtime sanitizer
 * option is set here — Mayhem alone owns the runtime ASan/libFuzzer options. */
int __lsan_is_turned_off(void) { return 1; }
