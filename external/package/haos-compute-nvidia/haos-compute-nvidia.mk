################################################################################
#
# haos-compute-nvidia
#
# NVIDIA open GPU kernel modules built against the HAOS kernel + the proprietary
# user-space *driver* libraries that must live on the host. The CUDA runtime is
# intentionally NOT installed here (it lives in the add-on container); the
# NVIDIA Container Toolkit injects these host libraries into containers.
#
################################################################################

HAOS_COMPUTE_NVIDIA_VERSION = $(call qstrip,$(BR2_PACKAGE_HAOS_COMPUTE_NVIDIA_VERSION))
HAOS_COMPUTE_NVIDIA_SITE = https://us.download.nvidia.com/XFree86/Linux-x86_64/$(HAOS_COMPUTE_NVIDIA_VERSION)
HAOS_COMPUTE_NVIDIA_SOURCE = NVIDIA-Linux-x86_64-$(HAOS_COMPUTE_NVIDIA_VERSION).run
HAOS_COMPUTE_NVIDIA_LICENSE = NVIDIA Software License
HAOS_COMPUTE_NVIDIA_LICENSE_FILES = payload/LICENSE
HAOS_COMPUTE_NVIDIA_DEPENDENCIES = linux

# Short aliases for the extracted payload dir and driver version.
HAOS_COMPUTE_NVIDIA_PAYLOAD = $(@D)/payload
HAOS_COMPUTE_NVIDIA_V = $(HAOS_COMPUTE_NVIDIA_VERSION)

# ---------------------------------------------------------------------------
# The .run file is a self-extracting shell archive, not a tarball. Override the
# extract step to unpack it into $(@D)/payload.
# ---------------------------------------------------------------------------
define HAOS_COMPUTE_NVIDIA_EXTRACT_CMDS
	cd $(@D) && \
	sh $(HAOS_COMPUTE_NVIDIA_DL_DIR)/$(HAOS_COMPUTE_NVIDIA_SOURCE) \
		--extract-only --target $(HAOS_COMPUTE_NVIDIA_PAYLOAD)
endef

# ---------------------------------------------------------------------------
# Build the open kernel modules against the configured HAOS kernel tree.
# NVIDIA's kernel-open Makefile drives kbuild itself; we hand it SYSSRC/SYSOUT
# and the cross toolchain from Buildroot.
# ---------------------------------------------------------------------------
define HAOS_COMPUTE_NVIDIA_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(HAOS_COMPUTE_NVIDIA_PAYLOAD)/kernel-open \
		modules \
		SYSSRC=$(LINUX_DIR) \
		SYSOUT=$(LINUX_DIR) \
		ARCH=$(KERNEL_ARCH) \
		CC="$(TARGET_CC)" \
		LD="$(TARGET_LD)" \
		CROSS_COMPILE="$(TARGET_CROSS)" \
		IGNORE_CC_MISMATCH=1 \
		NV_VERBOSE=1
endef

