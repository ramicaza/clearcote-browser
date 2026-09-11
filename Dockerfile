# Clearcote — reproducible build environment.
#
# A pinned Ubuntu image with the base tools the build scripts need. It fetches the exact pinned
# Chromium source, applies the same patch series, installs Chromium's own build deps + toolchain,
# and compiles the browser — for Windows x64 (cross), Linux x64 (native), or Linux arm64
# (cross from a native x86-64 host) — producing the same distributable archive as the published
# release, which you verify against SHA256SUMS.txt.
#
#   # build the image once (the build ENVIRONMENT, not the browser)
#   docker build -t clearcote-build .
#
#   # then build a target (multi-hour; needs ~16 GB+ RAM, ~120 GB disk). Artifacts land in ./out:
#   docker run --rm -v "$PWD/out:/clearcote-build/dist" clearcote-build linux
#   docker run --rm -v "$PWD/out:/clearcote-build/dist" clearcote-build windows
#
#   # arm64 cross-compile MUST run on a NATIVE x86-64 host (never --platform emulation — see
#   # docs/BUILD-ARM64.md: host tools under Rosetta corrupt the V8 snapshot):
#   docker run --rm -v clearcote-work:/clearcote-build -v "$PWD":/clearcote:ro \
#     --entrypoint bash clearcote-build /clearcote/scripts/fresh-arm64.sh
#
#   # verify (see docs/VERIFY.md):
#   sha256sum -c out/clearcote-149.0.7827.114-linux-x64.tar.xz.sha256
#
# For byte-for-byte reproducibility pin the base image to a digest (see docs/BUILDING.md).
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# Base tools the numbered build scripts need. Chromium's own (large) build dependencies are
# installed at RUN time by scripts/02-host-toolchain.sh (install-build-deps.py), because they
# need the source tree that scripts/00 fetches first. ciopfs = case-insensitive overlay for the
# Windows SDK headers; xz-utils = unpack the Linux .tar.xz; wget = third_party/node/
# update_node_binaries hard-codes wget; qemu-user-static = the arm64 math-correctness gate in
# scripts/fresh-arm64.sh executes the produced aarch64 binary here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 python3-pip curl ca-certificates \
      wget ninja-build zip unzip xz-utils ciopfs patch binutils \
      sudo lsb-release file pkg-config qemu-user-static \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /clearcote
COPY . /clearcote

# The build scripts write everything (source tree, toolchains, dist) under $WORK.
ENV WORK=/clearcote-build

ENTRYPOINT ["/clearcote/build.sh"]
CMD ["windows"]
