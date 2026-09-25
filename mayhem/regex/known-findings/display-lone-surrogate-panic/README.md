# `oxc_regular_expression`: `Display` panics on a lone surrogate from a non-unicode identity escape

Found during this integration, in the first 45 seconds of fork-mode fuzzing of the `regex` target.

## Reproducer

`repro.bin` — 5 bytes, the libFuzzer input that first triggered it (minimised with
`-minimize_crash=1` from a 23-byte artifact):

```
5c f1 84 91 91      =  '\' followed by U+44451 encoded as UTF-8
```

With the `regex` harness's input format (`flags NUL pattern`, no NUL here) that is
`flags = None`, `pattern = "\<U+44451>"`, i.e. the **non-unicode / Annex B** grammar.

Equivalent standalone Rust (this is what actually panics — see "Why the shipped harness no longer
hits it" below):

```rust
use oxc_allocator::Allocator;
use oxc_regular_expression::{LiteralParser, Options};

let allocator = Allocator::default();
let pattern = LiteralParser::new(&allocator, "\\\u{44451}", None, Options::default())
    .parse()
    .unwrap();           // parsing SUCCEEDS
let _ = pattern.to_string();   // <-- panics: Invalid `Character`!
```

## Symptom

```
thread '<unnamed>' panicked at crates/oxc_regular_expression/src/ast_impl/display.rs:321:33:
Invalid `Character`!
   ...
   oxc_regular_expression::ast_impl::display::character_to_string
   <oxc_regular_expression::ast::Alternative as core::fmt::Display>::fmt
```

## Cause

Without a `u`/`v` flag the pattern reader steps by **UTF-16 code unit**, so an astral character is
seen as a surrogate pair. `\` + lead-surrogate parses as an *identity escape*, producing a
`Character { kind: CharacterKind::Identifier, value: 0xD8D1 }` — a lone surrogate, which is not a
valid `char`.

`character_to_string` (`ast_impl/display.rs`) has surrogate handling, but it is gated on the
character kind:

```rust
if matches!(this.kind, CharacterKind::Symbol | CharacterKind::UnicodeEscape) {
    // ... lone-lead / lone-trail / lead+trail handling, all returning \uXXXX ...
}

let ch = char::from_u32(cp).expect("Invalid `Character`!");   // line 321
```

`CharacterKind::Identifier` is not in that set, so the value falls straight through to the
unconditional `char::from_u32(...).expect(...)` and the process aborts.

## Impact

`Display`/`to_string()` on the pattern AST is public API and is how oxc renders a parsed pattern
back to source; it is reachable from anything that formats a parsed regex (diagnostics,
tooling, tests). A panic is a denial of service for any caller that renders a pattern taken from
untrusted source, and it fires on a 2-character regex that the parser itself accepts — so the
crash is not guarded by any validation the caller could reasonably add.

## One-line fix

Widen the surrogate guard so every kind that can carry a raw code-unit value is covered, e.g.

```rust
-    if matches!(this.kind, CharacterKind::Symbol | CharacterKind::UnicodeEscape) {
+    if matches!(
+        this.kind,
+        CharacterKind::Symbol | CharacterKind::UnicodeEscape | CharacterKind::Identifier
+    ) {
```

(or, more conservatively, replace the `expect` at line 321 with a `\u{XXXX}` fallback for any
`cp` that is not a valid scalar value).

## Why the shipped harness no longer hits it

The harness originally ended with `pattern.to_string()`. That single defect dominated the target:
**26 of 26** crash artifacts from a 45-second `-fork=4` run were this exact program counter, while
coverage of the parser itself crawled. Per the fleet's remediation guidance for a target that
rediscovers one bug forever, the harness now walks the AST instead of rendering it
(`mayhem/fuzz/fuzz_targets/regex.rs`), so the fuzzer spends its budget on the *parser* — the
surface the target exists for. Nothing about the parser's behaviour is filtered or masked: the same
inputs are still parsed, and the defect above is recorded here rather than silently dropped.

This reproducer is deliberately kept OUT of `mayhem/regex/testsuite/` — seeds are replayed on every
Mayhem run, and a crashing seed breaks the startup probe for every run, permanently.
