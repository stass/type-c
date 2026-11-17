# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The Linux glibc test host, x86-64 or arm64: Debian 13 with its own GCC,
# a Clang from apt.llvm.org, the oldest that typec supports
# (Target.minimum_major_version), as Debian 13's own is older, and OCaml
# and dune from opam, since Debian 13's OCaml 5.3 lacks the Char.Ascii of
# 5.4 that tools/fuzz uses. The Clang comes with its sanitizer runtimes,
# as the tests of test/run link with -fsanitize. The base image is pinned by the digest of its
# multi-platform index; the compilers, the C library's and the kernel's
# headers, file (the own suite of the corpus's chibicc runs it), and ninja
# and CMake (the tests of the build rules run them), by package version,
# the same on both platforms; the key of
# apt.llvm.org by fingerprint; OCaml and dune by a commit of
# opam-repository. Their own dependencies follow Debian 13, and Clang's
# apt.llvm.org. A pinned version that leaves the archive fails the build
# until it is bumped here.

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc=4:14.2.0-1 gcc-14=14.2.0-19 \
      libc6-dev=2.41-12+deb13u4 linux-libc-dev=6.12.117-1 \
      file=1:5.46-5 ninja-build=1.12.1-1 cmake=3.31.6-2 \
      csmith=2.3.0-8 libcsmith-dev=2.3.0-8 m4=1.4.19-8 \
      opam=2.3.0-1+deb13u2 \
      ca-certificates curl gpg git make patch unzip bzip2 \
 && rm -rf /var/lib/apt/lists/*

# apt checks the repository against the key, and the key is the one
# whose fingerprint apt.llvm.org publishes, the only one in the file.
RUN fingerprint=6084F3CF814B57C1CF12EFD515CF4D18AF4F7421 \
 && llvm_version=1:21.1.8~++20251221033036+2078da43e25a-1~exp1~20251221153213.50 \
 && keyring=/usr/share/keyrings/apt.llvm.org.asc \
 && curl --fail --silent --show-error --location --proto '=https' \
      --output "$keyring" https://apt.llvm.org/llvm-snapshot.gpg.key \
 && keys=$(gpg --show-keys --with-colons "$keyring" \
      | awk -F: '$1 == "pub" { primary = 1; next } \
                 $1 == "fpr" && primary { print $10; primary = 0 }') \
 && test "$keys" = "$fingerprint" \
 && echo "deb [signed-by=$keyring]" \
      https://apt.llvm.org/trixie/ llvm-toolchain-trixie-21 main \
      > /etc/apt/sources.list.d/apt.llvm.org.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      clang-21="$llvm_version" libclang-rt-21-dev="$llvm_version" \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s clang-21 /usr/bin/clang

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
