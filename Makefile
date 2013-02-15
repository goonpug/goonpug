# Copyright (c) 2013 Peter Rowlands

DIRS = goonpug
BUILDDIRS = $(DIRS:%=build-%)
BUILDDIRS_DEBUG = $(DIRS:%=build-debug-%)
CLEANDIRS = $(DIRS:%=clean-%)
TESTDIRS = $(DIRS:%=test-%)

all: $(BUILDDIRS)
$(DIRS): $(BUILDDIRS)
$(BUILDDIRS):
	$(MAKE) -C $(@:build-%=%)

debug: $(BUILDDIRS_DEBUG)
$(BUILDDIRS_DEBUG):
	$(MAKE) -C $(@:build-debug-%=%) debug

build-plugin: build-goonpug
build-debug-plugin: build-goonpug

test:

clean: $(CLEANDIRS)
$(CLEANDIRS):
	$(MAKE) -C $(@:clean-%=%) clean

.PHONY: subdirs $(DIRS)
.PHONY: subdirs $(BUILDDIRS)
.PHONY: subdirs $(BUILDDIRS_DEBUG)
.PHONY: subdirs $(TESTDIRS)
.PHONY: subdirs $(CLEANDIRS)
.PHONY: all clean test
