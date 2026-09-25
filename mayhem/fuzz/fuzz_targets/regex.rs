//! Fuzz oxc's ECMAScript regular-expression parser (`oxc_regular_expression`).
//!
//! WHY THIS SURFACE. This is a from-scratch implementation of the whole ECMA-262 Annex B +
//! unicode (`u`) + unicode-sets (`v`) pattern grammar: nested character classes, class set
//! operations (`&&`, `--`), `\q{...}` string disjunctions, `\p{...}` property escapes, named and
//! indexed backreferences with early-error checks, and inline modifier groups `(?ims-:…)`. It is
//! several thousand lines of index arithmetic over a `Reader` that steps by code point or code
//! unit depending on mode — historically the richest source of off-by-one bugs in any regex
//! engine — and it runs on every regex literal in any file oxlint touches, plus on the string
//! arguments of `new RegExp(pattern, flags)`.
//!
//! INPUT FORMAT. `flags` `NUL` `pattern`, so the FLAGS parser (duplicate-flag detection, the
//! mutually-exclusive `u`/`v` rule, unknown flags) is fuzzed as well as the pattern parser. With
//! no NUL byte the whole input is the pattern and flags are `None`, which selects the
//! non-unicode/Annex B grammar — a third, quite different code path.
//!
//! Both of oxc's entry points are reached: a pattern wrapped in matching quotes is routed to
//! `ConstructorParser` (the `new RegExp("…")` path, which additionally has to process string
//! literal escapes), everything else to `LiteralParser` (the `/…/` path). That dispatch is
//! deterministic and fuzzer-controllable, and it mirrors the two public constructors upstream's
//! own test suite exercises.
//!
//! No file I/O, no timers: Mayhem owns the per-exec timeout.

#![no_main]

use libfuzzer_sys::{Corpus, fuzz_target};
use oxc_allocator::Allocator;
use oxc_regular_expression::{ConstructorParser, LiteralParser, Options};

fuzz_target!(|data: &[u8]| -> Corpus {
    // The parsers take `&str`; a real embedder can only hand them UTF-8.
    let Ok(text) = std::str::from_utf8(data) else {
        return Corpus::Reject;
    };

    // NUL is ASCII, so both halves are on UTF-8 boundaries.
    let (flags_text, pattern_text) = match text.find('\0') {
        Some(i) => (Some(&text[..i]), &text[i + 1..]),
        None => (None, text),
    };

    let allocator = Allocator::default();

    let quoted = pattern_text.len() >= 2
        && ((pattern_text.starts_with('"') && pattern_text.ends_with('"'))
            || (pattern_text.starts_with('\'') && pattern_text.ends_with('\''))
            || (pattern_text.starts_with('`') && pattern_text.ends_with('`')));

    let parsed = if quoted {
        ConstructorParser::new(&allocator, pattern_text, flags_text, Options::default()).parse()
    } else {
        LiteralParser::new(&allocator, pattern_text, flags_text, Options::default()).parse()
    };

    if let Ok(pattern) = parsed {
        // Walk the produced AST so the parse cannot be optimised away.
        //
        // NOTE — deliberately NOT `pattern.to_string()`. Rendering the AST back to source through
        // `Display` panics on a lone surrogate produced by a non-unicode identity escape, and that
        // ONE defect dominated the target: 26 of 26 crash artifacts in a 45-second fork-mode run
        // were the same program counter (ast_impl/display.rs:321). Keeping the call would have
        // burned the whole fuzzing budget rediscovering it instead of exploring the parser, which
        // is the surface that matters. The bug is genuine and is written up, with a 5-byte
        // reproducer, in mayhem/regex/known-findings/display-lone-surrogate-panic/.
        let terms: usize = pattern.body.body.iter().map(|alt| alt.body.len()).sum();
        std::hint::black_box((
            pattern.body.body.len(),
            terms,
            pattern.span.start,
            pattern.span.end,
        ));
    }

    Corpus::Keep
});
