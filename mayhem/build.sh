#!/usr/bin/env bash
#
# mayhem/build.sh — build oxc's parser fuzz targets as sanitized libFuzzer binaries (OSS-Fuzz Rust
# path: cargo-fuzz + ASan via RUSTFLAGS), the mayhem/kat oracle probe, and (built only, not run)
# the upstream test suite mayhem/test.sh executes.
#
# TARGETS (one Mayhemfile each), both from the ADDITIVE crate mayhem/fuzz:
#
#   /mayhem/parser   The JS / TS / JSX parser (crates/oxc_parser). Arbitrary UTF-8 source text,
#                    parsed twice per input — once as TSX and once as TS — because oxc's TypeScript
#                    and TSX grammars genuinely diverge (`<T>expr` is a type assertion in .ts and
#                    a JSX element in .tsx; generic arrows are disambiguated differently), so the
#                    two source types reach different bodies of code in oxc_parser::ts /
#                    oxc_parser::jsx. `parse_regular_expression` is enabled so regex literals in
#                    the source are parsed too, as oxlint does. This is THE attacker-reachable
#                    surface in the repo: every oxc consumer (oxlint, oxfmt, the napi bindings,
#                    the playground) feeds it third-party source code, and it is a hand-written
#                    recursive-descent parser over a lexer doing raw pointer arithmetic on the
#                    source buffer.
#
#   /mayhem/regex    The ECMAScript regular-expression parser (crates/oxc_regular_expression), a
#                    from-scratch implementation of the Annex B / `u` / `v` pattern grammars:
#                    nested character classes, class-set operators (&& and --), \q{…} string
#                    disjunctions, \p{…} property escapes, named + indexed backreferences with
#                    early-error checks and inline modifier groups. Input is `flags NUL pattern`,
#                    so the FLAGS parser is fuzzed as well; a quoted pattern is routed to
#                    ConstructorParser (the `new RegExp("…")` front end) instead of LiteralParser.
#
#   /mayhem/kat      dynamically-linked known-answer probe (used by mayhem/test.sh; not a target).
#
# NOTHING UPSTREAM IS EDITED. Upstream removed its own fuzz/ directory in 0236e947bd (moved to
# oxc-project/oxc-fuzz-parser, which depends on the PUBLISHED oxc 0.151.0 crates). We do not
# vendor that: depending on crates.io would fuzz a release instead of this commit. mayhem/fuzz is
# an additive crate that is its OWN cargo workspace and only CALLS the oxc crates through path
# dependencies.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The Rust toolchain and
# cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo (absolute, $HOME-independent).
#
# DWARF gate (SPEC §6.2 item 10) + LeakSanitizer policy, both handled by ONE generated cc-wrapper:
# rustc's own CUs land at DWARF4 and the ASan runtime archive at DWARF5, and the gate reads only
# the FIRST .debug_info CU. The Dockerfile precompiles a DWARF3 anchor object; this script
# compiles mayhem/lsan_off.c next to it and writes a `-Clinker` wrapper that PREPENDS BOTH objects
# ahead of every other link input. Prepend (not append) is required for the anchor's CU to land at
# .debug_info offset 0. Prepending is also how the __lsan_is_turned_off() hook reaches EVERY
# sanitized binary rather than one of them.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The re-run resolves crates from that cache; the rlenv runtime exports CARGO_NET_OFFLINE=true
#     for it, so we do NOT hard-code `--offline` here (that would break this first, online build).
#   - Re-running on an already-built tree must also succeed: every step below is safe to repeat
#     (mkdir -p, cp -f, cargo overwrites).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
cd "$SRC"

# Parallelism is bounded by MEMORY, not cores: an ASan-instrumented rustc job on oxc_ast (a
# generated AST of several hundred types) peaks well over 1 GB, and both the conformance gate and
# the rlenv analyze nodes run this build under a hard container memory cap (8 GB by default).
# Unbounded `nproc` jobs on a 16-core runner would OOM-kill the build.
#
# The budget is read from the CGROUP (/sys/fs/cgroup/memory.max), not from /proc/meminfo:
# /proc/meminfo inside a container reports the HOST's memory, so a `--memory=8g` build on a 15 GB
# box would look like 15 GB and happily oversubscribe. Fall back to nproc when the cgroup file is
# absent or says "max" (uncapped). Override with MAYHEM_JOBS=<n> when you know the box.
: "${MAYHEM_JOBS:=$(
    _cores=$(nproc)
    _lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
    case "$_lim" in
      ''|max|*[!0-9]*) echo "$_cores" ;;
      *) _bymem=$(( _lim / 2000000000 ))
         [ "$_bymem" -lt 1 ] && _bymem=1
         [ "$_bymem" -lt "$_cores" ] && echo "$_bymem" || echo "$_cores" ;;
    esac)}"
