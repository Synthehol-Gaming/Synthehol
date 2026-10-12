CC := xcrun clang
ROOT := $(CURDIR)
UPSTREAM := $(ROOT)/Upstream
BUILD := $(ROOT)/build
PAYLOAD := $(ROOT)/../SyntheholKit/Sources/SyntheholKit/Resources/NativeSteamPayload
MIN_VER := 15.0

CFLAGS := -arch arm64 -mmacosx-version-min=$(MIN_VER) -std=c17 -O2 -Wall -Wextra \
	-Wno-unused-parameter -fPIC -MMD -MP -I$(UPSTREAM)/dylib \
	-I$(UPSTREAM)/vendor -I$(UPSTREAM)/vendor/dobby/include -I$(BUILD)/generated
LDFLAGS := -arch arm64 -mmacosx-version-min=$(MIN_VER) -dynamiclib \
	-install_name @rpath/synthehol-steamplay.dylib

SOURCES := \
	dylib/core/loader.c dylib/core/macho.c \
	dylib/resolver/anchor.c dylib/resolver/aob.c dylib/resolver/resolver.c dylib/resolver/sigdb.c \
	dylib/util/log.c dylib/util/file.c dylib/util/peicon.c \
	dylib/hooks/hooks.c dylib/hooks/hook_compat.c dylib/hooks/hook_shortcut.c \
	dylib/hooks/hook_icon.c dylib/hooks/hook_webui.c dylib/hooks/hook_webpatch.c \
	dylib/hooks/hook_spawn.c dylib/hooks/hook_launch.c \
	dylib/feats/compat.c dylib/feats/webui.c dylib/feats/compatsvc.c \
	dylib/feats/webpatch.c dylib/feats/input_access.c vendor/cJSON.c
OBJECTS := $(patsubst %.c,$(BUILD)/%.o,$(SOURCES))
DEPS := $(OBJECTS:.o=.d)

DOBBY_BUILD := $(BUILD)/dobby
DOBBY_LIBS := \
	$(DOBBY_BUILD)/libdobby.a \
	$(DOBBY_BUILD)/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a \
	$(DOBBY_BUILD)/builtin-plugin/SymbolResolver/libmacho_ctx_kit.a \
	$(DOBBY_BUILD)/builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a \
	$(DOBBY_BUILD)/external/osbase/libosbase.a \
	$(DOBBY_BUILD)/external/logging/liblogging.a

ARM_DYLIB := $(BUILD)/synthehol-steamplay.arm64.dylib
X86_STUB := $(BUILD)/synthehol-steamplay.x86_64.dylib
DYLIB := $(BUILD)/synthehol-steamplay.dylib
OVERLAY_ARM := $(BUILD)/synthehol-overlay-shim.arm64.dylib
OVERLAY_X86 := $(BUILD)/synthehol-overlay-shim.x86_64.dylib
OVERLAY := $(BUILD)/synthehol-overlay-shim.dylib
RUN_HEADER := $(BUILD)/generated/compat_run.h

.PHONY: all dobby payload clean
all: $(DYLIB) $(OVERLAY)

dobby: $(DOBBY_BUILD)/libdobby.a

$(DOBBY_BUILD)/libdobby.a:
	@mkdir -p $(DOBBY_BUILD)
	cd $(DOBBY_BUILD) && cmake $(UPSTREAM)/vendor/dobby \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_VER) \
		-DDOBBY_DEBUG=OFF -DDOBBY_GENERATE_SHARED=OFF -G "Unix Makefiles"
	$(MAKE) -C $(DOBBY_BUILD) -j$$(sysctl -n hw.ncpu)

$(RUN_HEADER): $(UPSTREAM)/dylib/feats/compat_run.sh $(UPSTREAM)/dylib/embed_script.py
	@mkdir -p $(dir $@)
	python3 $(UPSTREAM)/dylib/embed_script.py $< $@ RUN_SCRIPT

$(BUILD)/dylib/feats/compat.o: $(RUN_HEADER)

$(BUILD)/%.o: $(UPSTREAM)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(ARM_DYLIB): $(DOBBY_BUILD)/libdobby.a $(OBJECTS)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS) $(DOBBY_LIBS) \
		-framework CoreFoundation -framework CoreGraphics -lc++

$(X86_STUB): $(UPSTREAM)/dylib/stub_x86_64.c
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -dynamiclib \
		-install_name @rpath/synthehol-steamplay.dylib -o $@ $<

$(DYLIB): $(ARM_DYLIB) $(X86_STUB)
	lipo -create $^ -output $@
	codesign -fs - $@

$(OVERLAY_ARM): $(UPSTREAM)/overlay-shim/overlay_shim.m
	@mkdir -p $(dir $@)
	$(CC) -arch arm64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -O2 -Wall -Wextra \
		-install_name @rpath/synthehol-overlay-shim.dylib \
		-framework Metal -framework QuartzCore -framework CoreGraphics \
		-framework CoreFoundation -o $@ $<

$(OVERLAY_X86): $(UPSTREAM)/overlay-shim/overlay_shim.m
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -O2 -Wall -Wextra \
		-install_name @rpath/synthehol-overlay-shim.dylib \
		-framework Metal -framework QuartzCore -framework CoreGraphics \
		-framework CoreFoundation -o $@ $<

$(OVERLAY): $(OVERLAY_ARM) $(OVERLAY_X86)
	lipo -create $^ -output $@
	codesign -fs - $@

payload: all
	@mkdir -p $(PAYLOAD)/signatures/macos.arm64
	cp -f $(DYLIB) $(PAYLOAD)/synthehol-steamplay.dylib
	cp -f $(OVERLAY) $(PAYLOAD)/synthehol-overlay-shim.dylib
	cp -f $(UPSTREAM)/dylib/feats/compat_run.sh $(PAYLOAD)/run
	cp -f $(UPSTREAM)/signatures/macos.arm64/*.json $(PAYLOAD)/signatures/macos.arm64/
	chmod 755 $(PAYLOAD)/run

clean:
	rm -rf $(BUILD)

-include $(DEPS)
