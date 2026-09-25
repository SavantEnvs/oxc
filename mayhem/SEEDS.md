# Seed corpora

Both corpora are built from files oxc already ships, so every seed is a *genuine* input for the
grammar it targets rather than something synthesised. Neither harness reads the filesystem — the
seeds are delivered by Mayhem through the `testsuite:` directive in each Mayhemfile
(`file://mayhem/<target>/testsuite` plus the server-accumulated tar).

## `mayhem/parser/testsuite` — 156 files, ~37 KB

Real JavaScript / TypeScript / JSX source files copied verbatim out of the repo, selected with a
deterministic script:

| source | what it contributes |
| --- | --- |
| `tasks/coverage/misc/pass` | oxc's own curated "must parse" edge cases (decorators, `accessor`, `using`, top-level await, ambient declarations, …) |
| `tasks/coverage/misc/fail` | oxc's own curated "must be rejected" cases — these drive the parser's **error-recovery** paths, which is where recursive-descent parsers usually break |
| `crates/oxc_isolated_declarations/tests/fixtures` | dense TypeScript type syntax |
| `crates/oxc_semantic/tests/fixtures/typescript-eslint` | typescript-eslint's declaration/class/export corpus |
| `crates/oxc_react_compiler/fixtures`, `crates/oxc_formatter/tests/fixtures/js/jsx` | JSX / TSX |

Selection rules: file extension in `{js,jsx,mjs,cjs,ts,tsx,mts,cts}`, 4 ≤ size ≤ 3000 bytes, valid
UTF-8, **deduplicated by SHA-256**, then stride-sampled per source directory (sorted by extension
and size) so the set stays spread across file types and sizes instead of clustering on one
fixture family. Extension mix: 66 `.ts`, 43 `.js`, 26 `.tsx`, 14 `.jsx`, 5 `.cjs`, 1 `.cts`,
1 `.mjs`.

Measured: the seed corpus alone gets the target to **9108 edges** at `INITED`.

## `mayhem/regex/testsuite` — 248 files, ~3.3 KB

The `regex` harness takes `flags` `NUL` `pattern` (no NUL ⇒ flags absent ⇒ the non-unicode/Annex B
grammar). The seeds are the `(pattern, flags)` pairs from oxc's own regular-expression test
tables, extracted by a Rust-string-literal scanner over:

- `crates/oxc_regular_expression/src/parser/mod.rs` — the `should_pass`, `should_fail` and
  `should_fail_early_errors` tables plus the oversized-backreference cases
- `crates/oxc_regular_expression/src/parser/flags_parser.rs`
- `crates/oxc_regular_expression/tests/diagnostics.rs` — one case per diagnostic variant

plus a dozen hand-written entries that cover the `ConstructorParser` dispatch (a quoted pattern,
with quoted flags) and the no-flags path, which the tables under-represent. Deduplicated by
SHA-256.

Measured: **2244 edges** at `INITED`.

## Verification (run inside the commit image)

Every seed was replayed individually and as a directory, because one hanging or crashing seed
breaks Mayhem's startup probe for *every* run, permanently:

```
for f in /mayhem/mayhem/<t>/testsuite/*; do /mayhem/<t> -runs=1 "$f"; done   # 0 failures, both targets
/mayhem/<t> -runs=5   /mayhem/mayhem/<t>/testsuite                          # rc 0 — Mayhem's probe
/mayhem/<t> -runs=200 /mayhem/mayhem/<t>/testsuite                          # rc 0
```

No dictionaries are shipped: for a source-text grammar this large the corpus carries far more
signal than a token list would, and a malformed or unreferenced dict is a well-known silent
failure mode.
