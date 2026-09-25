//! Known-answer probe for `mayhem/test.sh` — a small, DYNAMICALLY LINKED binary that runs oxc's
//! parser and regular-expression parser over FIXED input embedded at compile time and prints the
//! exact values it computed. `mayhem/test.sh` compares every line literally.
//!
//! Why it exists: the conformance gate re-runs `mayhem/test.sh` with an `LD_PRELOAD` shim whose
//! constructor `_exit(0)`s every non-system executable. `cargo test` on its own survives that
//! badly — an empty run looks like a clean run — so the oracle would be reward-hackable. Neutered,
//! this probe prints nothing and every assertion in test.sh fails. A patch that stubs out the
//! parser to dodge a crash cannot reproduce these numbers either.
//!
//! No runtime file I/O, no arguments, no environment dependence: everything is a `const` below.
//! Expected values for the regular-expression section are lifted from oxc's own unit tests
//! (crates/oxc_regular_expression/src/parser/mod.rs), which is what makes them trustworthy.

use oxc_allocator::Allocator;
use oxc_parser::{ParseOptions, Parser};
use oxc_regular_expression::{ConstructorParser, LiteralParser, Options};
use oxc_span::{GetSpan, SourceType};

/// A deliberately dense TSX fixture: ESM import, conditional + template-literal types, an
/// interface with optional and readonly members, a regex literal with named groups, a default-
/// exported generic function, a JSX arrow component, and a class using `accessor`, a private
/// static field, a BigInt literal and an async generator. Every top-level statement is on ONE line
/// so the asserted source slices below never span a newline.
const FIXTURE: &str = r##"import { readFile } from "node:fs/promises";
export type Id<T> = T extends string ? `id-${T}` : never;
export interface Point<T extends number = number> { readonly x: T; y?: T }
const RE = /(?<y>\d{4})-(?<m>\d{2})/u;
export default function dist<T extends number>(a: Point<T>, b: Point<T>): number { return Math.hypot(a.x - b.x, (a.y ?? 0) - (b.y ?? 0)); }
export const El = (p: { n: string }) => <div className="c" data-n={p.n}>{RE.source}</div>;
class C { accessor v = 0; static #s = 1n; async *g() { yield await readFile("x"); } }
// tail comment
"##;

/// `<number>x` is a TYPE ASSERTION in .ts and the start of a JSX element in .tsx. Parsing it under
/// both source types proves the parser really dispatches on `SourceType`.
const TYPE_ASSERTION: &str = "const n = <number>x;";

fn parse_opts() -> ParseOptions {
    ParseOptions { parse_regular_expression: true, ..ParseOptions::default() }
}

/// Parse and report `(fatal_error, diagnostics, statements)`.
fn parse_counts(source: &str, source_type: SourceType) -> (bool, usize, usize) {
    let allocator = Allocator::default();
    let ret = Parser::new(&allocator, source, source_type).with_options(parse_opts()).parse();
    (ret.fatal_error, ret.diagnostics.len(), ret.program.body.len())
}

fn parser_section() {
    println!("KAT_SRC_BYTES={}", FIXTURE.len());

    let allocator = Allocator::default();
    let ret = Parser::new(&allocator, FIXTURE, SourceType::tsx()).with_options(parse_opts()).parse();

    println!("KAT_TSX_FATAL={}", ret.fatal_error);
    println!("KAT_TSX_DIAGNOSTICS={}", ret.diagnostics.len());
    println!("KAT_TSX_STMTS={}", ret.program.body.len());
    println!("KAT_TSX_COMMENTS={}", ret.program.comments.len());
    println!("KAT_TSX_PROGRAM_SPAN={}:{}", ret.program.span.start, ret.program.span.end);

    let spans = ret
        .program
        .body
        .iter()
        .map(|stmt| {
            let span = stmt.span();
            format!("{}:{}", span.start, span.end)
        })
        .collect::<Vec<_>>()
        .join(",");
    println!("KAT_TSX_STMT_SPANS={spans}");

    // Golden source slices, recovered from the AST spans — a stubbed parser cannot produce these.
    for (i, stmt) in ret.program.body.iter().enumerate() {
        println!("KAT_TSX_STMT{i}_TEXT={}", stmt.span().source_text(FIXTURE));
    }

    // The same TypeScript source is NOT valid plain JavaScript: the parser must report errors
    // rather than silently accepting it.
    let (fatal, diags, _) = parse_counts(FIXTURE, SourceType::mjs());
    println!("KAT_AS_JS_FATAL={fatal}");
    println!(
        "KAT_AS_JS={}",
        if diags > 0 { "rejected" } else { "ACCEPTED-BUG" }
    );

    // Source-type dispatch: type assertion parses in .ts, is a JSX error in .tsx.
    let (_, ts_diags, ts_stmts) = parse_counts(TYPE_ASSERTION, SourceType::ts());
    println!(
        "KAT_TYPE_ASSERTION_TS={}",
        if ts_diags == 0 && ts_stmts == 1 { "ok" } else { "unexpected" }
    );
    let (_, tsx_diags, _) = parse_counts(TYPE_ASSERTION, SourceType::tsx());
    println!(
        "KAT_TYPE_ASSERTION_TSX={}",
        if tsx_diags > 0 { "rejected" } else { "ACCEPTED-BUG" }
    );

    // Empty input is valid and must not be fatal.
    let (empty_fatal, empty_diags, empty_stmts) = parse_counts("", SourceType::tsx());
    println!("KAT_EMPTY={empty_fatal},{empty_diags},{empty_stmts}");
}

fn literal(allocator: &Allocator, pattern: &str, flags: Option<&str>) -> Result<String, ()> {
    LiteralParser::new(allocator, pattern, flags, Options::default())
        .parse()
        .map(|p| p.to_string())
        .map_err(|_| ())
}

fn regex_section() {
    let allocator = Allocator::default();

    // Term counts for a mixed-script/astral pattern. Expected values are oxc's own
    // `should_handle_unicode` test: 15 terms without a unicode flag (the emoji is a surrogate
    // pair), 14 with `u` or `v`.
    let unicode_pattern = "このEmoji🥹の数が変わる";
    let counts = [None, Some("u"), Some("v")]
        .iter()
        .map(|flags| {
            LiteralParser::new(&allocator, unicode_pattern, *flags, Options::default())
                .parse()
                .map_or_else(|_| "err".to_string(), |p| p.body.body[0].body.len().to_string())
        })
        .collect::<Vec<_>>()
        .join(",");
    println!("KAT_REGEX_TERMS={counts}");

    // Duplicate named capture groups in DIFFERENT alternatives are legal (ES2025); the parsed
    // pattern must have exactly two alternatives.
    let dup_alt = r"(?<year>[0-9]{4})-[0-9]{2}|[0-9]{2}-(?<year>[0-9]{4})";
    match LiteralParser::new(&allocator, dup_alt, Some(""), Options::default()).parse() {
        Ok(p) => println!("KAT_REGEX_ALTERNATIVES={}", p.body.body.len()),
        Err(_) => println!("KAT_REGEX_ALTERNATIVES=err"),
    }

    // Display re-renders the parsed AST: an exact round-trip is a strong known answer.
    let roundtrip = r"^(?:a|b)+[\d-]{2,3}\p{Sc}$";
    match literal(&allocator, roundtrip, Some("u")) {
        Ok(rendered) if rendered == roundtrip => println!("KAT_REGEX_ROUNDTRIP=exact"),
        Ok(rendered) => println!("KAT_REGEX_ROUNDTRIP=differs:{rendered}"),
        Err(()) => println!("KAT_REGEX_ROUNDTRIP=err"),
    }

    // The `/…/` and `new RegExp("…")` front ends must agree once escapes are resolved (oxc's own
    // `string_literal` test).
    let via_literal = literal(&allocator, r"\d{4}-\d{2}-\d{2}", Some("vi"));
    let via_ctor = ConstructorParser::new(
        &allocator,
        r"'\\d{4}-\\d{2}-\\d{2}'",
        Some("'vi'"),
        Options::default(),
    )
    .parse()
    .map(|p| p.to_string())
    .map_err(|_| ());
    println!(
        "KAT_REGEX_CTOR={}",
        match (&via_literal, &via_ctor) {
            (Ok(a), Ok(b)) if a == b => "same".to_string(),
            (Ok(a), Ok(b)) => format!("differs:{a}|{b}"),
            _ => "err".to_string(),
        }
    );

    // An out-of-range decimal backreference is an error under `u`, but falls back to an Annex B
    // legacy octal/identity escape without a unicode flag — and must then round-trip exactly.
    let oversized = r"()\4294967296";
    println!(
        "KAT_REGEX_BACKREF_U={}",
        if literal(&allocator, oversized, Some("u")).is_err() { "rejected" } else { "ACCEPTED-BUG" }
    );
    println!(
        "KAT_REGEX_BACKREF_ANNEXB={}",
        match literal(&allocator, oversized, None) {
            Ok(rendered) if rendered == oversized => "exact".to_string(),
            Ok(rendered) => format!("differs:{rendered}"),
            Err(()) => "err".to_string(),
        }
    );

    // Malformed patterns must be REJECTED, not repaired.
    for (label, pattern, flags) in [
        ("RANGE", "[z-a]", Some("")),
        ("PROPERTY", r"\p{Foo}", Some("u")),
        ("DUP_GROUP", r"(?<n>.)(?<n>.)", Some("")),
        ("UNTERMINATED", "(", Some("")),
        ("QUANTIFIER", "a{2,1}", Some("")),
        ("FLAGS_UV", "a", Some("uv")),
        ("FLAGS_DUP", "a", Some("gg")),
    ] {
        println!(
            "KAT_REGEX_{label}={}",
            if literal(&allocator, pattern, flags).is_err() { "rejected" } else { "ACCEPTED-BUG" }
        );
    }
}

fn main() {
    parser_section();
    regex_section();
    println!("KAT_DONE=1");
}
