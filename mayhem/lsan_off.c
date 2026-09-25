/*
 * lsan_off.c — turn LeakSanitizer OFF at BUILD time, fleet-wide policy.
 *
 * -fsanitize=address always bundles LeakSanitizer in and offers no flag to exclude just it. Leaks
 * are not the bug class this fleet fuzzes for (memory corruption + UB are), and for oxc in
 * particular a leak report would be pure noise: the parser allocates its whole AST into an
 * oxc_allocator arena (a bump allocator) that is intentionally not freed node-by-node.
 *
 * The sanctioned mechanism is this single build-time hook: the ASan runtime calls
 * __lsan_is_turned_off() once at startup and skips leak reporting when it returns non-zero. ASan
 * and UBSan stay fully active. Runtime toggling (a disable/enable pair around a call path) is
 * FORBIDDEN by the spec — unreliable in practice — and so is overriding the sanitizer
 * option-string hooks, which belong to Mayhem alone.
 *
 * Wiring (see mayhem/build.sh): this TU is compiled with $SANITIZER_FLAGS into
 * target/mayhem/lsan_off.o and PREPENDED, together with the DWARF3 anchor object, onto every rustc
 * link line by the generated `-Clinker` cc-wrapper — so it lands in every sanitized fuzz binary,
 * not just one of them.
 *
 * The definition below MUST stay on ONE line: the conformance gate's detector is a line-wise grep
 * for `int __lsan_is_turned_off (`.
 */
int __lsan_is_turned_off(void) { return 1; }
