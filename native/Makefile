# Titanium native Metal backend.
# Reproducible: no network, no package manager, only the macOS SDK.

UNAME_S := $(shell uname -s)
ifneq ($(UNAME_S),Darwin)
$(error Titanium's native backend only builds on macOS)
endif

CXX          ?= clang++
BUILD        ?= build
MIN_MACOS    ?= 12.0

SRC_DIR      := src
INC_DIR      := include
SOURCES      := $(SRC_DIR)/ti_core.mm $(SRC_DIR)/ti_resource.mm \
                $(SRC_DIR)/ti_shader.mm $(SRC_DIR)/ti_render.mm
OBJECTS      := $(patsubst $(SRC_DIR)/%.mm,$(BUILD)/%.o,$(SOURCES))

JNI_SOURCES  := $(SRC_DIR)/jni/ti_jni.mm
JNI_OBJECTS  := $(patsubst $(SRC_DIR)/jni/%.mm,$(BUILD)/jni_%.o,$(JNI_SOURCES))

# JAVA_HOME is only needed for the JNI bridge; the core library and the
# self-test build without a JDK present.
JAVA_HOME    ?= $(shell /usr/libexec/java_home 2>/dev/null)
JNI_INCLUDES := -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/darwin

WARN         := -Wall -Wextra -Wno-unused-parameter -Wno-nullability-completeness
CXXFLAGS     := -std=c++17 -ObjC++ -fobjc-arc -O2 -g \
                -fvisibility=hidden -fno-common \
                -mmacosx-version-min=$(MIN_MACOS) \
                -I$(INC_DIR) -I$(SRC_DIR) $(WARN)

FRAMEWORKS   := -framework Metal -framework Foundation -framework QuartzCore \
                -framework AppKit -framework CoreGraphics \
                -weak_framework MetalFX
LDFLAGS      := -dynamiclib -mmacosx-version-min=$(MIN_MACOS) \
                -install_name @rpath/libtitanium.dylib $(FRAMEWORKS)

DYLIB        := $(BUILD)/libtitanium.dylib
SELFTEST     := $(BUILD)/ti_selftest
WINDEMO      := $(BUILD)/ti_windowdemo

.PHONY: all lib jni test windowtest clean shaders

all: lib test

lib: $(DYLIB)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: $(SRC_DIR)/%.mm | $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/jni_%.o: $(SRC_DIR)/jni/%.mm | $(BUILD)
	@test -n "$(JAVA_HOME)" || (echo "JAVA_HOME not set and java_home found no JDK"; exit 1)
	$(CXX) $(CXXFLAGS) $(JNI_INCLUDES) -c $< -o $@

# The shipped dylib always contains the JNI bridge; the core objects alone
# are enough for the native self-test.
$(DYLIB): $(OBJECTS) $(JNI_OBJECTS)
	$(CXX) $(LDFLAGS) $(OBJECTS) $(JNI_OBJECTS) -o $@
	@echo "built $@"

jni: $(DYLIB)

$(SELFTEST): tests/ti_selftest.mm $(OBJECTS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_selftest.mm $(OBJECTS) -o $@
	@echo "built $@"

$(WINDEMO): tests/ti_windowdemo.mm $(OBJECTS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_windowdemo.mm $(OBJECTS) -o $@
	@echo "built $@"

test: $(SELFTEST)
	@echo "--- running native self-test ---"
	@$(SELFTEST)

# Opens a real window; needs a GUI session.
windowtest: $(WINDEMO)
	@echo "--- running on-screen validation ---"
	@$(WINDEMO)

clean:
	rm -rf $(BUILD)
