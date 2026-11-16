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
  mark.tc:2: a `#pragma` line whose text is no sequence of preprocessing tokens: unterminated literal (design 13.5) [TC0040]
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
