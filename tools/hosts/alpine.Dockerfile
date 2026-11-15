# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The Linux musl test host, x86-64 or arm64: Alpine 3.24 with its own GCC,
# Clang, OCaml 5 and dune. The base image is pinned by the digest of its
# multi-platform index; the compilers, musl's headers, OCaml and dune by
# package version, the same on both platforms. Their own dependencies
# follow Alpine 3.24. A pinned version that leaves the archive fails the
# build until it is bumped here.

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

RUN apk add --no-cache \
      gcc=15.2.0-r5 \
      clang22=22.1.3-r2 \
      musl-dev=1.2.6-r3 \
      ocaml5=5.4.1-r0 dune=3.22.2-r1

# git, for the revisions that the corpus runner records, follows Alpine
# 3.24 as in the Debian host.
RUN apk add --no-cache git

ENV TYPEC_TEST_CLANG=/usr/bin/clang TYPEC_TEST_GCC=/usr/bin/gcc

RUN adduser -D typec
USER typec
WORKDIR /home/typec
