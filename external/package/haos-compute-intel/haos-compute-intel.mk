################################################################################
#
# haos-compute-intel
#
# Config-only package: no upstream source. The Intel host "compute contract" is
# satisfied by the kernel fragment (i915/xe) + linux-firmware + the udev overlay.
# The heavy user-space runtime (NEO / IGC / level-zero / oneAPI) is delivered in
# the add-on container - see NOTES.md.
#
################################################################################

HAOS_COMPUTE_INTEL_VERSION = 1.0
HAOS_COMPUTE_INTEL_SITE_METHOD = local
HAOS_COMPUTE_INTEL_SITE = $(HAOS_COMPUTE_INTEL_PKGDIR)
# No SITE / SOURCE -> Buildroot performs no download for this package.
HAOS_COMPUTE_INTEL_DEPENDENCIES = linux-firmware

define HAOS_COMPUTE_INTEL_EXTRACT_CMDS
endef

define HAOS_COMPUTE_INTEL_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/haos-gpu
	printf '%s\n' \
		'vendor=intel' \
		'kernel=i915,xe' \
		'compute_node=/dev/dri/renderD*' \
		'runtime=container (level-zero / oneAPI / intel-compute-runtime)' \
		> $(TARGET_DIR)/usr/lib/haos-gpu/intel.contract
endef

$(eval $(generic-package))
