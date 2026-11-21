# CMake toolchain file for QNX 8.0 on x86_64 with qcc (source qnxsdp-env.sh first).
set(CMAKE_SYSTEM_NAME QNX)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER qcc)
set(CMAKE_C_COMPILER_TARGET gcc_ntox86_64)
