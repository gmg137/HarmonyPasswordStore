# 第三方组件声明（THIRD PARTY NOTICES）

本仓库的二进制产物中包含以下第三方组件的预编译静态库（位于 `entry/src/main/cpp/third_party/`），它们按照各自的许可证重新分发：

| 组件 | 版本 | 用途 | 许可证 |
|------|------|------|--------|
| [libgit2](https://github.com/libgit2/libgit2) | 1.9.0 | Git 操作（clone / pull / push / commit） | GPLv2 with linking exception |
| [libssh2](https://github.com/libssh2/libssh2) | 1.11.1 | libgit2 的 SSH 传输后端（OpenSSL 后端编译） | BSD-3-Clause |
| [OpenSSL](https://www.openssl.org/) (libcrypto) | 3.0.15 | libssh2 的加密后端 | Apache-2.0 |
| [Mbed TLS](https://www.trustedfirmware.org/projects/mbed-tls/) | 2.28.8 | libgit2 的 TLS 后端 | Apache-2.0 |

`third_party/pgp-patched/` 是 [pgp](https://github.com/rpgp/rpgp) 0.20.0 的本地副本（仅将 `ml-kem` 依赖升级到 0.3 并适配其 API，见该目录 `README-patch.md`），以其原有的 MIT OR Apache-2.0 双许可证分发。

`third_party/rpgp_wrapper/` 内的 Rust 静态库由本仓库源码构建，其第三方依赖（`pgp`、`russh`、`tokio`、`ml-kem`、RustCrypto 系列等）的完整清单见 `rpgp_wrapper/Cargo.toml` / `Cargo.lock`，各依赖的许可证以其上游声明为准（均为 MIT / Apache-2.0 / BSD / ISC / Unicode 等宽松许可证）。

各组件的上游版权与许可证全文不在本文件中逐字附上，可在上表链接的上游仓库中查阅。
