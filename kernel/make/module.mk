# Copyright 2016 The Fuchsia Authors
# Copyright (c) 2008-2015 Travis Geiselbrecht
#
# Use of this source code is governed by a MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT


# modules
#
# args:
# MODULE : module name (required)
# MODULE_SRCS : list of source files, local path (required)
# MODULE_DEPS : other modules that this one depends on
# MODULE_HEADER_DEPS : other headers that this one depends on, in addition to MODULE_DEPS
# MODULE_DEFINES : #defines local to this module
# MODULE_OPTFLAGS : OPTFLAGS local to this module
# MODULE_COMPILEFLAGS : COMPILEFLAGS local to this module
# MODULE_CFLAGS : CFLAGS local to this module
# MODULE_CPPFLAGS : CPPFLAGS local to this module
# MODULE_ASMFLAGS : ASMFLAGS local to this module
# MODULE_SRCDEPS : extra dependencies that all of this module's files depend on
# MODULE_EXTRA_OBJS : extra .o files that should be linked with the module
# MODULE_TYPE : "userapp" for userspace executables, "userlib" for userspace library,
#               "" for standard LK module

# the minimum module rules.mk file is as follows:
#
# LOCAL_DIR := $(GET_LOCAL_DIR)
# MODULE := $(LOCAL_DIR)
#
# MODULE_SRCS := $(LOCAL_DIR)/at_least_one_source_file.c
#
# include make/module.mk

MODULE_SRCDIR := $(MODULE)
MODULE_BUILDDIR := $(call TOBUILDDIR,$(MODULE_SRCDIR))

ifeq ($(MODULE_TYPE),)
# add a local include dir to the global include path for kernel code
GLOBAL_INCLUDES += $(MODULE_SRCDIR)/include
endif

# expand deps to canonical paths
MODULE_DEPS := $(foreach d,$(MODULE_DEPS),$(call modname-make-canonical,$(d)))
MODULE_HEADER_DEPS := $(foreach d,$(MODULE_HEADER_DEPS),$(call modname-make-canonical,$(strip $(d))))

# add the listed module deps to the global list
MODULES += $(MODULE_DEPS)

# add the headers to include to a list
HEADER_MODULE_DEPS := $(MODULE_DEPS)
HEADER_MODULE_DEPS += $(MODULE_HEADER_DEPS)

# compute our shortname, which has all of the build system prefix paths removed
MODULE_SHORTNAME = $(MODULE)
$(foreach pfx,$(LKPREFIXES),$(eval MODULE_SHORTNAME := $(patsubst $(pfx)%,%,$(MODULE_SHORTNAME))))

#$(info module $(MODULE))
#$(info MODULE_SRCDIR $(MODULE_SRCDIR))
#$(info MODULE_BUILDDIR $(MODULE_BUILDDIR))
#$(info MODULE_DEPS $(MODULE_DEPS))
#$(info MODULE_SRCS $(MODULE_SRCS))

MODULE_DEFINES += MODULE_COMPILEFLAGS=\"$(subst $(SPACE),_,$(MODULE_COMPILEFLAGS))\"
MODULE_DEFINES += MODULE_CFLAGS=\"$(subst $(SPACE),_,$(MODULE_CFLAGS))\"
MODULE_DEFINES += MODULE_CPPFLAGS=\"$(subst $(SPACE),_,$(MODULE_CPPFLAGS))\"
MODULE_DEFINES += MODULE_ASMFLAGS=\"$(subst $(SPACE),_,$(MODULE_ASMFLAGS))\"
MODULE_DEFINES += MODULE_OPTFLAGS=\"$(subst $(SPACE),_,$(MODULE_OPTFLAGS))\"
MODULE_DEFINES += MODULE_SRCDEPS=\"$(subst $(SPACE),_,$(MODULE_SRCDEPS))\"
MODULE_DEFINES += MODULE_DEPS=\"$(subst $(SPACE),_,$(MODULE_DEPS))\"
MODULE_DEFINES += MODULE_SRCS=\"$(subst $(SPACE),_,$(MODULE_SRCS))\"
MODULE_DEFINES += MODULE_HEADER_DEPS=\"$(subst $(SPACE),_,$(MODULE_HEADER_DEPS))\"
MODULE_DEFINES += MODULE_TYPE=\"$(subst $(SPACE),_,$(MODULE_TYPE))\"

