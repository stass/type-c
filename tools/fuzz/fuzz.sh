#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the fuzz harness with an AFL-instrumented OCaml and runs AFL++
# on it (docs/development.md, "Fuzzing").
#
#   fuzz.sh build                build the instrumented harness and its
#                                dictionary
#   fuzz.sh seeds                add preprocessed C headers to the seeds
#                                of every target
#   fuzz.sh run TARGET MINUTES [SECONDARIES]
#                                fuzz TARGET for MINUTES with one main
#                                AFL++ instance and SECONDARIES (default
#                                0) secondary ones that share its finds,
#                                resuming an earlier run of it
#   fuzz.sh triage TARGET        minimise each crash and hang of every
#                                instance and print what the harness says
#                                of each crash
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
# The harness and the dictionary of every target, as build puts them.
built=$work/_build/default/tools/fuzz
harness=$built/fuzz.exe
dictionary=$built/fuzz.dict

# The limits of one execution; docs/development.md says why these values. AFL++
# runs an input that times out again with AFL_HANG_TMOUT and saves it as a hang
# only if that run times out too. Twice the limit spares a run that a busy host
# made late, where AFL++'s default second would drop a step ten times too slow.
timeout_ms=300
# No AFL++ memory limit, spelled none because afl-tmin 5.03c refuses -m 0.
memory_limit=none
export AFL_HANG_TMOUT=$((timeout_ms * 2))

# The heap bound of fuzz.ml holds for the default GC settings.
unset OCAMLRUNPARAM

# The harness exits with this code on a crash (crash in fuzz.ml), so a
# crash never reaches the crash reporter of macOS. AFL++ refuses to start
# while that reporter is enabled unless told it may.
export AFL_CRASH_EXITCODE=70
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
# Instances run in the background, without the status screen; each logs to
# a file of its own.
export AFL_NO_UI=1
# The scheduler places the instances on every system, because AFL++ 5.03c
# on FreeBSD binds every one of them to the first core.
export AFL_NO_AFFINITY=1

usage() {
    echo "usage: fuzz.sh build | seeds | run TARGET MINUTES [SECONDARIES]" \
        "| triage TARGET" >&2
    exit 2
}

build() {
    cd "$repo"
    opam exec --switch "$switch" -- \
        dune build --root . --build-dir "$work/_build" @@tools/fuzz/harness
}

# Small headers, whose preprocessed text is below the harness's input
# limit with the macOS SDK and glibc, named for the compiler so that
# seeds from several can be kept. A seed is renamed into place only once
# the compiler succeeds, so a failure leaves no partial one.
seeds() {
    compiler=${CC:-cc}
    dir=$work/seeds/headers
    mkdir -p "$dir"
    for header in stddef stdint stdbool stdarg limits errno; do
        seed=$dir/$header-$(basename "$compiler").i
        printf '#include <%s.h>\n' "$header" |
            "$compiler" -E -x c - > "$seed.part"
        mv "$seed.part" "$seed"
    done
}

