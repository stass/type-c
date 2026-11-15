#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Prints the revision of the git working tree DIR in the form the corpus
# runner takes for --typec-revision and --corpus-revision (README,
# "Running the corpus"): the commit in at least twelve hex digits, then
# -dirty when the tree differs from it. A file git does not track but
# does not ignore counts as a difference, since dune builds it and the
# test hosts are sent it.
#
# usage: tools/corpus/revision.sh DIR

set -eu

[ $# -eq 1 ] || { echo "usage: $0 DIR" >&2; exit 2; }
commit=$(git -C "$1" rev-parse --short=12 HEAD)
changes=$(git -C "$1" status --porcelain)
if [ -n "$changes" ]; then
  echo "$commit-dirty"
else
  echo "$commit"
fi
