SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The backend exempts a system header from warnings by the flags of the
line marker in effect, and the markers that typec writes around lowered
text carry the flags of the marker in effect where they stand, so the
exemption holds after an edit (design 13.4). A zero-length array, which
-pedantic-errors refuses in the user's code, follows an edit in each kind
of system region: a header that #pragma GCC system_header makes one,
reached by -I, a header reached by -isystem, and, with GCC, which marks
the tokens of a system macro with flag 3, the expansion of such a macro
in the main file. A passing run prints nothing but the control.

  $ . ./backends.sh

  $ mkdir include system
  $ cat > include/pragma.tci <<'EOF'
  > #pragma GCC system_header
  > type pragma_metres = distinct int;
  > int pragma_zero[0];
  > #define ZERO type macro_metres = distinct int; int macro_zero[0]
  > EOF
  $ cat > system/isystem.tci <<'EOF'
  > type isystem_metres = distinct int;
  > int isystem_zero[0];
  > EOF
  $ cat > headers.tc <<'EOF'
  > #include "pragma.tci"
  > #include <isystem.tci>
  > int main(void) { return 0; }
  > EOF
GCC writes a marker for a system macro region only where the previous
token it printed is not in a system header, so a declaration of the user
stands between the header and the expansion.

  $ cat > macro.tc <<'EOF'
  > #include "pragma.tci"
  > int user;
  > ZERO;
  > int main(void) { return 0; }
  > EOF

The control: the same array in the user's code is refused.

  $ cat > user.tc <<'EOF'
  > type user_metres = distinct int;
  > int user_zero[0];
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -std=c11 -pedantic-errors -c user.tc -o user.o \
  >     2> /dev/null || echo refused
  > done
  refused
  refused

  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -std=c11 -pedantic-errors -I include -isystem system \
  >     -c headers.tc -o headers.o || echo "failed with $cc"
  > done
  $ typec --cc="$gcc" -std=c11 -pedantic-errors -I include \
  >   -c macro.tc -o macro.o
