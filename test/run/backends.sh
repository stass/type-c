# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The backends that the cram tests run, sourced by each test that runs
# one. TYPEC_TEST_CLANG and TYPEC_TEST_GCC name them; unset, they are
# those of the macOS development host. A host that lacks a backend fails
# the tests that run it.

clang=${TYPEC_TEST_CLANG:-/usr/bin/clang}
gcc=${TYPEC_TEST_GCC:-/usr/local/bin/gcc-16}
