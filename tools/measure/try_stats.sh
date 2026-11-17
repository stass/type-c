#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The measurements of package 3.12 that count: where the try expressions
# of the container library, of Pilot B and of the README's examples
# stand, which rule stops each unit that typec refuses, as try-loop,
# try-list and try-pragma of design 5.1 rule 3 do (P8, P34, P35), and
# the preludes that the holders of the units make (P33). Rows of the
# CSV that containers.sh writes, with these metrics:
#
#   refused               1 where typec refuses the unit, else 0
#   refused_rule          for a unit that typec refuses, the name of the
#                         rule that its first error ends with, as
#                         try-loop, try-list, try-pragma, try-position
#                         and try-declaration are for design 5.1 rule 3
#   try_holders ... try_multiple
#                         what typec --stats reports, for a unit that
#                         typec accepts
#   shape_statement, shape_initialiser, shape_assignment, shape_other
#                         the try expressions of a file by where they
#                         stand on their line (source_shapes.awk)
#   loops, loops_calling, loops_with_try, loops_calling_in_body,
#   do_while_tails
#                         the loops of a file, those whose header calls
#                         a function that returns a result, those whose
#                         body holds a try, and those whose body calls
#                         such a function; the lines "} while (" that
#                         end a do loop are counted by do_while_tails
#   lists_with_try        the initialiser lists of a file that hold a try
#   pragma_lines          its #pragma lines
#
# The sides are library (the units of test/run/containers.t), pilot (the
# unit toml.tc of Pilot B), pilot_c (its C original, toml.c, whose loops
# are counted by the function names of toml.tc) and readme (the files
# that test/run/readme.sh writes from the README). A file's metrics are
# those of its text; a unit's, of what typec says of it. The lines that
# the counts read, one for each try and each loop, are written to
# OUT.detail, to read the places that the counts name.
#
# Usage: tools/measure/try_stats.sh OUT CC
#
# OUT is the CSV file, outside the repository because it is raw data;
# the script writes it anew. CC names the backend. PILOT names the tree
# of Pilot B (default /Volumes/Optaine/type-c-pilot-b), TYPEC the
# compiler (by default the one dune builds in this tree) and REVISION
# the revision of the tree (by default what tools/corpus/revision.sh
# prints for it). The path of the tree holds no blank.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/try_expr
library=$root/test/run/containers.t
pilot=${PILOT:-/Volumes/Optaine/type-c-pilot-b}

fail() {
  echo "try_stats.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || { echo "usage: $0 OUT CC" >&2; exit 2; }
out=$1
cc=$2
case $root in
*[[:space:]]*) fail "the path of the tree holds a blank: $root" ;;
esac
[ ! -d "$out" ] || fail "OUT is a directory: $out"
case $cc in
*/*) cc=$(CDPATH='' cd "$(dirname "$cc")" && pwd -P)/$(basename "$cc") ;;
*) cc=$(command -v "$cc") || fail "no such backend: $cc" ;;
esac

out_dir=$(CDPATH='' cd "$(dirname "$out")" && pwd -P) ||
  fail "no directory for $out"
root_physical=$(CDPATH='' cd "$root" && pwd -P)
case $out_dir/ in
"$root_physical"/*)
  fail "$out is in the repository, and raw data stays out of it" ;;
esac
out=$out_dir/$(basename "$out")

if [ -n "${REVISION:-}" ]; then
  revision=$REVISION
else
  revision=$("$root/tools/corpus/revision.sh" "$root") ||
    fail "cannot tell the revision of $root; name it in REVISION"
fi
if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi
TYPEC=$(CDPATH='' cd "$(dirname "$TYPEC")" && pwd -P)/$(basename "$TYPEC")

host=$(uname -sm)
version=$("$cc" --version) || fail "$cc does not run"
cc_version=$(printf '%s\n' "$version" | head -n 1 | tr ',' ';')
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

# The rows are written to a scratch file and moved over OUT when every
# unit has been read, so that a failed run leaves no partial CSV.
rows=$scratch/rows
detail=$scratch/detail
echo "revision,host,cc,cc_version,opt,side,item,metric,value,n,rounds" \
  > "$rows"
: > "$detail"

row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" \
    "$cc" "$cc_version" -O2 "$side" "$@" >> "$rows"
}

# The rows of the unit $1, built from the directory $2 with the include
# options $3: whether typec refuses it, by which rule, and its counts.
measure_unit() {
  name=$(basename "$1")
  if (cd "$2" && "$TYPEC" --cc="$cc" --stats -std=c11 -O2 $3 --emit-c \
    -o "$scratch/unit.c" "$1" 2> "$scratch/stats"); then
    row "$name" refused 0 "" ""
    fields=$(sed -n 's/^typec: stats: .*: //p' "$scratch/stats")
    [ -n "$fields" ] || fail "no counts for $1"
    for field in $fields; do
      case $field in
      try_*) row "$name" "${field%%=*}" "${field#*=}" "" "" ;;
      esac
    done
    return 0
  fi
  # The first error ends in the name of its rule, in brackets; typec
  # that fails otherwise is no refusal of the unit.
  rule=$(sed -n 's/^[^:]*:[0-9]*: error: .*\[\([a-z0-9-]*\)\]$/\1/p' \
    "$scratch/stats" | head -n 1)
  [ -n "$rule" ] || fail "typec failed on $1: $(head -n 3 "$scratch/stats")"
  row "$name" refused 1 "" ""
  row "$name" refused_rule "$rule" "" ""
}

# The rows of the text of the file $1, whose fallible functions are $2.
measure_text() {
  name=$(basename "$1")
  awk -v names="$2" -f "$sources/source_shapes.awk" "$1" > "$scratch/shapes"
  while read -r kind first second; do
    case $kind in
    M) row "$name" "$first" "$second" "" "" ;;
    esac
  done < "$scratch/shapes"
  awk -v place="$side $name" '/^[DL] / { print place, $0 }' \
    "$scratch/shapes" >> "$detail"
}

fallible_names() {
  cat "$@" | awk -f "$sources/fallible_names.awk" | sort -u | tr '\n' ' '
}

# The library: its units with the interface files they include.
side=library
names=$(fallible_names "$library"/*.tc "$library"/*.tci)
for unit in "$library"/*.tc; do
  measure_unit "$unit" "$library" "-I $library"
  measure_text "$unit" "$names"
done
for header in "$library"/*.tci; do
  measure_text "$header" "$names"
done

# The pilot, and its C original under the names of the port.
side=pilot
names=$(fallible_names "$pilot/toml.tc")
measure_unit "$pilot/toml.tc" "$pilot" "-I $pilot"
measure_text "$pilot/toml.tc" "$names"
side=pilot_c
measure_text "$pilot/toml.c" "$names"

# The README: the files that test/run/readme.sh writes, each unit built
# with the include path that the README's examples use.
side=readme
sh "$root/test/run/readme.sh" --files "$root/README.md" "$scratch/readme" ||
  fail "readme.sh wrote no files"
names=$(fallible_names "$scratch"/readme/*.tc "$scratch"/readme/include/*.tci)
for unit in "$scratch"/readme/*.tc; do
  measure_unit "$unit" "$scratch/readme" "-I . -I include"
  measure_text "$unit" "$names"
done

mv "$rows" "$out"
mv "$detail" "$out.detail"
