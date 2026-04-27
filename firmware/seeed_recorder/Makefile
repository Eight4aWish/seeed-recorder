FQBN := rp2040:rp2040:seeed_xiao_rp2040:usbstack=tinyusb
PORT ?= /dev/cu.usbmodem21101

# Quotes around the values are intentional — they expand into a C string literal
# in -DUSB_PRODUCT=... at compile time.
BUILD_PROPS := \
	--build-property 'build.usb_product="Seeed Recorder"' \
	--build-property 'build.usb_manufacturer="n8synth"'

.PHONY: build upload clean

build:
	arduino-cli compile --fqbn "$(FQBN)" $(BUILD_PROPS) .

upload: build
	arduino-cli upload --fqbn "$(FQBN)" -p "$(PORT)" .

clean:
	rm -rf build/
