#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs typec's build and test suite, or the corpus runner, on a test host.
#
# usage: tools/hosts/run.sh [--source DIR] HOST [LOG]
#        tools/hosts/run.sh [--source DIR] --corpus HOST LOG PROGRAM...
#
# HOST is a name from the table below. A Linux host is a Dockerfile and a
# platform: the script builds its image and runs the suite in a container
# of it, with the source mounted read-only and no network, the container
# removed afterwards. The image is tagged by the content of the
# Dockerfile (typec-host-HOST:HASH), so an edited Dockerfile gets a new
# image and the build cache spares an unchanged one; after each build the
# host's images of other Dockerfiles are removed. A
# platform that the machine does not run itself needs emulation in Docker
# (binfmt and qemu-user), and the suite is slow there. The FreeBSD host
# is a script, which no container gives, and is run with LOG. Either kind
# writes to LOG, by default ${TMPDIR:-/tmp}/typec-host-HOST.log, outside
# the repository.
#
# The tooling is the tree this script sits in: its Dockerfiles, its
# corpus-in-container.sh and its revision.sh. The source is the typec
# checkout that is tested or recorded, by default that same tree, or DIR
# of --source, so that the tooling of one revision can run another (say,
# the current images on a checkout of an older revision). The corpus
# runner of the source must take the command line that
# corpus-in-container.sh gives it. The FreeBSD host takes no --source.
#
# --corpus runs the corpus runner (docs/development.md, "Running the corpus") on
# the named programs in a container of a Linux host, with the host's Clang and
# GCC as backends, and copies the records it writes into the corpus repository
# and its logs into the cache. The environment names both:
#
#   TYPEC_CORPUS        the corpus repository, by default
#                       /Volumes/Optaine/type-c-corpus.
#   TYPEC_CORPUS_CACHE  its cache, as fetch.sh fills it, by default
#                       /Volumes/Optaine/type-c-corpus-cache.
#
# Docker may not share either path, so nothing is mounted: the inputs go
# into the container as a tar stream on its stdin, and the results come
# out as one on its stdout (corpus-in-container.sh). The inputs are the
# source tree and the corpus repository, each as the files git
# tracks or does not ignore, and the sources of the cache. No git
# directory goes in, as the corpus programs are third-party code: the
# revision of each tree as the machine sees it (tools/corpus/revision.sh)
# goes to the runner on its command line. The FreeBSD host runs the
# corpus from its own script instead (TYPEC_FREEBSD_CORPUS).

set -eu

usage() {
  echo "usage: $0 [--source DIR] HOST [LOG]" >&2
  echo "       $0 [--source DIR] --corpus HOST LOG PROGRAM..." >&2
  echo "hosts: debian-amd64 alpine-amd64 alpine-arm64" \
    "freebsd (not with --corpus)" >&2
  exit 2
}

hosts_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
tooling_dir=$(CDPATH='' cd "$hosts_dir/../.." && pwd)
source_dir=$tooling_dir

mode=suite
while [ $# -gt 0 ]; do
  case $1 in
    --corpus) mode=corpus ;;
    --source)
      [ $# -ge 2 ] && [ -d "$2" ] || usage
      source_dir=$(CDPATH='' cd "$2" && pwd)
      shift
      ;;
    *) break ;;
  esac
  shift
done
if [ "$mode" = corpus ]; then
  # After this, the arguments left are the programs of the run.
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
  alpine-amd64) dockerfile=alpine.Dockerfile platform=linux/amd64 ;;
  alpine-arm64) dockerfile=alpine.Dockerfile platform=linux/arm64 ;;
  freebsd) script=freebsd.sh ;;
  *) usage ;;
esac

if [ -n "$script" ]; then
  [ "$mode" = suite ] || usage
  if [ "$source_dir" != "$tooling_dir" ]; then
    echo "$host: the FreeBSD host takes no --source" >&2
    exit 2
  fi
  exec "$hosts_dir/$script" "$log"
fi
dockerfile=$hosts_dir/$dockerfile
# The image of this host for this Dockerfile, whatever other Dockerfiles
# were built before.
image=typec-host-$host:$(shasum -a 256 < "$dockerfile" | cut -c1-12)

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
  remove_older_images
}

# Removes this host's images built from earlier Dockerfiles, so that
# each edit of a Dockerfile does not leave a stale image behind. Only
# the repository named for this host is touched. The removal is best
# effort: an image that a container still uses, or any other failure of
# docker, leaves it in place with a warning and does not stop the run.
remove_older_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' "typec-host-$host" |
    while read -r older; do
      if [ "$older" = "$image" ]; then
        continue
      fi
      docker rmi "$older" > /dev/null ||
        echo "$host: could not remove $older" >&2
    done
}

# Whether qemu-user runs the host: its platform is not the Docker
# daemon's.
emulated() {
  docker_arch=$(docker version --format '{{.Server.Arch}}') ||
    fail "docker gives no architecture"
  case $docker_arch in
    amd64 | arm64) ;;
    *) fail "docker runs on an unknown architecture: $docker_arch" ;;
  esac
  [ "${platform#linux/}" != "$docker_arch" ]
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
  # LeakSanitizer stops the threads of a program with ptrace, which
  # qemu-user does not implement, so an emulated host runs the sanitized
  # tests without leak detection. An empty ASAN_OPTIONS is the default.
  asan_options=''
  if emulated; then
    asan_options=detect_leaks=0
    echo "$host: emulated, so LeakSanitizer is off"
  fi
  if ! docker run --platform "$platform" --rm --network none --cap-drop ALL \
    --security-opt no-new-privileges --env "ASAN_OPTIONS=$asan_options" \
    --mount "type=bind,source=$source_dir,target=/src,readonly" \
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
    exec sh corpus-in-container.sh "$@"'
  tar -cf - --no-xattrs --no-mac-metadata --no-acls \
    -C "$stage/in" typec corpus corpus-in-container.sh -C "$cache" src \
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
  revision_sh=$tooling_dir/tools/corpus/revision.sh
  typec_revision=$("$revision_sh" "$source_dir")
  corpus_revision=$("$revision_sh" "$corpus")
  # The records name the source, not the image, so the log does.
  echo "$host: image $image, tooling $("$revision_sh" "$tooling_dir")," \
    "source $typec_revision" | tee -a "$log"
  stage_tree "$source_dir" "$stage/in" typec
  cp "$hosts_dir/corpus-in-container.sh" "$stage/in"
  stage_tree "$corpus" "$stage/in" corpus

  echo "$host: running the corpus runner on: $*"
  run_container "$stage" "$typec_revision" "$corpus_revision" "$@"
  take_results "$stage"
  copy_results "$stage"

  # The runner's status 3 is a run in which nothing failed but some
  # tests are substitutes (docs/development.md, "Running the corpus").
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
