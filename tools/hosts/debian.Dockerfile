# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The Linux x86-64 glibc test host: Debian 13 with its own GCC and Clang,
# and OCaml and dune from opam, since Debian 13's OCaml 5.3 lacks the
# Char.Ascii of 5.4 that tools/fuzz uses. The base image is pinned by
# digest; the compilers, the C library's and the kernel's headers by
# package version; OCaml and dune by a commit of opam-repository. Their
# own dependencies follow Debian 13. A pinned version that leaves the
# archive fails the build until it is bumped here.

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc=4:14.2.0-1 gcc-14=14.2.0-19 \
      clang=1:19.0-63 clang-19=1:19.1.7-3+b1 \
      libc6-dev=2.41-12+deb13u4 linux-libc-dev=6.12.117-1 \
      opam=2.3.0-1+deb13u2 \
      ca-certificates curl git make patch unzip bzip2 \
 && rm -rf /var/lib/apt/lists/*

ENV TYPEC_TEST_CLANG=/usr/bin/clang TYPEC_TEST_GCC=/usr/bin/gcc

RUN useradd --create-home typec
USER typec
WORKDIR /home/typec

ARG OPAM_REPOSITORY=git+https://github.com/ocaml/opam-repository.git#ca403de684b07caee6f246b36a2f3a1787d780ac
RUN opam init --bare --disable-sandboxing --no-setup --yes \
      default "$OPAM_REPOSITORY" \
 && opam switch create typec ocaml-base-compiler.5.4.1 --yes \
 && opam install --switch typec --yes dune.3.22.2 \
 && opam clean --all-switches --download-cache --repo-cache

ENV PATH=/home/typec/.opam/typec/bin:$PATH
