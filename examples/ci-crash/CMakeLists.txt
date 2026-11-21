# examples/ci-crash: a small CMake project whose tests fail in three different ways, to show what
# tools/qnx-ci.sh reports for each (demo/ci-crash.sh runs it):
#   parse_ok      passes
#   parse_crash   crashes on purpose: parse_record() reads a line without '=' and read_value() then
#                 reads through a null pointer (SIGSEGV); qnx-ci.sh writes gdb's backtrace of the
#                 core file into this test's JUnit <failure> element
#   child_crash   passes: a child process crashes on purpose and the test checks that it did; the
#                 child's core file is not a crash of the test
#   exit_one      fails with exit status 1 and no crash: no backtrace
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
cmake_minimum_required(VERSION 3.21)
project(ci_crash C)
enable_testing()
if(NOT CMAKE_CROSSCOMPILING_EMULATOR)
  set(CMAKE_CROSSCOMPILING_EMULATOR ${CMAKE_CURRENT_LIST_DIR}/../../tools/qnx-run)
endif()
set(CMAKE_C_STANDARD 11)
add_library(record STATIC src/record.c)
foreach(t parse_ok parse_crash child_crash exit_one)
  add_executable(${t} tests/${t}.c)
  target_link_libraries(${t} record)
  add_test(NAME ${t} COMMAND ${t})
endforeach()
