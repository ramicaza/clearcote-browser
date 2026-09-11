#!/usr/bin/env bash
# fresh-arm64 — build the arm64 (aarch64) Linux Clearcote from a CLEAN machine.
#
# This is the full, from-scratch pipeline: fetch -> patch (integrity gate) -> x64 host
# toolchain -> arm64 TARGET sysroot -> esbuild/gperf/mold -> gn gen -> GATE (per-toolchain
# --sysroot wiring + compile test) -> ninja chrome -> aarch64 check -> MATH CORRECTNESS GATE.
#
# WHY THIS EXISTS (read docs/BUILD-ARM64.md, "BEWARE — native x86-64 host", first):
#   Building the arm64 target from an x64 toolchain is correct ONLY when the x64 HOST TOOLS
#   (mksnapshot, builtin generators, gn) execute on a REAL x86-64 CPU. Under Rosetta 2 on an
#   Apple Silicon Mac they mistranslate a clang -O2 packed-SSE idiom in V8's IsSmiDouble and
#   bake floored constants (Math.PI -> 3) into the V8 snapshot that ships inside the binary.
#   The corruption is silent: the arch is right, the sha256 is stable, the browser runs — and
#   Math.PI === 3 on the target hardware. So:
#     * run this on a NATIVE x86-64 Linux host (e.g. a GCP n2 VM), inside the x64 build image
#       built WITHOUT --platform emulation, and
#     * the math gate below executes the produced arm64 binary (via qemu-user) and asserts the
#       V8 constants — the only check that catches the Rosetta failure mode.
#
#   This is the recipe for a machine with NOTHING (a fresh clone + empty volume) — which is
#   where every one of the gaps below actually bites. A reused pre-patched volume can skip the
#   fetch/patch stage, but the rest is the same.
#
# How to run (native x86-64 host, e.g. a spot n2-standard-32 VM, ~1-2h, ~$2-6):
#   git clone --branch arm64 https://github.com/ramicaza/clearcote-browser cc
#   cd cc && docker build -t clearcote-build-x64 .        # NO --platform: host is x86-64
#   docker volume create clearcote-work
#   docker run --rm -v clearcote-work:/clearcote-build \
#     -v "$PWD":/clearcote:ro --entrypoint bash clearcote-build-x64 \
#     /clearcote/scripts/fresh-arm64.sh
#   # artifact: /clearcote-build/dist/clearcote-<V>-linux-arm64.tar.xz
#   docker run --rm -v clearcote-work:/clearcote-build -v "$PWD/dist:/out" ... \
#     # or just: docker cp <ctr>:/clearcote-build/dist .
#
# Gaps this closes (each was hit in the wild on a fresh VM, 2026-09):
#   1. 02 only installs the amd64 HOST sysroot — the arm64 TARGET sysroot needs its own
#      install-sysroot.py --arch=arm64 (the target_sysroot in config/args.linux-arm64.gn points at it).
#   2. esbuild is NOT fetched by any numbered stage (a fresh VM has none).
#      The version is read from the tree's devtools-frontend package.json.
#   3. third_party/node/update_node_binaries uses wget — it must be in the image (the
#      Dockerfile installs it) or in $WORK for resume runs.
#   4. gperf + mold must be symlinked into the cipd/bin paths the build expects.
#   5. TARGET/ARCH must NOT be in the environment of the ninja invocation: Chromium's
#      Rust bindgen generator aborts with "saw TARGET in environment". They are therefore
#      scoped per-stage below, never exported for the whole script.
#   6. The sysroot gate asserts BOTH toolchains (arm64 target AND amd64 host) got --sysroot
#      and compiles a test object, aborting in minutes instead of hours on a broken config.
#   7. The math gate (qemu-user) executes the arm64 binary and asserts V8 constants.
#
#   WORK  working dir (default: /clearcote-build when run in the docker image)
#   NINJA_JOBS  parallelism (default: nproc; the link is the RAM spike — 32 GB+ recommended)
set -euo pipefail
export WORK="${WORK:-/clearcote-build}"
SRC=$WORK/build/src
REPO="${REPO:-/clearcote}"
OUT="$SRC/out/Default"
JOBS="${NINJA_JOBS:-$(nproc)}"

