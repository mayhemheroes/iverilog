/*
 * iverilog_parser_fuzzer.cc — libFuzzer harness for Icarus Verilog's
 * front end (lexer + parser + pform construction).
 *
 * The fuzzed surface is pform_parse() (declared in parse_api.h), the same
 * entry point ivl's main() drives for every input file. We feed
 * attacker-controlled Verilog/SystemVerilog SOURCE TEXT through the flex
 * lexer (lexor.lex), the bison grammar (parse.y) and the parse-form (pform)
 * builders (pform*.cc, PExpr/PGate/Statement/... .cc) that the grammar
 * actions invoke. This exercises the rich Verilog parser surface noted in
 * the integration brief.
 *
 * pform_parse() opens a path itself: with ivlpp_string left NULL and the
 * path != "-", it fopen()s the file directly (NO preprocessor subprocess),
 * resets the lexor, runs VLparse(), then destroy_lexor()s. So the harness
 * just needs to (a) set the language keyword mask once and (b) hand
 * pform_parse a file containing the fuzz bytes.
 *
 * All of ivl's global flags/heaps (generation_flag, lex_strings, flags map,
 * warn_count, error_count, ...) are DEFINED in main.cc. We keep main.o in
 * the link (compiled with -Dmain=ivl_disabled_main so its argv main never
 * runs) to provide those definitions verbatim — this avoids re-declaring
 * dozens of upstream globals and stays correct across upstream syncs.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <unistd.h>

#include "compiler.h"   // GN_KEYWORDS_* and `extern int lexor_keyword_mask;`

extern int  pform_parse(const char* path);
extern void pform_finish();

// Globals defined in main.cc that select the language dialect for the lexor.
extern int lexor_keyword_mask;

// One-time process init: enable the full keyword set so the lexer recognises
// the broadest dialect (IEEE1800-2012 SystemVerilog + Verilog-AMS + Icarus
// extensions). This maximises the reachable grammar surface.
static void fuzzer_init(void) {
  lexor_keyword_mask =
        GN_KEYWORDS_1364_1995
      | GN_KEYWORDS_1364_2001
      | GN_KEYWORDS_1364_2001_CONFIG
      | GN_KEYWORDS_1364_2005
      | GN_KEYWORDS_1800_2005
      | GN_KEYWORDS_1800_2009
      | GN_KEYWORDS_1800_2012
      | GN_KEYWORDS_VAMS_2_3
      | GN_KEYWORDS_ICARUS;
}

// Persistent temp file: created once, rewritten each iteration. Using a fixed
// fd avoids per-iteration open/unlink churn and keeps the file off the corpus
// directory.
static char  tmpl[] = "/tmp/iverilog_fuzz_XXXXXX";
static int   tmpfd  = -1;
static bool  inited = false;

#ifdef __cplusplus
extern "C"
#endif
int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (!inited) {
    fuzzer_init();
    tmpfd = mkstemp(tmpl);
    if (tmpfd < 0) return 0;   // cannot create scratch file; nothing to do
    inited = true;
  }

  // Rewrite the scratch file with the current input.
  if (ftruncate(tmpfd, 0) != 0) return 0;
  if (lseek(tmpfd, 0, SEEK_SET) != 0) return 0;
  size_t off = 0;
  while (off < size) {
    ssize_t w = write(tmpfd, data + off, size - off);
    if (w <= 0) return 0;
    off += (size_t)w;
  }

  // pform_parse() fopen()s the path read-only, so the data must be flushed to
  // the filesystem — it is, since we used the raw fd write() above.
  (void)pform_parse(tmpl);

  // Drive the post-parse import resolution the driver runs after parsing.
  pform_finish();

  return 0;
}
