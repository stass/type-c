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
if echo "$clang_macros" | grep -q __x86_64__; then
  second_target="-m32 -funsigned-char"
elif echo "$clang_macros" | grep -q __CHAR_UNSIGNED__; then
  second_target="-fsigned-char"
else
  second_target="-funsigned-char"
fi