log(){ echo "##### $1 @ $(date -u +%H:%M:%S)" ; }
fail(){ echo "##### FATAL: $1" >&2; exit 1; }

# Host must be real x86-64 — this is the entire point of the recipe (see docs/BUILD-ARM64.md).
[ "$(uname -m)" = "x86_64" ] || fail "host is $(uname -m), not x86_64. arm64 Chrome built by
host tools running under emulation (Rosetta/QEMU-x64) can ship corrupt V8 snapshots. Build on a
native x86-64 Linux machine."

command -v wget >/dev/null || fail "wget missing — rebuild the image from the arm64 branch Dockerfile (gap #3)"

log "STAGE A: fetch source + apply patches (TARGET=linux; integrity gate runs inside 01)"
( export TARGET=linux ; bash "$REPO/scripts/00-fetch-source.sh" )
( export TARGET=linux ; bash "$REPO/scripts/01-apply-patches.sh" )

log "STAGE B: host toolchain (prebuilt x64 clang + rust + amd64 host sysroot + node + gn)"
bash "$REPO/scripts/02-host-toolchain.sh"

log "STAGE B2: arm64 TARGET sysroot (gap #1 — 02 only installs the amd64 host sysroot)"
( cd "$SRC" && python3 build/linux/sysroot_scripts/install-sysroot.py --arch=arm64 )
[ -d "$SRC/build/linux/debian_bullseye_arm64-sysroot" ] || fail "arm64 sysroot dir missing"

log "STAGE B3: extra host tools (gaps #2/#4 — esbuild, gperf, mold)"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends gperf mold >/dev/null 2>&1 || true
mkdir -p "$SRC/third_party/gperf/cipd/bin" "$SRC/third_party/mold/cipd/bin"
[ -f "$SRC/third_party/gperf/cipd/bin/gperf" ] || ln -sf "$(which gperf)" "$SRC/third_party/gperf/cipd/bin/gperf"
[ -f "$SRC/third_party/mold/cipd/bin/mold" ]  || ln -sf "$(which mold)"  "$SRC/third_party/mold/cipd/bin/mold"
ES_DIR="$SRC/third_party/devtools-frontend/src/third_party/esbuild"
if [ ! -f "$ES_DIR/esbuild" ]; then
  EB_VER=$(python3 -c "import json;print(json.load(open('$ES_DIR/package.json'))['version'])" 2>/dev/null || echo 0.25.1)
  echo "  fetching @esbuild/linux-x64 $EB_VER (gap #2)"
  curl -fsSL "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${EB_VER}.tgz" -o /tmp/eb.tgz
  tar -xzf /tmp/eb.tgz -C /tmp/ package/bin/esbuild
  install -m 0755 /tmp/package/bin/esbuild "$ES_DIR/esbuild"
fi
echo "  esbuild: $(file -b "$ES_DIR/esbuild" | cut -c1-60)"

log "STAGE C: configure (gn gen) with the arm64 cross config from the repo"
# gap #5: TARGET is scoped to the stages that need it, never in the ninja/bindgen environment.
( cd "$SRC"
  export PATH="$SRC/third_party/llvm-build/Release+Asserts/bin:$PATH"
  mkdir -p out/Default
  cp "$REPO/config/args.linux-arm64.gn" out/Default/args.gn
  grep -q 'target_cpu = "arm64"' out/Default/args.gn || fail "config/args.linux-arm64.gn not arm64 — build image from the arm64 branch"
  grep -q 'target_sysroot'      out/Default/args.gn || fail "config/args.linux-arm64.gn lacks target_sysroot"
  "$WORK/bin/gn" gen out/Default
)

