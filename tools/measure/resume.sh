#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The record of package 3.6 for design section 8 rule 10: what a slice
# index reaches when its full expression is resumed after its function
# has begun to evaluate it again. It builds the programs of
# tools/measure/resume with typec on each backend at -O0 and -O2 and
# writes to OUT one CSV row for each run:
#
#   revision,host,cc,cc_version,opt,program,variant,route,result
#
# The programs are resume (the index of a slice, over a static array and
# then a heap array that is freed, under AddressSanitizer), arg (the
# address of an element held across a call that returns twice in another
# argument, under AddressSanitizer) and tear (two live arrays, whose
# lengths 4 and 64 the index tests). The routes name what returns twice:
# SE, setjmp in a statement expression; GC, getcontext; BSJ,
# __builtin_setjmp. The variants are those of the sources' comments;
# ONCE and PLAINC are the partners, which C defines or which have no
# test. The results are "reads 10" (the resumed evaluation read the
# array of its own evaluation), "use after free", "write after free",
# "own[J]" (the store reached element J of the static array), "A[J]" and
# "B[J]" (the address of the element J of the array of the first or of
# the later evaluation), "trap" (the test of the slice ended the
# program), and, for a run that none of these names, "sanitizer: KIND"
# or "status N".
#
# Usage: tools/measure/resume.sh OUT [CC...]
#
# OUT is the CSV file, outside the repository because it is raw data;
# the programs go to the directory OUT.build, which the script makes and
# removes again only when it holds the script's mark. CC names the
# backends, by default the Clang and the GCC of test/run/backends.sh.
# TYPEC names the compiler (by default the one dune builds in this
# tree) and REVISION the revision of the tree (by default what
# tools/corpus/revision.sh prints for it). The path of the tree holds no
# blank.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/resume
mark=.resume-measure

fail() {
  echo "resume.sh: $*" >&2
  exit 1
}

[ $# -ge 1 ] || { echo "usage: $0 OUT [CC...]" >&2; exit 2; }
out=$1
shift
[ -n "$out" ] || fail "OUT is empty"
[ ! -d "$out" ] || fail "OUT is a directory: $out"
case $root in
*[[:space:]]*) fail "the path of the tree holds a blank: $root" ;;
esac

out_dir=$(CDPATH='' cd "$(dirname "$out")" && pwd -P) ||
  fail "no directory for $out"
root_physical=$(CDPATH='' cd "$root" && pwd -P)
case $out_dir/ in
"$root_physical"/*)
  fail "$out is in the repository, and raw data stays out of it" ;;
esac
out=$out_dir/$(basename "$out")
build=$out.build

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

row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" "$cc" \
    "$cc_version" "$opt" "$@" >> "$out"
}

# Builds PROGRAM with the defines of VARIANT and ROUTE (and the
# sanitizer, where SANITIZE is not empty), runs it, and leaves its
# standard output in $build/run.out, its standard error in
# $build/run.err and its exit status in $status.
build_and_run() {
  program=$1
  route=$2
  variant=$3
  sanitize=$4
  defines="-DROUTE_$route"
  for word in $variant; do
    defines="$defines -D$word"
  done
  "$TYPEC" --cc="$cc" $opt -w $sanitize $defines \
    -o "$build/$program" "$sources/$program.tc" ||
    fail "typec failed on $program $variant $route"
  status=0
  { "$build/$program" > "$build/run.out" 2> "$build/run.err"; } 2> /dev/null ||
    status=$?
}

# Whether the program died of a signal, as the test of a slice makes it
# die: an illegal instruction (x86-64 ud2) or a breakpoint trap (arm64
# brk), which the shell reports as 128 plus the signal. A sanitizer
# report, which may end the program with SIGABRT, or any other signal
# is no trap.
trapped() {
  [ "$status" -gt 128 ] || return 1
  case $(kill -l $((status - 128))) in
  ILL | TRAP) ! grep -q AddressSanitizer "$build/run.err" ;;
  *) return 1 ;;
  esac
}

# The result of a run that no result of its program names: the kind of
# the sanitizer's report (C's own index, with no test, reaches beyond
# the static array), else the exit status.
unclassified() {
  kind=$(sed -n 's/^.*ERROR: AddressSanitizer: \([a-z-]*\).*$/\1/p' \
    "$build/run.err" | head -n 1)
  if [ -n "$kind" ]; then
    echo "sanitizer: $kind"
  else
    echo "status $status"
  fi
}

# The result of resume: where the resumed evaluation read.
resume_result() {
  if grep -q 'heap-use-after-free' "$build/run.err"; then
    echo "use after free"
  elif grep -q '^phase 2 reads 10$' "$build/run.out"; then
    echo "reads 10"
  elif trapped; then
    echo trap
  else
    unclassified
  fi
}

# The result of arg: where the resumed call stored.
arg_result() {
  if grep -q 'AddressSanitizer: heap-use-after-free' "$build/run.err"; then
    echo "write after free"
  elif grep -q '^own\[' "$build/run.out"; then
    grep '^own\[' "$build/run.out" | head -n 1
  elif trapped; then
    echo trap
  else
    unclassified
  fi
}

# The result of tear: where the address points, or the trap.
tear_result() {
  if grep -q '^[AB]\[' "$build/run.out"; then
    head -n 1 "$build/run.out"
  elif trapped; then
    echo trap
  else
    unclassified
  fi
}

# Runs one variant of PROGRAM on every route.
measure_program() {
  program=$1
  variant=$2
  sanitize=$3
  for route in SE GC BSJ; do
    build_and_run "$program" "$route" "$variant" "$sanitize"
    result=$("${program}_result")
    row "$program" "$variant" "$route" "$result"
  done
}

measure() {
  for variant in "" ONCE; do
    measure_program resume "$variant" -fsanitize=address
  done
  for variant in "" SWAP PLAINC "PLAINC SWAP"; do
    measure_program arg "$variant" -fsanitize=address
  done
  for variant in "" FIRST "FIRST SWAP" ONCE "ONCE WANT=2"; do
    measure_program tear "$variant" ""
  done
}

if [ -e "$build" ]; then
  [ -f "$build/$mark" ] || fail "$build is not the script's; remove it"
  rm -rf "$build"
fi
mkdir -p "$build"
: > "$build/$mark"
echo "revision,host,cc,cc_version,opt,program,variant,route,result" > "$out"
for cc in "$@"; do
  cc_version=$("$cc" --version | head -n 1 | tr ',' ';')
  for opt in -O0 -O2; do
    measure
  done
done
