#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The gate to run before a commit: builds typec, runs the default test
# suite, then builds the typing oracle and runs its tests, which compare
# typec's types with Clang's and build only in the oracle context
# (docs/development.md, "Typing oracle").
#
# Usage: tools/gate.sh
#
# OPAMROOT is the opam root that holds the switch tools (default
# /Volumes/Optaine/opam); a missing switch is a failure, not a skip.
# ORACLE_BUILD is the oracle's build directory and GATE_LOG the log; by
# default both are in /Volumes/Optaine/typec-oracle/NAME, outside the
# repository, where NAME is the name of the checkout's directory, so
# gates of different worktrees do not share them.
# TYPEC_TEST_CLANG names the Clang of the oracle tests as for the other
# tests. The gate first prints the report of test/run/backends.sh: the
# Arm backends of short_enums.t and c_header.t that run and those
# skipped, a dropped -m32, and whether the lldb examples of the tutorial
# run; a TYPEC_TEST_REQUIRE_ARM, TYPEC_TEST_REQUIRE_M32 or
# TYPEC_TEST_REQUIRE_LLDB that is set makes a skip of what it names fail
# the gate. Exits 0 only when every step passes.

set -u

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$root" || exit 1

OPAMROOT=${OPAMROOT:-/Volumes/Optaine/opam}
out=/Volumes/Optaine/typec-oracle/$(basename "$root")
ORACLE_BUILD=${ORACLE_BUILD:-$out/_build}
GATE_LOG=${GATE_LOG:-$out/gate.log}
export OPAMROOT

die() {
	echo "gate: $*" >&2
	exit 1
}

# The oracle needs the opam switch tools, which holds yojson.
require_tools_switch() {
	command -v opam >/dev/null 2>&1 || die "opam is not installed"
	opam switch list --short 2>/dev/null | grep -qx tools ||
		die "no opam switch tools in OPAMROOT=$OPAMROOT; create it \
there as docs/development.md, section \"Typing oracle\", says"
}

# Runs one step with its output appended to the log; on failure prints
# the end of the log and exits.
step() {
	name=$1
	shift
	echo "gate: $name"
	echo "gate: $name" >>"$GATE_LOG"
	if ! "$@" >>"$GATE_LOG" 2>&1; then
		tail -n 60 "$GATE_LOG" >&2
		die "$name failed; full log in $GATE_LOG"
	fi
}

# The cram tests skip a backend that the host lacks, and dune test sends
# their report to the log; printing it here keeps a skip in sight.
report_backends() {
	echo "gate: backends"
	(cd ./test/run && . ./backends.sh && backends_report) ||
		die "the report of test/run/backends.sh failed"
}

require_tools_switch
report_backends
mkdir -p "$(dirname "$GATE_LOG")" "$ORACLE_BUILD" || exit 1
: >"$GATE_LOG"

step "dune build" dune build --root .
step "dune test" dune test --root .
step "oracle tests" dune build --root . \
	--workspace tools/oracle/oracle.workspace \
	--build-dir "$ORACLE_BUILD" @tools/oracle/runtest

echo "gate: passed; log in $GATE_LOG"
