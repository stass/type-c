#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the corpus runner in a container of a Linux test host, for
# tools/hosts/run.sh --corpus, which explains the layout.
#
# usage: sh typec/tools/hosts/corpus-in-container.sh TYPEC_REVISION \
#          CORPUS_REVISION PROGRAM...
#
# The current directory holds the inputs that run.sh sends: the trees
# typec and corpus, without their git directories, and src, the sources
# of the cache. The revisions name the two trees as run.sh found them;
# the runner writes them into its records. The results go to stdout as a
# tar stream: every record under corpus/runs, of which run.sh keeps those
# that changed, the runner's logs under cache/build, and last the file
# status, holding the runner's exit status, so that a stream cut short
# has none. Everything else goes to stderr. The runner does not inherit
# stdout, but the programs it runs could still reach it, so run.sh checks
# what it takes.

set -eu
exec 3>&1 1>&2 0< /dev/null

typec_revision=$1 corpus_revision=$2
shift 2
mkdir cache
mv src cache/src
dune build --root typec
status=0
typec/_build/default/tools/corpus/corpus.exe --corpus "$PWD/corpus" \
  --cache "$PWD/cache" --typec "$PWD/typec/_build/install/default/bin/typec" \
  --typec-revision "$typec_revision" --corpus-revision "$corpus_revision" \
  --cc "$TYPEC_TEST_CLANG" --cc "$TYPEC_TEST_GCC" "$@" 3>&- || status=$?
echo "$status" > status

# The runner makes neither directory when it stops before any program.
mkdir -p corpus/runs cache/build
find corpus/runs -mindepth 2 -maxdepth 2 -type f -name '*.txt' > results
find cache/build -mindepth 3 -maxdepth 3 -type f -name '*.log' >> results
find cache/build -mindepth 4 -maxdepth 4 -type f \
  -path 'cache/build/*/*/*.tests/*' >> results
tar -cf - -T results status >&3
