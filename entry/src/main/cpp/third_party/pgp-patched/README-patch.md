# pgp-patched（pgp 0.20.0 + ml-kem 0.3 适配）

本目录是上游 `pgp` 0.20.0 的本地副本，仅用于把其 `ml-kem` 依赖从 **0.2.1 升级到 0.3**，
以便启用 `draft-pqc`（RFC 9580 后量子算法，如 ML-KEM）后仍能编译。

## 为什么必须 patch

上游 `pgp 0.20.0` 在 `draft-pqc` feature 下依赖 `ml-kem 0.2.1`，而 `ml-kem 0.2.1`
是为 `kem 0.3.0-pre.0` 编写的；本项目同时依赖 `russh 0.63.3`，它强制 `ml-kem 0.3`
（要求 `kem 0.3.0` 正式版）。Cargo 会把 `kem` 统一到 0.3.0 正式版，导致 `ml-kem 0.2.1`
编译失败（18 个错误，`type Error is not a member of trait kem::Decapsulate` 等）。

因此无法直接 `cargo update`：必须在 pgp 侧改依赖版本并适配 API。

## 改动清单（共 4 个文件）

| 文件 | 改动 |
|---|---|
| `Cargo.toml` | `ml-kem` 依赖 `0.2.1` → `0.3`；移除 `deterministic` feature（0.3 已无此 feature，改为默认能力） |
| `src/crypto/ml_kem768_x25519.rs` | API 适配（见下） |
| `src/crypto/ml_kem1024_x448.rs` | API 适配（见下） |
| `src/types/params/public/ml_kem768_x25519.rs` | 类型与序列化适配 |
| `src/types/params/public/ml_kem1024_x448.rs` | 类型与序列化适配 |

## ml-kem 0.2 → 0.3 的 API 变更与对应改法

| 0.2 写法 | 0.3 写法 |
|---|---|
| `MlKem768Params` / `MlKem1024Params`（参数类型） | `MlKem768` / `MlKem1024`（参数集类型，`DecapsulationKey<MlKem768>`） |
| `KemCore::generate_deterministic(&d, &z)` 返回 `(dk, ek)` | `DecapsulationKey::<MlKem768>::from_seed(seed)`，seed 为 64 字节 `d‖z` |
| `EncodedSizeUser::from_bytes()`（无校验） | `EncapsulationKey::new()` 返回 `Result`（会校验编码） |
| `as_bytes()`（`EncodedSizeUser`） | `to_bytes()`（`KeyExport` trait） |
| `decapsulate(..)` 返回 `Result<SharedKey, _>` | 直接返回 `SharedKey`（不再有 `Result`） |
| `encapsulate(&mut rng)`（`rand_core 0.10` 的 `CryptoRng`） | `encapsulate_deterministic(&B32)`，见下方说明 |
| `Encapsulate` trait 导入 | 不再需要（改用 `encapsulate_deterministic`） |

### 关于 encapsulate 的特别处理

0.3 的 `encapsulate_with_rng` 要求 `rand_core 0.10` 的 `CryptoRng`，而本 crate 用的是
`rand 0.8`（`pgp` 的既有选择），两者**不是同一个 trait**，无法直接传入。

因此改用不取 RNG 的 `encapsulate_deterministic(&B32)`：自行用本 crate 的 CSPRNG 生成
32 字节随机数 `m` 再调用。语义与 `encapsulate_with_rng` 一致——后者内部同样只取
32 字节随机数。**注意**：`encapsulate_deterministic` 在上游标注为 "hazmat"，不可复用
同一个 `m`，本处每次调用都新生成随机数，故安全。

## 维护方式

上游 `pgp` 若发布已使用 `ml-kem 0.3`（或更高）的新版本，应删除本目录并改回
`pgp = { version = "<新版>", features = ["draft-pqc"] }`，同时移除
`rpgp_wrapper/Cargo.toml` 中的 `[patch.crates-io]` 段。

改动均以注释形式在源码中标注，便于对照上游 diff。
