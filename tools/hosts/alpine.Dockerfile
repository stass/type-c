# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The Linux musl test host, x86-64 or arm64: Alpine 3.24 with its own GCC,
# Clang and Clang's sanitizer runtimes (compiler-rt), OCaml 5 with its
# compiler libraries (a separate package on Alpine, which
# test_small_stack needs for Config.architecture), dune, and make, which
# c_header.t runs. Cut's check.sh lists the UTF-8 locale with
# musl-locales' locale(1), and nested_patterns.t compares the output of
# diff in POSIX's default format, which BusyBox's diff does not write but
# GNU's (diffutils) does. The base image is pinned by the
# digest of its multi-platform index; the packages by version, the same
# on both platforms. Their own dependencies follow Alpine 3.24. A
# pinned version that leaves the archive fails the build until it is
# bumped here.

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache \
      gcc=15.2.0-r5 \
      clang22=22.1.3-r2 compiler-rt=22.1.3-r0 \
      musl-dev=1.2.6-r3 \
      musl-locales=0.1.0-r1 \
      ocaml5=5.4.1-r0 ocaml5-compiler-libs=5.4.1-r0 \
      dune=3.22.2-r1 \
      make=4.4.1-r4 \
      diffutils=3.12-r0

ENV TYPEC_TEST_CLANG=/usr/bin/clang TYPEC_TEST_GCC=/usr/bin/gcc

RUN adduser -D typec
USER typec
WORKDIR /home/typec
