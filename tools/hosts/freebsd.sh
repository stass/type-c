#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs typec's build and test suite, and optionally the corpus runner, on
# a FreeBSD x86-64 host reached over ssh, in the user space of an account
# there.
#
# usage: tools/hosts/freebsd.sh [LOG]
#        tools/hosts/run.sh freebsd [LOG]
#
# The environment names the host and what to run:
#
#   TYPEC_FREEBSD_TARGET  USER@HOST of the account, required.
#   TYPEC_FREEBSD_KEY     the ssh identity file; unset, ssh chooses.
#   TYPEC_FREEBSD_DIR     the directory of the account's home that holds
#                         everything this script puts on the host, by
#                         default typec-host.
#   TYPEC_FREEBSD_CORPUS  the programs of the corpus to run after the
#                         suite, as plain names separated by spaces;
#                         unset or empty, none.
#   TYPEC_CORPUS          the corpus repository (README, "Running the
#                         corpus"), by default
#                         /Volumes/Optaine/type-c-corpus.
#
# The host supplies its own GCC and Clang, which this script only checks
# for, together with gmake, git and curl. OCaml and dune are built from
# source tarballs, pinned by SHA-256, into DIR/toolchain once, and again
# when a pin changes. Each run copies the files of the working tree that
# git tracks or would track into DIR/src, read-only, builds in DIR/build,
# and runs the suite twice: with the oldest Clang and the GCC, then with
# the newest Clang and the GCC. Nothing runs as root, and the tools get
# a HOME inside DIR. The corpus programs are third-party code that runs
# with the account's own rights, so the account should be one that
# holds nothing else. The output goes to LOG, by default
# ${TMPDIR:-/tmp}/typec-host-freebsd.log, outside the repository.

set -eu

# The compilers of the host: the oldest Clang that typec supports
# (Target.minimum_major_version), the newest one the host has, and a GCC.
# The base system's Clang is older than the minimum.
oldest_clang=/usr/local/bin/clang20
newest_clang=/usr/local/bin/clang23
gcc=/usr/local/bin/gcc14

# tools/fuzz needs OCaml 5.4 (Char.Ascii), which the host lacks. The
# hashes are those of the tarballs from the projects' own hosts; a
# changed tarball fails the build until the pin is checked and bumped
# here.
ocaml_url=https://caml.inria.fr/pub/distrib/ocaml-5.4/ocaml-5.4.1.tar.gz
ocaml_sha256=cd4807a9d85b3eacbdcb9b84807b21fc1e290e56d73adfd8dd4bfdf87f36fab4
dune_url=https://github.com/ocaml/dune/releases/download/3.22.2/dune-3.22.2.tbz
dune_sha256=c2ccf8bc6b17afa47c450297357496303aa7c8680e329b79d98c68e35013a118

usage() {
  echo "usage: $0 [LOG]" >&2
  exit 2
}

[ $# -le 1 ] || usage
target=${TYPEC_FREEBSD_TARGET:-}
key=${TYPEC_FREEBSD_KEY:-}
dir=${TYPEC_FREEBSD_DIR:-typec-host}
programs=${TYPEC_FREEBSD_CORPUS:-}
corpus=${TYPEC_CORPUS:-/Volumes/Optaine/type-c-corpus}
log=${1:-${TMPDIR:-/tmp}/typec-host-freebsd.log}

# Everything sent to the host is a plain word (see run_script), and the
# directory is no hidden name, as DIR/.typec-host marks the ones we own.
case $target in
  '' | -* | *[!A-Za-z0-9._@-]*)
    echo "$0: TYPEC_FREEBSD_TARGET must be USER@HOST" >&2
    exit 2
    ;;
