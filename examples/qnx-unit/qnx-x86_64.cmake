# CMake toolchain file for QNX 8.0 on x86_64 with qcc (source qnxsdp-env.sh first).
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set(CMAKE_SYSTEM_NAME QNX)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER qcc)
set(CMAKE_C_COMPILER_TARGET gcc_ntox86_64)
# find_package() and find_library() look in the SDP's target folders (QNX_TARGET, set by
# qnxsdp-env.sh), not on the Linux host; programs such as cmake itself come from the host.
set(CMAKE_FIND_ROOT_PATH $ENV{QNX_TARGET} $ENV{QNX_TARGET}/x86_64)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
