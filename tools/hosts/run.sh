#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs typec's build and test suite on a test host.
#
# usage: tools/hosts/run.sh HOST [LOG]
#
# HOST is a name from the table below. A Linux host is a Dockerfile and a
# platform: the script builds its image and runs the suite in a container
# of it, with the source mounted read-only and no network, the container
# removed afterwards. A platform that the machine does not run itself
# needs emulation in Docker (binfmt and qemu-user), and the suite is slow
# there. The FreeBSD host is a script, which no container gives, and is
# run with LOG. Either kind writes to LOG, by default
# ${TMPDIR:-/tmp}/typec-host-HOST.log, outside the repository.

set -eu

usage() {
  echo "usage: $0 HOST [LOG]" >&2
  echo "hosts: debian-amd64 debian-arm64 alpine-amd64 alpine-arm64" \
    "freebsd" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
host=$1

# The hosts: the Dockerfile and the platform of each Linux host, which is
# the host's whatever the machine that runs it, and the script of the
# others.
dockerfile= platform= script=
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
log=${2:-${TMPDIR:-/tmp}/typec-host-$host.log}

if [ -n "$script" ]; then
  exec "$hosts_dir/$script" "$log"
fi
dockerfile=$hosts_dir/$dockerfile

echo "$host: building $image; log in $log"

# The Dockerfile comes on stdin, so no build context is sent. buildx
# builds for a platform that the machine does not run; the classic
# builder reuses a base image of the machine's own platform instead.
if ! docker buildx build --platform "$platform" --load --tag "$image" - \
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
