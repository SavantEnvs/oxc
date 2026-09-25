#!/usr/bin/env bash
#
# mayhem/test.sh — RUN oxc's own parser / regular-expression test suites plus a known-answer
# probe, and emit a CTRF summary. Exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `cargo test -p oxc_parser -p oxc_regular_expression` — oxc's real conformance suite for
#     exactly the code the two fuzz targets hit: the parser's own tests over the JS/TS/JSX grammar
#     and its error-recovery paths, plus oxc_regular_expression's should_pass / should_fail /
#     early-error tables and its diagnostics snapshots. These assert exact AST shapes, exact
#     rejection behaviour and exact rendered diagnostics, not merely "didn't panic". Scoped to
#     those two crates because a `--workspace` run would compile and exercise the whole toolchain
#     (linter, formatter, minifier, transformer, language server) for no oracle benefit.
#
#  2) The KAT probe /mayhem/kat. `cargo test` ALONE is explicitly not an acceptable oracle: its
#     libtest harness runs every #[test] in-process from one entrypoint, so an early process-wide
#     _exit(0) is indistinguishable from "the test binary produced no output" — easy to
#     reward-hack around. /mayhem/kat is a tiny, separate, DYNAMICALLY LINKED binary that parses
#     FIXED TSX source and a fixed set of regular expressions (embedded at compile time — no
#     runtime file I/O) and prints exact computed values: statement counts, AST span offsets, the
#     source slices those spans recover, regex term counts and exact Display round-trips, plus the
#     inputs that MUST be rejected. Neutered, it prints nothing and every assertion below fails; a
#     patch that stubs the parser to dodge a crash cannot reproduce these numbers either.
#
# This script only RUNS things — mayhem/build.sh built the fuzz targets, pre-built the test suite,
# and built /mayhem/kat.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/rust/cargo/bin:$PATH"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
# Must match mayhem/build.sh exactly: a different CARGO_INCREMENTAL changes cargo's fingerprint,
# which would silently rebuild the whole oracle suite at test time instead of just running it.
export CARGO_INCREMENTAL=0
: "${SRC:=/mayhem}"
cd "$SRC"

# oxc's own rust-toolchain.toml hijacks any BARE `cargo` under this tree via rustup's
# directory-override lookup (see mayhem/build.sh / mayhem/Dockerfile). build.sh already resolved
# and RECORDED which toolchain it used for the oracle build; read that back rather than
# re-deriving, so the suite can never silently rebuild under a different compiler at test time.
ORACLE_TOOLCHAIN="$(cat "$SRC/target/mayhem/oracle-toolchain.txt" 2>/dev/null || true)"
if [ -z "$ORACLE_TOOLCHAIN" ]; then
  echo "FAIL: target/mayhem/oracle-toolchain.txt missing — mayhem/build.sh did not run" >&2
  exit 2
fi
echo "oracle toolchain (recorded by build.sh): $ORACLE_TOOLCHAIN"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) oxc's own test suites (NORMAL flags, upstream's own toolchain pin) ────────────────────
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test+kat" 0 1 0; exit 2
fi

mkdir -p "$SRC/target/mayhem"
TESTLOG="$SRC/target/mayhem/cargo-test.log"
TESTERR="$SRC/target/mayhem/cargo-test.err"
echo "=== running: cargo +$ORACLE_TOOLCHAIN test -p oxc_parser -p oxc_regular_expression ==="
env -u RUSTFLAGS cargo "+$ORACLE_TOOLCHAIN" test \
    -p oxc_parser -p oxc_regular_expression --no-fail-fast \
  > "$TESTLOG" 2>"$TESTERR"
rc=$?
tail -40 "$TESTLOG" || true
[ -s "$TESTERR" ] && { echo "--- stderr (tail) ---"; tail -20 "$TESTERR"; }

# Plain-text libtest summary lines: "test result: ok. 88 passed; 0 failed; 0 ignored; ..."
# (one per test binary + doctests). Sum them all.
PASSED=$(grep -oE '[0-9]+ passed'  "$TESTLOG" | awk '{s+=$1} END{print s+0}')
FAILED=$(grep -oE '[0-9]+ failed'  "$TESTLOG" | awk '{s+=$1} END{print s+0}')
SKIPPED=$(grep -oE '[0-9]+ ignored' "$TESTLOG" | awk '{s+=$1} END{print s+0}')
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# A suite that produced NO parseable result did not run at all (build error, or the binaries were
# neutered). That is a FAILURE, not a reason to stop: fall through so the KAT probe below still
# runs and reports independently — two failing signals localise the problem better than one.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test results parsed — the suite did not run (cargo exit $rc)" >&2
  FAILED=$(( FAILED + 1 ))
fi
# A non-zero cargo exit with zero counted failures means a build/harness error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -f ... ]` guard here
# is how a probe silently stops running and the oracle quietly degrades to the (weaker)
# cargo-test-only case.
echo "=== KAT probe: /mayhem/kat (parses fixed TSX + fixed regexes; asserts computed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi

