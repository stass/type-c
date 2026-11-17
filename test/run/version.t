SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec --version runs the backend with --version alone, passes on its
output, then prints typec and the release that dune-project names, so a
build tool that reads the output sees the backend. The status is the
backend's.

  $ unset TYPEC_CC
  $ . ./backends.sh
  $ release=$(sed -n 's/^(version \(.*\))$/\1/p' ../../dune-project)
  $ echo "$release" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'

  $ for cc in "$clang" "$gcc"; do
  >   "$cc" --version > expected && echo "typec $release" >> expected &&
  >   typec --cc="$cc" --version > printed && diff expected printed
  > done

TYPEC_CC chooses the backend as for a compile. The rest of the command
line does not reach the backend, and nothing is compiled.

  $ "$gcc" --version > expected && echo "typec $release" >> expected
  $ TYPEC_CC="$gcc" typec --version -E x.tc > printed
  $ diff expected printed

A reader that stops at the backend's first line gets it, and typec
succeeds although its own line finds the pipe closed.

  $ set -o pipefail
  $ typec --cc="$gcc" --version | head -1 > first
  $ set +o pipefail
  $ head -1 expected | diff - first

A backend that cannot be started or fails is named, typec's line still
follows, and the status is the backend's, or 81 when it cannot be
started; a backend ended by a signal ends typec by it, here by SIGPIPE,
which the shell does not announce.

  $ typec --cc=./no-such-cc --version > printed
  typec: cannot run the C compiler "./no-such-cc": No such file or directory
  [81]
  $ test "$(cat printed)" = "typec $release"

  $ printf '#!/bin/sh\nexit 3\n' > exits-3 && chmod +x exits-3
  $ typec --cc=./exits-3 --version > printed
  typec: the C compiler "./exits-3" failed to print its version
  [3]
  $ test "$(cat printed)" = "typec $release"

  $ printf '#!/bin/sh\nkill -PIPE $$\n' > killed && chmod +x killed
  $ typec --cc=./killed --version > printed
  [141]
  $ test "$(cat printed)" = "typec $release"

An error in one of typec's own options is still one.

  $ typec --version --cc=
  typec: --cc= needs the path of a C compiler
  [81]
