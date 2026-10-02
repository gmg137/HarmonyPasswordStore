# HarmonyPasswordStore native 桥接模块
#
# 构建 NAPI 共享库 libnativebridge.so，
# 链接 libgit2（C）和 rpgp_wrapper（Rust）静态库。
cmake_minimum_required(VERSION 3.5.0)
project(nativebridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 裁剪策略：打进 HAP 的 .so 由 hvigor 的 DoNativeStrip 负责（见
# entry/build-profile.json5 的 nativeLib.debugSymbol.strip），而静态库与中间产物
# 不经过它，故在这里补两步：
#   - 链接前对预编译静态库做 --strip-debug（去掉调试段、保留符号表仍可链接）：
#     rpgp_wrapper 的两个归档各带约 6 MB 调试段，是 third_party 体积的大头；
#   - 链接后对刚产出的 libnativebridge.so 做 --strip-all（打包时会再裁一次）。
# 归档裁剪是「内容真变了才写回」的（strip_archive.cmake 比对 SHA256），否则每次
# 构建都刷新 .a 的 mtime，会让 Ninja 反复重链接。
find_program(HPS_STRIP_TOOL llvm-strip
  HINTS
    "${OHOS_SDK_NATIVE}/llvm/bin"
    "$ENV{DEVECO_SDK_HOME}/openharmony/native/llvm/bin"
    "$ENV{DEVECO_SDK_HOME}/default/openharmony/native/llvm/bin"
    "$ENV{HOME}/.deveco-cli-clt/sdk/default/openharmony/native/llvm/bin"
)
if(NOT HPS_STRIP_TOOL)
  message(WARNING "llvm-strip not found; native artifacts stay unstripped")
endif()

include_directories(${NATIVERENDER_ROOT_PATH})
include_directories(${NATIVERENDER_ROOT_PATH}/third_party/libgit2/include)
include_directories(${NATIVERENDER_ROOT_PATH}/third_party/rpgp_wrapper)

add_library(nativebridge SHARED
  hps_napi.cpp
)

# 按 ABI 选择对应架构的静态库（arm64-v8a / x86_64，模拟器为 x86_64）
if(OHOS_ARCH STREQUAL "x86_64")
  set(LIBGIT2_LIB ${NATIVERENDER_ROOT_PATH}/third_party/libgit2-x64/lib/libgit2.a)
  set(LIBSSH2_LIB ${NATIVERENDER_ROOT_PATH}/third_party/libssh2-x64/lib/libssh2.a)
  set(OPENSSL_DIR ${NATIVERENDER_ROOT_PATH}/third_party/openssl-x64)
  set(RPGP_LIB ${NATIVERENDER_ROOT_PATH}/third_party/rpgp_wrapper/librpgp_wrapper_x64.a)
  set(MBEDTLS_DIR ${NATIVERENDER_ROOT_PATH}/third_party/mbedtls-x64)
  set(TIME_LIB_ARCH x86_64-linux-ohos)
else()
  set(LIBGIT2_LIB ${NATIVERENDER_ROOT_PATH}/third_party/libgit2/lib/libgit2.a)
  set(LIBSSH2_LIB ${NATIVERENDER_ROOT_PATH}/third_party/libssh2/lib/libssh2.a)
  set(OPENSSL_DIR ${NATIVERENDER_ROOT_PATH}/third_party/openssl)
  set(RPGP_LIB ${NATIVERENDER_ROOT_PATH}/third_party/rpgp_wrapper/librpgp_wrapper.a)
  set(MBEDTLS_DIR ${NATIVERENDER_ROOT_PATH}/third_party/mbedtls)
  set(TIME_LIB_ARCH aarch64-linux-ohos)
endif()

# libgit2 静态库（OHOS 交叉编译产物）
add_library(libgit2 STATIC IMPORTED)
set_target_properties(libgit2 PROPERTIES
  IMPORTED_LOCATION ${LIBGIT2_LIB}
)

# libssh2 静态库（libgit2 的 SSH 传输后端，OHOS 交叉编译产物）
#
# libgit2 编译时必须带 -DUSE_SSH=libssh2，否则其 ssh 传输会编成桩函数，
# git@host:path / ssh:// 一律报「不支持的协议」（原先就是这样）。
#
# **必须用 OpenSSL 后端**：libssh2 的 mbedTLS 后端把 LIBSSH2_ED25519 硬编码为 0
# （mbedtls.c 里根本没有 ed25519 实现），于是客户端既不提供 ssh-ed25519 主机密钥
# 算法、也不能用 ed25519 用户密钥签名——而本应用生成的正是 ed25519 密钥，克隆
# 必然失败（实测：能连上但 KEX 阶段就被对端以「no matching host key type」拒绝）。
add_library(ssh2 STATIC IMPORTED)
set_target_properties(ssh2 PROPERTIES
  IMPORTED_LOCATION ${LIBSSH2_LIB}
)

# OpenSSL libcrypto（仅 libssh2 的 OpenSSL 后端需要，与 mbedTLS 互不冲突）
include_directories(${OPENSSL_DIR}/include)
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES
  IMPORTED_LOCATION ${OPENSSL_DIR}/lib64/libcrypto.a
)

