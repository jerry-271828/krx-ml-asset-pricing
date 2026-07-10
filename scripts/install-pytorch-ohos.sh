#!/bin/bash
# 在 HarmonyOS 设备上安装 CI 交叉编译的 PyTorch wheel。
#
# 用法：
#   ./scripts/install-pytorch-ohos.sh <torch-*.whl>
#   （wheel 来自 GitHub Actions artifact "pytorch-ohos-v2.5.1"，
#     可用 gh run download <run-id> --name pytorch-ohos-v2.5.1 获取）
#
# pip 安装之外还需三步设备端处理，缺一不可：
#   1. wheel 里的 .so 无执行位 → chmod +x
#   2. 依赖 libc++_shared.so / libomp.so 不在默认搜索路径
#      → 从设备 harmonybrew 的 ohos-sdk 复制进 torch/lib（RUNPATH=$ORIGIN 可达）
#   3. HongMeng 内核校验代码签名，CI 的 --code-sign 段不被信任
#      → 用 ohos-pip-autosign 的钩子模块重新自签名（strip + 64KB 对齐 + selfSign）
set -euo pipefail

WHEEL="${1:?用法: $0 <torch-*.whl>}"
BREW="/storage/Users/currentUser/.harmonybrew"
HOOK_DIR="$BREW/Cellar/ohos-pip-autosign/1.0.0/libexec"

echo "==> pip 安装 $WHEEL"
pip3 install --break-system-packages --force-reinstall "$WHEEL"

SP=$(python3 -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")
TL="$SP/torch/lib"

echo "==> 从设备 SDK 补齐运行时依赖"
SDK_LIB=$(ls -d "$BREW"/Cellar/ohos-sdk/*/native/llvm/lib/aarch64-linux-ohos | sort -V | tail -1)
cp "$SDK_LIB/libc++_shared.so" "$SDK_LIB/libomp.so" "$TL/"

echo "==> 补执行位"
chmod +x "$TL"/*.so "$SP"/torch/*.so "$SP"/functorch/*.so "$SP"/torch/bin/* 2>/dev/null || true

echo "==> 设备端重签名（内核要求）"
python3 - "$SP" "$HOOK_DIR" <<'EOF'
import sys, glob
sp, hook_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, hook_dir)
import _ohos_pip_autosign_hook as hook
targets = sorted(
    glob.glob(f"{sp}/torch/lib/*.so")
    + glob.glob(f"{sp}/torch/*.so")
    + glob.glob(f"{sp}/functorch/*.so")
    + glob.glob(f"{sp}/torch/bin/*")
)
for t in targets:
    hook._perform_binary_sign(t)
print(f"signed {len(targets)} binaries")
EOF

echo "==> 验证"
python3 -c "import torch; print('torch', torch.__version__, 'import OK')"
