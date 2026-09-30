# HarmonyPasswordStore

[简体中文] | [English](README_en.md) | [Русский](README_ru.md) | [Deutsch](README_de.md) | [繁體中文](README_zh-TW.md)

[pass](https://www.passwordstore.org/) 密码管理器的 HarmonyOS（鸿蒙）原生客户端，兼容标准 pass 仓库格式，设计参考 [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)。应用显示名为 **PasswordStore**。

## 功能特性

| 功能 | 说明 |
|------|------|
| pass 完整兼容 | 标准目录结构与 GPG 加密条目（`.gpg`）；`.gpg-id` 支持每行一把密钥（指纹 / Key ID / 邮箱均可），兼容行尾注释与 `!` 强制子密钥标记，与 pass CLI 及桌面端生态互通 |
| 后量子加密（PQC） | 支持 GnuPG algo 8 密钥（ML-KEM-768 + X25519 / brainpoolP256r1 / brainpoolP384r1）的导入与加解密，与 gpg 2.5+ 双向互通；普通密钥与 PQC 密钥可作为同一条目的混合接收方 |
| 三种搜索模式 | 模糊 / 精确 / **内容匹配**——内容匹配会解密条目并检索除主密码以外的字段值（永不搜索密码本身），命中行附片段说明 |
| 密码生成 | 密码学安全随机源；长度、字符集、排除易混淆字符；Diceware 口令词组与熵值评估 |
| PGP 密钥管理 | 从文本或文件导入（armor 与二进制自动识别）、生成 EdDSA/RSA 密钥、修改密钥口令、导出 `.asc` 文件、默认加密密钥选择 |
| Git 同步 | SSH 与 HTTPS 的 clone / pull / push / commit；主机指纹 TOFU 三态校验（首连确认 / 已信任 / 同类型不匹配告警）；强制推送；拉取变基；HTTPS 代理 |
| 自动填充 | 对接系统自动填充框架，按包名 / 域名匹配凭据候选 |
| 生物识别解锁 | 指纹 / 面容（锁屏自动拉起系统认证）；会话超时自动上锁；上锁即清空内存中的口令与解密缓存 |
| 文件管理 | 目录树浏览、条目移动 / 重命名（跨密钥目录自动重加密）、目录创建与删除 |
| 密码文件格式 | 二进制（与桌面 pass 输出一致）或 ASCII armor，可随时切换（仅影响新写入） |
| 剪贴板安全 | 复制密码后定时自动清除；通过短时任务保障应用在后台时清除依然生效 |
| 多语言 | 简体中文、繁體中文、English、Deutsch、Русский（跟随系统，可在应用内切换） |

## 系统要求

- HarmonyOS 手机（API 26+）

## 构建与安装

首次构建前，先从模板生成本地签名配置（该文件含签名材料路径与口令，**不入库**）：

```bash
cp build-profile.example.json5 build-profile.json5
```

再用 DevEco Studio 打开工程，经 **File → Project Structure → Signing Configs** 勾选 Automatically generate signature 生成调试签名材料（命令行构建同样依赖该文件）。

然后即可用 [DevEco Studio](https://developer.huawei.com/consumer/harmonyos/)（含 HarmonyOS SDK）打开工程构建，或用命令行（Hvigor）：

```bash
hvigorw assembleHap                                            # 调试 HAP
hvigorw -p buildMode=release assembleHap                       # release（启用 ArkTS 混淆）
hvigorw -p product=default -p buildMode=release assembleApp    # 发布 .app 包
```

产物位置：HAP 在 `entry/build/default/outputs/default/`，.app 在项目根 `build/outputs/default/`。

PGP（Rust）与 Git（libgit2）的 native 静态库已随仓库预编译（aarch64 / x86_64 双 ABI），常规构建无需 Rust 工具链；如需修改 native 代码，见 `entry/src/main/cpp/rpgp_wrapper/`（Rust 侧单元测试：`cargo test --release`）。

## pass 仓库格式兼容

- 条目为 `<目录>/<名称>.gpg`，解密后首行是密码，后续行为 `user:` / `email:` / `phone:` / `notes:` 字段与自由文本
- 仓库根（及任意子目录）的 `.gpg-id` 指定加密公钥，支持多把密钥与全部 pass 写法
- 解密按**密文实际收件人**选择密钥（与 `pass show` 行为一致），缺密钥时明确提示而不是反复索要口令
- 产出密文可用桌面端 `gpg --decrypt` 直接验证

## 安全设计

- **本地优先**：无任何云服务，密码只存在于本机加密文件与你配置的 Git 远端
- **明文生命周期**：解密内容仅存在于内存；搜索缓存只存「除主密码外的字段值」的派生文本；应用上锁或切后台时统一清空（含 native 侧已解锁私钥缓存）
- **凭据封装**：Git 凭据等敏感信息经 HUKS 加密落盘；剪贴板内容定时自动清除
- **日志安全**：日志不输出密码、密钥与明文内容
- **解密校验**：armor 导入统一规范化（防单行 base64 导致 native 解析失败）；二进制密文 CRC24 校验后才落盘

## 单元测试

ArkTS（LocalUnit，在 DevEco Studio 中运行；新文件须在 `List.test.ets` 手工登记）：

```
entry/src/test/
├── List.test.ets               # 测试套件入口
├── PasswordFileParser.test.ets # pass 格式解析 / 序列化往返 / 可搜索文本与命中片段
├── PgpPacketParser.test.ets    # armor 转换（CRC24 对拍 RFC 4880 标准向量）与 gpg 指纹对拍
├── PasswordGenerator.test.ets  # 生成器长度 / 字符集 / 歧义排除 / 熵值
├── CredentialMatcher.test.ets  # 自动填充包名域名匹配 / RP ID 校验
└── PathSafety.test.ets         # 路径穿越防护（用户输入与仓库内容双来源）
```

Rust（27 个用例，含 gpg 端到端与 PQC 互通）：

```bash
cd entry/src/main/cpp/rpgp_wrapper && cargo test --release
```

## 相关项目

- [pass — the standard unix password manager](https://www.passwordstore.org/)
- [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)

## 开源协议

GPL-3.0（第三方组件的许可证信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）
