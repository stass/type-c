#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs typec's build and test suite, or the corpus runner, on a test host.
#
# usage: tools/hosts/run.sh HOST [LOG]
#        tools/hosts/run.sh --corpus HOST LOG PROGRAM...
#
# HOST is a name from the table below. A Linux host is a Dockerfile and a
# platform: the script builds its image and runs the suite in a container
# of it, with the source mounted read-only and no network, the container
# removed afterwards. A platform that the machine does not run itself
# needs emulation in Docker (binfmt and qemu-user), and the suite is slow
# there. The FreeBSD host is a script, which no container gives, and is
# run with LOG. Either kind writes to LOG, by default
# ${TMPDIR:-/tmp}/typec-host-HOST.log, outside the repository.
#
# --corpus runs the corpus runner (README, "Running the corpus") on the
# named programs in a container of a Linux host, with the host's Clang
# and GCC as backends, and copies the records it writes into the corpus
# repository and its logs into the cache. The environment names both:
#
#   TYPEC_CORPUS        the corpus repository, by default
#                       /Volumes/Optaine/type-c-corpus.
#   TYPEC_CORPUS_CACHE  its cache, as fetch.sh fills it, by default
#                       /Volumes/Optaine/type-c-corpus-cache.
#
# Docker may not share either path, so nothing is mounted: the inputs go
# into the container as a tar stream on its stdin, and the results come
# out as one on its stdout (corpus-in-container.sh). The inputs are the
# typec working tree and the corpus repository, each as the files git
# tracks or does not ignore, and the sources of the cache. No git
# directory goes in, as the corpus programs are third-party code: the
# revision of each tree as the machine sees it (tools/corpus/revision.sh)
# goes to the runner on its command line. The FreeBSD host runs the
# corpus from its own script instead (TYPEC_FREEBSD_CORPUS).

set -eu

usage() {
  echo "usage: $0 HOST [LOG]" >&2
  echo "       $0 --corpus HOST LOG PROGRAM..." >&2
  echo "hosts: debian-amd64 debian-arm64 alpine-amd64 alpine-arm64" \
    "freebsd (not with --corpus)" >&2
  exit 2
}

# After this, the arguments left are the programs of a corpus run.
mode=suite
if [ "${1:-}" = --corpus ]; then
  mode=corpus
  shift
  [ $# -ge 3 ] || usage
  host=$1 log=$2
  shift 2
else
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  host=$1 log=${2:-${TMPDIR:-/tmp}/typec-host-$1.log}
fi

# The hosts: the Dockerfile and the platform of each Linux host, which is
# the host's own on whatever machine runs it, and the script of the
# others.
dockerfile='' platform='' script=''
case $host in
  debian-amd64) dockerfile=debian.Dockerfile platform=linux/amd64 ;;
  debian-arm64) dockerfile=debian.Dockerfile platform=linux/arm64 ;;
  alpine-amd64) dockerfile=alpine.Dockerfile platform=linux/amd64 ;;
  alpine-arm64) dockerfile=alpine.Dockerfile platform=linux/arm64 ;;
  freebsd) script=freebsd.sh ;;
  *) usage ;;
esac

hosts_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
repo=$(CDPATH='' cd "$hosts_dir/../.." && pwd)
image=typec-host-$host

if [ -n "$script" ]; then
  [ "$mode" = suite ] || usage
  exec "$hosts_dir/$script" "$log"
fi
dockerfile=$hosts_dir/$dockerfile

fail() {
  echo "$host: $1" >&2
  exit 1
}

# Sets corpus and cache from the environment, as absolute paths, since
# tar resolves a relative one against the directory before it.
find_corpus() {
  corpus=${TYPEC_CORPUS:-/Volumes/Optaine/type-c-corpus}
  cache=${TYPEC_CORPUS_CACHE:-/Volumes/Optaine/type-c-corpus-cache}
  if [ ! -d "$corpus/programs" ]; then
    echo "$host: $corpus is not a corpus repository" >&2
    exit 2
  fi
  if [ ! -d "$cache/src" ]; then
    echo "$host: $cache holds no sources: run $corpus/fetch.sh" >&2
    exit 2
  fi
  corpus=$(CDPATH='' cd "$corpus" && pwd)
  cache=$(CDPATH='' cd "$cache" && pwd)
}

build_image() {
  echo "$host: building $image; log in $log"
  # The Dockerfile comes on stdin, so no build context is sent. buildx
  # builds for a platform that the machine does not run; the classic
  # builder reuses a base image of the machine's own platform instead.
  if ! docker buildx build --platform "$platform" --load --tag "$image" - \
    < "$dockerfile" > "$log" 2>&1; then
    fail "the image does not build; see $log"
  fi
}

# Runs the suite with the source mounted read-only.
run_suite() {
  echo "$host: running dune build and dune test"
  # dune would show a test's diff with git when the image has it, and git
  # fails on the .git file of a worktree, which names a directory outside
  # the mount.
  # The single quotes are deliberate: $HOME is the container's.
  # shellcheck disable=SC2016
  suite='dune build --root /src --build-dir "$HOME/build" &&
    dune test --root /src --build-dir "$HOME/build" --diff-command "diff -u"'
  if ! docker run --platform "$platform" --rm --network none --cap-drop ALL \
    --security-opt no-new-privileges \
    --mount "type=bind,source=$repo,target=/src,readonly" \
    "$image" sh -c "$suite" >> "$log" 2>&1; then
    fail "the suite fails; see $log"
  fi
  echo "$host: the suite passes"
}