# ---------------------------------------------------------------------------
# Install kernel modules (with depmod) + host user-space driver libraries.
# ---------------------------------------------------------------------------
define HAOS_COMPUTE_NVIDIA_INSTALL_TARGET_CMDS
	# --- kernel modules -> /lib/modules/<ver>/extra/nvidia + depmod ---
	$(TARGET_MAKE_ENV) $(MAKE) -C $(HAOS_COMPUTE_NVIDIA_PAYLOAD)/kernel-open \
		modules_install \
		SYSSRC=$(LINUX_DIR) \
		SYSOUT=$(LINUX_DIR) \
		INSTALL_MOD_PATH=$(TARGET_DIR) \
		INSTALL_MOD_DIR=extra/nvidia \
		DEPMOD=$(HOST_DIR)/sbin/depmod

	# --- host driver libraries (injected into containers by the toolkit) ---
	$(INSTALL) -D -m 0755 \
		$(HAOS_COMPUTE_NVIDIA_PAYLOAD)/libcuda.so.$(HAOS_COMPUTE_NVIDIA_V) \
		$(TARGET_DIR)/usr/lib/libcuda.so.$(HAOS_COMPUTE_NVIDIA_V)
	ln -sf libcuda.so.$(HAOS_COMPUTE_NVIDIA_V) $(TARGET_DIR)/usr/lib/libcuda.so.1
	ln -sf libcuda.so.1 $(TARGET_DIR)/usr/lib/libcuda.so

	$(INSTALL) -D -m 0755 \
		$(HAOS_COMPUTE_NVIDIA_PAYLOAD)/libnvidia-ml.so.$(HAOS_COMPUTE_NVIDIA_V) \
		$(TARGET_DIR)/usr/lib/libnvidia-ml.so.$(HAOS_COMPUTE_NVIDIA_V)
	ln -sf libnvidia-ml.so.$(HAOS_COMPUTE_NVIDIA_V) $(TARGET_DIR)/usr/lib/libnvidia-ml.so.1
	ln -sf libnvidia-ml.so.1 $(TARGET_DIR)/usr/lib/libnvidia-ml.so

	# --- PTX JIT compiler + JIT companions (REQUIRED at model load) ----------
	# CONFIRMED on hardware: with this absent, llama-server's cuda runner aborts
	# at warmup: "CUDA error: PTX JIT compiler library not found" (CUDA err 221),
	# terminating with HTTP 500. libcuda routes runtime PTX->SASS JIT through
	# libnvidia-ptxjitcompiler; on 5xx-era drivers the JIT path can also pull in
	# NVVM / gpucomp / the memory allocator lib. Install ptxjitcompiler (Tier-1,
	# named by the error) plus any of those companions that EXIST in the 595.84
	# payload (Tier-2, glob-guarded so a missing name can't fail the build).
	# Each real .so.<ver> gets its .so.1 + .so symlinks so the loader resolves it.
	for base in libnvidia-ptxjitcompiler libnvidia-nvvm libnvidia-gpucomp libnvidia-allocator; do \
		f="$(HAOS_COMPUTE_NVIDIA_PAYLOAD)/$$base.so.$(HAOS_COMPUTE_NVIDIA_V)"; \
		if [ -e "$$f" ]; then \
			$(INSTALL) -D -m 0755 "$$f" $(TARGET_DIR)/usr/lib/$$base.so.$(HAOS_COMPUTE_NVIDIA_V); \
			ln -sf $$base.so.$(HAOS_COMPUTE_NVIDIA_V) $(TARGET_DIR)/usr/lib/$$base.so.1; \
			ln -sf $$base.so.1 $(TARGET_DIR)/usr/lib/$$base.so; \
			echo "[nvidia] installed JIT lib: $$base.so.$(HAOS_COMPUTE_NVIDIA_V)"; \
		else \
			echo "[nvidia] JIT lib not in payload (skipping): $$base"; \
		fi; \
	done


	# --- helpers ---
	# nvidia-modprobe must be setuid root: it creates /dev/nvidia* + /dev/nvidia-uvm
	# on demand when no static udev node exists yet.
	$(INSTALL) -D -m 4755 \
		$(HAOS_COMPUTE_NVIDIA_PAYLOAD)/nvidia-modprobe \
		$(TARGET_DIR)/usr/bin/nvidia-modprobe
	$(INSTALL) -D -m 0755 \
		$(HAOS_COMPUTE_NVIDIA_PAYLOAD)/nvidia-smi \
		$(TARGET_DIR)/usr/bin/nvidia-smi

	# --- GSP firmware (REQUIRED by the open kernel modules on Turing+/Ada) ---
	# The open modules offload init to the GPU System Processor and load
	# nvidia/<ver>/gsp_*.bin at RmInitAdapter. Without it: "Direct firmware load
	# for .../gsp_ga10x.bin failed with error -2" -> RmInitAdapter failed ->
	# nvidia-smi finds no devices. The blobs live in the .run payload under
	# firmware/. Install every gsp_*.bin into /usr/lib/firmware/nvidia/<ver>/ (merged-usr).
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/firmware/nvidia/$(HAOS_COMPUTE_NVIDIA_V)
	for fw in $(HAOS_COMPUTE_NVIDIA_PAYLOAD)/firmware/gsp_*.bin; do \
		[ -e "$$fw" ] && $(INSTALL) -D -m 0644 "$$fw" \
			$(TARGET_DIR)/usr/lib/firmware/nvidia/$(HAOS_COMPUTE_NVIDIA_V)/$$(basename "$$fw") || true; \
	done

endef

$(eval $(generic-package))
