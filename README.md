# HAOS GPU-AI Universal

A Buildroot **external-tree** overlay that turns Home Assistant OS into a
bare-metal, tri-vendor GPU host for local LLM/AI add-ons. A single unified
x86-64 image ships driver support for **NVIDIA + Intel + AMD**; the correct
stack is activated at boot from the PCI bus. Upstream HAOS releases are tracked
daily and rebuilt into signed, decoupled OTA bundles.

The submodule under `upstream/` is **never modified** — everything is injected
through this external tree, the rootfs overlay, patches, and a merged defconfig.

> **New here? Follow [`SETUP.md`](SETUP.md)** for the exact step-by-step: build
> the OS locally (Phase 1), then wire up GitHub CI + Releases + OTA (Phase 2).

---

## The core architecture decision (read this first)

This preserves HAOS's read-only, atomic appliance model by putting the right
things in the right layer:

| Layer | Responsibility |
|-------|----------------|
| **Host OS (this repo)** | Kernel drivers, firmware, `/dev` nodes, and — for NVIDIA only — the driver's user-space libs + the Container Toolkit injection layer |
| **Add-on container** | The heavy compute *runtime*: CUDA runtime, ROCm/HIP, oneAPI/Level-Zero/NEO |

That split is what makes a universal image feasible. Compiling CUDA, ROCm, and
Intel's NEO/IGC into an immutable OS is impractical (much of it won't
cross-compile in Buildroot) and would defeat the appliance model you're
preserving. So:

- **NVIDIA** is the one vendor needing host user space: its proprietary driver
  libs (`libcuda`, `libnvidia-ml`, `libnvidia-ptxjitcompiler`) plus the NVIDIA
  Container Toolkit, which *injects* those host libs into containers at runtime.
- **Intel & AMD** use open kernel drivers and standard kernel interfaces
  (`/dev/dri`, `/dev/kfd`). Their packages are deliberately kernel + firmware +
  udev coordinators. The runtime (ROCm image, oneAPI image) lives in the add-on.

---

## Design corrections vs. a literal reading of the spec

Several details in the original brief would break the build or the
universal-image goal. What this repo actually does, and why:

1. **`CONFIG_STAGING` is not the mechanism for out-of-tree modules.** It only
   enables the in-tree `drivers/staging` subsystem. Out-of-tree NVIDIA modules
   need `CONFIG_MODULES` + a configured kernel tree. The real *unified-memory*
   kernel dependencies are `HMM_MIRROR` / `ZONE_DEVICE` / `DEVICE_PRIVATE`
   (+ `HSA_AMD_SVM` for AMD) — all set in `external/kernel/gpu-ai.config`.

2. **`libnvrtc`/`libcudart` are CUDA *toolkit* libraries, not driver libraries.**
   They are not in the driver `.run`; they ship in the container. The host
   installs only what the driver payload provides.

3. **`default-runtime: nvidia` breaks non-NVIDIA hosts.** It forces every
   container through the NVIDIA hook, which fails when there's no NVIDIA GPU. So
   the shipped `daemon.json` keeps `runc` as default and `gpu-autodetect`
   promotes NVIDIA to default-runtime **only when an NVIDIA GPU is detected**.

4. **The version suffix is cosmetic.** `-gpu-ai-universal` only discourages the
   frontend from offering a stock update. The *hard* guards against a stock
   image overwriting this branch are the custom RAUC **`compatible` string**
   (`haos-generic-x86-64-gpu-ai`, rejected pre-signature) **and our own
   keyring**. Both are configured.

5. **HA add-ons can't request `--gpus`/`--runtime`.** The working patterns are
   (a) NVIDIA via the conditional default-runtime, and (b) Intel/AMD via device
   mapping. For a *universal* add-on, naming `/dev/nvidia0` in `devices:` would
   fail to start on Intel/AMD, so the sample add-on uses `full_access: true`
   (trade-off documented in `addon-ollama/config.yaml`).

6. **NVIDIA *open* kernel modules** are used (vendor-recommended for Turing+ and
   the only variant that builds on recent kernels). RTX 40-series is fully
   supported.

---

## Repository layout

```
haos-gpu-ai/
├── upstream/                         # submodule: home-assistant/operating-system (PRISTINE)
├── external/                         # our BR2_EXTERNAL tree (name: HAOS_GPU_AI)
│   ├── external.desc                 # -> $(BR2_EXTERNAL_HAOS_GPU_AI_PATH)
│   ├── external.mk                   # wildcard-includes package/*/*.mk
│   ├── Config.in                     # BR2_PACKAGE_HAOS_GPU_AI_ALL selects all 3 vendors
│   ├── configs/
│   │   └── gpu_ai.fragment           # additive defconfig symbols
│   ├── kernel/
│   │   └── gpu-ai.config             # unified kernel fragment (DRM/i915/xe/amdgpu/HMM…)
│   ├── package/
│   │   ├── haos-compute-nvidia/      # open kernel modules + driver libs
│   │   ├── haos-nvidia-container-toolkit/  # runtime hook
│   │   ├── haos-compute-intel/       # kernel+firmware contract (+NOTES.md)
│   │   └── haos-compute-amd/         # kernel+firmware contract (+NOTES.md)
│   ├── rootfs-overlay/
│   │   └── etc/{modprobe.d,udev,docker,rauc}/…  + usr/bin + systemd units
│   ├── patches/                      # BR2_GLOBAL_PATCH_DIR
│   └── scripts/                      # merge-defconfig, build, post-build, generate-ca
├── ota/version-gpu-ai.json           # custom OTA channel manifest
├── addon-ollama/                     # sample GPU-accelerated add-on
└── .github/workflows/build-and-track.yml
```

