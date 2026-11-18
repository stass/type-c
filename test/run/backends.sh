# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The backends that the cram tests run, sourced by each test that runs
# one. TYPEC_TEST_CLANG and TYPEC_TEST_GCC name them; unset, they are
# those of the macOS development host. A host that lacks a backend fails
# the tests that run it. TYPEC_TEST_REQUIRE_M32, when set and not empty,
# declares that the host must compile the C headers with -m32.
# TYPEC_TEST_ARM_GCC names the arm-none-eabi-gcc of the Arm tests,
# short_enums.t and c_header.t; unset, it is the one on the PATH.
# TYPEC_TEST_REQUIRE_ARM, when set and not empty, declares that the host
# has both Arm backends of those tests. TYPEC_TEST_REQUIRE_LLDB, when
# set and not empty, declares that lldb runs on the host for the
# examples of docs/tutorial.md that use it.

clang=${TYPEC_TEST_CLANG:-/usr/bin/clang}
gcc=${TYPEC_TEST_GCC:-/usr/local/bin/gcc-16}
arm_gcc=${TYPEC_TEST_ARM_GCC:-arm-none-eabi-gcc}

# The Arm backends of short_enums.t and c_header.t, each run where
# present: Clang where it has the target of a Cortex-M3, and arm_gcc.
arm_clang_target=--target=thumbv7m-none-eabi
arm_clang_present() {
  "$clang" $arm_clang_target -E -x c /dev/null > /dev/null 2>&1
}
arm_gcc_present() {
  command -v "$arm_gcc" > /dev/null 2>&1
}

# lldb_present CC: whether the lldb on the PATH stops a program that CC
# built with -g at the line of its trap, as the lldb examples of the
# tutorial need: lldb may be missing, may not read the debug information
# of CC, or the host may not let it debug. The directory is made in the
# current one, which runs programs where a temporary one may not. The
# subshell keeps the variables out of the tests.
lldb_present() (
  lldb_dir=$(mktemp -d ./lldb.XXXXXX) || return 1
  printf 'int main(void) { __builtin_trap(); }\n' > "$lldb_dir/probe.c"
  "$1" -g -o "$lldb_dir/probe" "$lldb_dir/probe.c" > /dev/null 2>&1 &&
    lldb --batch -o run "$lldb_dir/probe" < /dev/null 2>&1 |
    grep -q 'at probe\.c:1'
  lldb_status=$?
  rm -rf "$lldb_dir"
  return $lldb_status
)

# The configurations of the Arm backends present, one per line: a
# backend, its target option, the option of an enumeration
# representation and that of the other. Clang for thumbv7m-none-eabi
# defaults to int-sized enumerations and arm-none-eabi-gcc to short ones;
# each runs under both.
arm_configurations() {
  if arm_clang_present; then
    echo "$clang $arm_clang_target -fno-short-enums -fshort-enums"
    echo "$clang $arm_clang_target -fshort-enums -fno-short-enums"
  fi
  if arm_gcc_present; then
    echo "$arm_gcc -mcpu=cortex-m3 -fshort-enums -fno-short-enums"
    echo "$arm_gcc -mcpu=cortex-m3 -fno-short-enums -fshort-enums"
  fi
}

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

# Reports what the tests could not run on this host, and fails when the
# host declared that it has it. The subshell bodies keep the variables
# of the reports out of the tests.
backends_report() (
  report_status=0
  m32_report || report_status=1
  arm_report || report_status=1
  lldb_report || report_status=1
  return $report_status
)

# Prints a line when -m32 was dropped from hosted_second_target, and
# fails instead when TYPEC_TEST_REQUIRE_M32 is set.
m32_report() {
  case " $hosted_second_target " in
  *" -m32 "*) return 0 ;;
  esac
  if [ -n "${TYPEC_TEST_REQUIRE_M32:-}" ]; then
    echo "backends.sh: TYPEC_TEST_REQUIRE_M32 is set, but the backends" \
      "do not both compile <limits.h> with -m32 for x86-64" >&2
    return 1
  fi
  case " $second_target " in
  *" -m32 "*)
    echo "backends.sh: the backends do not both compile <limits.h>" \
      "with -m32; the tests that include the C headers run" \
      "$hosted_second_target instead"
    ;;
  esac
}

# Prints which Arm backends the Arm tests run and which they skip, so a
# host without them does not pass that test unnoticed, and fails when one
# is missing and TYPEC_TEST_REQUIRE_ARM is set.
arm_report() (
  arm_missing=
  if arm_clang_present; then
    echo "backends.sh: the Arm tests run $clang $arm_clang_target"
  else
    echo "backends.sh: the Arm tests skip $clang," \
      "which fails under $arm_clang_target"
    arm_missing=yes
  fi
  if arm_gcc_present; then
    echo "backends.sh: the Arm tests run $arm_gcc"
  else
    echo "backends.sh: the Arm tests skip $arm_gcc, which is not found;" \
      "TYPEC_TEST_ARM_GCC names it"
    arm_missing=yes
  fi
  if [ -n "$arm_missing" ] && [ -n "${TYPEC_TEST_REQUIRE_ARM:-}" ]; then
    echo "backends.sh: TYPEC_TEST_REQUIRE_ARM is set, but an Arm" \
      "backend of the Arm tests is missing" >&2
    return 1
  fi
)

# Prints whether the lldb examples of the tutorial run on this host or
# are skipped, and fails when they are skipped and
# TYPEC_TEST_REQUIRE_LLDB is set.
lldb_report() {
  if lldb_present "$clang" && lldb_present "$gcc"; then
    echo "backends.sh: the lldb examples of the tutorial run lldb"
    return 0
  fi
  echo "backends.sh: the lldb examples of the tutorial skip lldb," \
    "which is not found or does not debug the programs of both backends"
  if [ -n "${TYPEC_TEST_REQUIRE_LLDB:-}" ]; then
    echo "backends.sh: TYPEC_TEST_REQUIRE_LLDB is set, but lldb" \
      "does not run" >&2
    return 1
  fi
}

# compile_emitted CC FILE OPTION...: checks the preprocessed text in FILE
# with backend CC under the strictest user options and OPTION..., reading
# it as typec's compile step reads emitted C: as -x cpp-output (design
# 2.4). The step's -fno-trigraphs for Clang is left out, as no input of
# these tests holds a trigraph. The subshell keeps the variables out of
# the test.
compile_emitted() (
  emitted_cc=$1 emitted_file=$2
  shift 2
  "$emitted_cc" -Wall -Wextra -pedantic-errors -Werror "$@" -fsyntax-only \
    -x cpp-output "$emitted_file"
)