# Introduce local, libc, and dependency include paths and defines
ifneq (,$(filter userapp userlib,$(MODULE_TYPE)))
# user app
MODULE_SRCDEPS += $(USER_CONFIG_HEADER)
MODULE_COMPILEFLAGS += -I$(LOCAL_DIR)/include
MODULE_COMPILEFLAGS += -Isystem/ulib/global/include
MODULE_COMPILEFLAGS += -Ithird_party/ulib/musl/include
MODULE_COMPILEFLAGS += -D_XOPEN_SOURCE=700
ifneq ($(MODULE),third_party/ulib/musl)
# musl has to carefully manipulate this define internally, so don't set it for it.
MODULE_COMPILEFLAGS += -D_BSD_SOURCE
endif
MODULE_COMPILEFLAGS += $(foreach DEP,$(HEADER_MODULE_DEPS),-I$(DEP)/include)
else
# kernel module
KERNEL_DEFINES += $(addsuffix =1,$(addprefix WITH_,$(MODULE_SHORTNAME)))
MODULE_SRCDEPS += $(KERNEL_CONFIG_HEADER)
endif

# generate a per-module config.h file
MODULE_CONFIG := $(MODULE_BUILDDIR)/module_config.h

$(MODULE_CONFIG): MODULE_DEFINES:=$(MODULE_DEFINES)
$(MODULE_CONFIG): configheader
	@$(call MAKECONFIGHEADER,$@,MODULE_DEFINES)

GENERATED += $(MODULE_CONFIG)

MODULE_COMPILEFLAGS += --include $(MODULE_CONFIG)

MODULE_SRCDEPS += $(MODULE_CONFIG)

# include the rules to compile the module's object files
ifeq ($(MODULE_TYPE),)
# for kernel code
include make/compile.mk
else
# for userspace code
include make/ucompile.mk
endif

# MODULE_OBJS is passed back from compile.mk
#$(info MODULE_OBJS = $(MODULE_OBJS))

# build a ld -r style combined object
MODULE_OBJECT := $(call TOBUILDDIR,$(MODULE_SRCDIR).mod.o)
$(MODULE_OBJECT): $(MODULE_OBJS) $(MODULE_EXTRA_OBJS)
	@$(MKDIR)
	@echo linking $@
	$(NOECHO)$(LD) $(GLOBAL_MODULE_LDFLAGS) -r $^ -o $@

# track all of the source files compiled
ALLSRCS += $(MODULE_SRCS)

# track all the objects built
ALLOBJS += $(MODULE_OBJS)

# track the module object for make clean
GENERATED += $(MODULE_OBJECT)

# track the requested install name of the module
ifeq ($(MODULE_NAME),)
MODULE_NAME := $(basename $(notdir $(MODULE)))
endif

ifeq ($(MODULE_TYPE),)
# make the rest of the build depend on our output
ALLMODULE_OBJS := $(ALLMODULE_OBJS) $(MODULE_OBJECT)
else ifeq ($(MODULE_TYPE),userapp)
MODULE_$(MODULE)_DEPS := $(MODULE_DEPS)
MODULE_USERAPP_OBJECT := $(patsubst %.mod.o,%.elf,$(MODULE_OBJECT))
ALLUSER_APPS += $(MODULE_USERAPP_OBJECT)
ALLUSER_MODULES += $(MODULE)
USER_MANIFEST_LINES += bin/$(MODULE_NAME)=$(addsuffix .strip,$(MODULE_USERAPP_OBJECT))
else ifeq ($(MODULE_TYPE),userlib)
MODULE_$(MODULE)_DEPS := $(MODULE_DEPS)

