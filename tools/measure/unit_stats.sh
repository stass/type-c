#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# What typec --stats reports for Type-C units of any program, and which
# of the refusals of design 7.3 rule 4 (P27) and of design section 8
# rule 9 (P28) stop each, as rows of the CSV that containers.sh writes
# (package 3.6). The metrics are the fields of --stats, and
# refusal_instance_pragma and refusal_slice_check_place, each 1 where
# the unit's first error names that rule (typec stops at the first
# error, so a unit holds at most one) and 0 where the unit has none. A
# unit that fails for another reason fails the script.
#
# Usage: tools/measure/unit_stats.sh OUT SIDE CC [-I DIR]... -- UNIT...
#
# OUT is the CSV file, outside the repository because it is raw data;
# the script appends to it and writes its header where it is new. SIDE
# names the program in the side field. CC names the backend. The options
# before -- go to typec with -std=c11 and -O2. TYPEC names the compiler
# (by default the one dune builds in this tree), and REVISION the
# revision of the tree (by default what tools/corpus/revision.sh prints
# for it). The item of each row is the base name of its unit.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)

fail() {
  echo "unit_stats.sh: $*" >&2
  exit 1
}

[ $# -ge 4 ] || {
  echo "usage: $0 OUT SIDE CC [-I DIR]... -- UNIT..." >&2
  exit 2
}
out=$1
side=$2
cc=$3
shift 3
options=
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  options="$options $1"
  shift
done
[ $# -ge 2 ] || fail "no unit after --"
shift

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

host=$(uname -sm)
cc_version=$("$cc" --version | head -n 1 | tr ',' ';')
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

[ -e "$out" ] ||
  echo "revision,host,cc,cc_version,opt,side,item,metric,value,n,rounds" \
    > "$out"

row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" \
    "$cc" "$cc_version" -O2 "$side" "$@" >> "$out"
}

# The rows of one unit: its refusals, and its counts where it has none.
measure_unit() {
  name=$(basename "$1")
  instance_pragma=0
  slice_check_place=0
  if "$TYPEC" --cc="$cc" --stats -std=c11 -O2 $options --emit-c \
    -o "$scratch/unit.c" "$1" 2> "$scratch/stats"; then
    fields=$(sed -n 's/^typec: stats: .*: //p' "$scratch/stats")
    [ -n "$fields" ] || fail "no counts for $1"
    for field in $fields; do
      row "$name" "${field%%=*}" "${field#*=}" "" ""
    done
  elif grep -q '\[instance-pragma\]' "$scratch/stats"; then
    instance_pragma=1
  elif grep -q '\[slice-check-place\]' "$scratch/stats"; then
    slice_check_place=1
  else
    fail "typec failed on $1: $(cat "$scratch/stats")"
  fi
  row "$name" refusal_instance_pragma "$instance_pragma" "" ""
  row "$name" refusal_slice_check_place "$slice_check_place" "" ""
}

for unit in "$@"; do
  measure_unit "$unit"
done