# mbedTLS 静态库（libgit2 TLS 后端，OHOS 交叉编译产物）
add_library(mbedtls STATIC IMPORTED)
add_library(mbedx509 STATIC IMPORTED)
add_library(mbedcrypto STATIC IMPORTED)
set_target_properties(mbedtls PROPERTIES IMPORTED_LOCATION ${MBEDTLS_DIR}/lib/libmbedtls.a)
set_target_properties(mbedx509 PROPERTIES IMPORTED_LOCATION ${MBEDTLS_DIR}/lib/libmbedx509.a)
set_target_properties(mbedcrypto PROPERTIES IMPORTED_LOCATION ${MBEDTLS_DIR}/lib/libmbedcrypto.a)

# rpgp_wrapper 静态库（Rust rpgp FFI，OHOS 交叉编译产物）
add_library(rpgp_wrapper STATIC IMPORTED)
set_target_properties(rpgp_wrapper PROPERTIES
  IMPORTED_LOCATION ${RPGP_LIB}
)

# NAPI 头文件与日志库由 DevEco 构建系统自动注入
find_library(hilog-lib hilog_ndk.z)
# time_service_ndk: Rust std 依赖的系统时间库
# find_library 在 OHOS 构建系统中找不到它，直接用 sysroot 路径
set(TIME_LIB ${CMAKE_CURRENT_SOURCE_DIR}/third_party/sysroot/usr/lib/${TIME_LIB_ARCH}/libtime_service_ndk.so)
# 回退到 SDK sysroot 路径：优先 DEVECO_SDK_HOME（devecocli / DevEco Studio 构建时注入，
# 兼容「…/sdk」与「…/sdk/default」两种布局），否则尝试 deveco-cli-clt 的默认安装位置
if(NOT EXISTS ${TIME_LIB})
  set(OHOS_NDK_CANDIDATES
    "$ENV{DEVECO_SDK_HOME}/openharmony/native"
    "$ENV{DEVECO_SDK_HOME}/default/openharmony/native"
    "$ENV{HOME}/.deveco-cli-clt/sdk/default/openharmony/native"
  )
  foreach(OHOS_NDK IN LISTS OHOS_NDK_CANDIDATES)
    if(OHOS_NDK AND EXISTS "${OHOS_NDK}/sysroot/usr/lib/${TIME_LIB_ARCH}/libtime_service_ndk.so")
      set(TIME_LIB "${OHOS_NDK}/sysroot/usr/lib/${TIME_LIB_ARCH}/libtime_service_ndk.so")
      break()
    endif()
  endforeach()
  if(NOT EXISTS ${TIME_LIB})
    message(FATAL_ERROR
      "未找到 libtime_service_ndk.so（sysroot: ${TIME_LIB_ARCH}）。"
      "请设置 DEVECO_SDK_HOME 指向 HarmonyOS SDK 根目录（其下应有 openharmony/native/sysroot）。")
  endif()
endif()
target_link_libraries(nativebridge
  PUBLIC
  libace_napi.z.so
  ${hilog-lib}
  ${TIME_LIB}
  libgit2
  # libssh2 必须排在 libgit2 之后（静态库按序解析未定义符号），
  # crypto 再排在 libssh2 之后（libssh2 的 OpenSSL 后端依赖 libcrypto）
  ssh2
  crypto
  mbedtls
  mbedx509
  mbedcrypto
  rpgp_wrapper
  z
)

if(HPS_STRIP_TOOL)
  # 链接前逐个裁剪本 ABI 用到的静态库（内容守卫，避免无谓刷新 mtime）
  set(HPS_ARCHIVES
    ${LIBGIT2_LIB}
    ${LIBSSH2_LIB}
    ${OPENSSL_DIR}/lib64/libcrypto.a
    ${MBEDTLS_DIR}/lib/libmbedtls.a
    ${MBEDTLS_DIR}/lib/libmbedx509.a
    ${MBEDTLS_DIR}/lib/libmbedcrypto.a
    ${RPGP_LIB}
  )
  foreach(HPS_ARCHIVE IN LISTS HPS_ARCHIVES)
    add_custom_command(TARGET nativebridge PRE_BUILD
      COMMAND ${CMAKE_COMMAND}
        -DSTRIP_TOOL=${HPS_STRIP_TOOL}
        -DARCHIVE=${HPS_ARCHIVE}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/strip_archive.cmake
      VERBATIM)
  endforeach()

  # 链接后裁剪刚产出的 .so，中间产物也不再带调试段
  add_custom_command(TARGET nativebridge POST_BUILD
    COMMAND ${HPS_STRIP_TOOL} --strip-all $<TARGET_FILE:nativebridge>
    COMMENT "strip libnativebridge.so (${OHOS_ARCH})"
    VERBATIM)
endif()
