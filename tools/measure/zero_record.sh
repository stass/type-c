#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The record of package 3.6 for the bytes of a long double that the zero
# initialiser leaves (design 13.5): it takes the program of
# test/run/zero_initialisers.t, builds it with typec on each backend at
# -O0, -O2 and -O3, runs it as `zeroes record`, and writes to OUT one CSV
# row for each place and type of the test:
#
#   revision,host,cc,cc_version,opt,place,type,passed_over
#
# passed_over is how many of the bytes of a long double, or of the parts
# of a complex one, that hold none of its value were not zero after the
# initialiser. How many are left depends on the harness as well as on
# the backend, so this is a record and asserts nothing of them; it does
# fail where a byte that rule 3 promises is not zero. A place of an
# array has a row for each of its three elements, and the control, a
# union that the initialiser does not zero, has one.
#
# Usage: tools/measure/zero_record.sh OUT [CC...]
#
# OUT is the CSV file, outside the repository because it is raw data. CC
# names the backends, by default the Clang and the GCC of
# test/run/backends.sh. TYPEC names the compiler (by default the one
# dune builds in this tree) and REVISION the revision of the tree (by
# default what tools/corpus/revision.sh prints for it).

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
test_file=$root/test/run/zero_initialisers.t

fail() {
  echo "zero_record.sh: $*" >&2
  exit 1
}

[ $# -ge 1 ] || { echo "usage: $0 OUT [CC...]" >&2; exit 2; }
out=$1
shift
[ -n "$out" ] || fail "OUT is empty"
[ ! -d "$out" ] || fail "OUT is a directory: $out"

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

if [ $# -eq 0 ]; then
  . "$root/test/run/backends.sh"
  set -- "$clang" "$gcc"
fi

if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi

host=$(uname -sm)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

# The program is the heredoc of zeroes.tc in the test, without the
# cram prefix of its lines.
sed -n "/cat > zeroes.tc <<'EOF'/,/^  > EOF/p" "$test_file" |
  sed -e '1d' -e '$d' -e 's/^  > \{0,1\}//' > "$scratch/zeroes.tc"
[ -s "$scratch/zeroes.tc" ] || fail "no zeroes.tc in $test_file"

# The rows go to a file of the scratch directory, which replaces OUT
# only when every run has passed, so that OUT is never partial.
rows=$scratch/rows
echo "revision,host,cc,cc_version,opt,place,type,passed_over" > "$rows"
for cc in "$@"; do
  cc_version=$("$cc" --version | head -n 1 | tr ',' ';')
  for opt in -O0 -O2 -O3; do
    "$TYPEC" --cc="$cc" -std=c11 "$opt" -o "$scratch/zeroes" \
      "$scratch/zeroes.tc" 2> "$scratch/log" ||
      fail "typec failed on zeroes.tc: $(cat "$scratch/log")"
    "$scratch/zeroes" record > "$scratch/lines"
    # The record is only of a build that keeps the promise of rule 3 and
    # whose control shows that the program reads the bytes it claims to.
    [ "$(grep -c ' bytes not zero$' "$scratch/lines")" -eq 1 ] &&
      grep -qx '0 bytes not zero' "$scratch/lines" ||
      fail "$cc $opt: the zero initialiser leaves bytes it promises"
    ! grep -q '^the control leaves no byte$' "$scratch/lines" ||
      fail "$cc $opt: the control leaves no byte"
    # A line is "PLACE TYPE: N passed over"; the type may hold blanks.
    sed -n 's/^\([^ ]*\) \(.*\): \([0-9]*\) passed over$/\1,\2,\3/p' \
      "$scratch/lines" > "$scratch/parsed"
    [ -s "$scratch/parsed" ] || fail "$cc $opt: no line of the record"
    [ "$(wc -l < "$scratch/parsed")" -eq \
      "$(grep -c ' passed over$' "$scratch/lines")" ] ||
      fail "$cc $opt: a line of the record is not read"
    while IFS= read -r line; do
      printf '%s,%s,%s,%s,%s,%s\n' "$revision" "$host" "$cc" \
        "$cc_version" "$opt" "$line" >> "$rows"
    done < "$scratch/parsed"
  done
done
mv "$rows" "$out"
