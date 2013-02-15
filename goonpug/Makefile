# Copyright (c) 2013 Peter Rowlands

HL2SDK_CSGO = ../hl2sdk-csgo
MMSOURCE = ../mmsource-central

PROJECT = goonpug
OBJECTS = goonpug.cpp

ifndef BUILD_DIR
	BUILD_DIR = ../build
endif

VERSION_HEADER = version.h

CFLAGS += -Wall
OPT_FLAGS = -O3 -funroll-loops -pipe
GCC4_FLAGS = -fvisibility=hidden -fvisibility-inlines-hidden
DEBUG_FLAGS = -g -ggdb3 -D_DEBUG
CPP = gcc
CPP_OSX = clang

HL2SDK = $(HL2SDK_CSGO)
CFLAGS += -DSOURCE_ENGINE=12

HL2PUB = $(HL2SDK)/public

INCLUDE += -I$(HL2SDK)/public/game/server
METAMOD = $(MMSOURCE)/core

OS := $(shell uname -s)
ENGINE = csgo

ifeq "$(OS)" "Darwin"
	LIB_EXT = dylib
	HL2LIB = $(HL2SDK)/lib/mac
else
	LIB_EXT = so
	HL2LIB = $(HL2SDK)/lib/linux
endif

LIB_PREFIX = lib
LIB_SUFFIX = .$(LIB_EXT)

CFLAGS += -DSE_EPISODEONE=1 -DSE_DARKMESSIAH=2 -DSE_ORANGEBOX=3 -DSE_BLOODYGOODTIME=4 -DSE_EYE=5 \
	-DSE_CSS=6 -DSE_ORANGEBOXVALVE=7 -DSE_LEFT4DEAD=8 -DSE_LEFT4DEAD2=9 -DSE_ALIENSWARM=10 \
	-DSE_PORTAL2=11 -DSE_CSGO=12

LINK += $(HL2LIB)/tier1_i486.a $(LIB_PREFIX)vstdlib$(LIB_SUFFIX) $(LIB_PREFIX)tier0$(LIB_SUFFIX)

ifeq "$(ENGINE)" "csgo"
	LINK += $(HL2LIB)/interfaces_i486.a
endif

INCLUDE += -I. -I.. -I$(HL2PUB) -I$(HL2PUB)/engine -I$(HL2PUB)/mathlib -I$(HL2PUB)/vstdlib \
	-I$(HL2PUB)/tier0 -I$(HL2PUB)/tier1 -I. -I$(METAMOD) -I$(METAMOD)/sourcehook

BINARY = $(PROJECT).$(LIB_EXT)

ifeq "$(OS)" "Darwin"
	CPP = $(CPP_OSX)
	LIB_EXT = dylib
	CFLAGS += -DOSX -D_OSX
	LINK += -dynamiclib -lstdc++ -mmacosx-version-min=10.5
else
	LIB_EXT = so
	CFLAGS += -D_LINUX
	LINK += -shared
endif

IS_CLANG := $(shell $(CPP) --version | head -1 | grep clang > /dev/null && echo "1" || echo "0")

ifeq "$(IS_CLANG)" "1"
	CPP_MAJOR := $(shell $(CPP) --version | grep clang | sed "s/.*version \([0-9]\)*\.[0-9]*.*/\1/")
	CPP_MINOR := $(shell $(CPP) --version | grep clang | sed "s/.*version [0-9]*\.\([0-9]\)*.*/\1/")
else
	CPP_MAJOR := $(shell $(CPP) -dumpversion >&1 | cut -b1)
	CPP_MINOR := $(shell $(CPP) -dumpversion >&1 | cut -b3)
endif

CFLAGS += -DPOSIX -Dstricmp=strcasecmp -D_stricmp=strcasecmp -D_strnicmp=strncasecmp \
	-Dstrnicmp=strncasecmp -D_snprintf=snprintf -D_vsnprintf=vsnprintf -D_alloca=alloca \
	-Dstrcmpi=strcasecmp -DCOMPILER_GCC -Wall -Wno-non-virtual-dtor -Wno-overloaded-virtual \
	-Werror -fPIC -fno-exceptions -fno-rtti -msse -m32 -fno-strict-aliasing

# Clang || GCC >= 4
ifeq "$(shell expr $(IS_CLANG) \| $(CPP_MAJOR) \>= 4)" "1"
	CFLAGS += $(GCC4_FLAGS)
endif

# Clang >= 3 || GCC >= 4.7
ifeq "$(shell expr $(IS_CLANG) \& $(CPP_MAJOR) \>= 3 \| $(CPP_MAJOR) \>= 4 \& $(CPP_MINOR) \>= 7)" "1"
	CFLAGS += -Wno-delete-non-virtual-dtor
endif

# OS is Linux and not using clang
ifeq "$(shell expr $(OS) \= Linux \& $(IS_CLANG) \= 0)" "1"
	LINK += -static-libgcc
endif

BIN_DIR = $(BUILD_DIR)/Release.$(ENGINE)

all: gitversion builddir hl2lib goonpug

builddir:
	mkdir -p $(BIN_DIR)

hl2lib:
	ln -sf $(HL2LIB)/$(LIB_PREFIX)vstdlib$(LIB_SUFFIX)
	ln -sf $(HL2LIB)/$(LIB_PREFIX)tier0$(LIB_SUFFIX)

debug: BIN_DIR = $(BUILD_DIR)/Debug.$(ENGINE)
debug: CFLAGS += $(DEBUG_FLAGS)
debug: OPT_FLAGS = 
debug: all

release: all

OBJ_BIN := $(OBJECTS:%.cpp=$(BIN_DIR)/%.o)

$(BIN_DIR)/%.o: %.cpp
	$(CPP) $(INCLUDE) $(CFLAGS) $(OPT_FLAGS) -o $@ -c $<

goonpug: $(OBJ_BIN)
	$(CPP) $(INCLUDE) -m32 $(OBJ_BIN) $(LINK) -ldl -lm -o $(BIN_DIR)/$(BINARY)

default: all

clean: 
	rm -rf $(BIN_DIR)/*.o
	rm -rf $(BIN_DIR)/$(BINARY)

.PHONY: gitversion
gitversion:
	@(GOONPUG_VERSION="" ; \
		[ -e "$(VERSION_HEADER)" ] && GOONPUG_VERSION=$$(grep "define GOONPUG_VERSION " $(VERSION_HEADER) | cut -f3 -d" " | sed 's/"//g') ; \
		GIT_VERSION=$$(git describe --always --tags --dirty) ;\
		echo "GOONPUG_VERSION = $$GOONPUG_VERSION" ; \
		echo "GIT_VERSION = $$GIT_VERSION" ; \
		if [ "$${GIT_VERSION}" != "$${GOONPUG_VERSION}" ] ; then \
			echo "Updating version.h." ; \
			printf "#ifndef _VERSION_H_\n#define _VERSION_H_\n\n#define GOONPUG_VERSION \"$${GIT_VERSION}\"\n\n#endif /* ! _VERSION_H_ */\n" > $(VERSION_HEADER) ; \
			$(MAKE) clean ; \
		fi )
