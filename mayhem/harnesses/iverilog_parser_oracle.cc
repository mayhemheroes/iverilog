/*
 * iverilog_parser_oracle.cc — a small golden oracle over the SAME parser path
 * the fuzzer drives (pform_parse), used by mayhem/test.sh.
 *
 * It asserts a positive AND a negative property, so a no-op / "always succeed"
 * patch cannot pass:
 *   - a known-GOOD Verilog module must parse with zero errors, and
 *   - a known-MALFORMED input must be rejected (non-zero error_count).
 *
 * Usage:  iverilog_parser_oracle <good.v> <bad.v>
 * Exit 0 iff good parses cleanly AND bad is rejected.
 */

#include <cstdio>
#include <cstdlib>
#include "compiler.h"   // GN_KEYWORDS_*, `extern int lexor_keyword_mask;`

extern int  pform_parse(const char* path);
extern void pform_finish();
extern int lexor_keyword_mask;

static void init_mask(void) {
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

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <good.v> <bad.v>\n", argv[0]);
    return 2;
  }
  init_mask();

  // pform_parse returns the accumulated error_count for that file.
  int good_errs = pform_parse(argv[1]);
  int bad_errs  = pform_parse(argv[2]);
  pform_finish();

  fprintf(stderr, "oracle: good_errs=%d bad_errs=%d\n", good_errs, bad_errs);

  int ok = (good_errs == 0) && (bad_errs > 0);
  return ok ? 0 : 1;
}
