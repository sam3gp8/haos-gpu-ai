################################################################################
#
# HAOS_GPU_AI external tree - package aggregation
#
# The external.desc "name:" field (HAOS_GPU_AI) makes Buildroot export
# $(BR2_EXTERNAL_HAOS_GPU_AI_PATH) pointing at this directory. We include every
# package makefile found under package/*/ so new vendor packages are picked up
# automatically without editing this file.
#
################################################################################

include $(sort $(wildcard $(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/package/*/*.mk))
