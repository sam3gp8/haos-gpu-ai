# Setup & Build Guide — HAOS GPU-AI Universal

Two phases. **Phase 1** builds and flashes the first image on your workstation.
**Phase 2** puts the repo on GitHub so CI tracks upstream nightly and the device
self-updates. After Phase 1 you have a booting GPU image; after Phase 2 updates
are automatic. The first image is always a manual flash — OTA takes over after.

## Prerequisites (build host)
- x86_64 Linux with **Docker**, `git`, `xz`.
- **~80 GB free disk** and **16 GB+ RAM** — a full HAOS build is heavy.
- You do NOT need Buildroot's dependencies on the host: the build runs inside
  HAOS's own builder container. You only need Docker.

---

## Phase 1 — Build the OS

### 1. Put the tree in a git repo and add the upstream submodule
```bash
cd haos-gpu-ai                       # the delivered tree
git init
git add -A && git commit -m "HAOS GPU-AI external tree"

# add the HAOS submodule (this is what .gitmodules describes)
git submodule add -b dev https://github.com/home-assistant/operating-system.git upstream
git -C upstream submodule update --init --recursive
```

### 2. Pin the HAOS release you want to build
Pick a tag from https://github.com/home-assistant/operating-system/releases.
```bash
HAOS_TAG=14.2                         # example — use a real current tag
git -C upstream fetch --tags
git -C upstream checkout "tags/${HAOS_TAG}"
git -C upstream submodule update --init --recursive   # buildroot is nested
```

