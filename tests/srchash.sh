#!/bin/sh
# tests/srchash.sh - print the first 12 hex digits of the sha256 of the sources, as named in the
# first line of every log in tests/logs/. The file list is sorted with LC_ALL=C, so the value does
# not depend on the locale.
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
cd "$(dirname "$0")/.." || exit 1
LC_ALL=C; export LC_ALL
ls -d AGENTS.md Makefile src/*.c src/*.h tools/* image/* tests/*.c tests/*.sh tests/host/* demo/*.sh \
      examples/qnx-unit/*.* examples/qnx-unit/Makefile examples/qnx-unit/tests/* \
      examples/ci-crash/CMakeLists.txt examples/ci-crash/src/* examples/ci-crash/tests/* \
      .github/workflows/* | sort | xargs cat |
    sha256sum | cut -c1-12
