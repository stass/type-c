# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The Linux glibc test host, x86-64 or arm64: Debian 13 with GCC 16 from
# Debian testing as the test GCC, a Clang from apt.llvm.org, the oldest
# that typec supports (Target.minimum_major_version), as Debian 13's own
# is older, and OCaml and dune from opam, since Debian 13's OCaml 5.3
# lacks the Char.Ascii of 5.4 that tools/fuzz uses. The Clang comes with
# its sanitizer runtimes, as the tests of test/run link with
# -fsanitize. Besides the compilers the image has the C library's and
# the kernel's headers, file (the own suite of the corpus's chibicc runs
# it), and ninja and CMake (the tests of the build rules run them).
#
# The base image is pinned by the digest of its multi-platform index;
# every Debian package, with its dependencies, by one timestamp of
# snapshot.debian.org (SNAPSHOT below), which apt reads instead of the
# live archive, so that a package that the archive has since replaced
# still installs; Clang by package version and the key of apt.llvm.org
# by fingerprint; OCaml and dune by a commit of opam-repository. A
# package version is not pinned by name, as it can differ between the
# platforms: a binNMU rebuilds a package for one architecture under a
# new version (ninja-build is 1.12.1-1 on amd64 and 1.12.1-1+b1 on
# arm64). A snapshot's Release file expires a week after its date,
# hence Check-Valid-Until no; its signature is still checked against
# the archive key. That proves the packages are Debian's but not which
# snapshot they come from, so plain HTTP is used only where the slim
# base image has no CA bundle yet, for the first install.
#
# Debian 13 stops at GCC 14, so GCC 16 comes from Debian testing (forky),
# from which apt takes gcc-16 and the newer runtime libraries of GCC that
# it depends on, and nothing else. The suite runs with it as the test GCC
# (TYPEC_TEST_GCC below); the image's own GCC 14 is installed but not
# tested, and Clang takes its crt files and libgcc from the newest GCC
# installation, so from GCC 16.

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG SNAPSHOT=20261110T000000Z

RUN printf '%s\n' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian/$SNAPSHOT/" \
      'Suites: trixie trixie-updates' \
      'Components: main' \
      'Check-Valid-Until: no' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      '' \
      'Types: deb' \
      "URIs: http://snapshot.debian.org/archive/debian-security/$SNAPSHOT/" \
      'Suites: trixie-security' \
      'Components: main' \
      'Check-Valid-Until: no' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      > /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc gcc-14 libc6-dev linux-libc-dev file ninja-build cmake \
      csmith libcsmith-dev m4 opam \
      ca-certificates curl gpg git make patch unzip bzip2 \
 && rm -rf /var/lib/apt/lists/*

# GCC 16 from Debian testing at the same timestamp. The C library stays
# on hold, so that a gcc-16 that needs a newer one fails the build
# instead of moving the host to testing's glibc. The source is removed
# again, so that no later install takes anything from it.
RUN printf '%s\n' \
      'Types: deb' \
      "URIs: https://snapshot.debian.org/archive/debian/$SNAPSHOT/" \
      'Suites: forky' \
      'Components: main' \
      'Check-Valid-Until: no' \
      'Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp' \
      > /etc/apt/sources.list.d/forky.sources \
 && apt-mark hold libc6 libc6-dev linux-libc-dev \
 && apt-get update \
 && apt-get install -y --no-install-recommends -t forky gcc-16 \
 && rm /etc/apt/sources.list.d/forky.sources \
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

ENV TYPEC_TEST_CLANG=/usr/bin/clang TYPEC_TEST_GCC=/usr/bin/gcc-16

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
