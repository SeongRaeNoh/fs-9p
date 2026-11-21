# examples/qnx-unit with CMake: ctest on the host runs each test inside the QNX 8.0 guest through
# tools/qnx-run (CMAKE_CROSSCOMPILING_EMULATOR). Put the build folder inside the shared folder:
#   source qnxsdp-env.sh; export QNX_SHARE=...   (and QNX_SSH_PORT or QNX_SSH, see tools/qnx-run -h)
#   cmake -S . -B $QNX_SHARE/qnx-unit-build -DCMAKE_TOOLCHAIN_FILE=qnx-x86_64.cmake
#   cmake --build $QNX_SHARE/qnx-unit-build
#   ctest --test-dir $QNX_SHARE/qnx-unit-build --output-junit junit.xml
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
cmake_minimum_required(VERSION 3.21)
project(qnx_unit C)
enable_testing()
if(NOT CMAKE_CROSSCOMPILING_EMULATOR)
  set(CMAKE_CROSSCOMPILING_EMULATOR ${CMAKE_CURRENT_LIST_DIR}/../../tools/qnx-run)
endif()
set(CMAKE_C_STANDARD 11)
foreach(t test_ring test_msg test_pulse exit_status)
  add_executable(${t} tests/${t}.c)
endforeach()
add_test(NAME test_ring  COMMAND test_ring)
add_test(NAME test_msg   COMMAND test_msg)
add_test(NAME test_pulse COMMAND test_pulse)
# checks of the runner: a non-zero exit status reaches ctest (the test passes because it must fail),
# and a host path argument inside the share reaches the program as its guest path
add_test(NAME runner_exit_status COMMAND exit_status 3)
set_tests_properties(runner_exit_status PROPERTIES WILL_FAIL TRUE)
add_test(NAME runner_host_path_argument COMMAND exit_status 0 $<TARGET_FILE:exit_status>)
# A test that never ends (it waits in MsgReceive()), to check that ctest's TIMEOUT stops it inside the
# guest as well. It fails by design, so it is added only with -DQNX_UNIT_TIMEOUT_CHECK=ON.
add_executable(stuck_receive tests/stuck_receive.c)
option(QNX_UNIT_TIMEOUT_CHECK "add the test runner_timeout, which ctest stops after 5 s" OFF)
if(QNX_UNIT_TIMEOUT_CHECK)
  add_test(NAME runner_timeout COMMAND stuck_receive fork)
  set_tests_properties(runner_timeout PROPERTIES TIMEOUT 5)
endif()
