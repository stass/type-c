SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The text of a `#pragma` line after `pragma`, which typec reads as
preprocessing tokens (design 13.5). Each source is preprocessed text, as
the backend writes it for -E; a file named *.tc holds Type-C text.

A pragma line of tokens passes through in Type-C text.

  $ cat > tokens.tc <<'EOF'
  > #pragma GCC diagnostic push
  > #pragma message("don't")
  > int x;
  > EOF
  $ ./golden.exe tokens.tc
  # 1 "tokens.tc"
  #pragma GCC diagnostic push
  #pragma message("don't")
  int x;

A line with a quote that begins no literal ending on the line is no
sequence of tokens, which Type-C text refuses.

  $ cat > mark.tc <<'EOF'
  > int x;
  > #pragma mark - Don't edit
  > int y;
  > EOF
  $ ./golden.exe mark.tc
  mark.tc:2: error: a `#pragma` line whose text is no sequence of preprocessing tokens: unterminated literal [pragma-tokens]
  [1]

C text that does not move passes such a line on whole.

  $ cat > mark.c <<'EOF'
  > int x;
  > #pragma mark - Don't edit
  > int y;
  > EOF
  $ ./golden.exe mark.c
  # 1 "mark.c"
  int x;
  #pragma mark - Don't edit
  int y;

The arguments of a `#pragma pack`, `align`, `options` or `ms_struct`
line are the pragma's own words and numbers (design 13.5). Clang
replaces a macro there when it compiles C, but finds it as written in
the preprocessed text that typec compiles, so another identifier is
refused, in C text as in Type-C text: here Clang packs `struct wire` to
1 in a `.c` unit and to its natural alignment in the `.tc` unit that
includes the same header, where `M_PACK` reads as a label.

  $ cat > wire.c <<'EOF'
  > #pragma pack(push, M_PACK)
  > struct wire { char a; int b; };
  > #pragma pack(pop)
  > EOF
  $ ./golden.exe wire.c
  wire.c:1: error: `M_PACK` in a `#pragma pack` line, which is none of the pragma's words (push, pop, show): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

A label of `push` and `pop` is refused as well, since typec cannot tell
it from a macro.

  $ cat > label.tc <<'EOF'
  > #pragma pack(push, saved, 1)
  > struct wire { char a; int b; };
  > #pragma pack(pop, saved)
  > EOF
  $ ./golden.exe label.tc
  label.tc:1: error: `saved` in a `#pragma pack` line, which is none of the pragma's words (push, pop, show): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

The other pragmas of the table hold their own words alone too.

  $ cat > align.c <<'EOF'
  > #pragma options align=ALIGNMENT
  > struct wire { char a; int b; };
  > EOF
  $ ./golden.exe align.c
  align.c:1: error: `ALIGNMENT` in a `#pragma options` line, which is none of the pragma's words (align, native, natural, packed, power, mac68k, reset): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

  $ cat > ms_struct.c <<'EOF'
  > #pragma ms_struct SWITCH
  > struct wire { char a; int b; };
  > EOF
  $ ./golden.exe ms_struct.c
  ms_struct.c:1: error: `SWITCH` in a `#pragma ms_struct` line, which is none of the pragma's words (on, off, reset): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

  $ cat > align.tc <<'EOF'
  > struct wire { char a; int b; };
  > #pragma align=ALIGNMENT
  > EOF
  $ ./golden.exe align.tc
  align.tc:2: error: `ALIGNMENT` in a `#pragma align` line, which is none of the pragma's words (native, natural, packed, power, mac68k, reset): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

A label after `pop` is refused as one after `push` is.

  $ cat > pop.c <<'EOF'
  > #pragma pack(push, 1)
  > #pragma pack(pop, saved)
  > EOF
  $ ./golden.exe pop.c
  pop.c:2: error: `saved` in a `#pragma pack` line, which is none of the pragma's words (push, pop, show): Clang replaces a macro there when it compiles C and keeps it as written in the preprocessed text that typec compiles; write the value the macro stands for [pragma-word]
  [1]

Numbers and the pragmas' own words pass through, as do the identifiers
of every other pragma, which both backends read as written in either
mode.

  $ cat > words.tc <<'EOF'
  > #pragma pack(push, 1)
  > #pragma pack(show)
  > #pragma pack(pop)
  > #pragma pack(4)
  > #pragma pack()
  > #pragma options align=packed
  > #pragma options align=reset
  > #pragma align=natural
  > #pragma ms_struct on
  > #pragma ms_struct off
  > #pragma GCC visibility push(hidden)
  > #pragma GCC visibility pop
  > #pragma STDC FP_CONTRACT ON
  > struct wire { char a; int b; };
  > EOF
  $ ./golden.exe words.tc
  # 1 "words.tc"
  #pragma pack(push, 1)
  #pragma pack(show)
  #pragma pack(pop)
  #pragma pack(4)
  #pragma pack()
  #pragma options align=packed
  #pragma options align=reset
  #pragma align=natural
  #pragma ms_struct on
  #pragma ms_struct off
  #pragma GCC visibility push(hidden)
  #pragma GCC visibility pop
  #pragma STDC FP_CONTRACT ON
  struct wire { char a; int b; };