[ -n "$MAYHEM_JOBS" ] || MAYHEM_JOBS=2
echo "build parallelism: MAYHEM_JOBS=$MAYHEM_JOBS (nproc=$(nproc))"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# Incremental compilation is pure cost here: every build in this image is a one-shot build in a
# fresh container, and the incremental cache is never reused across them — it only inflates the
# image. Measured on this repo: target/debug/incremental alone was 346 MB of the commit image.
# It MUST be set identically in mayhem/test.sh, or cargo sees a different fingerprint at test time
# and rebuilds the whole oracle suite.
export CARGO_INCREMENTAL=0

# Build OUTPUT lives under the repo-root target/ tree, NOT under mayhem/, and that placement is
# load-bearing rather than cosmetic. The conformance gate greps mayhem/ RECURSIVELY and
# CONTENT-WISE for the forbidden __asan/__lsan option-override symbol names; an ASan-linked fuzz
# binary contains those strings in its own symbol table, so a cargo target/ dir left anywhere
# under mayhem/ makes the gate hard-FAIL on a perfectly clean integration. target/ is already
# ignored by oxc's root .gitignore and dropped from the docker build context by
# mayhem/Dockerfile.dockerignore, and rlenv preserves target/ for cargo projects, so the cache
# still survives an offline PATCH re-run.
OUT="$SRC/target/mayhem"
mkdir -p "$OUT"

# ── toolchains ─────────────────────────────────────────────────────────────────────────────
# oxc's root rust-toolchain.toml (channel = "1.98.1" — an upstream file we never edit) overrides
# EVERY bare `cargo` under this tree through rustup's directory-override lookup, INCLUDING inside
# mayhem/fuzz and mayhem/kat. A bare `cargo fuzz build` would therefore silently run on that
# stable toolchain and fail on `-Zsanitizer=address` ("only accepted on the nightly compiler").
# So: never a bare `cargo` below — always an explicit `+<toolchain>`.
: "${RUST_FUZZ_TOOLCHAIN:?RUST_FUZZ_TOOLCHAIN must be set by mayhem/Dockerfile}"
ORACLE_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml)"
[ -n "$ORACLE_TOOLCHAIN" ] || { echo "ERROR: could not read channel from rust-toolchain.toml" >&2; exit 1; }
echo "fuzz toolchain  (Dockerfile-pinned nightly): $RUST_FUZZ_TOOLCHAIN"
echo "oracle toolchain (upstream's own rust-toolchain.toml pin): $ORACLE_TOOLCHAIN"
# Record it so mayhem/test.sh runs the suite on the IDENTICAL toolchain instead of re-deriving it.
printf '%s\n' "$ORACLE_TOOLCHAIN" > "$OUT/oracle-toolchain.txt"

# ── LeakSanitizer OFF at build time + the DWARF3 anchor, via one cc-wrapper ─────────────────
# $SANITIZER_FLAGS is the base image's CLANG-oriented ASan/UBSan contract (SPEC §6.1 / §6.2 item
# 8). rustc ignores it entirely and gets its own sanitizer switch through RUSTFLAGS below, but the
# clang-compiled hook TU here is exactly where it applies. -gdwarf-3 is appended AFTER
# $SANITIZER_FLAGS (which ends in a plain -g): last flag wins, so appending is what actually pins
# the DWARF version — putting it before would let -g re-select clang-19's default DWARF-5.
echo "SANITIZER_FLAGS=${SANITIZER_FLAGS:-}"
echo "=== compiling the LeakSanitizer hook (mayhem/lsan_off.c) ==="
clang ${SANITIZER_FLAGS:-} -gdwarf-3 -c "$SRC/mayhem/lsan_off.c" -o "$OUT/lsan_off.o"
nm "$OUT/lsan_off.o" | grep -q '__lsan_is_turned_off' \
  || { echo "FATAL: $OUT/lsan_off.o does not define __lsan_is_turned_off" >&2; exit 1; }

ANCHOR=/opt/toolchains/rust/dwarf3/anchor.o
[ -f "$ANCHOR" ] || { echo "FATAL: DWARF3 anchor $ANCHOR missing (built by mayhem/Dockerfile)" >&2; exit 1; }

CCWRAP="$OUT/cc-wrapper.sh"
# PREPEND both objects: anchor first (its CU must be at .debug_info offset 0), then the LSan hook.
printf '#!/bin/sh\nexec clang %s %s "$@"\n' "$ANCHOR" "$OUT/lsan_off.o" > "$CCWRAP"
chmod +x "$CCWRAP"
echo "cc-wrapper: $(tail -1 "$CCWRAP")"

