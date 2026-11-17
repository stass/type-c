# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# What a source file holds of the places that design 5.1 rule 3 names,
# read from its text. Run as
#
#   awk -v names="f g h" -f source_shapes.awk FILE
#
# where names are the functions of the program that return a result (the
# output of fallible_names.awk), and it prints one line "M metric value"
# for each count and one line "D line shape text" for each try, so that
# the places can be read. The try expressions are counted by where they
# stand on their line:
#
#   statement    it begins its statement, as in "try f(x);"
#   initialiser  a declaration of one object begins the statement, as in
#                "T x = try f(x);"
#   assignment   an object, a member or an element begins the statement,
#                as in "x->y = try f(x);"
#   other        every other place, which the detail lists for reading
#
# A statement is what follows the last semicolon before the try on its
# line, and an opening brace does not begin one.
#
# The loops are those that begin with while, for or do; a loop is
# calling when its header holds a call of one of names, and holding a try
# when its body does, a body being the lines that stand deeper than the
# loop. A try of an inner loop is a try of the outer, and so is a call
# (loops_calling_in_body, for the loops of the C original, where a call
# of one of names stands where the port has a try). The lists are the
# initialiser lists "= { ... try" that the first semicolon after the
# brace does not precede. Comments and the text of strings are blank for
# the count.

BEGIN {
  # The word try, which no identifier such as try_lock contains.
  try_word = "(^|[^A-Za-z0-9_])try([^A-Za-z0-9_]|$)"
  # "T x =" or "const T *x =" at the start of a statement.
  declaration_of_one = "^[ \t{]*(const[ \t]+)?[A-Za-z_][A-Za-z_0-9]*" \
    "[ \t]+\\**[ \t]*[A-Za-z_][A-Za-z_0-9]*[ \t]*=[ \t]*$"
  # An object, a member or an element: "x =", "p->m =", "a[i + 1] =".
  object_assigned = "^[ \t{]*[A-Za-z_][A-Za-z_0-9>.\\[\\] +&*-]*" \
    "[ \t]*=[ \t]*$"
}

function blank_comments(text,    out, i, c, n, state) {
  # state: 0 code, 1 block comment, 2 line comment, 3 string, 4 character
  out = ""
  n = length(text)
  for (i = 1; i <= n; i++) {
    c = substr(text, i, 1)
    if (state == 0) {
      if (c == "/" && substr(text, i + 1, 1) == "*") {
        state = 1; out = out "  "; i++; continue
      }
      if (c == "/" && substr(text, i + 1, 1) == "/") {
        state = 2; out = out "  "; i++; continue
      }
      if (c == "\"") { state = 3; out = out c; continue }
      if (c == "'") { state = 4; out = out c; continue }
      out = out c
    } else if (state == 1) {
      if (c == "*" && substr(text, i + 1, 1) == "/") {
        state = 0; out = out "  "; i++; continue
      }
      out = out (c == "\n" ? "\n" : " ")
    } else if (state == 2) {
      if (c == "\n") { state = 0; out = out c } else out = out " "
    } else if (state == 3) {
      if (c == "\\") { out = out "  "; i++; continue }
      if (c == "\"") { state = 0; out = out c; continue }
      out = out " "
    } else {
      if (c == "\\") { out = out "  "; i++; continue }
      if (c == "'") { state = 0; out = out c; continue }
      out = out " "
    }
  }
  return out
}

function indent_of(line,    i, c, width) {
  width = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (c == " ") width++
    else if (c == "\t") width = width + 8 - width % 8
    else break
  }
  return width
}

# The line of the "} while (" that closes the do loop of line i, which
# stands at the indentation of the do; the line of the do where none does.
function do_tail(i,    j) {
  for (j = i + 1; j <= count; j++)
    if (code[j] ~ /^[ \t]*\}[ \t]*while[ \t]*\(/ &&
        indent_of(code[j]) == indent_of(code[i]))
      return j
  return i
}

