SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The examples of docs/reference.md hold on both backends: readme.sh
writes the files that the reference shows into one directory, runs the
commands of its console blocks and compares what they print. It prints
nothing when they agree.

  $ . ./backends.sh
  $ sh ./readme.sh clang "$clang" ../../docs/reference.md
  $ sh ./readme.sh gcc "$gcc" ../../docs/reference.md