# RUST_DEBUG_FLAGS is the SPEC §6.2 item 10 knob for the Rust path — EDIT only if the wrapper
# moves; dropping -Clinker regresses BOTH the DWARF check and the LSan hook.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Clinker=$CCWRAP}"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself; we pin it explicitly.
# --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids ASan backtraces.
#
# -Coverflow-checks=on, and NO `--debug-assertions` on the cargo fuzz build lines below. This pair
# is deliberate:
#
#   oxc's hot paths are built around debug-only invariant checks that vanish in the release builds
#   it actually ships. crates/oxc_data_structures exposes `assert_unchecked!`, a wrapper that is a
#   plain safe `assert!` under cfg!(debug_assertions) and `std::hint::assert_unchecked` (a pure
#   optimiser hint, i.e. UB if false) otherwise; oxc_parser/oxc_lexer and the arena allocator use
#   it and ordinary `debug_assert!` throughout their pointer arithmetic. Building the fuzz targets
#   WITH debug assertions therefore converts every would-be memory-safety bug into a tidy panic
#   BEFORE ASan can see it — the opposite of what we want — while also aborting the run on
#   recoverable internal invariants that are not production bugs, which burns the whole fuzzing
#   budget on a handful of program counters. Release is also what ships to npm.
#
#   Nothing is being masked: the harnesses are untouched, no input is filtered, and the library is
#   built exactly as it ships. -Coverflow-checks=on is added back explicitly so the one bug class
#   that --debug-assertions would otherwise have bought us — Rust arithmetic overflow, which is
#   real here because oxc_span::Span packs source offsets into u32 — is STILL a hard panic.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers -Coverflow-checks=on $RUST_DEBUG_FLAGS"
echo "RUSTFLAGS=$RUSTFLAGS"

TRIPLE="x86_64-unknown-linux-gnu"

# ── 1. the ADDITIVE cargo-fuzz crate (its own workspace) ────────────────────────────────────
ADD_FUZZ_DIR="mayhem/fuzz"
# Discover the targets from the crate's own fuzz_targets/ dir rather than hard-coding them, so
# adding a harness file is enough.
ADD_TARGETS=()
for f in "$ADD_FUZZ_DIR"/fuzz_targets/*.rs; do
  ADD_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#ADD_TARGETS[@]}" -gt 0 ] \
  || { echo "ERROR: no fuzz targets under $ADD_FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
echo "=== cargo fuzz build — additive crate: ${ADD_TARGETS[*]} ==="
for t in "${ADD_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # -O only: see the RUSTFLAGS block above for why --debug-assertions is deliberately absent.
  # CARGO_TARGET_DIR redirects this crate's output out of mayhem/ (see the $OUT comment above);
  # mayhem/fuzz declares its own [workspace], so without the override cargo would write
  # mayhem/fuzz/target/ and trip the gate's recursive content grep.
  env CARGO_TARGET_DIR="$OUT/fuzz-target" \
    cargo "+$RUST_FUZZ_TOOLCHAIN" fuzz build --fuzz-dir "$ADD_FUZZ_DIR" -O "$t"
  bin="$OUT/fuzz-target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp -f "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── 2. per-target dictionaries into the flat /mayhem root (where each Mayhemfile points) ────
# A dict named by a Mayhemfile but absent from the image makes libFuzzer exit 1 at 0 edges, so
# copy every one that exists and let the Mayhemfile reference the copy.
for t in "${ADD_TARGETS[@]}"; do
  d="mayhem/$t/$t.dict"
  if [ -f "$d" ]; then
    cp -f "$d" "/mayhem/$t.dict"
    echo "copied dictionary /mayhem/$t.dict"
  fi
done

# ── 3. the KAT probe used by mayhem/test.sh ─────────────────────────────────────────────────
# NORMAL flags: it is a functional oracle, not a triage artifact — no sanitizer, no fuzz
# instrumentation, no DWARF3 anchor, and upstream's OWN toolchain pin (the nightly above is only
# needed for -Zsanitizer=address). A plain cargo build on the gnu target is already dynamically
# linked; assert it anyway so a future static-link change can't silently weaken the oracle.
echo "=== building /mayhem/kat (KAT probe, oracle toolchain $ORACLE_TOOLCHAIN) ==="
( cd mayhem/kat && env -u RUSTFLAGS CARGO_TARGET_DIR="$OUT/kat-target" \
    cargo "+$ORACLE_TOOLCHAIN" build --release )
cp -f "$OUT/kat-target/release/kat" /mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the gate's sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# ── 4. upstream's own test suite — BUILD only; mayhem/test.sh runs it ───────────────────────
# Scoped to the two crates the fuzz targets actually drive: oxc_parser (88 #[test]s over the
# JS/TS/JSX grammar and its error recovery) and oxc_regular_expression (35, including the
# should_pass / should_fail / early-error tables this port's KAT expectations are taken from).
# A `--workspace` build here would compile the whole toolchain (linter, formatter, minifier,
# transformer, language server, napi bindings) for no oracle benefit. NOTE crates/oxc_lexer is
# deliberately NOT included: at this commit it is an incubating standalone crate that oxc_parser
# does not depend on, so none of its code is reachable from either fuzz target.
echo "=== building oxc's own test suite (oracle toolchain $ORACLE_TOOLCHAIN) ==="
env -u RUSTFLAGS cargo "+$ORACLE_TOOLCHAIN" test \
    -p oxc_parser -p oxc_regular_expression --no-run

echo "build.sh complete:"
ls -la /mayhem/kat "${ADD_TARGETS[@]/#//mayhem/}"
