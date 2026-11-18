SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The examples of docs/tutorial.md hold on both backends: readme.sh
writes the files that the tutorial shows, one directory for each stage
of its program, runs the commands of its console blocks and compares
what they print, and the C of its emit-c blocks, with what the tutorial
shows. It prints nothing when they agree. Its lldb blocks run where
lldb debugs the programs of the backend, and backends_report says
whether they do.

  $ . ./backends.sh
  $ sh ./readme.sh clang "$clang" ../../docs/tutorial.md
  $ sh ./readme.sh gcc "$gcc" ../../docs/tutorial.md