# Puts the working tree SOURCE in INTO/NAME: the files git tracks or does
# not ignore, without the contents of the repositories nested in it or
# its git directory.
stage_tree() {
  source=$1 into=$2 name=$3
  mkdir "$into/$name"
  (cd "$source" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$source" && tar -cf - --no-recursion --null -T -) \
    | tar -xf - -C "$into/$name"
}

# Sends the inputs in STAGE/in to a container that runs
# corpus-in-container.sh with the arguments after STAGE, and extracts its
# results in STAGE/out. Whether the run gave results is for take_results
# to say.
run_container() {
  stage=$1
  shift
  # The single quotes are deliberate: $HOME and $@ are the container's.
  # shellcheck disable=SC2016
  unpack='set -eu
    cd "$HOME"
    mkdir work
    cd work
    tar -xf -
    exec sh typec/tools/hosts/corpus-in-container.sh "$@"'
  tar -cf - --no-xattrs --no-mac-metadata --no-acls \
    -C "$stage/in" typec corpus -C "$cache" src \
    | docker run --platform "$platform" --rm --interactive --init \
      --network none --cap-drop ALL --security-opt no-new-privileges \
      "$image" sh -c "$unpack" sh "$@" 2>> "$log" \
    | tar -xf - -C "$stage/out" 2>> "$log" \
    || fail "the corpus run gives no results; see $log"
}

# Checks the results in STAGE/out, which come from a container that ran
# the corpus programs, and sets status to the runner's. They must be
# plain files with plain names, in ASCII, and the records that changed
# and the logs must be of one host. Only the files where the runner
# writes them are taken (copy_results).
take_results() {
  out=$1/out
  if [ -n "$(find "$out" ! -type d ! -type f)" ]; then
    fail "the results hold a file that is not plain"
  fi
  if [ -n "$(LC_ALL=C find "$out" -name '*[!A-Za-z0-9._-]*')" ]; then
    fail "the results hold a name that is not plain"
  fi
  status=$(cat "$out/status" 2> /dev/null || true)
  case $status in
    '' | *[!0-9]*) fail "the corpus run gives no results; see $log" ;;
  esac
  mkdir -p "$out/corpus/runs" "$out/cache/build"
  hosts=$( (changed_records "$1" && cd "$out/cache" && find build \
    -mindepth 1 -maxdepth 1) | cut -d / -f 2 | sort -u | wc -l)
  [ "$hosts" -le 1 ] || fail "the results name more than one host"
}

# Lists the records in STAGE/out/corpus that differ from those sent in
# STAGE/in/corpus, relative to them: the ones the run wrote, since the
# runner rewrites only the records of the programs it runs.
changed_records() {
  (cd "$1/out/corpus" && find runs -mindepth 2 -maxdepth 2 -type f \
    -name '*.txt') | while read -r record; do
    cmp -s "$1/out/corpus/$record" "$1/in/corpus/$record" \
      || echo "$record"
  done
}

# Copies each file that standard input names, relative to FROM, to TO.
copy_files() {
  from=$1 to=$2
  while read -r file; do
    [ -n "$file" ] || continue
    mkdir -p "$(dirname "$to/$file")"
    cp "$from/$file" "$to/$file"
  done
}

# Copies the records that changed in STAGE/out into the corpus repository
# and the logs into the cache, where the runner on the machine would
# write them. The test outputs of a backend replace the old ones, as the
# runner's do, whether or not the run made new ones.
copy_results() {
  out=$1/out
  changed_records "$1" | copy_files "$out/corpus" "$corpus"
  logs=$(cd "$out/cache" && find build -mindepth 3 -maxdepth 3 -type f \
    -name '*.log')
  for log_file in $logs; do
    rm -rf "${cache:?}/${log_file%.log}.tests"
  done
  (cd "$out/cache" && echo "$logs" && find build -mindepth 4 -maxdepth 4 \
    -type f -path 'build/*/*/*.tests/*') | copy_files "$out/cache" "$cache"
}

# Runs the corpus runner on the programs and copies its results out.
run_corpus() {
  stage=$(mktemp -d "${TMPDIR:-/tmp}/typec-corpus.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  mkdir "$stage/in" "$stage/out"
  typec_revision=$("$repo/tools/corpus/revision.sh" "$repo")
  corpus_revision=$("$repo/tools/corpus/revision.sh" "$corpus")
  stage_tree "$repo" "$stage/in" typec
  stage_tree "$corpus" "$stage/in" corpus

  echo "$host: running the corpus runner on: $*"
  run_container "$stage" "$typec_revision" "$corpus_revision" "$@"
  take_results "$stage"
  copy_results "$stage"

  # The runner's status 3 is a run in which nothing failed but some
  # tests are substitutes (README, "Running the corpus").
  case $status in
    0) echo "$host: the corpus runner passes" ;;
    3) echo "$host: the corpus runner passes, with substitute tests" ;;
    *) fail "the corpus runner fails with status $status; see $log" ;;
  esac
}

if [ "$mode" = suite ]; then
  build_image
  run_suite
else
  find_corpus
  build_image
  run_corpus "$@"
fi
