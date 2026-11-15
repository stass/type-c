SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

C that names a function `try` and an object `defer` builds and runs as
Type-C text, on each backend (design 2.3): the declarations hide the
Type-C words, the one of `try` in a header that the Type-C file
includes.

  $ . ./backends.sh

  $ cat > try.h <<'EOF'
  > static int try(const char *hex, int err) { return hex[0] == '0' && !err; }
  > EOF
  $ cat > words.tc <<'EOF'
  > #include "try.h"
  > static int spill(int try) { int defer = try + 1; return defer; }
  > int main(void) { return !(try("00", 0) && spill(1) == 2); }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-words words.tc && ./clang-words
  $ typec --cc=$gcc -Wall -Werror -o gcc-words words.tc && ./gcc-words