---

## How the pieces fit

- **`external/Config.in`** — `BR2_PACKAGE_HAOS_GPU_AI_ALL=y` force-`select`s the
  three vendor packages so one image contains all stacks.
- **`scripts/merge-defconfig.sh`** — copies the upstream `generic_x86_64_defconfig`
  into *our* tree's `configs/` and **appends in place** to the space-separated
  multi-value vars (`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`, `BR2_ROOTFS_OVERLAY`,
  `BR2_GLOBAL_PATCH_DIR`, `BR2_ROOTFS_POST_BUILD_SCRIPT`) so upstream values are
  preserved, then adds the additive fragment.
- **`scripts/build.sh`** — chains both external trees
  (`BR2_EXTERNAL=<upstream>/buildroot-external:<ours>`), exports
  `ota_compatible`, and runs Buildroot.
- **`gpu-autodetect.service`** (before `docker.service`) — loads the matching
  vendor modules and writes the conditional `daemon.json`.
- **`haos-gpu-updater.timer`** — daily, pulls our signed `.raucb` from our
  GitHub Releases and `rauc install`s it, bypassing the Supervisor updater.

---

## Build

```bash
git clone --recurse-submodules https://github.com/your-org/haos-gpu-ai.git
cd haos-gpu-ai

# one-time: create the signing CA
./external/scripts/generate-ca.sh ./pki      # cert.pem public, key.pem secret

# build (inside the HAOS builder container; see the workflow for the CI form)
cp pki/cert.pem cert.pem && cp pki/key.pem key.pem
./external/scripts/build.sh
# -> output/images/*.raucb  and  output/images/haos_*.img.xz
```

## Getting to a green build

Out-of-tree GPU drivers rarely build clean on the first try, so converge in two
stages using the build profile and the preflight gate.

**Stage 1 - NVIDIA + AMD, smallest surface:**

```bash
PROFILE=nvidia-amd ./external/scripts/build.sh
```

This drops the Intel package and, critically, the `CONFIG_DRM_XE` kernel symbol
(the most kernel-version-fragile part of the fragment). What's left is the
proprietary NVIDIA out-of-tree build plus in-tree `amdgpu`/`i915` - the pieces
most likely to succeed. Since you've already boot-verified an NVIDIA-only
branch, the NVIDIA package here should be close to known-good.

**The preflight gate runs first and fails fast** (seconds, not minutes) on:
- kernel vs. NVIDIA driver-branch mismatch (bump the pin or the matrix in
  `preflight-check.sh` - e.g. a 6.12 HAOS kernel wants driver branch 560/565,
  not 550);
- a typo'd driver/toolkit version (asset unreachable);
- asking for Xe on a kernel too old to have it.

```bash
# run the gate on its own without building
./external/scripts/preflight-check.sh nvidia-amd
```

**Stage 2 - add Intel + Xe once Stage 1 is green:**

```bash
PROFILE=all ./external/scripts/build.sh      # (this is the default)
```

If the Xe build errors that `CONFIG_DRM_XE` is unknown for your pinned kernel,
either stay on `nvidia-amd` or delete the two `DRM_XE` lines from
`external/kernel/gpu-ai.config` - i915 still provides `/dev/dri` for Intel.

In CI, choose the profile from the **Run workflow** dropdown; the scheduled
nightly build always uses `all`. The gate runs there too (`STRICT=1`) so a bad
pin fails the job before the builder container is even pulled.

## Flash a fresh install

```bash
xz -dc output/images/haos_generic-x86-64-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

## Update an existing GPU-AI install

- **Automatic:** the daily timer installs new releases from your fork.
- **Manual:** `rauc install haos_generic-x86-64-<ver>.raucb && reboot`

## GPU-accelerated add-on

Copy `addon-ollama/` into a local add-on repo, install it from the HA add-on
store, start it, and check the log for the detected GPU. It serves the Ollama
API on `:11434`.

---

## Honest caveats

This is a **correct, production-oriented scaffold**, not a guaranteed
first-try build. The parts inherent to out-of-tree GPU work that will need
version-pinning iteration against your specific HAOS kernel:

- **NVIDIA module build flags** vs. the exact pinned kernel (the open-modules
  `make` invocation is right in shape; specific flags can shift by kernel).
- **NVIDIA Container Toolkit asset name** — verify the release artifact name for
  the version you pin (flagged in the `.mk`).
- **`ota_compatible` env var name** and **`rauc.sh` cert path** — confirm both
  against your pinned `upstream/buildroot-external/` (the RAUC key location has
  moved between HAOS versions; the CI writes it to two places to be safe).
- **`CONFIG_DRM_XE`** availability depends on the pinned kernel; drop it if the
  build reports it unknown (i915 still provides `/dev/dri`).
- **CI runner limits** — a full HAOS build is disk/time-heavy; a larger or
  self-hosted runner is strongly advised.

The structure, the layering, the RAUC/OTA safety model, and the host/container
split are the durable parts; the vendor packages are where you'll iterate.
