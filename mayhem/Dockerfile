# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz) for oxc-project/oxc. Builds ON TOP of
# the org base (ghcr.io/savantenvs/base), which supplies clang — needed both to link the
# ASan-instrumented cargo-fuzz binaries and to compile the two prepended objects (the DWARF3
# anchor and the LeakSanitizer hook) — then runs the repo's mayhem/build.sh.
#
# WHAT IS FUZZED. oxc is a JavaScript/TypeScript toolchain written in Rust. The harnessed surface
# is its FRONT END: the JS/TS/JSX parser (`crates/oxc_parser`) and the ECMAScript
# regular-expression parser (`crates/oxc_regular_expression`). Both consume untrusted third-party
# source code by design — that is what a linter, formatter or bundler is for — and both are
# hand-written recursive-descent parsers over raw pointer/index arithmetic. See mayhem/build.sh
# and the two harnesses under mayhem/fuzz/fuzz_targets/ for the per-target rationale.
#
# UPSTREAM SHIPS NO fuzz/ DIRECTORY at this commit: 0236e947bd ("chore: move fuzz/ to
# https://github.com/oxc-project/oxc-fuzz-parser") moved it into a separate repository whose
# fuzz/Cargo.toml depends on the PUBLISHED crates (oxc = "0.151.0"). Vendoring that as-is would
# fuzz a crates.io release rather than this commit, so mayhem/fuzz/ is an ADDITIVE cargo-fuzz
# crate that adapts the harness logic and reaches every oxc crate BY PATH. No upstream file is
# touched.
#
# WHY a Rust-specific template (SPEC §6.2 items 8/9, §6.5):
#   The Rust toolchain and its package cache (the cargo registry) are NOT in the base. We install
#   them at a FIXED, $HOME-independent prefix (/opt/toolchains/rust) and pin CARGO_HOME/RUSTUP_HOME
#   there as ENV, so the cargo registry this FIRST (online) build populates is found again — by the
#   SAME absolute CARGO_HOME — when the PATCH RL tier re-runs build.sh with NO network.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t oxc-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────────────────
# Nightly is required for -Zsanitizer=address (the OSS-Fuzz Rust ASan path), pinned by DATE for a
# reproducible build. It must be at least as new as the stable channel upstream pins
# (rust-toolchain.toml = 1.98.1), because oxc's crates are edition 2024 with an MSRV of 1.96;
# nightly-2026-06-15 is a ~1.98-era nightly.
# cargo-fuzz is pinned by version but installed WITHOUT --locked on purpose: cargo-fuzz 0.13.1's
# own shipped lockfile pins rustix 0.38.x, which no longer compiles on a 2026 nightly
# ("attributes starting with `rustc` are reserved"), so the install step resolves fresh instead.
# NOTE the `rust-src` component is deliberately NOT installed: it is only needed for -Zbuild-std,
# which cargo-fuzz is not asked for here, and it costs ~81 MB in the image.
ARG RUST_CHANNEL=nightly-2026-06-15
ARG CARGO_FUZZ_VERSION=0.13.1

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH} \
    RUST_FUZZ_TOOLCHAIN=${RUST_CHANNEL}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must read the
 # toolchain and read/refresh the cargo registry cache, so hand the whole prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# ── upstream's OWN rust-toolchain.toml pins a SECOND toolchain (stable, not our nightly) ──
# oxc's repo root ships `rust-toolchain.toml` (channel = "1.98.1", an upstream file we never edit).
# rustup's directory-override lookup applies that file to EVERY cargo invocation anywhere under
# this tree — including our additive mayhem/fuzz and mayhem/kat crates — so a BARE `cargo fuzz
# build` here would silently run under that stable toolchain and die with "the option `Z` is only
# accepted on the nightly compiler". Fix, applied in mayhem/build.sh and mayhem/test.sh: ALWAYS
# pass an explicit `+<toolchain>`, never bare `cargo`. The oracle path (oxc's own test suite + the
# KAT probe) uses upstream's OWN pin, which must therefore be installed HERE, online, once.
# `rustup toolchain install` for a fully-qualified version like "1.98.1" resolves without a channel
# refresh, and a later `+1.98.1` reference to an already-installed toolchain needs no network at
# all — which is what keeps the air-gapped PATCH re-run working.
RUN rustup toolchain install 1.98.1 --profile minimal \
 && chown -R 2000:2000 /opt/toolchains/rust

# ── DWARF<4 anchor object (SPEC §6.2 item 10) ──────────────────────────────────────────────
# cargo-fuzz's ASan runtime archive and rustc's own code generation both emit CUs at DWARF4/5;
# Mayhem's triage reads DWARF<=3, and the gate reads the FIRST .debug_info CU only. Compile a tiny,
# real (non-empty — a CU DIE is only emitted when the TU defines something) translation unit at
# -gdwarf-3 here; mayhem/build.sh generates a `-Clinker` cc-wrapper that PREPENDS this object ahead
# of every other link input. Empirically, PREPEND (not append) is required for its CU to land at
# .debug_info offset 0, which is what `readelf --debug-dump=info | grep -m1 Version:` reads.
RUN install -d /opt/toolchains/rust/dwarf3 \
 && printf 'int __mayhem_dwarf3_anchor;\n' > /tmp/anchor.c \
 && clang -g -gdwarf-3 -c /tmp/anchor.c -o /opt/toolchains/rust/dwarf3/anchor.o \
 && rm -f /tmp/anchor.c \
 && chown -R 2000:2000 /opt/toolchains/rust/dwarf3

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz targets, the LSan
# hook object, the cc-wrapper, the /mayhem/kat oracle probe and oxc's own test suite.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
