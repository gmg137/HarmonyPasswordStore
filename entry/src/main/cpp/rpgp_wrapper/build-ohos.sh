#!/usr/bin/env bash
# 交叉编译 rpgp_wrapper 静态库并更新 third_party 下的产物。
#
# 静态库（librpgp_wrapper.a / librpgp_wrapper_x64.a）已随仓库预编译，
# 仅在修改 Rust 代码后需要执行本脚本；host 侧单元测试不经它，直接
# `cargo test --release` 即可。
#
# 用法: ./build-ohos.sh [aarch64|x86_64|all] [--release|--debug]
#
# 工具链定位（取第一个存在 llvm/bin 的）：
#   $HPS_SDK_NATIVE                                          直接指定 native 目录
#   $DEVECO_SDK_HOME/openharmony/native                      DEVECO_SDK_HOME 已含 default 层
#   $DEVECO_SDK_HOME/default/openharmony/native              devecocli / DevEco Studio wrapper 注入的布局
#   $HOME/.deveco-cli-clt/sdk/default/openharmony/native     deveco-cli-clt 默认安装位置
#
# 工具链路径全部经环境变量注入（CARGO_TARGET_*_LINKER / CARGO_TARGET_*_RUSTFLAGS /
# cc crate 的 CC_/AR_/CFLAGS_），不在 .cargo/config.toml 里保存任何绝对路径——
# 每台机器的 SDK 安装位置不同，config.toml 无法引用环境变量。
set -euo pipefail

cd "$(dirname "$0")"

profile=release
flag=--release
targets=()
for arg in "$@"; do
  case "$arg" in
    --release) profile=release; flag=--release ;;
    --debug)   profile=dev;     flag="" ;;
    aarch64|x86_64|all) targets+=("$arg") ;;
    *) echo "未知参数: $arg（用法: $0 [aarch64|x86_64|all] [--release|--debug]）" >&2; exit 1 ;;
  esac
done
[[ ${#targets[@]} -eq 0 ]] && targets=(all)

SDK_NATIVE=""
if [[ -n "${HPS_SDK_NATIVE:-}" ]]; then
  SDK_NATIVE="$HPS_SDK_NATIVE"
else
  base="${DEVECO_SDK_HOME:-$HOME/.deveco-cli-clt/sdk/default}"
  for cand in "$base/openharmony/native" "$base/default/openharmony/native"; do
    if [[ -d "$cand/llvm/bin" ]]; then SDK_NATIVE="$cand"; break; fi
  done
fi
if [[ -z "$SDK_NATIVE" || ! -x "$SDK_NATIVE/llvm/bin/llvm-ar" ]]; then
  echo "错误: 未找到 OHOS native 工具链（llvm/bin/llvm-ar）。" >&2
  echo "请设置 DEVECO_SDK_HOME 指向 HarmonyOS SDK 根目录，或用 HPS_SDK_NATIVE 直接指定 native 目录。" >&2
  exit 1
fi

build_one() {
  local arch="$1" triple out uc prof_dir
  case "$arch" in
    aarch64) triple=aarch64-unknown-linux-ohos; out=../third_party/rpgp_wrapper/librpgp_wrapper.a ;;
    x86_64)  triple=x86_64-unknown-linux-ohos;  out=../third_party/rpgp_wrapper/librpgp_wrapper_x64.a ;;
  esac
  uc="${triple//-/_}"; uc="${uc^^}"
  # 注意：cc crate 的变量名带连字符（CC_<triple>），bash 的 export 不接受，
  # 必须经 env 前缀注入；CARGO_TARGET_* 同样一并交给 env
  env \
    "CARGO_TARGET_${uc}_LINKER=$SDK_NATIVE/llvm/bin/${triple}-clang" \
    "CARGO_TARGET_${uc}_RUSTFLAGS=-C link-arg=--sysroot=$SDK_NATIVE/sysroot -C link-arg=-fuse-ld=lld" \
    "CC_${triple}=$SDK_NATIVE/llvm/bin/${triple}-clang" \
    "AR_${triple}=$SDK_NATIVE/llvm/bin/llvm-ar" \
    "CFLAGS_${triple}=--sysroot=$SDK_NATIVE/sysroot" \
    cargo build --target "$triple" $flag
  cp "target/$triple/$profile/librpgp_wrapper.a" "$out"
  # 裁剪调试段（--strip-debug 保留符号表，仍可链接）：产物随仓库入库，每架构
  # 约 -6 MB。CMake 侧还有一道内容守卫的兜底裁剪，这里做是为了让入库的 .a
  # 本身就是裁剪过的。
  "$SDK_NATIVE/llvm/bin/llvm-strip" --strip-debug "$out"
  echo "已更新 $(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
}

for t in "${targets[@]}"; do
  if [[ "$t" == all ]]; then
    build_one aarch64
    build_one x86_64
  else
    build_one "$t"
  fi
done
