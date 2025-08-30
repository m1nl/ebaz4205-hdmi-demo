VIVADO_VERSION ?= 2023.2

CROSS_COMPILE = arm-buildroot-linux-gnueabihf-
TOOLS_PATH = PATH="$(CURDIR)/buildroot/output/host/bin:$(CURDIR)/buildroot/output/host/sbin:$(PATH)"
TOOLCHAIN = $(CURDIR)/buildroot/output/host/bin/$(CROSS_COMPILE)gcc

NCORES = $(shell grep -c ^processor /proc/cpuinfo)
VIVADO_SETTINGS ?= /opt/Xilinx/Vivado/$(VIVADO_VERSION)/settings64.sh
VSUBDIRS = hdl buildroot linux u-boot-xlnx

VERSION = $(shell git describe --abbrev=4 --dirty --always --tags)
LATEST_TAG = $(shell git describe --abbrev=0 --tags)

TARGET ?= ebaz4205
SUPPORTED_TARGETS := ebaz4205

UBOOT_VERSION = $(shell echo -n "${TARGET}_" && cd u-boot-xlnx && git describe --abbrev=0 --dirty --always --tags)

# Include target specific constants
include scripts/$(TARGET).mk

TARGETS = build/boot.bin build/uImage build/rootfs.ext4 sdimg jtag-bootstrap

ifeq ($(findstring $(TARGET),$(SUPPORTED_TARGETS)),)
all:
	@echo "Invalid `TARGET variable ; valid values are: ebaz4205" &&
	exit 1
else
all: clean-build $(TARGETS) # zip-all
endif

.NOTPARALLEL: all

TARGET_DTS_FILES:=$(foreach dts,$(TARGET_DTS_FILES),build/$(dts))

TOOLCHAIN:
	make -C buildroot ARCH=arm zynq_$(TARGET)_defconfig
	make -C buildroot toolchain

build:
	mkdir -p $@

%: build/%
	cp $< $@


### u-boot ###

.PHONY: u-boot-xlnx/u-boot.elf
.PHONY: u-boot-xlnx/u-boot.dtb

u-boot-xlnx/u-boot.elf u-boot-xlnx/u-boot.dtb u-boot-xlnx/tools/mkimage: TOOLCHAIN
	$(TOOLS_PATH) make -C u-boot-xlnx ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) zynq_$(TARGET)_defconfig
	$(TOOLS_PATH) make -C u-boot-xlnx ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) UBOOTVERSION="$(UBOOT_VERSION)"

build/u-boot.elf: u-boot-xlnx/u-boot.elf | build
	cp $< $@
	$(TOOLS_PATH) $(CROSS_COMPILE)strip build/u-boot.elf

build/uboot-env.txt: u-boot-xlnx/u-boot.elf TOOLCHAIN | build
	$(TOOLS_PATH) CROSS_COMPILE=$(CROSS_COMPILE) scripts/get_default_envs.sh > $@

build/uboot-env.bin: build/uboot-env.txt
	u-boot-xlnx/tools/mkenvimage -s 0x20000 -o $@ $<

build/devicetree.dtb: u-boot-xlnx/u-boot.dtb | build
	cp $< $@

### Linux ###

menuconfig: TOOLCHAIN
	$(TOOLS_PATH) make -C linux ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) zynq_$(TARGET)_defconfig
	$(TOOLS_PATH) make -C linux ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) menuconfig

linux/arch/arm/boot/uImage: TOOLCHAIN
	$(TOOLS_PATH) make -C linux ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) zynq_$(TARGET)_defconfig
	$(TOOLS_PATH) make -C linux -j $(NCORES) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) uImage UIMAGE_LOADADDR=0x8000 KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=buildhost

.PHONY: linux/arch/arm/boot/uImage

build/uImage: linux/arch/arm/boot/uImage | build
	cp $< $@

### Buildroot ###

.PHONY: buildroot/output/images/rootfs.ext4

buildroot/output/images/rootfs.ext4:
	@echo device-fw $(VERSION)> $(CURDIR)/buildroot/board/$(TARGET)/VERSIONS
	@$(foreach dir,$(VSUBDIRS),echo $(dir) $(shell cd $(dir) && git describe --abbrev=4 --dirty --always --tags) >> $(CURDIR)/buildroot/board/$(TARGET)/VERSIONS;)
	make -C buildroot ARCH=arm zynq_$(TARGET)_defconfig
	make -C buildroot ARCH=arm all

