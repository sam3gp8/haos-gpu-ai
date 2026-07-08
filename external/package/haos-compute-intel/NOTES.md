# Intel GPU/XPU compute — host vs container split

## What the HOST provides (this package + kernel fragment)
- `i915` and/or `xe` kernel drivers (`CONFIG_DRM_I915=m`, `CONFIG_DRM_XE=m`)
- Intel GuC/HuC/DMC firmware (from `linux-firmware`)
- `/dev/dri/renderD*` render node with `0666` permissions (udev overlay)

That is the complete and correct host responsibility for containerized Intel
compute. The kernel driver is what the user-space runtime binds to; everything
above the render node is user space and belongs in the container.

## What the CONTAINER provides (the add-on image)
The Intel LLM/compute user-space stack — **Intel Compute Runtime (NEO)**,
**Intel Graphics Compiler (IGC)**, **gmmlib**, and the **Level-Zero loader** —
is shipped in the add-on image. The cleanest base is Intel's oneAPI image, or an
IPEX-LLM / SYCL-enabled `llama.cpp` build. Sketch:

```dockerfile
FROM intel/oneapi-basekit:latest
# NEO + level-zero + compute-runtime are already present in this base.
# Build llama.cpp with the SYCL backend targeting Level-Zero:
RUN cmake -B build -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
 && cmake --build build --config Release -j
```

At runtime the container needs the render node the host exposes:

```yaml
# add-on config.yaml
devices:
  - /dev/dri
```

## Why not build NEO/IGC into the OS
1. **It won't cross-compile cleanly.** IGC pulls in a specific LLVM/Clang +
   SPIRV-LLVM-Translator toolchain; matching it to Buildroot's toolchain is a
   project in itself and breaks on most kernel/LLVM bumps.
2. **It defeats the appliance model.** HAOS is a read-only, atomically-updated
   image. Pinning a compute runtime into it means an OS rebuild every time you
   want a newer runtime. Keeping it container-side lets you update the runtime
   independently of the OS — which is the entire point of the host/container
   split you asked to preserve.
