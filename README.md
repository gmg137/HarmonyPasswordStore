# HarmonyPasswordStore

[pass](https://www.passwordstore.org/) 密码管理器的 HarmonyOS（鸿蒙）原生客户端，兼容标准 pass 仓库格式，功能参考 [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)。

## 功能特性

| 能力 | 说明 |
|------|------|
| 密码存储 | 标准 pass 目录结构与 GPG 加密文件（`.gpg`），与 pass CLI 生态互通 |
| 密码生成 | 密码学安全随机源（cryptoFramework）、字符集配置、Diceware 口令词组 |
| 搜索与排序 | 全局模糊/精确搜索（300ms 防抖）、按名称/最近使用排序 |
| Git 同步 | clone / pull / push / commit（HTTPS 与 SSH，libgit2/libssh2 桥接） |
| PGP 密钥管理 | 密钥导入/列出/生成（EdDSA/RSA）/改密码/备份恢复/默认密钥选择，多目录 `.gpg-id` 多密钥加密 |
| 自动填充 | 按包名/域名匹配凭据候选，最近使用排序，复制降级路径 |
| Passkey | WebAuthn/FIDO2 凭据创建与认证（ES256/Ed25519/RS256），pass 兼容存储 |
| 快速解锁 | 生物识别（指纹/面容）与独立 PIN（HUKS 混淆摘要存储）、超时自动锁定 |
| 文件操作 | 密码条目跨目录移动/重命名、文件夹创建/删除/重命名、目录树选择器 |
| SSH 高级 | 主机指纹 TOFU（首次确认/信任直连/不匹配拒绝）、PGP→SSH 密钥转换 |
| HTTPS 代理 | mbedTLS 后端 HTTPS clone/pull/push，HTTP(S) 代理配置 |
| 安全增强 | 敏感字段遮罩（password/notes/extra）、内存缓存后台自动清除、指纹检测三态提示 |

## 构建要求

- DevEco Studio / deveco-cli 1.3.2+
- HarmonyOS SDK（API 26+）
- ArkTS 状态管理 V2（`@ComponentV2` / `@ObservedV2` / `@Trace`）

```bash
# 命令行构建
devecocli build          # 等价于 hvigorw assembleHap

# 产物位置
entry/build/default/outputs/default/*.hap
```

## 架构

严格 MVVM 分层，View 禁止直接 import Model：

```
entry/src/main/ets/
├── model/        # 数据层：PasswordRepository、SettingsRepository、实体模型
├── viewmodel/    # 视图模型：@ObservedV2 + @Trace，持有 UI 状态
├── views/        # 可复用组件（@ComponentV2）
├── pages/        # 页面（Navigation 路由，Index.ets 为路由容器）
├── common/       # 路由、常量、主题令牌、LazyForEach 数据源
├── crypto/       # PGP/SSH/Passkey 密钥管理
├── passgen/      # 密码生成器与 Diceware
├── format/       # pass 文件格式解析与 Passkey 编码
├── autofill/     # 凭据匹配服务
└── utils/        # Git/Ssh 客户端、HUKS PIN、应用锁、生物识别
```

- **状态管理**：全部使用 V2 装饰器，禁止 V1/V2 混用
- **路由**：`RouteManager` 单例持有全局 `NavPathStack`，页面名定义于 `Constants.RouteNames`
- **主题**：`ThemeColors` 调色板令牌层（深/浅两套），页面通过 token 取色

## pass 仓库格式兼容

- 密码条目：`<目录>/<名称>.gpg`，解密后首行为密码，`user:` / `url:` / `notes:` 字段从后续行提取
- 密钥指示：仓库根目录 `.gpg-id` 文件指定加密公钥
- Passkey 条目：解密后首行后为 `passkey: v1 <JSON>` 段落

## 安全设计

- **私钥不落盘**：PGP/SSH 私钥经 HUKS 管理；PIN 仅存 `salt + sha256(salt+PIN)` 摘要并用 HUKS 不可导出密钥 AES-GCM 加密
- **明文生命周期**：加密不可用时拒绝写入（无明文落盘路径）；解密内容仅存在于内存；剪贴板定时清除（默认 30s，可配置）
- **日志安全**：hilog 不输出密码/密钥/明文内容，仅记录路径与状态
- **防爆破**：连续 5 次解锁失败锁定 30 秒
- **WebAuthn 校验**：rpId 与 origin 域匹配强制校验（父域规则），Asset Links 远程校验接口预留

## 单元测试

```
entry/src/test/
├── List.test.ets               # 测试套件入口
├── PasswordFileParser.test.ets # pass 格式解析/序列化往返
├── PasswordGenerator.test.ets  # 长度/字符集/歧义排除/熵值
└── CredentialMatcher.test.ets  # 包名域名提取/得分/RP 校验
```

在 DevEco Studio 中运行 LocalUnit 测试任务执行。

## 当前状态

Phase 0–21 全部完成，应用已具备发布就绪状态。Native 桥接与安全机制全链路验证：

| 模块 | 现状 | 备注 |
|------|------|------|
| PGP 加解密 | ✅ 全链路验证 | NAPI 桥接 Rust pgp 0.20.0（encrypt/decrypt/generateKey/changePassphrase/backup/restore/splitKeyring） |
| Git 操作 | ✅ HTTPS + SSH | NAPI 桥接 libgit2（mbedTLS 后端 HTTPS clone/pull/push/commitAll/log/status + 代理） |
| SSH 连接 | ✅ TOFU 三态 | NAPI 桥接 russh 0.63.3（指纹探测 + 期望指纹校验 + 公钥/密码认证；PGP→SSH 密钥转换） |
| Passkey 签名 | ✅ 已实现 | cryptoFramework ECC-P256 生成 + ECDSA-SHA256 签名 |
| 自动填充 | ✅ 接口层完成 | autoFillManager requestAutoFill/requestAutoSave + viewData 类型化回填；真机联调待验证 |
| 安全增强 | ✅ 已实现 | 敏感字段遮罩（password/notes/extra）、内存缓存后台自动清除、指纹检测三态提示 |

### 里程碑完成总览

| 里程碑 | 内容 | 状态 |
|--------|------|------|
| M0–M14 | 架构/密码 CRUD/生成搜索/Git 同步/设置安全/自动填充/Passkey/打磨/i18n/测试/Native 桥接 | ✅ |
| M15 目录级密钥 | `.gpg-id` 多密钥加密 + 文件夹创建 + 密钥多选 | ✅ |
| M16 PGP 密钥增强 | 密钥生成/改密码/备份恢复/keyring 拆分 | ✅ |
| M17 SSH 高级 | 主机指纹 TOFU + PGP→SSH 转换 + 多认证 fallback | ✅ |
| M18 文件操作 | 移动/重命名/文件夹 CRUD/目录树选择器 | ✅ |
| M19 Git HTTPS | mbedTLS + HTTPS clone/代理/外部导入 | ✅ |
| M20 安全增强 | 敏感字段遮罩/缓存过期/独立 PIN/指纹检测 | ✅ |
| M21 发布就绪 | README/CHANGELOG/隐私政策/关于页/UI 打磨/回归 | ✅ |

## 开源协议

GPL-3.0