ifeq ($(ENABLE_BUILD_SYSROOT),true)
# exported modules have libraries and headers installed in sysroot/...
ifneq ($(MODULE_EXPORT),)

# where to install our static library:
MODULE_USERLIB_STATIC := $(BUILDDIR)/sysroot/lib/lib$(MODULE_EXPORT).a

# for now, unify all headers in one pile
# TODO: ddk, etc should be packaged separately
MODULE_INSTALL_HEADERS := $(BUILDDIR)/sysroot/include

MODULE_USERLIB_OBJS := $(MODULE_OBJS)

ifeq ($(MODULE_EXPORT),c)
# locate the crt files in libc, remove them from the objects list,
# and install them (under the expected name) as standalone .o files
CRT_NAMES := crt1.c.o crti.s.o crtn.s.o

$(foreach crt,$(CRT_NAMES),\
$(eval CRT_SRC := $(filter %/$(crt),$(MODULE_OBJS)))\
$(eval CRT_DST := $(BUILDDIR)/sysroot/lib/$(subst .s.o,.o,$(subst .c.o,.o,$(crt))))\
$(eval MODULE_USERLIB_OBJS := $(filter-out %/$(crt),$(MODULE_USERLIB_OBJS)))\
$(call copy-dst-src,$(CRT_DST),$(CRT_SRC))\
$(eval SYSROOT_DEPS += $(CRT_DST))\
$(eval GENERATED += $(CRT_DST)))
endif

ifeq ($(filter $(MODULE_EXPORT),$(SYSROOT_MEGA_LIBC)),)
# build a static library if not part of mega-libc
$(MODULE_USERLIB_STATIC): $(MODULE_USERLIB_OBJS)
	@$(MKDIR)
	@echo linking $@
	$(NOECHO)$(AR) cr $@ $^

SYSROOT_DEPS += $(MODULE_USERLIB_STATIC)
GENERATED += $(MODULE_USERLIB_STATIC)
else
SYSROOT_MEGA_LIBC_OBJS += $(MODULE_USERLIB_OBJS)
endif

# locate headers from module source public include dir
MODULE_PUBLIC_HEADERS := $(shell find $(MODULE_SRCDIR)/include -name \*\.h -or -name \*\.inc)
MODULE_PUBLIC_HEADERS := $(patsubst $(MODULE_SRCDIR)/include/%,%,$(MODULE_PUBLIC_HEADERS))

# translate them to the final destination
MODULE_PUBLIC_HEADERS := $(patsubst %,$(MODULE_INSTALL_HEADERS)/%,$(MODULE_PUBLIC_HEADERS))

# generate rules to copy them
$(call copy-dst-src,$(MODULE_INSTALL_HEADERS)/%.h,$(MODULE_SRCDIR)/include/%.h)
$(call copy-dst-src,$(MODULE_INSTALL_HEADERS)/%.inc,$(MODULE_SRCDIR)/include/%.inc)

SYSROOT_DEPS += $(MODULE_PUBLIC_HEADERS)
GENERATED += $(MODULE_PUBLIC_HEADERS)
endif
endif # if ENABLE_BUILD_SYSROOT true
endif # if MODULE_TYPE userlib

# empty out any vars set here
MODULE :=
MODULE_SHORTNAME :=
MODULE_SRCDIR :=
MODULE_BUILDDIR :=
MODULE_DEPS :=
MODULE_HEADER_DEPS :=
MODULE_SRCS :=
MODULE_OBJS :=
MODULE_DEFINES :=
MODULE_OPTFLAGS :=
MODULE_COMPILEFLAGS :=
MODULE_CFLAGS :=
MODULE_CPPFLAGS :=
MODULE_ASMFLAGS :=
MODULE_SRCDEPS :=
MODULE_EXTRA_OBJS :=
MODULE_CONFIG :=
MODULE_OBJECT :=
MODULE_TYPE :=
MODULE_NAME :=
MODULE_EXPORT :=
