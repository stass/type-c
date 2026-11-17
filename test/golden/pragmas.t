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

An identifier of a `#pragma` line that names a macro there is refused,
whatever the pragma, in C text as in Type-C text (design 13.5). Clang
replaces a macro in many pragmas when it compiles C, but finds it as
written in the preprocessed text that typec compiles: here Clang packs
`struct wire` to 1 in a `.c` unit and to its natural alignment in the
`.tc` unit that includes the same header, where `M_PACK` reads as a
label.

  $ cat > wire.c <<'EOF'
  > #define M_PACK 1
  > #pragma pack(push, M_PACK)
  > struct wire { char a; int b; };
  > #pragma pack(pop)
  > EOF
  $ ./golden.exe wire.c
  wire.c:2: error: `M_PACK` in a `#pragma pack` line names the macro defined at wire.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

A label of `push` and `pop` that names no macro passes.

  $ cat > label.tc <<'EOF'
  > #pragma pack(push, saved, 1)
  > struct wire { char a; int b; };
  > #pragma pack(pop, saved)
  > EOF
  $ ./golden.exe label.tc
  # 1 "label.tc"
  #pragma pack(push, saved, 1)
  struct wire { char a; int b; };
  #pragma pack(pop, saved)

A macro named as a word of the pragma is refused as any other: under
it a `.c` unit packs the structure and a `.tc` unit does not.

  $ cat > natural.c <<'EOF'
  > #define natural packed
  > #pragma options align=natural
  > struct wire { char a; int b; };
  > EOF
  $ ./golden.exe natural.c
  natural.c:2: error: `natural` in a `#pragma options` line names the macro defined at natural.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

A name that an `#undef` before the line removes passes, and a macro
defined after the line is none there.

  $ cat > undef.tc <<'EOF'
  > #define M_PACK 1
  > #undef M_PACK
  > #pragma pack(push, M_PACK)
  > #pragma pack(pop)
  > #pragma pack(push, LATER)
  > #define LATER 1
  > EOF
  $ ./golden.exe undef.tc
  # 1 "undef.tc"
  
  
  #pragma pack(push, M_PACK)
  #pragma pack(pop)
  #pragma pack(push, LATER)
  

The rule holds for every pragma, not only those of layout.

  $ cat > weak.c <<'EOF'
  > #define TARGET g
  > void f(void);
  > #pragma weak f = TARGET
  > EOF
  $ ./golden.exe weak.c
  weak.c:3: error: `TARGET` in a `#pragma weak` line names the macro defined at weak.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

  $ cat > extname.c <<'EOF'
  > #define NEW_NAME other
  > #pragma redefine_extname old NEW_NAME
  > EOF
  $ ./golden.exe extname.c
  extname.c:2: error: `NEW_NAME` in a `#pragma redefine_extname` line names the macro defined at extname.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

  $ cat > float_control.c <<'EOF'
  > #define MODE precise
  > #pragma float_control(MODE, on)
  > EOF
  $ ./golden.exe float_control.c
  float_control.c:2: error: `MODE` in a `#pragma float_control` line names the macro defined at float_control.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

The pragma's own name is held to the rule as its arguments are.

  $ cat > name.c <<'EOF'
  > #define pack align
  > #pragma pack(1)
  > EOF
  $ ./golden.exe name.c
  name.c:2: error: `pack` in a `#pragma pack` line names the macro defined at name.c:1: Clang replaces a macro in many pragmas when it compiles C and keeps it as written in the preprocessed text that typec compiles; rename the identifier or #undef the macro before the line [pragma-macro]
  [1]

Numbers and identifiers that name no macro pass, whatever the pragma.

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
