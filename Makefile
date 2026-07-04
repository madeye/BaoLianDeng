# Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

RUST_FFI_DIR = Rust/meow-ffi
FFI_OBJC = $(RUST_FFI_DIR)/objc
FRAMEWORK_DIR = Framework
FRAMEWORK_NAME = MihomoCore
BUILD_DIR = /tmp/meow-ffi-build

CARGO_FLAGS = --release
RUSTFLAGS_MACOS = -C strip=symbols

# macOS SDK path
MACOS_SDK = $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: all framework framework-macos clean e2e-test e2e-setup stress-test

all: framework

# Default target: build macOS universal (arm64 + x86_64)
framework: framework-macos

framework-macos:
	# Build Rust staticlib for each macOS target
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-darwin
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_MACOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-darwin
	# Compile ObjC wrapper for each macOS arch
	@mkdir -p $(BUILD_DIR)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-arm64.o \
		-target arm64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o $(BUILD_DIR)/objc-macos-x86.o \
		-target x86_64-apple-macos14.0 -fobjc-arc -isysroot $(MACOS_SDK) -I$(FFI_OBJC)
	# Combine Rust .a + ObjC .o into single .a per arch
	xcrun libtool -static -o $(BUILD_DIR)/macos-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-darwin/release/libmeow_ffi.a $(BUILD_DIR)/objc-macos-arm64.o
	xcrun libtool -static -o $(BUILD_DIR)/macos-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-darwin/release/libmeow_ffi.a $(BUILD_DIR)/objc-macos-x86.o
	# Fat library for macOS (arm64 + x86_64)
	@mkdir -p $(BUILD_DIR)/macos
	lipo -create $(BUILD_DIR)/macos-arm64.a $(BUILD_DIR)/macos-x86.a \
		-output $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a
	# Prepare headers directory (use the hand-written MihomoCore.h, NOT any
	# tool-generated header — Swift imports the stable ObjC API)
	@rm -rf $(BUILD_DIR)/headers
	@mkdir -p $(BUILD_DIR)/headers
	@cp $(FFI_OBJC)/MihomoCore.h $(BUILD_DIR)/headers/
	@cp $(FFI_OBJC)/module.modulemap $(BUILD_DIR)/headers/
	# Create xcframework (macOS only)
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library $(BUILD_DIR)/macos/lib$(FRAMEWORK_NAME).a -headers $(BUILD_DIR)/headers \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	@echo "Built $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework (macOS arm64+x86_64)"

clean:
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	rm -rf $(BUILD_DIR)
	cd $(RUST_FFI_DIR) && cargo clean

e2e-setup:
	./tests/e2e/vm-setup.sh

e2e-test:
	./tests/e2e/run-e2e.sh

stress-test:
	./tests/e2e/run-stress-test.sh

stability-test:
	./tests/e2e/run-stability-test.sh
