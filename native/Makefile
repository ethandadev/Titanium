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

TRANSLATE_OBJ := $(BUILD)/ti_translate.o

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
XLATETEST    := $(BUILD)/ti_translate_test
FRAMETEST    := $(BUILD)/ti_frame_test

# ---------------------------------------------------------------------------
# Third-party: glslang (GLSL -> SPIR-V) and SPIRV-Cross (SPIR-V -> MSL).
# Sources are fetched at pinned commits by tools/fetch-deps.sh and built here
# as static archives with hidden visibility, so none of their symbols leak out
# of libtitanium.dylib and collide with another mod's native code.
# ---------------------------------------------------------------------------
TP           := third_party
DEPS_BUILD   := $(BUILD)/deps
CMAKE_COMMON := -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_MACOS) -DCMAKE_OSX_ARCHITECTURES=arm64 \
                -DBUILD_SHARED_LIBS=OFF -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
                -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
NPROC        := $(shell sysctl -n hw.ncpu)

# This glslang release folds SPIRV/MachineIndependent/etc. into libglslang.a
# (the others build as empty stubs), so only two archives are needed.
GLSLANG_LIBS := $(DEPS_BUILD)/glslang/glslang/libglslang.a \
                $(DEPS_BUILD)/glslang/glslang/libglslang-default-resource-limits.a
SPVC_LIBS    := $(DEPS_BUILD)/spirv-cross/libspirv-cross-msl.a \
                $(DEPS_BUILD)/spirv-cross/libspirv-cross-glsl.a \
                $(DEPS_BUILD)/spirv-cross/libspirv-cross-core.a
DEP_LIBS     := $(SPVC_LIBS) $(GLSLANG_LIBS)
DEP_INCLUDES := -I$(TP)/glslang -I$(TP)/SPIRV-Cross -I$(DEPS_BUILD)/glslang/include

$(TP)/glslang/CMakeLists.txt $(TP)/SPIRV-Cross/CMakeLists.txt:
	../tools/fetch-deps.sh

$(DEPS_BUILD)/.glslang.stamp: $(TP)/glslang/CMakeLists.txt
	cmake -S $(TP)/glslang -B $(DEPS_BUILD)/glslang $(CMAKE_COMMON) \
	  -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=OFF \
	  -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_HLSL=OFF -DENABLE_SPVREMAPPER=OFF \
	  -DALLOW_EXTERNAL_SPIRV_TOOLS=OFF
	cmake --build $(DEPS_BUILD)/glslang -j$(NPROC)
	@touch $@

$(DEPS_BUILD)/.spirv-cross.stamp: $(TP)/SPIRV-Cross/CMakeLists.txt
	cmake -S $(TP)/SPIRV-Cross -B $(DEPS_BUILD)/spirv-cross $(CMAKE_COMMON) \
	  -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_ENABLE_HLSL=OFF \
	  -DSPIRV_CROSS_ENABLE_CPP=OFF -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
	  -DSPIRV_CROSS_ENABLE_C_API=OFF -DSPIRV_CROSS_ENABLE_UTIL=OFF \
	  -DSPIRV_CROSS_STATIC=ON -DSPIRV_CROSS_SHARED=OFF \
	  -DSPIRV_CROSS_ENABLE_GLSL=ON -DSPIRV_CROSS_ENABLE_MSL=ON
	cmake --build $(DEPS_BUILD)/spirv-cross -j$(NPROC)
	@touch $@

deps: $(DEPS_BUILD)/.glslang.stamp $(DEPS_BUILD)/.spirv-cross.stamp

.PHONY: all lib jni test windowtest translatetest frametest clean shaders deps licenses

all: lib test

lib: $(DYLIB)

$(BUILD):
	@mkdir -p $(BUILD)

# Every object depends on the shared headers; without this an ABI change in a
# header leaves stale objects that fail at link time (or, worse, don't).
HEADERS      := $(INC_DIR)/titanium/ti_api.h $(SRC_DIR)/ti_internal.h $(SRC_DIR)/ti_error.h

$(BUILD)/%.o: $(SRC_DIR)/%.mm $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TRANSLATE_OBJ): $(SRC_DIR)/ti_translate.cpp $(SRC_DIR)/ti_error.h $(INC_DIR)/titanium/ti_api.h \
                  $(DEPS_BUILD)/.glslang.stamp $(DEPS_BUILD)/.spirv-cross.stamp | $(BUILD)
	$(CXX) -std=c++17 -O2 -g -fvisibility=hidden -mmacosx-version-min=$(MIN_MACOS) \
	    -I$(INC_DIR) -I$(SRC_DIR) $(DEP_INCLUDES) -Wall -Wno-unused-parameter \
	    -c $< -o $@

$(BUILD)/jni_%.o: $(SRC_DIR)/jni/%.mm $(HEADERS) | $(BUILD)
	@test -n "$(JAVA_HOME)" || (echo "JAVA_HOME not set and java_home found no JDK"; exit 1)
	$(CXX) $(CXXFLAGS) $(JNI_INCLUDES) -c $< -o $@

# The shipped dylib always contains the JNI bridge; the core objects alone
# are enough for the native self-test.
$(DYLIB): $(OBJECTS) $(TRANSLATE_OBJ) $(JNI_OBJECTS)
	$(CXX) $(LDFLAGS) $(OBJECTS) $(TRANSLATE_OBJ) $(JNI_OBJECTS) $(DEP_LIBS) -o $@
	@echo "built $@"

jni: $(DYLIB)

$(SELFTEST): tests/ti_selftest.mm $(OBJECTS) $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_selftest.mm $(OBJECTS) -o $@
	@echo "built $@"

$(WINDEMO): tests/ti_windowdemo.mm $(OBJECTS) $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_windowdemo.mm $(OBJECTS) -o $@
	@echo "built $@"

test: $(SELFTEST)
	@echo "--- running native self-test ---"
	@$(SELFTEST)

$(XLATETEST): tests/ti_translate_test.mm $(OBJECTS) $(TRANSLATE_OBJ) $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_translate_test.mm $(OBJECTS) $(TRANSLATE_OBJ) $(DEP_LIBS) -o $@
	@echo "built $@"

translatetest: $(XLATETEST)
	@echo "--- running GLSL->MSL golden tests ---"
	@$(XLATETEST)

$(FRAMETEST): tests/ti_frame_test.mm $(OBJECTS) $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -mmacosx-version-min=$(MIN_MACOS) \
	    tests/ti_frame_test.mm $(OBJECTS) -o $@
	@echo "built $@"

frametest: $(FRAMETEST)
	@echo "--- running frame/backend-support tests ---"
	@$(FRAMETEST)

# Opens a real window; needs a GUI session.
windowtest: $(WINDEMO)
	@echo "--- running on-screen validation ---"
	@$(WINDEMO)

# Licence texts that must ship inside any distributed jar (docs/third-party.md).
licenses: $(TP)/glslang/CMakeLists.txt $(TP)/SPIRV-Cross/CMakeLists.txt
	@mkdir -p $(BUILD)/licenses
	cp $(TP)/glslang/LICENSE.txt   $(BUILD)/licenses/glslang-LICENSE.txt
	cp $(TP)/SPIRV-Cross/LICENSE   $(BUILD)/licenses/SPIRV-Cross-LICENSE.txt
	@echo "licences staged in $(BUILD)/licenses"

clean:
	rm -rf $(BUILD)
