# Clearcote arm64 (aarch64) Linux build

Build arm64 Chromium for Linux (the Pi and other ARM boxes) by **cross-compiling from an x64
host** — the prebuilt x64 clang Chromium ships is multi-target and compiles arm64 code, which is
exactly how Chromium produces arm64-Linux binaries. The arm64 target side is a one-line config
delta on the usual x64 Linux build; the host side is where the one real trap lives.

> ## ⚠️ BEWARE — the build host must be a native x86-64 machine
>
> Do **not** build arm64 Clearcote on an Apple Silicon Mac (or any arm64 host running the x64
> toolchain under emulation). During the build, **x64 host tools** — `mksnapshot` and the V8
> builtin generators — run and bake the V8 snapshot into the browser. Under **Rosetta 2** those
> tools compute a double-integrality check incorrectly (a mistranslated packed-SSE idiom), which
> silently floors constants: the shipped browser has `Math.PI === 3`, `Math.E === 2`,
> `Number.EPSILON === 0`, … It is a *silent* corruption — the binary is the right arch, has a
> stable sha256, and launches fine. Only **executing its JS math** reveals it.
>
> **Fix:** build where the x64 host tools run on a real x86-64 CPU — a native x86-64 Linux box
> (e.g. a GCP `n2`/`c2` VM). That is the only requirement that matters here; nothing about the
> arm64 target config changes. `scripts/fresh-arm64.sh` hard-fails unless `uname -m` is
> `x86_64`, and its final math gate re-proves the constants on the finished binary.

## How it builds

Same pipeline as the Linux x64 build, with two arm64-specific pieces:

1. **Config** — `config/args.linux-arm64.gn` (a copy of `config/args.linux.gn` with
   `target_cpu = "arm64"` and `target_sysroot = "//build/linux/debian_bullseye_arm64-sysroot"`).
   `use_sysroot=true` + `target_sysroot` scope the arm64 sysroot to the **target** toolchain only
   (GN is per-toolchain), so the arm64 `chrome` links against the arm64 bullseye sysroot while
   the x64 host tools keep the amd64 one.
2. **Two sysroots + a few host tools** — `02-host-toolchain.sh` installs the amd64 *host*
   sysroot; the arm64 *target* sysroot is installed separately (`install-sysroot.py --arch=arm64`).
   `esbuild`, `gperf`, and `mold` are host tools the tree expects (fetched/installed by the
   driver).

Everything else (fetch, patch, prebuilt x64 clang, `gn gen`, `ninja`, package) is shared with the
x64 build.

## Build on a GCP x86-64 VM (the recommended, unattended path)

`scripts/provision-gcp.sh` does the whole thing — provision a native x86-64 spot VM, build the
image natively, run the arm64 pipeline, then fetch the artifact and tear down:

```sh
export PROJECT=<your-gcp-project>
scripts/provision-gcp.sh provision     # creates the VM; it builds unattended for ~1-2 h (~$2-6 spot)
scripts/provision-gcp.sh status        # poll until the marker says OK
scripts/provision-gcp.sh fetch         # pulls dist/clearcote-<V>-linux-arm64.tar.xz + SHA256SUMS.txt
(cd dist && sha256sum -c SHA256SUMS.txt)
scripts/provision-gcp.sh teardown      # delete the VM — stops billing
```

Tune with `ZONE`, `MACHINE` (default `n2-standard-32` = 32 vCPU / 128 GB), `SPOT=0` for
on-demand, `DISK_GB`, `REPO_URL`/`REPO_BRANCH`.

## Build manually on any native x86-64 Linux box

```sh
git clone --branch arm64 https://github.com/ramicaza/clearcote-browser cc && cd cc
docker build -t clearcote-build-x64 .            # NO --platform: the host IS x86-64
docker volume create clearcote-work
docker run --rm \
  -v clearcote-work:/clearcote-build \
  -v "$PWD":/clearcote:ro \
  --entrypoint bash clearcote-build-x64 \
  /clearcote/scripts/fresh-arm64.sh
# -> /clearcote-build/dist/clearcote-<V>-linux-arm64.tar.xz
```

`scripts/fresh-arm64.sh` runs: fetch → patch (integrity gate) → x64 toolchain → arm64 sysroot →
esbuild/gperf/mold → `gn gen` → a **`--sysroot` wiring gate** (both toolchains present + a test
object compiles to aarch64, so a broken config aborts in minutes, not hours) → `ninja` (auto-
parallel) → `file chrome` = ARM aarch64 → **math gate** → `05-package.sh` (TARGET=linux,
ARCH=arm64).

## The math gate — the check that matters

The arch check (`file chrome` → `ARM aarch64`) and a sha256 sum prove **nothing** about the
snapshot. The driver therefore *executes* the finished arm64 binary (via `qemu-aarch64-static -L
<arm64-sysroot>`, or on real arm64 hardware such as the Pi) and asserts:

```
Math.PI === 3.141592653589793   →  true
Math.E  === 2.718281828459045   →  true
Math.LN10=== 2.302585092994046  →  true
Number.EPSILON === 2.220446049250313e-16 → true
```

All five must be `true`. If any is `false`, the snapshot is corrupt (a host-tool failure) —
**do not ship**; rebuild on a clean native-x86-64 host. If `qemu-user-static` is unavailable the
gate is skipped with a loud warning — in that case run it manually on arm64 hardware before
releasing.

## Files

- `config/args.linux-arm64.gn` — the arm64 cross config (target delta on the x64 Linux config)
- `scripts/fresh-arm64.sh` — the from-scratch arm64 pipeline (host-verified, gated)
- `scripts/provision-gcp.sh` — provision/run/fetch/teardown a GCP x86-64 VM
- `scripts/05-package.sh` — honors `ARCH` for the `-linux-arm64.tar.xz` asset name
- `Dockerfile` — base image (+ `wget` for the node fetcher, + `qemu-user-static` for the gate)