# Expected values — computed against THIS build from the fixture embedded in mayhem/kat/main.rs.
# The parser lines are structural facts about that TSX source (statement count, comment count, the
# exact byte spans of every top-level statement, and the source slices those spans recover). The
# regex lines are known answers taken from oxc's own unit tests in
# crates/oxc_regular_expression/src/parser/mod.rs.
kat_expect "fixture size in bytes"                                              'KAT_SRC_BYTES=550'
kat_expect "TSX fixture parses without a fatal error"                           'KAT_TSX_FATAL=false'
kat_expect "TSX fixture parses with zero diagnostics"                           'KAT_TSX_DIAGNOSTICS=0'
kat_expect "top-level statement count"                                          'KAT_TSX_STMTS=7'
kat_expect "comment count"                                                      'KAT_TSX_COMMENTS=1'
kat_expect "program span"                                                       'KAT_TSX_PROGRAM_SPAN=0:550'
kat_expect "byte span of every top-level statement"                             'KAT_TSX_STMT_SPANS=0:44,45:102,103:177,178:216,217:356,357:447,448:533'
kat_expect "stmt 0 source slice (ESM import)"                                   'KAT_TSX_STMT0_TEXT=import { readFile } from "node:fs/promises";'
kat_expect "stmt 1 source slice (conditional + template-literal type)"          'KAT_TSX_STMT1_TEXT=export type Id<T> = T extends string ? `id-${T}` : never;'
kat_expect "stmt 2 source slice (generic interface)"                            'KAT_TSX_STMT2_TEXT=export interface Point<T extends number = number> { readonly x: T; y?: T }'
kat_expect "stmt 3 source slice (regex literal with named groups)"              'KAT_TSX_STMT3_TEXT=const RE = /(?<y>\d{4})-(?<m>\d{2})/u;'
kat_expect "stmt 4 source slice (default-exported generic function)"            'KAT_TSX_STMT4_TEXT=export default function dist<T extends number>(a: Point<T>, b: Point<T>): number { return Math.hypot(a.x - b.x, (a.y ?? 0) - (b.y ?? 0)); }'
kat_expect "stmt 5 source slice (JSX arrow component)"                          'KAT_TSX_STMT5_TEXT=export const El = (p: { n: string }) => <div className="c" data-n={p.n}>{RE.source}</div>;'
kat_expect "stmt 6 source slice (class with accessor/private/BigInt/async gen)" 'KAT_TSX_STMT6_TEXT=class C { accessor v = 0; static #s = 1n; async *g() { yield await readFile("x"); } }'
kat_expect "the same source is fatal when parsed as plain JavaScript"           'KAT_AS_JS_FATAL=true'
kat_expect "TypeScript syntax rejected in a .js source type"                    'KAT_AS_JS=rejected'
kat_expect "<number>x is a type assertion under SourceType::ts"                 'KAT_TYPE_ASSERTION_TS=ok'
kat_expect "<number>x is rejected as JSX under SourceType::tsx"                 'KAT_TYPE_ASSERTION_TSX=rejected'
kat_expect "empty source: not fatal, no diagnostics, no statements"             'KAT_EMPTY=false,0,0'
kat_expect "term counts for an astral pattern under no flag / u / v"            'KAT_REGEX_TERMS=15,14,14'
kat_expect "duplicate named groups across alternatives parse to 2 alternatives" 'KAT_REGEX_ALTERNATIVES=2'
kat_expect "parsed pattern re-renders byte-exact"                               'KAT_REGEX_ROUNDTRIP=exact'
kat_expect "LiteralParser and ConstructorParser agree after escape resolution"  'KAT_REGEX_CTOR=same'
kat_expect "out-of-range backreference rejected under u"                        'KAT_REGEX_BACKREF_U=rejected'
kat_expect "same input is an Annex B escape and round-trips exactly"            'KAT_REGEX_BACKREF_ANNEXB=exact'
kat_expect "reversed character-class range rejected"                            'KAT_REGEX_RANGE=rejected'
kat_expect "unknown unicode property rejected"                                  'KAT_REGEX_PROPERTY=rejected'
kat_expect "duplicate named group in one alternative rejected"                  'KAT_REGEX_DUP_GROUP=rejected'
kat_expect "unterminated group rejected"                                        'KAT_REGEX_UNTERMINATED=rejected'
kat_expect "out-of-order braced quantifier rejected"                            'KAT_REGEX_QUANTIFIER=rejected'
kat_expect "mutually exclusive u+v flags rejected"                              'KAT_REGEX_FLAGS_UV=rejected'
kat_expect "duplicated flag rejected"                                           'KAT_REGEX_FLAGS_DUP=rejected'
kat_expect "probe ran to completion"                                            'KAT_DONE=1'

emit_ctrf "cargo-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
