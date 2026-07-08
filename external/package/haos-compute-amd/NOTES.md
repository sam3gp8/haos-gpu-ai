# AMD GPU compute — host vs container split

## What the HOST provides (this package + kernel fragment)
- `amdgpu` kernel driver (`CONFIG_DRM_AMDGPU=m`)
- KFD compute interface (`CONFIG_HSA_AMD=y`, `CONFIG_HSA_AMD_SVM=y`) → `/dev/kfd`
- Radeon/Instinct firmware blobs (from `linux-firmware`)
- `/dev/dri/*` and `/dev/kfd` nodes with `0666` permissions (udev overlay)

That is the complete and correct host responsibility. ROCm on Linux is a
kernel-interface (KFD) + user-space-runtime design; the host owns the kernel
interface, the container owns the runtime.

## What the CONTAINER provides (the add-on image)
The ROCm/HIP user-space runtime. The simplest path for LLM serving is the
prebuilt ROCm variant of the inference engine:

```dockerfile
FROM ollama/ollama:rocm
```

or, building `llama.cpp` against ROCm:

```dockerfile
FROM rocm/dev-ubuntu-22.04:latest
RUN cmake -B build -DGGML_HIPBLAS=ON && cmake --build build -j
```

At runtime the container needs the two nodes the host exposes:

```yaml
# add-on config.yaml
devices:
  - /dev/kfd
  - /dev/dri
```

and the process must be in the `video`/`render` groups (handled by the `0666`
node permissions on the appliance).

## Why not build ROCm into the OS
ROCm is tens of gigabytes of source across many repos with strict LLVM/toolchain
coupling; it does not build in Buildroot and would balloon the immutable image.
Keeping it container-side means you can move to a newer ROCm (or switch between
`ollama:rocm` and a custom `llama.cpp` HIP build) without rebuilding the OS.
