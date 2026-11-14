#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the image of a Linux test host and runs typec's build and test
# suite in a container of it.
#
# usage: tools/hosts/run.sh HOST [LOG]
#
# HOST names HOST.Dockerfile in this directory. The source is mounted
# read-only and built in the container, which has no network and is
# removed afterwards. The image build and the run write to LOG, by
# default ${TMPDIR:-/tmp}/typec-host-HOST.log, outside the repository.

set -eu

usage() {
  echo "usage: $0 HOST [LOG]" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
host=$1
# The name becomes part of a path and of an image tag.
case $host in
  '' | *[!a-z0-9-]*) usage ;;
esac

hosts_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
repo=$(CDPATH='' cd "$hosts_dir/../.." && pwd)
dockerfile=$hosts_dir/$host.Dockerfile
image=typec-host-$host
log=${2:-${TMPDIR:-/tmp}/typec-host-$host.log}

if [ ! -f "$dockerfile" ]; then
  echo "$0: no host $host: $dockerfile does not exist" >&2
  exit 2
fi

echo "$host: building $image; log in $log"
# The hosts are x86-64 whatever the machine that runs them.
platform=linux/amd64

# The Dockerfile comes on stdin, so no build context is sent.
if ! docker build --platform "$platform" --tag "$image" - \
  < "$dockerfile" > "$log" 2>&1; then
  echo "$host: the image does not build; see $log" >&2
  exit 1
fi

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
  echo "$host: the suite fails; see $log" >&2
  exit 1
fi
echo "$host: the suite passes"
