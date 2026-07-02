#!/usr/bin/env bash
#
# iverilog/mayhem/build.sh — build Icarus Verilog's front end (lexer + bison
# grammar + pform builders) as a sanitized libFuzzer target (+ a standalone
# reproducer), AND a small golden parser oracle for mayhem/test.sh.
#
# Fuzzed surface: pform_parse() — the parser entry point ivl's main() drives for
# every input file. The harness (mayhem/harnesses/iverilog_parser_fuzzer.cc)
# feeds attacker-controlled Verilog/SystemVerilog source text through the flex
# lexer (lexor.lex), the bison grammar (parse.y) and the parse-form construction
# code (pform*.cc, PExpr/PGate/Statement/... .cc).
#
# Build strategy: use iverilog's own autotools build to compile every `ivl`
# object (this also runs bison/flex/gperf to generate parse.cc/lexor.cc/
# lexor_keyword.cc), then LINK our own libFuzzer + standalone binaries from
# those objects. We compile the whole project with $SANITIZER_FLAGS AND
# -fsanitize=fuzzer-no-link so the parser (not just the harness) carries
# SanitizerCoverage counters — without that, libFuzzer sees ~15 edges and can't
# explore the grammar.
#
# main.cc DEFINES dozens of global flags/heaps the parser needs (generation_flag,
# lex_strings, the `flags` map, warn_count, error_count, ...). Rather than
# re-declare them all (and drift on upstream syncs) we keep main.o in the link,
# recompiled with -Dmain=ivl_disabled_main so its argv main() is never the entry
# point — only its global definitions are used.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/
# LIB_FUZZING_ENGINE/SRC/STANDALONE_FUZZ_MAIN/OUT).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required so Mayhem triage can read symbols (§6.2 item 10).
# clang-19 defaults to DWARF-5; be explicit. Overridable; threaded AFTER $SANITIZER_FLAGS.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${SRC:=/mayhem}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN SRC OUT MAYHEM_JOBS

# Coverage instrumentation for the project objects so libFuzzer can explore.
COVERAGE_FLAGS="-fsanitize=fuzzer-no-link"
ALL_FLAGS="$SANITIZER_FLAGS $COVERAGE_FLAGS $DEBUG_FLAGS"

cd "$SRC"

# git describe (for version_tag.h) refuses to run on a repo whose owner != the
# build user; mark it safe so the Makefile's version_tag.h rule succeeds.
git config --global --add safe.directory "$SRC" 2>/dev/null || true

# ── 1) Generate configure + the gperf keyword table, then configure ───────────────
# autoconf.sh also runs gperf for vhdlpp/, which we don't fuzz; do just what we need.
autoconf -f
gperf -o -i 7 -C -k '1-4,6,9,$' -H keyword_hash -N check_identifier -t \
      ./lexor_keyword.gperf > lexor_keyword.cc

./configure CC="$CC" CXX="$CXX" CFLAGS="$ALL_FLAGS" CXXFLAGS="$ALL_FLAGS"

# Force a real VERSION_TAG (the rule no-ops if an empty file already exists).
rm -f version_tag.h
make version_tag.h

# ── 2) Compile every ivl object (sanitized + instrumented). The final `ivl` link
#       step is EXPECTED to fail (the Makefile links without the sanitizer runtime),
#       so use `-k` (keep going) to compile ALL objects despite that link error. ────
make -k -j"$MAYHEM_JOBS" ivl || true

# Guard: the parser objects we depend on must exist.
for o in pform.o parse.o lexor.o lexor_keyword.o main.o; do
  [ -f "$o" ] || { echo "ERROR: expected object $o was not built" >&2; exit 1; }
done

# Recompile main.cc with main() renamed so it's never the entry point; we only
# want the global definitions it provides.
$CXX -std=c++11 -DHAVE_CONFIG_H -I. -Ilibmisc $ALL_FLAGS $DEBUG_FLAGS \
     -Dmain=ivl_disabled_main -c main.cc -o main_fuzz.o

# The object set = every ivl object EXCEPT the original main.o (replaced by main_fuzz.o).
OBJS=()
for o in *.o; do
  case "$o" in main.o|main_fuzz.o|standalone_solo_main.o) continue;; esac
  OBJS+=("$o")
done

HARNESS="$SRC/mayhem/harnesses/iverilog_parser_fuzzer.cc"

# ── 3) libFuzzer target -> $OUT/iverilog_parser_fuzzer ────────────────────────────
$CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS -I. -Ilibmisc \
     "$HARNESS" main_fuzz.o "${OBJS[@]}" \
     $LIB_FUZZING_ENGINE -ldl \
     -o "$OUT/iverilog_parser_fuzzer"

# ── 4) standalone reproducer (org StandaloneFuzzTargetMain.c, no libFuzzer rt) ────
# Compile the standalone driver as C (with $CC) so its `extern int
# LLVMFuzzerTestOneInput(...)` keeps C linkage and matches the harness's
# `extern "C"` definition — compiling the .c through $CXX would C++-mangle it
# and break the link.
# Use a unique object name (standalone_solo_main.o) to avoid collision with any
# cached standalone_main.o in the project build tree on idempotent re-runs.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o standalone_solo_main.o
$CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS -I. -Ilibmisc \
     "$HARNESS" standalone_solo_main.o main_fuzz.o "${OBJS[@]}" \
     -ldl \
     -o "$OUT/iverilog_parser_fuzzer-standalone"

# ── 5) golden parser oracle for mayhem/test.sh (same pform_parse path) ────────────
$CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS -I. -Ilibmisc \
     "$SRC/mayhem/harnesses/iverilog_parser_oracle.cc" main_fuzz.o "${OBJS[@]}" \
     -ldl \
     -o "$OUT/iverilog_parser_oracle"

echo "build.sh complete:"
ls -la "$OUT/iverilog_parser_fuzzer" "$OUT/iverilog_parser_fuzzer-standalone" \
       "$OUT/iverilog_parser_oracle"
