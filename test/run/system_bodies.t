SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Only a function body whose `{` is C text of a system header is passed
through unread (design 13.3). An interface found through -isystem is
Type-C text, read and lowered as any other: the match of its inline
function runs on each backend.

  $ . ./backends.sh

  $ mkdir system
  $ cat > system/values.tci <<'EOF'
  > type value = | None | Some(int i);
  > static inline int unwrap(value v) {
  >   match (v) { case Some(i): return i; default: return 0; }
  > }
  > EOF
  $ cat > main.tc <<'EOF'
  > #include <values.tci>
  > int main(void) { return unwrap(Some(3)) == 3 && unwrap(None) == 0 ? 0 : 1; }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -isystem system main.tc -o main && ./main ||
  >     echo "failed with $cc"
  > done
