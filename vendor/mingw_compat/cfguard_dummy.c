/* Real, non-obvious gap: Zig 0.16's own self-built mingw-w64 CRT
 * (lib/zig/libc/mingw/cfguard/mingw_cfguard_support.c) ships mingw-w64's
 * real cfguard.c file, which declares this symbol `extern` and only ever
 * takes its address (never calls through it) to initialize a Control Flow
 * Guard dispatch-table pointer -- but Zig's bundled copy is missing the
 * real upstream companion architecture-specific stub that actually defines
 * it, so any windows-gnu link that happens to pull that object in from
 * `libmingw32.lib` fails with an undefined-symbol error.
 *
 * Confirmed safe to provide directly, not a workaround masking real
 * behavior: mingw-w64's own source comment describes this exact symbol as
 * a no-op regardless of what defines it ("it doesn't really matter here
 * because this is a no-op anyway") -- it is only ever exercised when a
 * binary is actually linked with real Control Flow Guard support
 * (`/guard:cf`), which a plain GNU-triple `lld-link` invocation like ours
 * never enables. Declared as a function (matching upstream's own real
 * definition shape, an assembly label under mingw-w64 proper) even though
 * the extern declaration in mingw_cfguard_support.c types it as `void *`
 * -- upstream's own comment explains this mismatch is deliberate, so
 * CFGuard's `jmp`-target validation doesn't treat this stub itself as a
 * valid call target.
 */
#if defined(_WIN64) && defined(__x86_64__)
void __guard_dispatch_icall_dummy(void) {}
#endif
