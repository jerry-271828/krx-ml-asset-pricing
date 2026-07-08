#!/usr/bin/env bash
# ==============================================================================
# Local / CI build script: cross-compile PyTorch for aarch64-linux-ohos
#
# Usage (after setting up OHOS toolchain):
#   source scripts/build-pytorch-ohos.sh
#   build_openblas
#   build_pytorch /path/to/pytorch-src
#
# Or run directly:
#   bash scripts/build-pytorch-ohos.sh /path/to/pytorch-src
# ==============================================================================
set -euo pipefail

# ---- Configuration ----------------------------------------------------------
OHOS_NATIVE="${OHOS_NATIVE:-$HOME/ohos-native/native}"
OHOS_SYSROOT="${OHOS_SYSROOT:-$OHOS_NATIVE/sysroot}"
OHOS_TARGET="aarch64-linux-ohos"
OPENBLAS_VER="${OPENBLAS_VER:-0.3.28}"
OPENBLAS_PREFIX="${OPENBLAS_PREFIX:-/tmp/openblas-ohos}"
PYTORCH_SRC="${1:-}"

# ---- Toolchain validation ---------------------------------------------------
validate_toolchain() {
    test -x "$OHOS_NATIVE/llvm/bin/clang"  || { echo "ERROR: clang not found at $OHOS_NATIVE/llvm/bin/clang" >&2; return 1; }
    test -x "$OHOS_NATIVE/llvm/bin/clang++" || { echo "ERROR: clang++ not found" >&2; return 1; }
    test -d "$OHOS_SYSROOT"                  || { echo "ERROR: sysroot not found at $OHOS_SYSROOT" >&2; return 1; }

    if ! "$OHOS_NATIVE/llvm/bin/ld.lld" --help 2>&1 | grep -F -- '--code-sign' >/dev/null; then
        echo "ERROR: lld lacks --code-sign. Use OHOS SDK >= 7.0-Beta1" >&2; return 1
    fi

    echo "[OK] Toolchain validated: $OHOS_NATIVE"
    echo "     clang: $($OHOS_NATIVE/llvm/bin/clang --version | head -1)"
}

# ---- Cross-compilation environment ------------------------------------------
setup_env() {
    export CC="$OHOS_NATIVE/llvm/bin/clang"
    export CXX="$OHOS_NATIVE/llvm/bin/clang++"
    export AR="$OHOS_NATIVE/llvm/bin/llvm-ar"
    export RANLIB="$OHOS_NATIVE/llvm/bin/llvm-ranlib"
    export STRIP="$OHOS_NATIVE/llvm/bin/llvm-strip"
    export LD="$OHOS_NATIVE/llvm/bin/ld.lld"

    TARGET_FLAGS="--target=$OHOS_TARGET --sysroot=$OHOS_SYSROOT -fPIC -D__MUSL__ -D__OHOS__"

    export CFLAGS="$TARGET_FLAGS ${CFLAGS:-}"
    export CXXFLAGS="$TARGET_FLAGS ${CXXFLAGS:-}"
    # For shared libraries (Python extensions): -shared, --code-sign
    export LDFLAGS="--target=$OHOS_TARGET --sysroot=$OHOS_SYSROOT -Wl,--code-sign ${LDFLAGS:-}"
    # For executables: -static-pie, --code-sign
    export LDFLAGS_EXE="--target=$OHOS_TARGET --sysroot=$OHOS_SYSROOT -static-pie -Wl,--code-sign"

    echo "[OK] Cross-compilation environment set"
    echo "     CC=$CC"
    echo "     CXX=$CXX"
    echo "     CFLAGS=$CFLAGS"
    echo "     LDFLAGS=$LDFLAGS"
}

# ---- Build OpenBLAS ---------------------------------------------------------
build_openblas() {
    if [ -f "$OPENBLAS_PREFIX/lib/libopenblas.a" ]; then
        echo "[SKIP] OpenBLAS already built at $OPENBLAS_PREFIX"
        return 0
    fi

    echo "=== Building OpenBLAS v$OPENBLAS_VER for $OHOS_TARGET ==="

    local workdir="$(mktemp -d)"
    trap "rm -rf $workdir" EXIT

    curl -fL --retry 3 \
        -o "$workdir/openblas.tar.gz" \
        "https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v${OPENBLAS_VER}.tar.gz"
    tar xzf "$workdir/openblas.tar.gz" -C "$workdir"
    cd "$workdir/OpenBLAS-${OPENBLAS_VER}"

    make -j"$(nproc)" \
        TARGET=ARMV8 \
        BINARY=64 \
        CC="$CC" \
        AR="$AR" \
        RANLIB="$RANLIB" \
        HOSTCC=gcc \
        NO_SHARED=0 \
        NO_LAPACK=1 \
        NO_FORTRAN=1 \
        NO_AFFINITY=1 \
        USE_OPENMP=0 \
        COMMON_OPT="$TARGET_FLAGS"

    make install PREFIX="$OPENBLAS_PREFIX" NO_SHARED=0 NO_LAPACK=1
    echo "[OK] OpenBLAS installed to $OPENBLAS_PREFIX"
}

