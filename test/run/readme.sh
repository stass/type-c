# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# readme.sh FAMILY BACKEND README: checks that the examples of README
# hold on BACKEND, of FAMILY clang or gcc, in a directory of its own
# named after FAMILY, and prints what differs.
#
# readme.sh FAMILY BACKEND README BASE: the same for a page that shows
# a program of its own, such as the README of an example, whose files
# and built programs the directory BASE holds. The directory of the
# page, and each of its stages, begins as a copy of BASE, and a c block
# without a marker is an excerpt of those files, which is not checked.
#
# readme.sh --files README DIRECTORY: writes the files of README into
# DIRECTORY and runs nothing, for a test that uses them otherwise, such
# as the build rules that README shows.
#
# The README marks its examples with a comment line right before the
# opening fence:
#
# - "<!-- file: NAME -->" writes the block to NAME, a relative path of
#   letters, digits and "_./-" that does not climb with "..";
# - "<!-- emit-c: NAME -->" says that the block is the C of
#   "typec --emit-c NAME", without its line markers and the assertions
#   that typec appends; the comparison is of tokens, so that the block
#   can be laid out for reading;
# - "<!-- console: FAMILY -->" runs the console block on FAMILY only,
#   and "<!-- console: lldb -->" only where lldb debugs a program of
#   BACKEND (lldb_present in backends.sh, which reports the skip), so
#   that a host without it skips the block, commands and output alike;
# - "<!-- untested: REASON -->" skips the c block, which shows Type-C
#   that typec does not build yet, or the console block, which shows a
#   run that REASON says cannot be repeated here;
# - "<!-- edit: NAME -->" changes the file NAME by the block: a diff
#   block, of context lines, which begin with a space, and of lines
#   that begin with "-" or "+", replaces its context and "-" lines,
#   which must occur in NAME once, by its context and "+" lines; a block
#   of another language is added to the end of NAME;
# - "<!-- run -->" runs the sh block in the directory of the stage, as
#   a script that must succeed and print nothing; it runs without the
#   backend, so it prepares files and does not compile them, and the
#   --files form does not run it;
# - "<!-- stage: NAME -->", NAME of letters, digits and "_", starts a
#   directory NAME. It begins as a copy of BASE, or else of the files
#   that the page writes into the stage before, made while the page is
#   read and so before any command runs, as are the edits and the runs
#   of sh blocks: what the commands of one stage make or change does not
#   reach the next, and a command must not depend on it. An edit or a
#   run comes before every console block of its stage, so that no
#   command shown before it sees what it changes.
#   The file markers after the stage marker write into NAME, and the
#   commands after it run there. A page that grows one program through
#   its chapters shows each file whole where it changes, and a file
#   shown again replaces its namesake. Files written before the first
#   stage marker belong to no stage. A page with no stage marker works
#   in one directory.
#
# Every c block of a page without BASE carries a file, emit-c, edit or
# untested marker, and a fence of a language other than c, console,
# diff, sh or text is an error, so that a forgotten marker or a misspelt
# fence cannot drop a check.
#
# Every line "$ COMMAND" of a console block is run, with cc meaning
# BACKEND and typec running it, and with the lines that follow a line
# ending in "|" or "\" as the rest of the command; the lines up to the
# next command or the end of the block are what it prints on stdout
# and stderr, without the carriage returns that a page cannot show,
# then its exit status in brackets when that is not 0. Blocks of other
# kinds, such as sh without a run marker, are not run.

if [ "$1" = --files ]; then
  family= lldb= readme=$2 work=$3 base=
else
  family=$1 backend=$2 readme=$3 lldb= work=work-$1 base=$4
  case $family in
  clang | gcc) ;;
  *) echo "readme.sh: FAMILY is clang or gcc, not $family" >&2; exit 1 ;;
  esac
  # Only a page with an lldb block pays for the probe.
  if grep -q '^<!-- console: lldb -->$' "$readme"; then
    . "$(dirname "$0")/backends.sh" || exit 1
    if lldb_present "$backend"; then
      lldb=yes
    fi
  fi
fi
mkdir "$work" || exit 1
# Symbolic links are copied as files, so that no write follows one out.
if [ -n "$base" ]; then
  cp -RL "$base/." "$work" || exit 1
fi

