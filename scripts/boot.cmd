echo "Running boot U-Boot script..."

# Load kernel and DTB from MMC
fatload mmc ${mmcdev}:${mmcpart} ${kernel_addr_r} uImage
fatload mmc ${mmcdev}:${mmcpart} ${fdt_addr_r} devicetree.dtb

# Boot the kernel
bootm ${kernel_addr_r} - ${fdt_addr_r}
