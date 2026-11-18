SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec's own diagnostic shows the line of the source file that it names
under the message, as the backends show theirs, without a caret: the
location is a file and a line, with no column (design 13.6).

  $ . ./backends.sh
  $ refused() {
  >   printf 'int f(void) {\n%s\n\treturn x;\n}\n' "$1" > "$2"
  > }

The line is shown as the file holds it, after the number of the line
and a bar; a tab stays a tab, and the prefix of eight columns keeps the
tab stops of the source.

  $ refused '		int x = Some(1);' plain.tc
  $ typec --cc=$clang -c plain.tc
  plain.tc:2: error: 'Some' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
      2 | 		int x = Some(1);
  [80]

The tokens of a macro's expansion are on the line of its use, which is
the line shown, as the backends show it.

  $ printf '#define S Some(1)\nint f(void) {\n\tint x = S;\n\treturn x;\n}\n' \
  >   > macro.tc
  $ typec --cc=$gcc -c macro.tc
  macro.tc:3: error: 'Some' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
      3 | 	int x = S;
  [80]

The source file is untrusted text printed to a terminal: a byte that is
not printable ASCII is escaped as in the message, a character of UTF-8
as a universal character name and any other byte as \xNN. A carriage
return that ends the line is not shown.

  $ refused "	int x = Some(1); /* $(printf '\033[31m \001 \303\251') */" \
  >   control.tc
  $ typec --cc=$clang -c control.tc
  control.tc:2: error: 'Some' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
      2 | 	int x = Some(1); /* \x1B[31m \x01 \u00E9 */
  [80]
  $ printf 'int f(void) {\r\n\tint x = Some(1);\r\n\treturn x;\r\n}\r\n' \
  >   > crlf.tc
  $ typec --cc=$gcc -c crlf.tc
  crlf.tc:2: error: 'Some' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
      2 | 	int x = Some(1);
  [80]

A line longer than 200 bytes is cut there, on the boundary of a
character, and ends with "...".

  $ long="	int x = Some(1); /* $(printf 'a%.0s' $(seq 178))"
  $ refused "$long$(printf '\303\251') */" long.tc
  $ typec --cc=$clang -c long.tc
  long.tc:2: error: 'Some' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
      2 | 	int x = Some(1); /* aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...
  [80]

Nothing more is shown for a line that no regular file holds: a name
that no file has, as that of standard input, a line past the end of the
file, a device or a FIFO, which is not opened, or a line past the first
16 MiB of the file, which is all that is read.

  $ echo 'one line' > short && mkfifo fifo
  $ { dd if=/dev/zero bs=1048576 count=16 2>/dev/null; printf '\nx\n'; } \
  >   > big
  $ for name in '<stdin>' gone.tc short /dev/zero fifo big; do
  >   refused "#line 2 \"$name\"
  > 	int x = Some(1);" named.tc
  >   typec --cc=$gcc -c named.tc 2>&1 | sed 's/: error: .*/: error/'
  > done
  <stdin>:2: error
  gone.tc:2: error
  short:2: error
  /dev/zero:2: error
  fifo:2: error
  big:2: error

A line marker spells a name with escape sequences, which typec does not
decode, so a name that holds a backslash is not read: the file named as
the marker spells it is another file.

  $ refused '	int x = Some(1);' 'a\b.tc'
  $ refused '	int decoy = 0;' 'a\\b.tc'
  $ typec --cc=$clang -c 'a\b.tc' 2>&1 | sed 's/: error: .*/: error/'
  a\\b.tc:2: error