### 3. Confirm the kernel <-> NVIDIA-driver pin
```bash
grep BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE \
  upstream/buildroot-external/configs/generic_x86_64_defconfig
```
The pinned NVIDIA driver must support that kernel. Reference points (verify on
NVIDIA's Unix driver page): 550 tops out ~6.11; 580.126.18 fixes the 6.19
module build; 595.84 is the current Production Branch. **HAOS 18.1 ships kernel
6.18.37, so the pin is 595.84** (already the default). Only change it if your
kernel differs:
```
# external/package/haos-compute-nvidia/Config.in
#   default "595.84"
```

### 4. Generate the RAUC signing CA (once)
```bash
./external/scripts/generate-ca.sh ./pki
# pki/cert.pem = PUBLIC (commit later)   pki/key.pem = SECRET (never commit)
```

### 5. Stage the signing material where the build reads it
```bash
mkdir -p output
cp pki/cert.pem cert.pem        && cp pki/key.pem key.pem
cp pki/cert.pem output/cert.pem && cp pki/key.pem output/key.pem
chmod 600 key.pem output/key.pem
```

### 6. Run the preflight gate (fail fast, seconds not minutes)
```bash
./external/scripts/preflight-check.sh nvidia-amd
```
Fix anything it flags (bad driver pin, unreachable asset) before building.

### 7. Build inside the HAOS builder container
Recommended order: `intel-amd` first (in-tree drivers only - proves the whole
pipeline on any kernel with almost no build risk), then `nvidia-amd` once you've
pinned an NVIDIA driver that supports your kernel, then `all`. Set `PROFILE=`
accordingly below.
```bash
docker build -t haos-gpu-builder ./upstream       # builder from the submodule's own Dockerfile

docker run --rm --privileged \
  -v "$PWD:/workspace" -w /workspace \
  -e ota_compatible=haos-generic-x86-64-gpu-ai \
  -e PROFILE=nvidia-amd \
  haos-gpu-builder \
  bash -c "./external/scripts/build.sh"
```
If `docker build ./upstream` doesn't match your HAOS version's build environment,
set a published builder image instead (see the workflow's `BUILDER_IMAGE`) and
run `./external/scripts/build.sh` inside it.

### 8. Verify the artifacts
```bash
ls -lh output/images/*.img.xz output/images/*.raucb
```
Expect a raw disk image and a signed bundle. (If no `.raucb` appears, see
Troubleshooting — some HAOS versions build the bundle from their top-level
Makefile rather than a Buildroot post-image hook.)

### 9. Flash the first image
**DANGER: `dd` overwrites the entire disk. Triple-check the device with `lsblk`.**
```bash
lsblk                                 # identify the target, e.g. /dev/sdb
xz -dc output/images/haos_generic-x86-64-*.img.xz | \
  sudo dd of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
sync
```

### 10. Boot and verify GPU bring-up
On the target, after first boot:
```bash
journalctl -u gpu-autodetect --no-pager     # which vendor was detected + loaded
lsmod | grep -E 'nvidia|amdgpu|i915'
cat /usr/lib/haos-gpu/*.contract             # host contract markers
nvidia-smi                                   # NVIDIA hosts only
ls -l /dev/dri /dev/kfd /dev/nvidia*         # compute nodes + 0666 perms
```

---

## Phase 2 — GitHub (CI, Releases, OTA)

### 1. Point the code at your real repo
```bash
NEW=myorg/haos-gpu-ai
grep -rl 'your-org/haos-gpu-ai' . | xargs -r sed -i "s#your-org/haos-gpu-ai#${NEW}#g"
```

### 2. Commit and push (submodule travels as a gitlink)
```bash
cp pki/cert.pem ota/gpu-ai-ca.pem     # optional: keep the public CA in-repo
git add -A && git commit -m "Configure repo + public CA"
git remote add origin git@github.com:myorg/haos-gpu-ai.git
git push -u origin main
```
Anyone cloning uses `git clone --recurse-submodules`.

### 3. Add the two Actions secrets
Settings -> Secrets and variables -> Actions, or with the `gh` CLI:
```bash
gh secret set RAUC_SIGNING_CERT < pki/cert.pem
gh secret set RAUC_SIGNING_KEY  < pki/key.pem
```
`GITHUB_TOKEN` is provided automatically by Actions.

### 4. First CI run — manual, smallest surface
```bash
gh workflow run build-and-track.yml -f profile=nvidia-amd -f force_tag="${HAOS_TAG}"
gh run watch
```
The preflight gate fails the job in seconds if the driver pin is wrong. Fix
`Config.in`, push, re-run. Iterate to green, then try `-f profile=all`.

### 5. What a green run publishes
A GitHub Release tagged with the upstream version, containing:
- `haos_generic-x86-64-<ver>.raucb` (signed with YOUR CA)
- `haos_generic-x86-64-<ver>.img.xz`
- `version-gpu-ai.json`

### 6. Automatic upstream tracking
The daily cron (`17 4 * * *`) checks `homeassistant/operating-system` for a new
tag; if found it builds the **full** image (`profile=all`) and publishes a
Release. Nothing else to do.

### 7. On-device OTA (decoupled from the Supervisor)
The flashed image runs `haos-gpu-updater.timer` daily, pointed at your repo. It
pulls the newest Release `.raucb`, verifies the `compatible` string, and
`rauc install`s it; reboot activates the new slot.
Manual update:
```bash
curl -fsSLO <release-asset-url>/haos_generic-x86-64-<ver>.raucb
rauc install haos_generic-x86-64-<ver>.raucb
reboot
```
Because the image uses a custom RAUC `compatible` + your keyring, the HAOS
Supervisor **cannot** overwrite it with a stock bundle. That is the decoupling.

---

## The whole flow in one breath
Flash once (Phase 1) -> push + set two secrets + one manual CI run (Phase 2) ->
after that, CI tracks upstream nightly and the device self-updates from your
Releases.

## Troubleshooting
- **Preflight fails on the driver ceiling** — bump the NVIDIA pin in
  `external/package/haos-compute-nvidia/Config.in`.
- **NVIDIA `kernel-open` compile error** — almost always the driver/kernel pair;
  bump the driver, or adjust `MODULE_MAKE_OPTS` in the package `.mk`.
- **`CONFIG_DRM_XE` unknown for your kernel** — stay on `profile=nvidia-amd`, or
  delete the two `DRM_XE` lines from `external/kernel/gpu-ai.config`.
- **No `.raucb` produced** — your HAOS version may create the bundle via its
  top-level Makefile instead of a Buildroot post-image hook; run that target in
  the container after `build.sh`.
- **Runner out of disk/time** — use a larger or self-hosted runner (the workflow
  already frees space and sets a long timeout).
- **RAUC signing path** — if the build ignores your `cert.pem`/`key.pem`, confirm
  where `upstream/buildroot-external/scripts/rauc.sh` expects them for your pin
  and copy accordingly (we stage both repo-root and `output/` to cover both).