build/rootfs.ext4: buildroot/output/images/rootfs.ext4 | build
	cp $< $@

#build/$(TARGET).itb: u-boot-xlnx/tools/mkimage build/zImage build/rootfs.ext4 $(TARGET_DTS_FILES) build/system_top.bit
#	u-boot-xlnx/tools/mkimage -f scripts/$(TARGET).its $@

### HDL ###

.PHONY: build/system_top.xsa

build/system_top.xsa: | build
	bash -c "source $(VIVADO_SETTINGS) && ADI_IGNORE_VERSION_CHECK=1 make -C hdl/projects/$(TARGET) && cp hdl/projects/$(TARGET)/$(TARGET).sdk/system_top.xsa $@"
	unzip -l $@ | grep -q ps7_init || cp hdl/projects/$(TARGET)/$(TARGET).srcs/sources_1/bd/system/ip/system_sys_ps7_0/ps7_init* build/

build/sdk/fsbl/Release/fsbl.elf build/system_top.bit: build/system_top.xsa
	rm -Rf build/sdk
	bash -c "source $(VIVADO_SETTINGS) && xsct scripts/create_fsbl_project.tcl"

build/fsbl.elf: build/sdk/fsbl/Release/fsbl.elf
	cp $< $@

### boot.bin ###

build/boot.bin: build/fsbl.elf build/system_top.bit build/u-boot.elf build/devicetree.dtb
    @echo "img : {[bootloader] build/fsbl.elf build/system_top.bit build/u-boot.elf [load = 0x00100000] build/devicetree.dtb}" > build/boot.bif
	bash -c "source $(VIVADO_SETTINGS) && bootgen -image build/boot.bif -w -o $@"

### sdcard image ##

SDIMGDIR = $(CURDIR)/build_sdimg

sdimg: build/fsbl.elf build/system_top.bit build/u-boot.elf build/devicetree.dtb build/uboot-env.bin build/uImage u-boot-xlnx/tools/mkimage
	rm -r $(SDIMGDIR)
	mkdir $(SDIMGDIR)
	cp build/fsbl.elf       $(SDIMGDIR)/fsbl.elf
	cp build/system_top.bit $(SDIMGDIR)/system_top.bit
	cp build/u-boot.elf     $(SDIMGDIR)/u-boot.elf
	cp build/uImage         $(SDIMGDIR)/uImage
	cp build/devicetree.dtb $(SDIMGDIR)/devicetree.dtb
#	cp build/uboot-env.bin  $(SDIMGDIR)/uboot.env
	u-boot-xlnx/tools/mkimage -A arm -T script -C none -n "Boot script" -d scripts/boot.cmd $(SDIMGDIR)/boot.scr
	echo "img : {[bootloader] $(SDIMGDIR)/fsbl.elf $(SDIMGDIR)/system_top.bit $(SDIMGDIR)/u-boot.elf [load = 0x00100000] $(SDIMGDIR)/devicetree.dtb}" > $(SDIMGDIR)/boot.bif
	bash -c "source $(VIVADO_SETTINGS) && bootgen -image $(SDIMGDIR)/boot.bif -w -o $(SDIMGDIR)/BOOT.bin"
	rm $(SDIMGDIR)/fsbl.elf
	rm $(SDIMGDIR)/system_top.bit
	rm $(SDIMGDIR)/u-boot.elf
	rm $(SDIMGDIR)/boot.bif

### clean ###

clean-build:
	rm -f $(notdir $(wildcard build/*))
	rm -rf build/*

clean:
	make -C u-boot-xlnx clean
	make -C linux clean
	make -C buildroot clean
	make -C hdl clean
	rm -f $(notdir $(wildcard build/*))
	rm -rf build/*

jtag-bootstrap: build/u-boot.elf build/ps7_init.tcl build/system_top.bit scripts/run.tcl scripts/run-xsdb.tcl
	zip -j build/$(ZIP_ARCHIVE_PREFIX)-$@-$(VERSION).zip $^
