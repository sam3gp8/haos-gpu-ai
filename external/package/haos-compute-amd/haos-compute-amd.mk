################################################################################
#
# haos-compute-amd
#
# Config-only package: no upstream source. The AMD host "compute contract" is
# satisfied by the kernel fragment (amdgpu + HSA_AMD/KFD) + linux-firmware + the
# udev overlay. The ROCm/HIP user-space runtime is delivered in the add-on
# container - see NOTES.md.
#
################################################################################

HAOS_COMPUTE_AMD_VERSION = 1.0
HAOS_COMPUTE_AMD_SITE_METHOD = local
HAOS_COMPUTE_AMD_SITE = $(HAOS_COMPUTE_AMD_PKGDIR)
# No SITE / SOURCE -> Buildroot performs no download for this package.
HAOS_COMPUTE_AMD_DEPENDENCIES = linux-firmware

define HAOS_COMPUTE_AMD_EXTRACT_CMDS
endef

define HAOS_COMPUTE_AMD_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/haos-gpu
	printf '%s\n' \
		'vendor=amd' \
		'kernel=amdgpu' \
		'compute_iface=/dev/kfd' \
		'render_node=/dev/dri/renderD*' \
		'runtime=container (ROCm / HIP - e.g. ollama:rocm)' \
		> $(TARGET_DIR)/usr/lib/haos-gpu/amd.contract
endef

$(eval $(generic-package))
