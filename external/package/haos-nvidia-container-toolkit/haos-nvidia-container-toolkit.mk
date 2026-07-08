################################################################################
#
# haos-nvidia-container-toolkit
#
# NVIDIA Container Toolkit host components. NVIDIA ships these as .deb packages
# bundled inside a release tarball -- verified against the GitHub releases API,
# the only amd64 asset is nvidia-container-toolkit_<ver>_deb_amd64.tar.gz (there
# is NO plain-binary tarball). We download that tarball, let Buildroot unpack it,
# then unpack each .deb with dpkg-deb (present in the Debian-based HAOS builder)
# and install the runtime shim + hook + CLI + libnvidia-container that the Docker
# "nvidia" runtime referenced in daemon.json needs.
#
################################################################################

HAOS_NVIDIA_CONTAINER_TOOLKIT_VERSION = 1.19.1
HAOS_NVIDIA_CONTAINER_TOOLKIT_SITE = https://github.com/NVIDIA/nvidia-container-toolkit/releases/download/v$(HAOS_NVIDIA_CONTAINER_TOOLKIT_VERSION)
HAOS_NVIDIA_CONTAINER_TOOLKIT_SOURCE = nvidia-container-toolkit_$(HAOS_NVIDIA_CONTAINER_TOOLKIT_VERSION)_deb_amd64.tar.gz
HAOS_NVIDIA_CONTAINER_TOOLKIT_LICENSE = Apache-2.0

# The tarball contains .deb files (at or near its root); do not strip the
# leading path component the way Buildroot does by default.
HAOS_NVIDIA_CONTAINER_TOOLKIT_STRIP_COMPONENTS = 0

define HAOS_NVIDIA_CONTAINER_TOOLKIT_INSTALL_TARGET_CMDS
	rm -rf $(@D)/debroot
	mkdir -p $(@D)/debroot $(TARGET_DIR)/usr/bin $(TARGET_DIR)/usr/lib $(TARGET_DIR)/etc/nvidia-container-runtime
	cd $(@D) && for deb in $$(find . -name '*.deb'); do dpkg-deb -x "$$deb" $(@D)/debroot; done
	cd $(@D)/debroot && find . -path '*bin/nvidia-*' ! -type d -exec cp -a {} $(TARGET_DIR)/usr/bin/ \;
	cd $(@D)/debroot && find . -name 'libnvidia-container*.so*' -exec cp -a {} $(TARGET_DIR)/usr/lib/ \;
	if [ -f $(@D)/debroot/etc/nvidia-container-runtime/config.toml ]; then \
		cp -a $(@D)/debroot/etc/nvidia-container-runtime/config.toml $(TARGET_DIR)/etc/nvidia-container-runtime/config.toml; \
	fi
	# nvidia-container-toolkit >= 1.17 ALWAYS uses the HOST's ldconfig: it
	# bind-mounts the host binary into the container and runs it there (the old
	# "container ldconfig" no-@ mode was removed as a container-escape fix). So
	# the config MUST point at a host path that exists. HAOS ships no ldconfig,
	# so post-build.sh installs glibc's ldconfig to /usr/sbin (merged-usr makes
	# /sbin/ldconfig resolve to it), and we write the config unconditionally
	# (the 1.19 debs ship an empty /etc/nvidia-container-runtime).
	printf '%s\n' \
		'[nvidia-container-cli]' \
		'load-kmods = true' \
		'ldconfig = "@/sbin/ldconfig"' \
		> $(TARGET_DIR)/etc/nvidia-container-runtime/config.toml
endef

$(eval $(generic-package))
