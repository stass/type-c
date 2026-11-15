# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The backends that the cram tests run, sourced by each test that runs
# one. TYPEC_TEST_CLANG and TYPEC_TEST_GCC name them; unset, they are
# those of the macOS development host. A host that lacks a backend fails
# the tests that run it.

clang=${TYPEC_TEST_CLANG:-/usr/bin/clang}
gcc=${TYPEC_TEST_GCC:-/usr/local/bin/gcc-16}

# The flags of a second target, for the tests that check two: -m32 where
# the backend targets x86-64; elsewhere, which has no 32-bit target to
# rely on, the other signedness of plain char.
clang_macros=$("$clang" -dM -E -x c /dev/null)
if echo "$clang_macros" | grep -q __CHAR_UNSIGNED__; then
  other_char=-fsigned-char
else
  other_char=-funsigned-char
fi
if echo "$clang_macros" | grep -q __x86_64__; then
  second_target="-m32 $other_char"
else
  second_target=$other_char
fi

# Whether both backends compile <limits.h> with the flags given and find
# in it the ULONG_MAX of the target: a host may have no C headers for a
# target, or only those of another, as musl's of x86-64 under -m32.
backends_fit() {
  for fit_cc in "$clang" "$gcc"; do
    printf '%s\n' '#include <limits.h>' \
      '_Static_assert((unsigned long)-1 == ULONG_MAX, "ULONG_MAX");' |
      "$fit_cc" "$@" -fsyntax-only -x c - 2>/dev/null || return 1
  done
}

# The second target of the tests that include the C headers of the
# host: second_target where the host has them, else the other signedness
# of plain char.
if backends_fit $second_target; then
  hosted_second_target=$second_target
else
  hosted_second_target=$other_char
fi
unset -f backends_fit
unset fit_cc other_char
