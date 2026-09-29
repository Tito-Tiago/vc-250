.PHONY: all deps packages bench clean help

REPO_DIR := $(CURDIR)
APKREPO  := $(REPO_DIR)/packages/x86_64

help:
	@echo "make deps      - instala alpine-sdk e deps de build"
	@echo "make packages  - compila todos os APKBUILDs"
	@echo "make bench     - roda bench-regress.sh"
	@echo "make clean     - remove artefatos de build"
	@echo "make kernel    - compila só linux-bc250-lts"
	@echo "make governor  - compila só governor-smu"
	@echo "make llama     - compila só llama.cpp-bc250"

all: packages

deps:
	apk add alpine-sdk abuild sudo
	abuild-keygen -a -i -n || true
	apk add git cmake ninja pkgconf linux-headers libdrm-dev \
		dbus-libs cargo rust vulkan-loader-dev glslang-dev \
		spirv-headers shaderc curl-dev zlib-dev zstd-dev openssl-dev

packages: kernel governor llama

kernel:
	cd apkbuilds/linux-bc250-lts && abuild -r

governor:
	cd apkbuilds/cyan-skillfish-governor-smu && abuild -r

llama:
	cd apkbuilds/llama.cpp-bc250 && abuild -r

bench:
	sh scripts/bench-regress.sh

clean:
	find apkbuilds -name src -o -name pkg -o -name '*.apk' | xargs rm -rf
	rm -rf $(APKREPO)