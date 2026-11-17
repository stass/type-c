# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The names of the functions that a Type-C source declares to return a
# result, one on each line: "result(...) NAME(", and the same where the
# return type is an alias of a result, as "type status = result(void,
# E);" or "typedef result(int, E) result_int;" make. A line break between
# the type and the name does not matter.

function names_after(type_pattern,    rest, name, pattern) {
  rest = flat
  pattern = type_pattern "[ \t]*\\**[ \t]*[A-Za-z_][A-Za-z_0-9]*[ \t]*\\("
  while (match(rest, pattern)) {
    name = substr(rest, RSTART, RLENGTH)
    sub(/[ \t]*\($/, "", name)
    sub(/^.*[^A-Za-z0-9_]/, "", name)
    print name
    rest = substr(rest, RSTART + RLENGTH - 1)
  }
}

{ flat = flat $0 " " }

END {
  gsub(/[ \t]+/, " ", flat)
  names_after("result\\([^()]*\\)")
  rest = flat
  while (match(rest, /type [A-Za-z_][A-Za-z_0-9]* = result\(/)) {
    alias = substr(rest, RSTART + 5, RLENGTH - 5)
    sub(/ .*/, "", alias)
    aliases[alias] = 1
    rest = substr(rest, RSTART + RLENGTH)
  }
  rest = flat
  while (match(rest, /typedef result\([^()]*\) [A-Za-z_][A-Za-z_0-9]*;/)) {
    alias = substr(rest, RSTART, RLENGTH)
    sub(/;$/, "", alias)
    sub(/^.* /, "", alias)
    aliases[alias] = 1
    rest = substr(rest, RSTART + RLENGTH)
  }
  for (alias in aliases)
    names_after("[^A-Za-z0-9_]" alias)
}
