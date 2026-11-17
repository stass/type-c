# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# readme.sh FAMILY BACKEND README: checks that the examples of README
# hold on BACKEND, of FAMILY clang or gcc, in a directory of its own
# named after FAMILY, and prints what differs. The README marks its
# examples with a comment line right before the opening fence:
#
# - "<!-- file: NAME -->" writes the block to NAME, a relative path of
#   letters, digits and "_./-" that does not climb with "..";
# - "<!-- emit-c: NAME -->" says that the block is the C of
#   "typec --emit-c NAME", without its line markers and the assertions
#   that typec appends; the comparison is of tokens, so that the block
#   can be laid out for reading;
# - "<!-- console: FAMILY -->" runs the console block on FAMILY only;
# - "<!-- untested: REASON -->" skips the c block, which shows Type-C
#   that typec does not build yet.
#
# Every c block carries a file, emit-c or untested marker, and a fence
# of a language other than c, console, sh or text is an error, so that
# a forgotten marker or a misspelt fence cannot drop a check.
#
# Every line "$ COMMAND" of a console block is run, with cc meaning
# BACKEND and typec running it, and the lines up to the next command or
# the end of the block are what it prints on stdout and stderr, then
# its exit status in brackets when that is not 0. Blocks of other
# kinds, such as sh, are not run.

family=$1
backend=$2
readme=$3
case $family in
clang | gcc) ;;
*) echo "readme.sh: FAMILY is clang or gcc, not $family" >&2; exit 1 ;;
esac
work=work-$family
mkdir "$work" || exit 1

# The awk program reads the README a line at a time. Outside a block,
# it keeps what the last line marks in marker and marked; at a fence it
# opens the block that the marker asks for. Inside a block, it copies
# each line where the block goes, until the closing fence. A marker
# that does not parse, or that no fence of its kind follows, is an
# error, so that a mistyped marker cannot drop its check.
awk -v work="$work" -v family="$family" '
  function fail(message) {
    print "readme.sh: " FILENAME ":" FNR ": " message > "/dev/stderr"
    exit 1
  }
  function checked_name(name) {
    if (name !~ "^[A-Za-z0-9_][A-Za-z0-9_./-]*$" || name ~ "[.][.]")
      fail("a file name outside the allowed set: " name)
    return name
  }
  function open_file(name, directory) {
    if (name in written)
      fail("a file written twice: " name)
    written[name] = 1
    directory = name
    if (sub("/[^/]*$", "", directory))
      system("mkdir -p " work "/" directory)
    return work "/" name
  }
  function open_block(language, kind) {
    kind = marker
    marker = ""
    block = "skipped"
    if (language !~ /^(c|console|sh|text)?$/)
      fail("a fence of an unknown language: " language)
    if (kind == "" && language == "c")
      fail("a c block without a file, emit-c or untested marker")
    if (kind == "untested" && language != "c")
      fail("an untested marker before a block of " language)
    if (kind == "console" && language != "console")
      fail("a console marker before a block of " language)
    if ((kind == "file" || kind == "emit-c") && language == "console")
      fail("a " kind " marker before a console block")
    if (kind == "file") {
      block = "copied"
      target = open_file(checked_name(marked))
    } else if (kind == "emit-c") {
      block = "copied"
      target = open_file(checked_name(marked) ".emitted")
      print marked > (work "/emit-c.list")
    } else if (language == "console") {
      if (kind != "console" || marked == family)
        block = "console"
    }
  }

  block != "" && /^```/ { block = ""; next }
  block == "copied" { print > target; next }
  block == "console" {
    if (/^\$ /)
      print substr($0, 3) > (work "/commands")
    print > (work "/expected")
    next
  }
  block == "skipped" { next }
  /^```/ { open_block(substr($0, 4)); next }
  marker != "" { fail("a marker that no fence follows: " marker) }
  /^<!-- untested:/ {
    if ($0 !~ /^<!-- untested: [^ ].* -->$/)
      fail("a marker that does not parse: " $0)
    marker = "untested"
    next
  }
  /^<!-- (file|emit-c|console):/ {
    if ($0 !~ /^<!-- (file|emit-c|console): [^ ]+ -->$/)
      fail("a marker that does not parse: " $0)
    marker = substr($0, 6)
    sub(/:.*/, "", marker)
    marked = $0
    sub(/^<!-- [a-z-]+: /, "", marked)
    sub(/ -->$/, "", marked)
    if (marker == "console" && marked != "clang" && marked != "gcc")
      fail("a console marker for neither clang nor gcc: " marked)
  }
' "$readme" || exit 1

cd "$work" || exit 1
TYPEC_CC=$backend
export TYPEC_CC
cc() { "$backend" "$@"; }

touch commands expected emit-c.list
while IFS= read -r command; do
  printf '$ %s\n' "$command"
  (eval "$command") < /dev/null 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "[$status]"
  fi
done < commands > actual
diff -u expected actual

# The tokens of a C text, one per line, so that white space and the
# layout of the README do not count: every character outside a word or
# a number stands alone.
tokens() {
  sed 's/[^A-Za-z0-9_.]/ & /g' | tr -s ' \t\n' '\n\n\n' | grep .
}

# The C that typec writes for NAME, as the README shows it: without the
# line markers and without the assertions after the marker of <typec>.
emitted_c() {
  typec --emit-c "$1" < /dev/null | sed '/^# 1 "<typec>"/,$d' |
    grep -v '^#' | tokens
}

while IFS= read -r name; do
  if [ "$(emitted_c "$name")" != "$(tokens < "$name.emitted")" ]; then
    echo "the C of $name differs from the README:"
    typec --emit-c "$name" < /dev/null
  fi
done < emit-c.list
