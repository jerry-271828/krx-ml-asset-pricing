# CMake toolchain file for cross-compiling to HarmonyOS/OpenHarmony (aarch64-linux-ohos).
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=toolchain-ohos.cmake \
#         -DOHOS_NATIVE=/path/to/ohos-native/native \
#         ...
#
# Expected directory layout under OHOS_NATIVE:
#   llvm/bin/clang       — cross-compiler (clang with aarch64-linux-ohos support)
#   llvm/bin/ld.lld      — linker (must support --code-sign)
#   llvm/bin/llvm-ar     — archiver
#   sysroot/             — musl-based sysroot for aarch64-linux-ohos
#
# Reference: jerry-271828/iperf build-ohos.yml

# ---- Essential ----
set(OHOS_NATIVE "$ENV{OHOS_NATIVE}" CACHE PATH "OHOS native toolchain root")
set(OHOS_SYSROOT "$ENV{OHOS_SYSROOT}" CACHE PATH "OHOS musl sysroot")

if(NOT OHOS_NATIVE OR NOT OHOS_SYSROOT)
    message(FATAL_ERROR "OHOS_NATIVE and OHOS_SYSROOT must be set (env vars or -D flags)")
endif()

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(OHOS_TARGET aarch64-linux-ohos)

# ---- Compiler ----
set(CMAKE_C_COMPILER    "${OHOS_NATIVE}/llvm/bin/clang"   CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER  "${OHOS_NATIVE}/llvm/bin/clang++" CACHE FILEPATH "C++ compiler")
set(CMAKE_ASM_COMPILER  "${OHOS_NATIVE}/llvm/bin/clang"   CACHE FILEPATH "ASM compiler")
set(CMAKE_AR            "${OHOS_NATIVE}/llvm/bin/llvm-ar" CACHE FILEPATH "archiver")
set(CMAKE_RANLIB        "${OHOS_NATIVE}/llvm/bin/llvm-ranlib" CACHE FILEPATH "ranlib")
set(CMAKE_STRIP         "${OHOS_NATIVE}/llvm/bin/llvm-strip"  CACHE FILEPATH "strip")

# ---- Compiler flags ----
set(CMAKE_C_FLAGS_INIT   "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -D__OHOS__")
set(CMAKE_CXX_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -fPIC -D__MUSL__ -D__OHOS__")
# ASM 也必须带 --target，否则 .S 文件按 host x86_64 汇编（aarch64 指令全部报错）
set(CMAKE_ASM_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -fPIC")

# Linker: --code-sign embeds the .codesign section required by HarmonyOS kernel.
# NOTE: PyTorch 构建产物是 Python 扩展 .so，不是独立可执行文件，不需要 -static-pie。
# -static-pie 会导致 CMake try_compile 失败（sysroot 里某些库只有 .so 没有 .a）。
set(CMAKE_EXE_LINKER_FLAGS_INIT    "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -Wl,--code-sign")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -Wl,--code-sign")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "--target=${OHOS_TARGET} --sysroot=${OHOS_SYSROOT} -Wl,--code-sign")

# ---- Cross-compilation mode ----
set(CMAKE_CROSSCOMPILING TRUE)
set(CMAKE_C_COMPILER_TARGET   "${OHOS_TARGET}")
set(CMAKE_CXX_COMPILER_TARGET "${OHOS_TARGET}")
set(CMAKE_ASM_COMPILER_TARGET "${OHOS_TARGET}")

# ---- Search paths: only look in sysroot, never in host ----
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# ---- pkg-config within sysroot ----
set(PKG_CONFIG_EXECUTABLE "${OHOS_NATIVE}/llvm/bin/llvm-pkg-config" CACHE FILEPATH "pkg-config")
set(PKG_CONFIG_USE_CMAKE_PREFIX_PATH OFF)

# ---- Python for cross-compilation ----
# pybind11 (bundled with PyTorch) needs Python::Module CMake target.
# In cross-compilation mode, find_package(Python3) fails to create this target,
# so we manually create it from environment variables.
# PYTHON_INCLUDE_DIR and NUMPY_INCLUDE_DIR are set as shell env vars
# by the CI workflow before invoking setup.py.
if(NOT TARGET Python::Module AND DEFINED ENV{PYTHON_INCLUDE_DIR})
  add_library(Python::Module INTERFACE IMPORTED)
  set_target_properties(Python::Module PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$ENV{PYTHON_INCLUDE_DIR}")
  message(STATUS "Created Python::Module (cross-compilation): $ENV{PYTHON_INCLUDE_DIR}")
endif()
if(NOT TARGET Python::Python AND DEFINED ENV{PYTHON_INCLUDE_DIR})
  add_library(Python::Python INTERFACE IMPORTED)
  set_target_properties(Python::Python PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$ENV{PYTHON_INCLUDE_DIR}")
endif()

message(STATUS "OHOS toolchain loaded: target=${OHOS_TARGET}")
message(STATUS "  C compiler:   ${CMAKE_C_COMPILER}")
message(STATUS "  C++ compiler: ${CMAKE_CXX_COMPILER}")
message(STATUS "  sysroot:      ${OHOS_SYSROOT}")