# The committed seeds of TARGET and the generated ones (in any directory
# of seeds/, such as the headers that seeds makes), which every target
# takes since each reads preprocessed text, in a fresh directory, as
# afl-fuzz -i wants them.
gather_seeds() {
    input=$work/in/$1
    rm -rf "$input"
    mkdir -p "$input"
    cp "$repo/tools/fuzz/seeds/$1/"* "$input/"
    # Only complete seeds: a failed compiler leaves a .part behind.
    for seed in "$work/seeds/"*/*.i; do
        [ -f "$seed" ] || continue
        # Named for its directory, so that two of one name keep both.
        group=$(basename "$(dirname "$seed")")
        cp "$seed" "$input/$group-$(basename "$seed")"
    done
}

# instance TARGET SECONDS ROLE NAME: one afl-fuzz, resuming the findings
# of NAME if it has any. Instances in one output directory (ROLE -M for
# the main, -S for a secondary) exchange their finds. It execs afl-fuzz so
# that the background process is afl-fuzz itself, which a signal can stop.
instance() {
    target=$1 seconds=$2 role=$3 name=$4
    output=$work/out/$target
    if [ -f "$output/$name/fuzzer_stats" ]; then
        input=-
    else
        input=$work/in/$target
    fi
    exec afl-fuzz -i "$input" -o "$output" -x "$dictionary" \
        -t "$timeout_ms" -m "$memory_limit" -V "$seconds" \
        "$role" "$name" -- "$harness" "$target" @@ \
        > "$output.$name.log" 2>&1
}

run() {
    target=$1
    seconds=$(($2 * 60))
    secondaries=$3
    mkdir -p "$work/out"
    gather_seeds "$target"
    pids=
    trap 'kill $pids 2> /dev/null' INT TERM
    instance "$target" "$seconds" -M default &
    pids=$!
    n=1
    while [ "$n" -le "$secondaries" ]; do
        instance "$target" "$seconds" -S "s$n" &
        pids="$pids $!"
        n=$((n + 1))
    done
    status=0
    for pid in $pids; do
        wait "$pid" || status=1
    done
    if [ "$status" -ne 0 ]; then
        echo "an instance failed; see $work/out/$target.*.log" >&2
    fi
    return $status
}

# minimise TARGET CASE OUTPUT [FLAG]: afl-tmin keeps CASE failing the
# same way while it shrinks it.
minimise() {
    target=$1 case_file=$2 minimised=$3
    shift 3
    afl-tmin "$@" -t "$timeout_ms" -m "$memory_limit" \
        -i "$case_file" -o "$minimised" -- "$harness" "$target" @@ \
        > /dev/null
}

# triage_instance TARGET NAME: the crashes and hangs of one instance.
triage_instance() {
    target=$1 name=$2
    findings=$work/out/$target/$name
    triaged=$work/triage/$target
    mkdir -p "$triaged"
    for case_file in "$findings"/crashes/id:*; do
        [ -f "$case_file" ] || continue
        minimised=$triaged/crash-$name-$(basename "$case_file")
        if ! minimise "$target" "$case_file" "$minimised"; then
            echo "$case_file: does not crash again"
            continue
        fi
        echo "$minimised:"
        "$harness" "$target" "$minimised" || true
    done
    for case_file in "$findings"/hangs/id:*; do
        [ -f "$case_file" ] || continue
        minimised=$triaged/hang-$name-$(basename "$case_file")
        if ! minimise "$target" "$case_file" "$minimised" -H; then
            echo "$case_file: no longer exceeds ${timeout_ms} ms"
            continue
        fi
        echo "$minimised: exceeds ${timeout_ms} ms"
    done
    # Every timeout, also those of inputs not saved for a path seen before.
    grep '^total_tmout' "$findings/fuzzer_stats" || true
}

triage() {
    for instance_dir in "$work/out/$1"/*/; do
        [ -f "${instance_dir}fuzzer_stats" ] || continue
        triage_instance "$1" "$(basename "$instance_dir")"
    done
}

# A target is a directory of committed seeds; checking that first keeps a
# name such as ../out from reaching the rm -rf of gather_seeds.
check_target() {
    case $1 in
    '' | *[!a-z_]*) usage ;;
    esac
    [ -d "$repo/tools/fuzz/seeds/$1" ] || usage
}

# At most one instance per core, so that a typo cannot fork thousands.
check_secondaries() {
    check_minutes "$1"
    [ "$1" -lt "$(getconf _NPROCESSORS_ONLN)" ] || usage
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
run:2 | run:3)
    check_target "$1"
    check_minutes "$2"
    check_secondaries "${3:-0}"
    run "$1" "$2" "${3:-0}"
    ;;
triage:1)
    check_target "$1"
    triage "$1"
    ;;
*) usage ;;
esac
