//! Fuzz oxc's JavaScript / TypeScript / JSX parser over arbitrary UTF-8 source text.
//!
//! WHY THIS SURFACE. `oxc_parser` is the front end of every oxc tool (oxlint, oxfmt, the napi
//! bindings, the minifier). Its input is, by construction, untrusted third-party source code — a
//! dependency pulled from npm, a file in a PR, a snippet pasted into a playground — and it is a
//! hand-written recursive-descent parser sitting on a lexer that does raw pointer arithmetic over
//! the source buffer (`oxc_lexer`'s `Source`/`SourcePosition`, `oxc_data_structures::non_null`).
//! Memory safety there depends on invariants the parser must maintain across every error-recovery
//! path, which is exactly what a fuzzer is good at breaking.
//!
//! NO FILE I/O, NO TIMERS. Every byte comes from the fuzzer; Mayhem owns the per-exec timeout
//! (see the Mayhemfile `timeout:` key). A hang here is a finding, not something to guard against.
//!
//! WHY TWO PARSES PER INPUT. oxc's TypeScript and TSX grammars genuinely diverge: in `.tsx`,
//! `<T>expr` is JSX, while in `.ts` it is a type assertion, and generic arrow functions are
//! disambiguated differently. Parsing the same source under both `SourceType::ts()` and
//! `SourceType::tsx()` therefore reaches two distinct bodies of code in `oxc_parser::ts` /
//! `oxc_parser::jsx` from one seed, and keeps the seed corpus plain, real source files (no magic
//! selector byte that would mangle any `.ts` file Mayhem later accumulates into the corpus).
//!
//! DIFFERENCE FROM upstream's oxc-fuzz-parser harness: that one additionally skips every input
//! containing a control character (`s.chars().all(|c| !c.is_control())`). We deliberately do NOT —
//! newlines and tabs are ordinary JavaScript, and lone control characters are a real lexer edge
//! case (oxc even tracks "irregular whitespace" separately). Filtering them would discard most of
//! the interesting corpus.

#![no_main]

use libfuzzer_sys::{Corpus, fuzz_target};
use oxc_allocator::Allocator;
use oxc_parser::{ParseOptions, Parser};
use oxc_span::SourceType;

/// Parse `source_text` under one source type and touch the result so nothing is optimised away.
fn parse_once(source_text: &str, source_type: SourceType) {
    let allocator = Allocator::default();
    let ret = Parser::new(&allocator, source_text, source_type)
        .with_options(ParseOptions {
            // oxlint parses regex literals; doing the same here reaches oxc_regular_expression
            // through the parser as a real embedder would, in addition to the dedicated `regex`
            // target which drives it directly.
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();
    std::hint::black_box((
        ret.program.body.len(),
        ret.program.directives.len(),
        ret.program.comments.len(),
        ret.diagnostics.len(),
        ret.fatal_error,
        ret.is_flow_language,
        ret.irregular_whitespaces.len(),
    ));
}

fuzz_target!(|data: &[u8]| -> Corpus {
    // Reject (never add to the corpus) anything that is not valid UTF-8: oxc's public API takes
    // `&str`, so a real embedder can only ever hand it UTF-8. Rejecting is the documented libFuzzer
    // way to say "this input can't reach the code under test"; repairing the bytes would be worse.
    let Ok(source_text) = std::str::from_utf8(data) else {
        return Corpus::Reject;
    };

    parse_once(source_text, SourceType::tsx());
    parse_once(source_text, SourceType::ts());

    Corpus::Keep
});
