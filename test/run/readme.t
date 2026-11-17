SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The examples of README.md, but those it marks untested, hold on both
backends: readme.sh writes the files that the README shows, runs the
commands of its console blocks and compares what they print, and the C
of its emit-c blocks, with what the README shows. It prints nothing
when they agree, and for a console block that the README marks for one
backend, it runs the block on that backend alone.

  $ . ./backends.sh
  $ sh ./readme.sh clang "$clang" ../../README.md
  $ sh ./readme.sh gcc "$gcc" ../../README.md