log "STAGE C-gate: per-toolchain --sysroot wiring (gap #6 — abort in minutes, not hours)"
cd "$OUT"
# Chromium splits ninja per-toolchain; flags live in sub-files under $OUT. Grep from $OUT cwd
# (grep from $SRC times out on the 40 GB tree).
ARM64_SR=$(grep -rhoE -- '--sysroot=[^"]*' . --include="*.ninja" 2>/dev/null | grep -c "arm64-sysroot" || true)
AMD64_SR=$(grep -rhoE -- '--sysroot=[^"]*' . --include="*.ninja" 2>/dev/null | grep -c "amd64-sysroot" || true)
echo "  arm64-sysroot flags: $ARM64_SR   amd64-sysroot flags: $AMD64_SR"
[ "${ARM64_SR:-0}" -ge 1 ] || fail "no arm64 --sysroot in the ninja graph"
[ "${AMD64_SR:-0}" -ge 1 ] || fail "no amd64 --sysroot in the ninja graph (host toolchain misconfigured)"
rm -f obj/base/simdutf_shim/simdutf_shim.o
CMD=$(ninja -t commands obj/base/simdutf_shim/simdutf_shim.o 2>/dev/null | head -1)
if [ -n "$CMD" ]; then
  bash -c "$CMD" >/tmp/tc.log 2>&1 \
    && echo "  compile-test rc=0 -> $(file -b obj/base/simdutf_shim/simdutf_shim.o | cut -c1-60)" \
    || { echo "  compile-test failed:"; tail -20 /tmp/tc.log; fail "test object did not compile"; }
fi
echo "  GATE PASS — arm64 target + amd64 host sysroots wired"

log "STAGE C-build: ninja -j$JOBS chrome chrome_sandbox chrome_crashpad_handler (the multi-hour step)"
cd "$SRC"
ninja -j"$JOBS" -C out/Default chrome chrome_sandbox chrome_crashpad_handler

log "VERIFY 1: produced binary is ARM aarch64"
file out/Default/chrome
file out/Default/chrome | grep -q "ARM aarch64" || fail "chrome is not ARM aarch64"
echo "  OK aarch64, size=$(du -sh out/Default/chrome | cut -f1)"

log "VERIFY 2: MATH CORRECTNESS GATE (the Rosetta check — executes the binary via qemu-user)"
# The arch check above proves nothing about the V8 snapshot: a Rosetta-built binary is the
# right arch, a stable sha256, launches fine — and has Math.PI === 3. Execute it instead.
HAVE_QEMU=0
if command -v qemu-aarch64-static >/dev/null 2>&1; then
  HAVE_QEMU=1
elif apt-get install -y --no-install-recommends qemu-user-static >/dev/null 2>&1 \
  && command -v qemu-aarch64-static >/dev/null 2>&1; then
  echo "  installed qemu-user-static"
  HAVE_QEMU=1
else
  echo "  WARN: qemu-aarch64-static unavailable — MATH GATE SKIPPED."
  echo "        Install it (apt-get install qemu-user-static) and re-run, or run the gate"
  echo "        manually on real arm64 hardware (the Pi) before shipping."
fi
if [ "$HAVE_QEMU" = 1 ]; then
  SYSROOT="$SRC/build/linux/debian_bullseye_arm64-sysroot"
  MATH_PAGE=/tmp/clearcote-math.html
  cat > "$MATH_PAGE" <<'EOF'
<script>document.write([
  Math.PI===3.141592653589793,
  Math.E===2.718281828459045,
  Math.LN10===2.302585092994046,
  Number.EPSILON===2.220446049250313e-16,
  (0.5===0.5)
].join(","));</script>
EOF
  ( cd "$OUT" && timeout 180 qemu-aarch64-static -L "$SYSROOT" ./chrome \
      --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
      --no-first-run --user-data-dir=/tmp/clearcote-math-vt \
      --dump-dom "file://$MATH_PAGE" 2>/dev/null ) > /tmp/clearcote-math-out.html || true
  RESULT=$(tr -d '[:space:]' < /tmp/clearcote-math-out.html | grep -oE 'true+|false[^<]*' | head -1)
  echo "  math gate result: ${RESULT:-<empty>}"
  [ "$RESULT" = "true,true,true,true,true" ] || fail "V8 constants WRONG (expect 5x true) —
snapshot is corrupt (host-tool failure); do NOT ship. See docs/BUILD-ARM64.md"
  echo "  MATH GATE PASS — V8 constants correct"
fi

log "STAGE D: package (TARGET=linux ARCH=arm64)"
( export TARGET=linux ARCH=arm64 ; bash "$REPO/scripts/05-package.sh" )

log "FRESH ARM64 PIPELINE COMPLETE — artifact in $WORK/dist/"
ls -la "$WORK/dist"/clearcote-*-linux-arm64.tar.xz* 2>/dev/null || true