esac
case $dir in
  '' | .* | /* | *[!A-Za-z0-9._-]*)
    echo "$0: TYPEC_FREEBSD_DIR must be a plain name in the home" >&2
    exit 2
    ;;
esac
case $programs in
  *[!A-Za-z0-9._\ -]*)
    echo "$0: TYPEC_FREEBSD_CORPUS must be plain names" >&2
    exit 2
    ;;
esac
if [ -n "$programs" ] && [ ! -d "$corpus/programs" ]; then
  echo "$0: $corpus is not a corpus repository" >&2
  exit 2
fi

repo=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)

# ssh never asks anything, so a host that needs a password or has an
# unknown host key fails the run, and it forwards nothing to the host.
remote() {
  if [ -n "$key" ]; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o ClearAllForwardings=yes -o ForwardAgent=no -o ForwardX11=no \
      -o IdentitiesOnly=yes -i "$key" "$target" "$@"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o ClearAllForwardings=yes -o ForwardAgent=no -o ForwardX11=no \
      "$target" "$@"
  fi
}

say() {
  echo "freebsd: $*"
  echo "== $*" >> "$log"
}

fail() {
  echo "freebsd: $*; see $log" >&2
  echo "== $*" >> "$log"
  exit 1
}

# Runs the sh script on stdin on the host, as the account's login shell
# is not sh, with the words of ARGS as its arguments. They go in a line
# of the script, not on the ssh command line, which that shell would
# parse; each is a plain word, so they need no quoting.
run_script() {
  { echo "set -- $*"; cat; } | remote sh -s
}

# Checks the host and builds OCaml and dune unless DIR/toolchain has them.
toolchain_script() {
  cat <<'SCRIPT'
set -eu
dir=$1 ocaml_url=$2 ocaml_sha256=$3 dune_url=$4 dune_sha256=$5
shift 5

if [ "$(uname -sm)" != "FreeBSD amd64" ]; then
  echo "not FreeBSD amd64" >&2
  exit 1
fi
for tool in gmake git curl; do
  command -v "$tool" > /dev/null || { echo "no $tool" >&2; exit 1; }
done
for compiler in "$@"; do
  [ -x "$compiler" ] || { echo "no $compiler" >&2; exit 1; }
  "$compiler" --version | head -n 1
done

# Later steps delete below DIR, so DIR must be one this script made.
if [ -e "$dir" ] && [ ! -f "$dir/.typec-host" ]; then
  echo "$dir exists and is not a typec host directory" >&2
  exit 1
fi
mkdir -p "$dir"
touch "$dir/.typec-host"
cd "$dir"
pins="$ocaml_sha256 $dune_sha256"
if [ -f toolchain/pins ] && [ "$(cat toolchain/pins)" = "$pins" ]; then
  echo "toolchain is current"
  PATH=$PWD/toolchain/bin:$PATH
  ocaml -version
  dune --version
  exit 0
fi

# Fetches URL to FILE, which must have the SHA-256 HASH.
download() {
  fetch -q -o "$3" "$1"
  [ "$(sha256 -q "$3")" = "$2" ] || { echo "bad checksum: $1" >&2; exit 1; }
}

jobs=$(sysctl -n hw.ncpu)
prefix=$PWD/toolchain
rm -rf toolchain toolchain-work
mkdir toolchain-work
cd toolchain-work
download "$ocaml_url" "$ocaml_sha256" ocaml.tar.gz
download "$dune_url" "$dune_sha256" dune.tbz
tar -xzf ocaml.tar.gz
(cd ocaml-* && ./configure --prefix="$prefix" && gmake -j "$jobs" \
  && gmake install)
PATH=$prefix/bin:$PATH
tar -xjf dune.tbz
(cd dune-* && ./configure --prefix "$prefix" && gmake release \
  && gmake install)
ocaml -version
dune --version
cd ..
rm -rf toolchain-work
echo "$pins" > toolchain/pins
SCRIPT
}

# Empties DIR/src, whose files are read-only, and DIR/corpus; DIR/build
# and DIR/corpus-cache are kept. The toolchain step has made DIR.
prepare_script() {
  cat <<'SCRIPT'
set -eu
cd "$1"
[ ! -e src ] || chmod -R u+w src
rm -rf src corpus
mkdir src corpus
SCRIPT
}

# Builds DIR/src in DIR/build, then tests it with the GCC and each of
# the Clangs in turn.
suite_script() {
  cat <<'SCRIPT'
set -eu
dir=$1 gcc=$2
shift 2
cd "$dir"
chmod -R a-w src
PATH=$PWD/toolchain/bin:$PATH
HOME=$PWD/home
export HOME
mkdir -p "$HOME"
dune build --root src --build-dir "$PWD/build"
# Every Clang runs, so that one failure does not hide another.
status=0
for clang in "$@"; do
  echo "== dune test with $clang and $gcc"
  TYPEC_TEST_CLANG=$clang TYPEC_TEST_GCC=$gcc \
    dune test --root src --build-dir "$PWD/build" --diff-command "diff -u" \
    || status=1
done
exit $status
SCRIPT
}

# Fetches the sources of DIR/corpus into DIR/corpus-cache and runs the
# corpus runner, built by the suite, on the programs after the compilers.
# It prints the record of each run, which the next run deletes with
# DIR/corpus.
corpus_script() {
  cat <<'SCRIPT'
set -eu
dir=$1 clang_oldest=$2 clang_newest=$3 gcc=$4
shift 4
cd "$dir"
HOME=$PWD/home
export HOME
mkdir -p "$HOME"
TYPEC_CORPUS_CACHE=$PWD/corpus-cache corpus/fetch.sh
build/default/tools/corpus/corpus.exe --corpus corpus \
  --cache "$PWD/corpus-cache" --typec build/install/default/bin/typec \
  --cc "$clang_oldest" --cc "$clang_newest" --cc "$gcc" "$@"
SCRIPT
}

# Writes the files of the working tree that git tracks or does not
# ignore, as a tar archive, without the contents of the repositories
# nested in it. The .git of a worktree is a file naming a directory
# outside it, so it stays behind.
source_archive() {
  cd "$repo"
  git ls-files -z --cached --others --exclude-standard \
    | tar -cf - --no-recursion --no-xattrs --no-mac-metadata --no-acls \
      --null -T -
}

: > "$log"
say "checking the host and the toolchain; log in $log"
toolchain_script \
  | run_script "$dir" "$ocaml_url" "$ocaml_sha256" \
    "$dune_url" "$dune_sha256" "$oldest_clang" "$newest_clang" "$gcc" \
    >> "$log" 2>&1 || fail "the toolchain is not ready"

say "copying the source"
prepare_script | run_script "$dir" >> "$log" 2>&1 \
  || fail "the source directory is not ready"
source_archive | remote tar -xf - -C "$dir/src" >> "$log" 2>&1 \
  || fail "the source does not copy"

say "running dune build and dune test"
suite_script \
  | run_script "$dir" "$gcc" "$oldest_clang" "$newest_clang" \
    >> "$log" 2>&1 || fail "the suite fails"
say "the suite passes"

if [ -n "$programs" ]; then
  say "running the corpus runner on: $programs"
  # The archive holds the repository with its history, whose revision
  # the runner records.
  tar -cf - --no-xattrs --no-mac-metadata --no-acls -C "$corpus" . \
    | remote tar -xf - -C "$dir/corpus" >> "$log" 2>&1 \
    || fail "the corpus does not copy"
  status=0
  corpus_script \
    | run_script "$dir" "$oldest_clang" "$newest_clang" "$gcc" \
      "$programs" >> "$log" 2>&1 || status=$?
  # The runner's status 3 is a run in which nothing failed but some
  # tests are substitutes (README, "Running the corpus").
  case $status in
    0) say "the corpus runner passes" ;;
    3) say "the corpus runner passes, with substitute tests (status 3)" ;;
    *) fail "the corpus runner fails with status $status" ;;
  esac
fi
