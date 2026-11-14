#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the fuzz harness with an AFL-instrumented OCaml and runs AFL++
# on it (README, "Fuzzing").
#
#   fuzz.sh build                build the instrumented harness
#   fuzz.sh seeds                add preprocessed C headers to the reader
#                                seeds
#   fuzz.sh run TARGET MINUTES   fuzz TARGET for MINUTES, resuming an
#                                earlier run of it
#   fuzz.sh triage TARGET        minimise each crash and hang and print
#                                what the harness says of each crash
#
# TYPEC_FUZZ_DIR holds the build, the seeds and the findings; OPAMROOT
# and TYPEC_FUZZ_SWITCH name the instrumented compiler; CC preprocesses
# the seeds.

set -eu

repo=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
work=${TYPEC_FUZZ_DIR:-/Volumes/Optaine/typec-fuzz}
mkdir -p "$work"
# Absolute, so that build, which runs in the repository, keeps out of it.
work=$(CDPATH='' cd "$work" && pwd)
switch=${TYPEC_FUZZ_SWITCH:-afl}
export OPAMROOT="${OPAMROOT:-/Volumes/Optaine/opam}"
harness=$work/_build/default/tools/fuzz/fuzz.exe

# The limits of one execution; the README says why these values. AFL++
# runs an input that times out again with AFL_HANG_TMOUT and saves it as
# a hang only if that run times out too. Twice the limit spares a run
# that a busy host made late, where AFL++'s default second would drop
# a step ten times too slow.
timeout_ms=100
memory_mb=0
export AFL_HANG_TMOUT=$((timeout_ms * 2))

# The heap bound of fuzz.ml holds for the default GC settings.
unset OCAMLRUNPARAM

# The harness exits with this code on a crash (crash in fuzz.ml), so a
# crash never reaches the crash reporter of macOS. AFL++ refuses to start
# while that reporter is enabled unless told it may.
export AFL_CRASH_EXITCODE=70
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1

usage() {
    echo "usage: fuzz.sh build | seeds | run TARGET MINUTES" \
        "| triage TARGET" >&2
    exit 2
}

build() {
    cd "$repo"
    opam exec --switch "$switch" -- \
        dune build --root . --build-dir "$work/_build" ./tools/fuzz/fuzz.exe
}

# Small headers, whose preprocessed text is below the harness's input
# limit with the macOS SDK and glibc, named for the compiler so that
# seeds from several can be kept. A seed is renamed into place only once
# the compiler succeeds, so a failure leaves no partial one.
seeds() {
    compiler=${CC:-cc}
    dir=$work/seeds/reader
    mkdir -p "$dir"
    for header in stddef stdint stdbool stdarg limits errno; do
        seed=$dir/$header-$(basename "$compiler").i
        printf '#include <%s.h>\n' "$header" |
            "$compiler" -E -x c - > "$seed.part"
        mv "$seed.part" "$seed"
    done
}

# The committed seeds of TARGET and any generated ones, in a fresh
# directory, as afl-fuzz -i wants them.
gather_seeds() {
    input=$work/in/$1
    rm -rf "$input"
    mkdir -p "$input"
    cp "$repo/tools/fuzz/seeds/$1/"* "$input/"
    if [ -d "$work/seeds/$1" ]; then
        cp "$work/seeds/$1/"* "$input/"
    fi
}

run() {
    target=$1
    seconds=$(($2 * 60))
    output=$work/out/$target
    mkdir -p "$work/out"
    if [ -f "$output/default/fuzzer_stats" ]; then
        input=-
    else
        gather_seeds "$target"
        input=$work/in/$target
    fi
    # The positional parameters, no longer needed, carry the optional -x.
    dictionary=$repo/tools/fuzz/$target.dict
    if [ -f "$dictionary" ]; then
        set -- -x "$dictionary"
    else
        set --
    fi
    afl-fuzz -i "$input" -o "$output" "$@" -t "$timeout_ms" \
        -m "$memory_mb" -V "$seconds" -- "$harness" "$target" @@
}

# minimise TARGET CASE OUTPUT [FLAG]: afl-tmin keeps CASE failing the
# same way while it shrinks it.
minimise() {
    target=$1 case_file=$2 minimised=$3
    shift 3
    afl-tmin "$@" -t "$timeout_ms" -m "$memory_mb" \
        -i "$case_file" -o "$minimised" -- "$harness" "$target" @@ \
        > /dev/null
}

triage() {
    target=$1
    findings=$work/out/$target/default
    triaged=$work/triage/$target
    mkdir -p "$triaged"
    for case_file in "$findings"/crashes/id:*; do
        [ -f "$case_file" ] || continue
        minimised=$triaged/crash-$(basename "$case_file")
        if ! minimise "$target" "$case_file" "$minimised"; then
            echo "$case_file: does not crash again"
            continue
        fi
        echo "$minimised:"
        "$harness" "$target" "$minimised" || true
    done
    for case_file in "$findings"/hangs/id:*; do
        [ -f "$case_file" ] || continue
        minimised=$triaged/hang-$(basename "$case_file")
        if ! minimise "$target" "$case_file" "$minimised" -H; then
            echo "$case_file: no longer exceeds ${timeout_ms} ms"
            continue
        fi
        echo "$minimised: exceeds ${timeout_ms} ms"
    done
    # Every timeout, also those of inputs not saved for a path seen before.
    grep '^total_tmout' "$findings/fuzzer_stats" || true
}

# A target is a directory of committed seeds; checking that first keeps a
# name such as ../out from reaching the rm -rf of gather_seeds.
check_target() {
    case $1 in
    '' | *[!a-z_]*) usage ;;
    esac
    [ -d "$repo/tools/fuzz/seeds/$1" ] || usage
}

check_minutes() {
    case $1 in
    '' | *[!0-9]*) usage ;;
    esac
}

[ $# -ge 1 ] || usage
command=$1
shift
case "$command:$#" in
build:0) build ;;
seeds:0) seeds ;;
run:2)
    check_target "$1"
    check_minutes "$2"
    run "$1" "$2"
    ;;
triage:1)
    check_target "$1"
    triage "$1"
    ;;
*) usage ;;
esac