# The awk program reads the README a line at a time. Outside a block,
# it keeps what the last line marks in marker and marked; at a fence it
# opens the block that the marker asks for. Inside a block, it copies
# each line where the block goes, until the closing fence. A marker
# that does not parse, or that no fence of its kind follows, is an
# error, so that a mistyped marker cannot drop its check.
awk -v work="$work" -v family="$family" -v lldb="$lldb" -v base="$base" '
  function fail(message) {
    print "readme.sh: " FILENAME ":" FNR ": " message > "/dev/stderr"
    exit 1
  }
  function stage_directory() {
    return stage == "" ? work : work "/" stage
  }
  # The lines of the file at path, into lines[1..n]; n is returned.
  function read_lines(path, lines,   n, line, status) {
    n = 0
    while ((status = (getline line < path)) > 0)
      lines[++n] = line
    if (status < 0)
      fail("an edit of a file that does not exist: " path)
    close(path)
    return n
  }
  # Splits the hunk into the lines that it replaces, old_lines[1..old_n], and
  # those that replace them, new_lines[1..new_n]. An empty line is a context
  # line whose trailing space an editor dropped.
  function split_hunk(   i, line, mark) {
    old_n = new_n = 0
    for (i = 1; i <= hunk_n; i++) {
      line = hunk[i]
      mark = line == "" ? " " : substr(line, 1, 1)
      if (mark !~ /^[ +-]$/)
        fail("a diff line of none of context, - and +: " line)
      if (mark != "+")
        old_lines[++old_n] = substr(line, 2)
      if (mark != "-")
        new_lines[++new_n] = substr(line, 2)
    }
  }
  # The line of lines[1..n] where old_lines[1..old_n] begins; it must begin
  # at exactly one, so that a hunk cannot change a place it does not
  # mean.
  function hunk_start(lines, n,   at, i, start, count) {
    count = 0
    for (at = 1; at + old_n - 1 <= n; at++) {
      for (i = 1; i <= old_n && lines[at + i - 1] == old_lines[i]; i++)
        continue
      if (i > old_n) {
        start = at
        count++
      }
    }
    if (count != 1)
      fail("a hunk found " count " times in " target)
    return start
  }
  function apply_hunk(   lines, n, start, i) {
    split_hunk()
    n = read_lines(target, lines)
    start = hunk_start(lines, n)
    for (i = 1; i < start; i++)
      print lines[i] > target
    for (i = 1; i <= new_n; i++)
      print new_lines[i] > target
    for (i = start + old_n; i <= n; i++)
      print lines[i] > target
    close(target)
  }
  # An edit or a run comes before the commands of its stage, as it is
  # made while the page is read, before any command runs.
  function refuse_after_command(change) {
    if (stage in commanded)
      fail(change " after a console block of the same stage")
  }
  function open_edit(language) {
    refuse_after_command("an edit")
    target = work "/" staged_name(checked_name(marked))
    read_lines(target)  # fails unless the file exists
    if (language == "diff") {
      block = "hunk"
      hunk_n = 0
    } else {
      block = "appended"
    }
  }
  function checked_name(name) {
    if (name !~ "^[A-Za-z0-9_][A-Za-z0-9_./-]*$" || name ~ "[.][.]")
      fail("a file name outside the allowed set: " name)
    return name
  }
  function staged_name(name) {
    return stage == "" ? name : stage "/" name
  }
  function open_file(name, directory) {
    name = staged_name(name)
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
    if (language !~ /^(c|console|diff|sh|text)?$/)
      fail("a fence of an unknown language: " language)
    if (kind == "" && language == "c" && base == "")
      fail("a c block without a file, emit-c, edit or untested marker")
    if (kind == "untested" && language !~ /^(c|console)$/)
      fail("an untested marker before a block of " language)
    if (kind == "console" && language != "console")
      fail("a console marker before a block of " language)
    if (kind ~ /^(file|emit-c|edit)$/ && language == "console")
      fail("a " kind " marker before a console block")
    if (kind == "run" && language != "sh")
      fail("a run marker before a block of " language)
    if (kind == "file") {
      block = "copied"
      target = open_file(checked_name(marked))
    } else if (kind == "emit-c") {
      block = "copied"
      target = open_file(checked_name(marked) ".emitted")
      print staged_name(marked) > (work "/emit-c.list")
    } else if (kind == "edit") {
      open_edit(language)
    } else if (kind == "run" && family != "") {
      refuse_after_command("a run block")
      block = "run"
      target = work "/run.sh"
    } else if (language == "console" && kind != "untested") {
      commanded[stage] = 1
      if (kind != "console" || marked == family ||
          (marked == "lldb" && lldb != ""))
        block = "console"
    }
  }

  # A command whose line ends in "|" or "\" goes on in the next line,
  # which is joined to it without the "\". The command is written
  # joined to the expected output too, as the loop prints it.
  function add_command(line) {
    command = command line
    continued = command ~ /[\\|]$/
    sub(/\\$/, "", command)
    if (continued)
      return
    print command > (work "/commands")
    print (stage == "" ? "." : stage) > (work "/directories")
    print "$ " command > (work "/expected")
    command = ""
  }

  # The script of a run block runs from a file, as the exit status of
  # a pipe that awk closes is not portable, and with no input. The
  # script lies in the work directory, one level above a stage.
  function run_script(script) {
    close(target)
    script = "run.sh"
    if (stage != "")
      script = "../run.sh"
    if (system("cd " stage_directory() " && sh -e " script \
        " < /dev/null") != 0)
      fail("a run block that failed")
  }

  block != "" && /^```/ {
    if (continued)
      fail("a command that the block ends before it does")
    if (block == "hunk")
      apply_hunk()
    else if (block == "run")
      run_script()
    else if (block != "console" && block != "skipped")
      close(target)
    block = ""
    next
  }
  block == "copied" || block == "run" { print > target; next }
  block == "appended" { print >> target; next }
  block == "hunk" { hunk[++hunk_n] = $0; next }
  block == "console" && continued { add_command($0); next }
  block == "console" && /^\$ / { add_command(substr($0, 3)); next }
  block == "console" { print > (work "/expected"); next }
  block == "skipped" { next }
  /^```/ { open_block(substr($0, 4)); next }
  marker != "" { fail("a marker that no fence follows: " marker) }
  /^<!-- stage:/ {
    if ($0 !~ /^<!-- stage: [A-Za-z0-9_]+ -->$/)
      fail("a marker that does not parse: " $0)
    previous = stage
    stage = $0
    sub(/^<!-- stage: /, "", stage)
    sub(/ -->$/, "", stage)
    if (stage in stages)
      fail("a stage named twice: " stage)
    stages[stage] = 1
    if (system("mkdir " work "/" stage) != 0)
      fail("cannot make the directory of stage " stage)
    if (base != "")
      origin = base
    else if (previous != "")
      origin = work "/" previous
    else
      origin = ""
    if (origin != "" && system("cp -RL " origin "/. " work "/" stage) != 0)
      fail("cannot copy " origin " to stage " stage)
    next
  }
  /^<!-- run/ {
    if ($0 !~ /^<!-- run -->$/)
      fail("a marker that does not parse: " $0)
    marker = "run"
    next
  }
  /^<!-- untested:/ {
    if ($0 !~ /^<!-- untested: [^ ].* -->$/)
      fail("a marker that does not parse: " $0)
    marker = "untested"
    next
  }
  /^<!-- (file|emit-c|console|edit):/ {
    if ($0 !~ /^<!-- (file|emit-c|console|edit): [^ ]+ -->$/)
      fail("a marker that does not parse: " $0)
    marker = substr($0, 6)
    sub(/:.*/, "", marker)
    marked = $0
    sub(/^<!-- [a-z-]+: /, "", marked)
    sub(/ -->$/, "", marked)
    if (marker == "console" && marked !~ /^(clang|gcc|lldb)$/)
      fail("a console marker for none of clang, gcc and lldb: " marked)
  }
' "$readme" || exit 1
if [ -z "$family" ]; then
  exit 0
fi

cd "$work" || exit 1
TYPEC_CC=$backend
export TYPEC_CC
cc() { "$backend" "$@"; }

touch commands directories expected emit-c.list
while IFS= read -r command && IFS= read -r directory <&3; do
  printf '$ %s\n' "$command"
  (cd "$directory" && eval "$command") < /dev/null 2>&1 3<&-
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "[$status]"
  fi
done < commands 3< directories | tr -d '\r' > actual
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