# The header of the loop that begins at line i: from its keyword to the
# parenthesis that closes it, over the lines that it takes.
function header_of(i,    text, j, k, c, depth, started, line) {
  depth = 0
  started = 0
  text = ""
  if (code[i] ~ /^[ \t]*do([ \t{]|$)/)
    i = do_tail(i)
  for (j = i; j <= count; j++) {
    line = code[j]
    for (k = 1; k <= length(line); k++) {
      c = substr(line, k, 1)
      text = text c
      if (c == "(") { depth++; started = 1 }
      if (c == ")") {
        depth--
        if (started && depth == 0) return text
      }
    }
    text = text " "
  }
  return text
}

function calls_one_of(text,    n, i, word, before, rest, at) {
  n = split(names, listed, " ")
  for (i = 1; i <= n; i++) {
    word = listed[i]
    rest = text
    while ((at = index(rest, word "(")) > 0) {
      before = at > 1 ? substr(rest, at - 1, 1) : " "
      if (before !~ /[A-Za-z0-9_]/) return 1
      rest = substr(rest, at + length(word))
    }
  }
  return 0
}

function text_of(from, to,    j, text) {
  for (j = from; j <= to; j++)
    text = text code[j] " "
  return text
}

function holds_try(from, to,    j) {
  for (j = from; j <= to; j++)
    if (code[j] ~ try_word)
      return 1
  return 0
}

function body_end(i,    depth, j) {
  depth = indent_of(code[i])
  for (j = i + 1; j <= count; j++)
    if (code[j] !~ /^[ \t]*$/ && indent_of(code[j]) <= depth)
      return j - 1
  return count
}

function shape_of(prefix) {
  if (prefix ~ /^[ \t{]*$/) return "statement"
  if (prefix ~ declaration_of_one)
    return "initialiser"
  if (prefix ~ object_assigned)
    return "assignment"
  return "other"
}

{ lines[NR] = $0; text = text $0 "\n" }

END {
  text = blank_comments(text)
  count = split(text, code, "\n")
  if (code[count] == "") count--
  for (i = 1; i <= count; i++) {
    line = code[i]
    rest = line
    offset = 0
    while (match(rest, try_word)) {
      start = RSTART + (substr(rest, RSTART, 1) ~ /[A-Za-z0-9_]/ ? 0 : 1)
      prefix = substr(line, 1, offset + start - 1)
      sub(/^.*;/, "", prefix)
      shape = shape_of(prefix)
      shapes[shape]++
      print "D", i, shape, lines[i]
      offset += start + 2
      rest = substr(line, offset + 1)
    }
    if (line ~ /^[ \t]*#[ \t]*pragma/) pragmas++
    if (line ~ /^[ \t]*\} *while[ \t]*\(/) tails++
  }
  for (i = 1; i <= count; i++) {
    line = code[i]
    if (line ~ /^[ \t]*(while|for)[ \t]*\(/ || line ~ /^[ \t]*do([ \t{]|$)/) {
      loops++
      is_calling = calls_one_of(header_of(i))
      has_try = holds_try(i, body_end(i))
      in_body = calls_one_of(text_of(i + 1, body_end(i)))
      calling += is_calling
      with_try += has_try
      body_calling += in_body
      print "L", i, (has_try ? "try" : "plain"),
        (is_calling ? "calling" : "-"), (in_body ? "body-calls" : "-"),
        lines[i]
    }
  }
  flat = ""
  for (i = 1; i <= count; i++) flat = flat code[i] " "
  rest = flat
  while (match(rest, /=[ \t]*\{[^;]*;/)) {
    if (substr(rest, RSTART, RLENGTH) ~ try_word)
      lists++
    rest = substr(rest, RSTART + RLENGTH)
  }
  print "M shape_statement", shapes["statement"] + 0
  print "M shape_initialiser", shapes["initialiser"] + 0
  print "M shape_assignment", shapes["assignment"] + 0
  print "M shape_other", shapes["other"] + 0
  print "M loops", loops + 0
  print "M loops_calling", calling + 0
  print "M loops_with_try", with_try + 0
  print "M loops_calling_in_body", body_calling + 0
  print "M do_while_tails", tails + 0
  print "M lists_with_try", lists + 0
  print "M pragma_lines", pragmas + 0
}