# ---- Build PyTorch via CMake ------------------------------------------------
build_pytorch() {
    local src="${1:-$PYTORCH_SRC}"
    if [ -z "$src" ] || [ ! -f "$src/CMakeLists.txt" ]; then
        echo "ERROR: PyTorch source not found at $src" >&2
        echo "Usage: build_pytorch /path/to/pytorch" >&2
        return 1
    fi

    echo "=== Cross-compiling PyTorch at $src for $OHOS_TARGET ==="
    cd "$src"

    # Host Python info (for codegen scripts)
    HOST_PYTHON_INCLUDE=$(python3 -c "import sysconfig; print(sysconfig.get_path('include'))")
    HOST_NUMPY_INCLUDE=$(python3 -c "import numpy; print(numpy.get_include())" 2>/dev/null || echo "")

    mkdir -p build-ohos && cd build-ohos

    # PyTorch CMake configuration for cross-compilation.
    # We pre-set try_run results to avoid CMake errors during cross-compilation.
    cmake .. \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$OLDPWD/../../cmake/toolchain-ohos.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=./install \
        -DPYTHON_EXECUTABLE="$(which python3)" \
        -DPYTHON_INCLUDE_DIR="$HOST_PYTHON_INCLUDE" \
        -DNUMPY_INCLUDE_DIR="$HOST_NUMPY_INCLUDE" \
        \
        `# BLAS` \
        -DBLAS=OpenBLAS \
        -DOpenBLAS_INCLUDE_DIR="$OPENBLAS_PREFIX/include" \
        -DOpenBLAS_LIBRARIES="$OPENBLAS_PREFIX/lib/libopenblas.a" \
        \
        `# Disable CUDA & accelerators` \
        -DUSE_CUDA=OFF \
        -DUSE_CUDNN=OFF \
        -DUSE_MKLDNN=OFF \
        -DUSE_NNPACK=OFF \
        -DUSE_QNNPACK=OFF \
        -DUSE_XNNPACK=OFF \
        -DUSE_FBGEMM=OFF \
        -DUSE_KINETO=OFF \
        -DUSE_PRECOMPILED_HEADERS=OFF \
        \
        `# Disable distributed & extra features` \
        -DUSE_DISTRIBUTED=OFF \
        -DUSE_MPI=OFF \
        -DUSE_GLOO=OFF \
        -DUSE_TENSORPIPE=OFF \
        \
        `# Minimal build` \
        -DBUILD_TEST=OFF \
        -DBUILD_CAFFE2=OFF \
        -DBUILD_CAFFE2_OPS=OFF \
        -DBUILD_PYTHON=ON \
        -DBUILD_SHARED_LIBS=ON \
        \
        `# Python` \
        -DUSE_SYSTEM_BLAS=ON \
        -DUSE_SYSTEM_CPUINFO=OFF \
        -DUSE_SYSTEM_SLEEF=OFF \
        -DUSE_SYSTEM_PYBIND11=OFF \
        \
        `# Cross-compilation cache: tell CMake the answers` \
        -DHAVE_SYSCONF_GET_NPROCESSORS_CONF_EXITCODE=0 \
        -DHAVE_SYSCONF_GET_NPROCESSORS_CONF_EXITCODE__TRYRUN_OUTPUT="16"

    # Build
    cmake --build . -j"$(nproc)" --target torch_python

    echo "[OK] PyTorch built in build-ohos/"
}

# ---- Sign all .so files -----------------------------------------------------
sign_artifacts() {
    local build_dir="${1:-build-ohos}"
    echo "=== Signing .so files in $build_dir ==="

    while IFS= read -r -d '' so; do
        # Skip symlinks
        [ -L "$so" ] && continue
        # Check if already signed
        if "$OHOS_NATIVE/llvm/bin/llvm-readelf" -S "$so" 2>/dev/null | grep -q codesign; then
            echo "  SIGNED: $so"
            continue
        fi
        echo "  UNSIGNED: $so (must re-link with -Wl,--code-sign)"
    done < <(find "$build_dir" -name "*.so" -type f -print0)
}

# ---- Verify signatures ------------------------------------------------------
verify_signatures() {
    local build_dir="${1:-build-ohos}"
    echo "=== Verifying code signatures ==="

    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    local verify_py="$script_dir/verify-codesign.py"

    local all_ok=true
    while IFS= read -r -d '' so; do
        [ -L "$so" ] && continue
        if python3 "$verify_py" "$so"; then
            echo "  VERIFIED: $so"
        else
            echo "  FAIL: $so"
            all_ok=false
        fi
    done < <(find "$build_dir" -name "*.so" -type f -print0)

    if [ "$all_ok" = false ]; then
        echo "Some signatures failed!" >&2
        return 1
    fi
    echo "[OK] All signatures verified"
}

# ---- Main -------------------------------------------------------------------
main() {
    validate_toolchain
    setup_env
    build_openblas
    build_pytorch "$PYTORCH_SRC"
    sign_artifacts
    verify_signatures
    echo ""
    echo "============================================"
    echo " Build complete!"
    echo " Output: pytorch-src/build-ohos/"
    echo "============================================"
}

# Allow sourcing for individual function use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
