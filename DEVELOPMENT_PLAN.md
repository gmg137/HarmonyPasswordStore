# HarmonyPasswordStore 开发计划书

> **项目定位**：开源密码管理工具 [pass](https://www.passwordstore.org/) 的 HarmonyOS（鸿蒙）原生版本，功能参考 [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)（v2.0.1，agrahn 分支）。
>
> **技术栈**：HarmonyOS SDK 6.1+（API 26）、ArkTS + ArkUI 声明式框架、状态管理 V2（`@ComponentV2` / `@ObservedV2` / `@Trace`）、MVVM 架构。
>
> **Native 桥接**：PGP → Rust rpgp（pgp 0.20.0）；SSH → Rust russh（0.63.3）；Git → libgit2（NAPI 桥接）。
>
> **开源协议**：GPL-3.0
>
> **包名**：`com.github.gmg137.HarmonyPasswordStore`

> **注**：本文档为开发期计划书，反映撰写时点的规划与状态。后续演进以 README 与 CHANGELOG 为准——Passkey（WebAuthn）与 PIN 解锁已整体移除（应用锁仅保留生物识别）；PGP 目录多密钥、混合收件人、GnuPG algo 8（ML-KEM）后量子密钥、「内容匹配」搜索等均已落地。

---

## 目录

1. [项目概述](#一项目概述)
2. [架构设计](#二架构设计)
3. [已完成开发阶段总结](#三已完成开发阶段总结)
4. [后续开发计划](#四后续开发计划)
5. [技术风险与应对](#五技术风险与应对)
6. [开发规范](#六开发规范)
7. [里程碑时间线](#七里程碑时间线)
8. [验证策略](#八验证策略)
9. [附录](#九附录)

---

## 一、项目概述

### 1.1 项目目标

构建一个与 `pass` 命令行工具 100% 兼容的鸿蒙原生密码管理器，对标 Android-Password-Store v2.0.1 全部核心能力，同时深度集成鸿蒙系统特性（HUKS 硬件密钥、autoFillManager 自动填充、生物识别）。

#### 核心能力域

| 能力域 | 说明 | 对标 APS | 本项目状态 |
|--------|------|----------|:----------:|
| **密码存储** | `pass` 标准 GPG 加密文件结构，`.gpg` 文件存储于本地加密目录 | ✅ 核心 | ✅ 已完成 |
| **Git 同步** | clone / pull / push / commit / log / status | ✅ 核心 | ✅ 已完成 |
| **PGP 加密** | OpenPGP 加解密，密钥导入/管理/选择，`.gpg-id` 多密钥支持 | ✅ 核心 | ⏳ 部分（单密钥） |
| **密码生成** | 随机密码 + Diceware 口令词组 | ✅ 核心 | ✅ 已完成 |
| **密码检索** | 模糊/精确搜索，按名称/最近使用排序 | ✅ 核心 | ✅ 已完成 |
| **自动填充** | 鸿蒙 autoFillManager 集成，凭据匹配 + 回填 | ✅ 核心 | ✅ 接口完成 |
| **Passkey** | WebAuthn/FIDO2 创建与认证（ES256/Ed25519/RS256） | ✅ v2.0 | ✅ 已完成 |
| **快速解锁** | 生物识别 + PIN 快速解锁，可配置过期天数 | ✅ 核心 | ✅ 已完成 |
| **目录式密钥** | 按子目录设置不同 PGP 密钥（`.gpg-id`） | ✅ APS 特性 | ✅ 已完成 |
| **SSH 认证** | Ed25519/ECDSA/RSA 密钥，russh 桥接 | ✅ APS 特性 | ✅ 已完成 |
| **PGP 密钥即 SSH 密钥** | 用 PGP 签名子键做 SSH 认证 | ✅ APS 1.16.0 | ✅ 已完成（Ed25519） |
| **PGP 密钥生成** | 应用内生成 PGP 密钥对 | ✅ APS 1.15.0 | ✅ 已完成 |
| **PGP 密钥备份** | 对称加密导出/导入私钥 | ✅ APS 1.15.2 | ✅ 已完成 |
| **PGP 密钥改密码** | 重设私钥 passphrase | ✅ APS 1.15.0 | ✅ 已完成 |
| **PGP 子键独立 passphrase** | 每个 PGP 子键可设不同 passphrase | ✅ APS 1.16.0 | ❌ 未实现 |
| **敏感字段标记** | extra content `secret:`/`*key*:` 前缀字段默认隐藏 | ✅ APS 1.16.0 | ❌ 未实现 |
| **文件移动/重命名** | 密码条目跨目录移动、重命名 | ✅ APS 核心 | ✅ 已完成 |
| **文件夹 CRUD** | 创建/删除/重命名文件夹 | ✅ APS 核心 | ✅ 已完成 |
| **SSH known_hosts TOFU** | 首次连接显示指纹供用户确认 | ✅ APS 1.16.3 | ✅ 已完成 |
| **Git HTTPS** | HTTPS 协议 clone/pull/push | ✅ APS 核心 | ❌ 未实现 |
| **HTTP(S) 代理** | libgit2 proxy 配置 | ✅ APS 1.13.0 | ❌ 未实现 |
| **外部仓库导入** | 从文件系统导入已有 pass 仓库 | ✅ APS 1.14.0 | ❌ 未实现 |
| **多密钥加密** | `.gpg-id` 列出多个密钥，多接收方加密 | ✅ APS 1.15.1 | ✅ 已完成 |
| **多密钥备份导入** | 一次导入多个密钥文件 | ✅ APS 1.16.4 | ✅ 已完成 |
| **复制后定时清除** | 复制密码后 30s 自动清空剪贴板 | ✅ APS 核心 | ✅ 已完成 |
| **自动启动同步** | autoSyncOnLaunch | ✅ APS 1.13.0 | ✅ 已完成 |
| **Git 提交历史** | GitLogView + GitLogViewModel | ✅ APS 核心 | ✅ 已完成 |
| **密码排序** | 名称 / 最近使用 | ✅ APS 1.12.0 | ✅ 已完成 |
| **SSH 自定义端口** | GitConfig.sshPort | ✅ APS 1.16.0 | ✅ 已完成 |
| **引导页** | OnboardingPage | ✅ APS 核心 | ✅ 已完成 |
| **从 .asc 导入密钥** | DocumentViewPicker | ✅ APS 核心 | ✅ 已完成 |
| **深色/浅色主题** | ThemeColors 设计令牌层 | ✅ APS 核心 | ✅ 已完成 |
| **国际化** | 中/英 | ✅ APS 核心 | ✅ 已完成 |

### 1.2 pass 仓库格式兼容规范

本项目严格遵循 [pass](https://www.passwordstore.org/) 的文件格式规范，确保与 `pass` CLI、Android-Password-Store 及其他 pass 生态工具完全互通。

#### 密码条目文件格式

```
<密码仓库根目录>/
├── .gpg-id                          # 加密密钥 ID 列表（每行一个 KeyID 或指纹）
├── .git/                            # Git 仓库元数据
├── work/
│   ├── example.org/
│   │   ├── john@doe.org.gpg         # 文件式组织：路径=work/example.org，名称=john@doe.org
│   │   └── jane@doe.org/
│   │       └── password.gpg         # 目录式组织：路径=work/example.org/jane@doe.org，名称=password
│   └── .gpg-id                      # 子目录级密钥覆盖（可选）
└── personal/
    └── bank.gpg
```

#### 解密后文件内容格式

```
<主密码>                              # 第一行：主密码（必填）
user: <用户名>                         # 用户名字段（可选）
email: <邮箱>                          # 邮箱字段（可选，本项目扩展）
phone: <手机号>                        # 手机号字段（可选，本项目扩展）
url: <URL>                            # URL 字段（可选，pass 标准）
notes: <备注>                          # 备注字段（可选）
*secret_field*: <敏感内容>            # 敏感字段（APS 扩展，默认隐藏）
                                      # 空行分隔自由文本
<自由文本内容>
```

#### Passkey 文件格式（APS v2.0 规范）

```
<Base64URL(CBOR(passkey_data))>       # 第一行：Base64URL 编码的 CBOR 序列化 passkey 数据
user: <用户名>                         # 后续行：可选额外内容
<其他键值对或自由文本>
```

Passkey CBOR 数据结构：

| 字段 | CBOR 类型 | 说明 |
|------|-----------|------|
| `id` | array (major 4) | 凭据 ID，32 字节无符号整数数组 |
| `rp.id` | tstr (major 3) | RP ID，如 `example.com` |
| `rp.name` | tstr / null | RP 名称（可选） |
| `user.id` | array (major 4) | 用户句柄，变长字节 |
| `user.name` | tstr | 登录名 |
| `user.display_name` | tstr / null | 显示名（可选） |
| `sign_count` | uint (major 0) | 签名计数器（APS 保持 0） |
| `alg` | int | COSE 算法 ID：ES256=-7, Ed25519=-8, RS256=-257 |
| `private_key` | array (major 4) | 原始私钥字节 |
| `created` | uint | Unix 时间戳 |
| `zone` | tstr | 时区 ID |

#### `.gpg-id` 文件格式

```
# 每行一个密钥标识（KeyID 或完整指纹）
300404824EE42CE62F82D553ECF97892BD45E551
ABCDEF0123456789
```

- 根目录 `.gpg-id` 指定默认加密密钥
- 子目录 `.gpg-id` 覆盖父目录设置（目录级密钥）
- 文件可包含注释行（`#` 开头）
- 空/无效 `.gpg-id` 需提供修复流程

### 1.3 项目约束

| 约束 | 说明 |
|------|------|
| **架构** | 严格 MVVM 分层，状态管理 V2，禁止 V1/V2 混用 |
| **安全** | 密钥通过 HUKS 管理，私钥永不明文落盘；密码明文仅在内存中短暂存在 |
| **兼容** | 密码文件格式 100% 兼容 `pass` CLI；Passkey 格式兼容 APS v2.0 |
| **性能** | 1000+ 条目列表滚动流畅（LazyForEach + LazyDataSource） |
| **ABI** | 双 ABI 支持：x86_64（模拟器）+ arm64（真机） |
| **开源协议** | GPL-3.0 |

---

## 二、架构设计

### 2.1 整体分层架构

```
┌──────────────────────────────────────────────────────────────────┐
│                           View 层                                 │
│  pages/   views/   (ArkUI @ComponentV2)                         │
│  密码列表 │ 详情 │ 新建/编辑 │ Git配置 │ 克隆 │ 设置 │ 密钥管理   │
│  引导 │ PIN │ Passkey │ 密码生成器 │ 自动填充 │ 锁屏              │
├──────────────────────────────────────────────────────────────────┤
│                        ViewModel 层                               │
│  viewmodel/   (@ObservedV2 + @Trace)                             │
│  PasswordListVM │ DetailVM │ CreateVM │ GitCloneVM │ GitConfigVM│
│  SettingsVM │ PgpKeyMgrVM │ SshKeyMgrVM │ PasskeyListVM          │
│  PassgenVM │ PinSetupVM │ AppLockVM │ SyncVM │ GitLogVM          │
│  AutofillFillVM │ OnboardingVM                                  │
├──────────────────────────────────────────────────────────────────┤
│                          Model 层                                 │
│  model/   (Repository + 数据实体)                                 │
│  PasswordRepository │ SettingsRepository │ GitConfig             │
│  PasswordEntry │ GpgKeyId │ PasskeyEntry │ RepositoryConfig      │
├──────────────────────────────────────────────────────────────────┤
│                         基础设施层                                │
│  crypto/      PgpCrypto │ PgpKeyManager │ PgpPacketParser        │
│                SshKeyManager │ PasskeyManager │ RelyingPartyVerifier│
│  passgen/     PasswordGenerator │ DicewareGenerator              │
│  format/      PasswordFileParser │ PasskeyEncoder                │
│  utils/       GitClient │ SshClient │ FileUtils │ PinManager     │
│                BiometricHelper │ AppLockManager                   │
│  autofill/    AutofillService │ AutofillBridge │ CredentialMatcher│
│  common/      Constants │ NativeBridge │ RouteManager             │
│                ThemeColors │ LazyDataSource │ RepoChangeNotifier  │
├──────────────────────────────────────────────────────────────────┤
│                        Native 桥接层                               │
│  cpp/hps_napi.cpp   (NAPI 入口，13 函数)                          │
│  cpp/rpgp_wrapper/  (Rust: pgp 0.20.0 + russh 0.63.3)           │
│  cpp/third_party/   (libgit2 + Rust 静态库，arm64 + x86_64)      │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 目录结构

```
HarmonyPasswordStore/
├── AppScope/
│   └── app.json5                      # 应用级配置
├── entry/
│   └── src/
│       ├── main/
│       │   ├── ets/
│       │   │   ├── common/            # 路由、常量、主题令牌、NAPI 桥接
│       │   │   │   ├── Constants.ets          # 路由常量 + 枚举 + 辅助函数
│       │   │   │   ├── NativeBridge.ets       # NAPI 封装（PGP/Git/SSH）
│       │   │   │   ├── RouteManager.ets       # 全局导航管理器（NavPathStack）
│       │   │   │   ├── ThemeColors.ets        # 设计令牌层（深/浅色 + 变更回调）
│       │   │   │   ├── LazyDataSource.ets     # LazyForEach 数据源
│       │   │   │   └── RepoChangeNotifier.ets # AppStorageV2 全局通知器
│       │   │   ├── model/             # 数据实体 + Repository
│       │   │   │   ├── PasswordEntry.ets          # 密码条目 + PasswordContent 接口
│       │   │   │   ├── PasswordRepository.ets     # 密码仓库（CRUD + .gpg-id + 空目录清理）
│       │   │   │   ├── SettingsRepository.ets      # 持久化设置
│       │   │   │   ├── GitConfig.ets              # Git 配置实体
│       │   │   │   ├── GpgKeyId.ets                # GPG 密钥 ID 实体
│       │   │   │   ├── PasskeyEntry.ets            # Passkey 实体
│       │   │   │   └── RepositoryConfig.ets       # 仓库配置
│       │   │   ├── viewmodel/         # 16 个 ViewModel
│       │   │   ├── views/             # 可复用组件
│       │   │   │   ├── PasswordItemView.ets       # 列表项卡片
│       │   │   │   ├── SyncSheet.ets              # 同步面板
│       │   │   │   └── GitLogView.ets             # 提交历史视图
│       │   │   ├── pages/            # 16 个页面
│       │   │   ├── crypto/            # PGP/SSH/Passkey 密钥管理
│       │   │   │   ├── PgpCrypto.ets              # PGP 加解密（单例 + 回退解密）
│       │   │   │   ├── PgpKeyManager.ets          # PGP 密钥管理（native 公钥提取）
│       │   │   │   ├── PgpPacketParser.ets        # 纯 ArkTS PGP 包解析
│       │   │   │   ├── SshKeyManager.ets          # SSH 密钥管理
│       │   │   │   ├── PasskeyManager.ets         # Passkey 管理器
│       │   │   │   └── RelyingPartyVerifier.ets   # RP 域名校验
│       │   │   ├── passgen/          # 密码生成
│       │   │   │   ├── PasswordGenerator.ets      # 随机密码生成器
│       │   │   │   └── DicewareGenerator.ets      # Diceware 口令词组
│       │   │   ├── format/           # 文件格式
│       │   │   │   ├── PasswordFileParser.ets     # pass 格式解析/序列化
│       │   │   │   └── PasskeyEncoder.ets         # Passkey CBOR 编解码
│       │   │   ├── utils/            # 工具层
│       │   │   │   ├── GitClient.ets              # Git 接口层
│       │   │   │   ├── SshClient.ets              # SSH 客户端
│       │   │   │   ├── FileUtils.ets             # 文件工具
│       │   │   │   ├── PinManager.ets            # PIN 管理（HUKS AES-GCM）
│       │   │   │   ├── BiometricHelper.ets       # 生物识别
│       │   │   │   └── AppLockManager.ets        # 应用锁
│       │   │   ├── autofill/         # 自动填充
│       │   │   │   ├── AutofillService.ets       # 自动填充服务
│       │   │   │   ├── AutofillBridge.ets        # autoFillManager 封装
│       │   │   │   └── CredentialMatcher.ets     # 凭据匹配器
│       │   │   ├── entryability/      # EntryAbility
│       │   │   └── entrybackupability/ # EntryBackupAbility
│       │   ├── cpp/                   # Native 层
│       │   │   ├── hps_napi.cpp               # NAPI 入口
│       │   │   ├── CMakeLists.txt             # 按 OHOS_ARCH 选库
│       │   │   ├── rpgp_wrapper/               # Rust FFI crate
│       │   │   │   ├── Cargo.toml
│       │   │   │   ├── src/lib.rs             # FFI 函数实现
│       │   │   │   └── .cargo/config.toml     # OHOS clang 环境固化
│       │   │   └── third_party/               # 预编译静态库
│       │   │       ├── libgit2/                # libgit2 (arm64)
│       │   │       ├── libgit2-x64/            # libgit2 (x86_64)
│       │   │       └── rpgp_wrapper/           # Rust 静态库 (arm64 + x86_64)
│       │   └── resources/            # 资源文件
│       │       ├── base/              # 默认资源
│       │       └── zh_CN/            # 中文资源
│       └── test/                     # 单元测试
│           ├── List.test.ets
│           ├── PasswordFileParser.test.ets
│           ├── PasswordGenerator.test.ets
│           └── CredentialMatcher.test.ets
├── docs/
│   ├── UI-DEV.md                    # UI 开发规范
│   ├── screenshots/                  # 功能验证截图
│   └── verification-report.html      # 验证报告
├── DEVELOPMENT_PLAN.md              # 本文件
├── README.md
└── build-profile.json5
```

### 2.3 状态管理 V2 规范

| 场景 | V2 装饰器 | 说明 | 禁止的 V1 |
|------|----------|------|-----------|
| ViewModel 类 | `@ObservedV2` | 所有 ViewModel 根类 | `@Observed` |
| VM 可观测属性 | `@Trace` | 需要驱动 UI 刷新的属性 | `@Track` |
| 页面/组件 | `@ComponentV2` | 所有组件和页面 | `@Component` |
| 父→子单向传值 | `@Param` | 替代 V1 @Prop | `@Prop` |
| 子→父事件回调 | `@Event` | 替代 V1 回调 | `@Link` |
| 组件内私有状态 | `@Local` | 替代 V1 @State | `@State` |
| 跨组件共享状态 | `AppStorageV2.connect()` | 全局状态连接 | `@Provide/@Consume` |
| 状态变化监听 | `@Monitor` | 监听 @Trace 属性变化 | `@Watch` |
| 计算属性 | `@Computed` | 派生状态 | — |

#### V2 使用要点

```typescript
// ✅ 正确：ViewModel 使用 @ObservedV2 + @Trace
@ObservedV2
export class PasswordListViewModel {
  @Trace entries: PasswordEntry[] = [];
  @Trace searchKeyword: string = '';
  @Trace isLoading: boolean = false;

  // AppStorageV2.connect 首次连接必须传默认创建函数
  private notifier: RepoChangeNotifier = AppStorageV2.connect(
    RepoChangeNotifier, 'repoNotifier',
    (): RepoChangeNotifier => new RepoChangeNotifier()
  )!;

  // @Monitor 监听 @Trace 属性变化
  @Monitor('notifier.nonce')
  onRepoChanged(): void {
    this.loadEntries();
  }
}

// ✅ 正确：页面使用 @ComponentV2
@ComponentV2
struct PasswordListPage {
  @Param viewModel: PasswordListViewModel = new PasswordListViewModel();
  @Local showSyncSheet: boolean = false;

  // getter 传参给 @Builder（@Builder 按值传参不响应 @Trace 变化）
  get colors(): ThemeColors { return ThemeColors.current(); }
}
```

### 2.4 数据流（单向 UDF）

```
用户操作 ──→ View (@Event) ──→ ViewModel (@Trace 方法) ──→ Model (Repository)
                                                                │
                      UI 刷新 ←── View (@Param) ←── ViewModel ←──┘
                           ↑
                      RepoChangeNotifier.bump()
                      （跨页面通知列表刷新）
```

- **View** 只依赖 ViewModel 类型，禁止 import Model。
- **ViewModel** 完成数据转换和业务逻辑，持有 UI 状态。
- **Model** 负责数据持久化、Git 操作、密钥管理。
- **RepoChangeNotifier** 通过 AppStorageV2 全局通知数据变化（解决 Navigation 根页面 `onPageShow` 不触发的问题）。

### 2.5 Native 桥接架构

```
┌─────────────────────────────────────────────────────────┐
│                    ArkTS 层                              │
│  NativeBridge.ets (import libhps_napi.so)               │
│  pgpEncrypt / pgpDecrypt / pgpListKeys / ...            │
├─────────────────────────────────────────────────────────┤
│                    NAPI 层 (C++)                         │
│  hps_napi.cpp                                           │
│  napi_value ↔ C 类型转换 + FFI 调用                       │
├─────────────────────────────────────────────────────────┤
│                    FFI 层 (Rust)                         │
│  rpgp_wrapper/src/lib.rs                                │
│  extern "C" fn hps_pgp_*() / hps_ssh_*()               │
│  使用 pgp 0.20.0 + russh 0.63.3                         │
├─────────────────────────────────────────────────────────┤
│                    C 库                                  │
│  libgit2 (clone/pull/push/commit/log/status)            │
│  libtime_service_ndk.so (Rust std 依赖)                 │
└─────────────────────────────────────────────────────────┘
```

#### NAPI 桥接要点

| 要点 | 说明 |
|------|------|
| ArkTS 侧 import | 必须静态 `import libxxx.so`，不支持 require/动态 import |
| 回调返回类型 | 箭头函数回调需显式返回类型（`arkts-no-implicit-return-types`） |
| C++ std::string | 需 `#include <string>`，`napi_get_value_string_utf8` 写缓冲用 `&out[0]` |
| Rust CC 环境 | `ring` 等 C/汇编 crate 的 CC 须在 `.cargo/config.toml [env]` 固化 OHOS clang |
| 双 ABI | CMakeLists.txt 按 `OHOS_ARCH` 选库路径 |
| Rust 链接依赖 | Rust std 依赖 `libtime_service_ndk.so`（OH_TimeService_GetTimeZone） |

### 2.6 安全架构

```
┌─────────────────────────────────────────────────────────┐
│                    密钥安全                              │
│                                                         │
│  PGP 私钥 ──→ HUKS 不可导出密钥 AES-GCM 加密 ──→ 落盘    │
│  SSH 私钥 ──→ HUKS 不可导出密钥 AES-GCM 加密 ──→ 落盘    │
│  PIN ──→ salt + sha256(salt+PIN) ──→ HUKS AES-GCM ──→ 落盘│
│  Passkey 私钥 ──→ PGP 加密 ──→ 仓库内 .gpg 文件         │
│                                                         │
│  规则：私钥永不明文落盘；明文仅在内存中短暂存在            │
├─────────────────────────────────────────────────────────┤
│                    密码安全                              │
│                                                         │
│  密码明文 ──→ 仅存在于内存（解密后）                      │
│  写入前 ──→ PGP 加密（无明文落盘路径）                     │
│  剪贴板 ──→ 30s 定时清除（可配置）                        │
│  日志 ──→ hilog 不输出密码/密钥/明文                      │
├─────────────────────────────────────────────────────────┤
│                    防爆破                                │
│                                                         │
│  连续 5 次解锁失败 ──→ 锁定 30 秒                        │
│  PIN 验证计数器 ──→ 持久化缓存（防重启重置）              │
├─────────────────────────────────────────────────────────┤
│                    WebAuthn 安全                         │
│                                                         │
│  rpId 与 origin 域匹配强制校验（父域规则）                 │
│  Asset Links 远程校验接口预留                             │
└─────────────────────────────────────────────────────────┘
```

#### HUKS 密钥管理要点

- `isKeyItemExist` 双参数形式
- AES-GCM 加密必须传 `HUKS_TAG_NONCE`
- AES-GCM 模式：`HUKS_TAG_BLOCK_MODE` + `HuksCipherMode.HUKS_MODE_GCM`
- Ed25519 密钥导出：`getEncodedDer(format)` 不支持 Ed25519，必须用通用 `Key.getEncoded()`
- RSA 私钥导出：`PriKey.getEncodedDer('PKCS8')`（需 API 26+）
- EC/RSA 私钥导出：`PriKey.getEncodedDer('PKCS8')` 可导出 DER，包装为 PEM 后经 FFI 传给 russh

---

## 三、已完成开发阶段总结

### 3.1 Phase 0–14 完成状态

| 阶段 | 内容 | 状态 | 关键产出 |
|------|------|:----:|----------|
| **Phase 0** | 项目初始化、MVVM 骨架、Navigation 路由、SettingsRepository | ✅ | 项目结构、RouteManager、Constants |
| **Phase 1** | 密码存储核心：PGP 加解密、密码 CRUD、列表/详情页 | ✅ | PasswordRepository、PgpCrypto、列表/详情页 |
| **Phase 2** | 密码生成器（随机 + Diceware）、全局搜索、排序 | ✅ | PasswordGenerator、DicewareGenerator |
| **Phase 3** | Git 同步：libgit2 clone/pull/push/commit/log、SSH 密钥 | ✅ | GitClient、SshClient、libgit2 NAPI |
| **Phase 4** | 设置页、快速解锁（PIN + 生物识别）、剪贴板安全 | ✅ | SettingsPage、PinManager、BiometricHelper |
| **Phase 5** | 自动填充：autoFillManager 集成、凭据匹配 | ✅ | AutofillService、AutofillBridge |
| **Phase 6** | Passkey：创建/认证/存储（ES256/Ed25519/RS256） | ✅ | PasskeyManager、PasskeyEncoder |
| **Phase 7** | 深色/浅色主题、国际化、基础测试 | ✅ | ThemeColors、resources/、单元测试 |
| **Phase 8** | Native 桥接层：rpgp（pgp 0.20）+ russh（0.63.3）NAPI | ✅ | rpgp_wrapper crate、hps_napi.cpp |
| **Phase 9** | 纯 ArkTS 缺口补全：PgpPacketParser、PgpCrypto native 走通 | ✅ | PgpPacketParser |
| **Phase 10** | PGP 端到端：加密/解密/passphrase 验证 | ✅ | hps_pgp_extract_public_key、.gpg-id 自动写入 |
| **Phase 11** | SSH 端到端：russh 握手 + 公钥/密码认证 | ✅ | russh 0.63.3 集成 |
| **Phase 12** | 双 ABI 支持：x86_64（模拟器）+ arm64（真机） | ✅ | CMakeLists OHOS_ARCH 选库 |
| **Phase 13** | UI/UX 优化：HarmonyOS Design 设计令牌、8 个表单页重写 | ✅ | ThemeColors 扩展令牌层 |
| **Phase 14** | Bug 修复 #1–#8：主题切换弹窗、PIN 逻辑、Slider、深色适配等 | ✅ | 8 个 bug 修复 |

### 3.2 当前 Native 函数清单

| 函数 | 模块 | 功能 | 参数 |
|------|------|------|------|
| `pgpEncrypt` | PGP | 用公钥加密明文 | plaintext, publicKeyArmor |
| `pgpDecrypt` | PGP | 用私钥 + passphrase 解密 | ciphertext, secKeyArmor, passphrase |
| `pgpListKeys` | PGP | 列出已导入密钥的 KeyID/指纹/算法 | secKeyArmor |
| `pgpVerifyPassphrase` | PGP | 验证私钥 passphrase | secKeyArmor, passphrase |
| `pgpImportKey` | PGP | 导入 ASCII-armored 私钥 | keyArmor |
| `pgpExtractPublicKey` | PGP | 从私钥提取公钥 | secKeyArmor |
| `gitClone` | Git | 克隆远程仓库 | url, localPath, sshKey, passphrase |
| `gitPull` | Git | 拉取远程更新 | localPath, sshKey, passphrase |
| `gitPush` | Git | 推送本地提交 | localPath, sshKey, passphrase |
| `gitCommitAll` | Git | 提交所有变更 | localPath, message, userName, userEmail |
| `gitLog` | Git | 查看提交历史 | localPath, maxCount |
| `gitStatus` | Git | 查看工作区状态 | localPath |
| `sshTestAuth` | SSH | 测试 SSH 公钥认证 | host, port, user, keyPem, passphrase |
| `sshTestPassword` | SSH | 测试 SSH 密码认证 | host, port, user, password |

### 3.3 已完成功能详细清单

#### 密码管理
- ✅ 密码 CRUD（创建/读取/更新/删除）
- ✅ 密码条目列表（LazyForEach + LazyDataSource）
- ✅ 密码详情页（字段重排 + 每项复制按钮）
- ✅ 密码编辑（标题"编辑密码" + takeLastParam 取参）
- ✅ 密码搜索（模糊匹配 + 300ms 防抖）
- ✅ 密码排序（名称 / 最近使用）
- ✅ 密码生成器（随机 + Diceware）
- ✅ 删除后空目录级联清理（pruneEmptyParentDirs）
- ✅ 列表自动刷新（RepoChangeNotifier）

#### PGP 加密
- ✅ PGP 加密（native rpgp 公钥提取 + 加密）
- ✅ PGP 解密（含回退到第一把已导入私钥）
- ✅ PGP 密钥导入（.asc 文件）
- ✅ PGP 密钥列出（KeyID/指纹/算法）
- ✅ PGP passphrase 验证
- ✅ `.gpg-id` 自动写入
- ✅ 纯 ArkTS PGP 包解析器（PgpPacketParser）

#### Git 同步
- ✅ Git clone/pull/push/commit/log/status（libgit2）
- ✅ SSH 协议克隆（russh 桥接）
- ✅ SSH 公钥/密码认证
- ✅ Git 提交历史查看
- ✅ 自动启动同步（autoSyncOnLaunch）
- ✅ 浮动同步按钮（SyncSheet）
- ✅ clone 协议预检测 + 友好错误提示

#### SSH
- ✅ SSH 密钥管理（Ed25519/ECDSA/RSA）
- ✅ SSH 连接测试（native 优先 + TCP 降级）
- ✅ SSH 自定义端口
- ✅ 私钥 PKCS8 PEM 内存传递（不落盘）

#### Passkey
- ✅ WebAuthn/FIDO2 凭据创建（ES256/Ed25519/RS256）
- ✅ Passkey 认证
- ✅ Passkey CBOR 编解码
- ✅ pass 兼容存储格式
- ✅ RP 域名校验

#### 自动填充
- ✅ autoFillManager 集成
- ✅ 凭据匹配（包名/域名）
- ✅ viewData 类型化回填
- ✅ 最近使用排序

#### 安全
- ✅ HUKS 密钥管理（私钥不落盘）
- ✅ PIN 快速解锁（HUKS AES-GCM）
- ✅ 生物识别（指纹/面容）
- ✅ 剪贴板定时清除（30s 可配置）
- ✅ 防爆破（5 次失败锁定 30s）
- ✅ 应用锁

#### UI/UX
- ✅ 深色/浅色主题（ThemeColors 设计令牌层）
- ✅ 沉浸式布局（setWindowLayoutFullScreen + expandSafeArea）
- ✅ 状态栏颜色同步（ThemeColors.addChangeListener）
- ✅ HarmonyOS Design 对齐
- ✅ 国际化（中/英）
- ✅ 引导页（OnboardingPage）

#### 扩展字段
- ✅ `email:` 字段支持
- ✅ `phone:` 字段支持
- ✅ 兼容旧文件 `url:` 前缀
- ✅ PasswordFileParser serialize 签名含 email/phone

---

## 四、后续开发计划

### Phase 15：目录级 PGP 密钥（`.gpg-id`）（1 周）

**目标**：支持按子目录设置不同 PGP 密钥，兼容 `pass` 的 `.gpg-id` 机制。支持多密钥加密。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 15.1 | `.gpg-id` 文件解析 | 扩展 `model/PasswordRepository.ets` | 递归查找最近的 `.gpg-id`（从当前目录向上遍历父目录链） | — |
| 15.2 | 加密时多密钥支持 | 扩展 `crypto/PgpCrypto.ets` + rpgp FFI | rpgp `encrypt_to_keys` 接受多公钥数组；多接收方加密文件可解密 | 15.1 |
| 15.3 | 创建文件夹时选密钥 | 新建 `pages/FolderCreatePage.ets` + ViewModel | 文件夹创建流程增加密钥选择步骤；可为子目录指定密钥 | 15.1 |
| 15.4 | 密钥列表多选 | 扩展 `pages/PgpKeyManagerPage.ets` | 可选多个密钥写入 `.gpg-id` | 15.1 |
| 15.5 | 无效 `.gpg-id` 修复 | 扩展 `model/PasswordRepository.ets` | 检测到无效/未知 KeyID 时提示重新选择密钥 | 15.1 |
| 15.6 | `.gpg-id` 用 KeyID 而非 UserID | 扩展 `model/PasswordRepository.ets` | 写入 KeyID（兼容 pass CLI） | 15.1 |

#### `.gpg-id` 查找算法

```
function findGpgId(filePath):
  currentDir = parentDir(filePath)
  while currentDir != root:
    gpgIdPath = currentDir + '/.gpg-id'
    if exists(gpgIdPath):
      return parseGpgId(gpgIdPath)  // 返回 KeyID 列表
    currentDir = parentDir(currentDir)
  // 回退到根目录 .gpg-id
  return parseGpgId(root + '/.gpg-id')
```

#### 多密钥加密

```rust
// rpgp 0.20 API
let message = MessageBuilder::from_bytes()
    .seipd_v1(OsRng, SymmetricKeyAlgorithm::AES256)
    .encrypt_to_key(&mut OsRng, &pubkey1)?
    .encrypt_to_key(&mut OsRng, &pubkey2)?
    // ... 对每个公钥调用 encrypt_to_key
    .to_armored_string(OsRng, ArmorOptions::default())?;
```

---

### Phase 16：PGP 密钥生成与管理增强（2 周）

**目标**：应用内生成 PGP 密钥对，支持导出/备份/改密码。兼容 OpenKeychain 备份格式。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 16.1 | PGP 密钥生成（native） | rpgp FFI `hps_pgp_generate_key` + NAPI | 可生成 RSA/EdDSA/Curve25519 密钥；生成后 HUKS 加密存储 | — |
| 16.2 | 密钥生成 UI | 扩展 `pages/PgpKeyManagerPage.ets` + ViewModel | 可选择算法（EdDSA/Curve25519/RSA4096）/UserID/过期时间 | 16.1 |
| 16.3 | 密钥导出 | rpgp FFI `hps_pgp_export_public_key` + NAPI | 可导出 ASCII-armored 公钥分享；可复制到剪贴板 | — |
| 16.4 | 密钥备份（对称加密） | rpgp FFI `hps_pgp_backup_key` + NAPI | GPG 对称加密导出私钥；兼容 OpenKeychain 备份格式 | — |
| 16.5 | 改 passphrase | rpgp FFI `hps_pgp_change_passphrase` + NAPI | 可修改密钥密码 | — |
| 16.6 | 多密钥备份导入 | 扩展 rpgp FFI `hps_pgp_import_keys` | rpgp `from_armor_many` 支持多密钥文件一次导入 | — |
| 16.7 | 子键独立 passphrase | rpgp FFI 扩展 | 每个 PGP 子键可设不同 passphrase | 16.5 |
| 16.8 | 过期密钥处理 | 扩展 `crypto/PgpCrypto.ets` | 过期密钥可解密显示但不可编辑/创建新条目 | — |

#### PGP 密钥生成参数

```
算法选项：
- EdDSA (Curve25519) — 推荐，快速且安全
- Curve25519 (Encryption + EdDSA Signing)
- RSA 4096 — 兼容性最好
- RSA 2048 — 速度优先

UserID 格式：Name <email@example.com>

子键配置：
- 主键（Certify）：EdDSA/RSA
- 签名子键（Sign）：EdDSA/RSA
- 加密子键（Encrypt）：Curve25519/RSA
- 认证子键（Auth）：EdDSA/RSA（可选）

过期时间：永不过期 / 1年 / 2年 / 5年 / 自定义
```

#### rpgp 密钥生成 API

```rust
use pgp::composed::{SignedSecretKey, SecretKeyBuilder};
use pgp::crypto::ecc_curve::ECCCurve;
use pgp::types::{PublicKeyTrait, SecretKeyTrait};

// EdDSA 密钥生成
let (secret_key, _) = SecretKeyBuilder::default()
    .set_algorithm(Algorithm::EdDSA)
    .set_curve(ECCCurve::Ed25519)
    .add_userid("Test <test@example.com>")
    .create_primary_key(&mut OsRng)?;
let signed_key = secret_key.sign(&mut OsRng, || "passphrase".into())?;
let armored = signed_key.to_armored_string(OsRng, ArmorOptions::default())?;
```

---

### Phase 17：SSH 高级特性（1 周）

**目标**：known_hosts TOFU 校验、PGP 密钥做 SSH 认证、多认证方式 fallback。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 17.1 | known_hosts TOFU | 扩展 rpgp_wrapper `check_server_key` + `utils/SshClient.ets` | 首次连接显示指纹供用户确认；保存已知指纹 | — |
| 17.2 | PGP 密钥做 SSH 认证 | rpgp 导出签名子键 PEM → russh `decode_secret_key` | PGP 密钥可做 Git SSH 认证 | — |
| 17.3 | 多认证方式 fallback | 扩展 `utils/SshClient.ets` | 先公钥后密码的 fallback 链 | 17.2 |
| 17.4 | SSH 密钥导出公钥 | 扩展 `pages/SshKeyManagerPage.ets` | 可复制/导出公钥到剪贴板 | — |
| 17.5 | chacha20-poly1305 支持 | 确认 russh 0.63.3 已支持 | chacha20-poly1305@openssh.com cipher 可用 | — |

#### PGP 密钥做 SSH 认证流程

```
1. 从 HUKS 解密获取 PGP 私钥（PEM 格式）
2. rpgp 提取签名子键（Authentication subkey，fallback 到 Signing subkey 或 Primary key）
3. 将签名子键转换为 SSH 私钥格式（PEM）
4. russh decode_secret_key(PEM, passphrase)
5. russh authenticate_publickey(user, PrivateKeyWithHashAlg)
```

#### known_hosts TOFU 流程

```
1. 首次连接：check_server_key 回调收到服务器公钥
2. 计算 SHA256 指纹
3. 检查本地 known_hosts 文件
4. 如果不存在 → 显示指纹对话框，用户确认后保存
5. 如果存在但不匹配 → 显示警告，拒绝连接
6. 如果存在且匹配 → 继续连接
```

---

### Phase 18：文件操作增强（1 周）

**目标**：密码条目移动/重命名、文件夹创建/删除、目录树导航。支持文件式和目录式两种组织方式。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 18.1 | 移动密码条目 | 新建 `pages/MoveEntryPage.ets` + ViewModel + 目录选择器 | 可跨目录移动；移动后加密内容不变 | — |
| 18.2 | 重命名 | 扩展 `model/PasswordRepository.ets` | 修改文件名/路径；重命名后加密内容不变 | — |
| 18.3 | 文件夹 CRUD | 扩展 `model/PasswordRepository.ets` | 创建/删除/重命名文件夹 | — |
| 18.4 | 目录树选择器 | 新建 `views/FolderTreeView.ets` | 可在目录树中选择目标路径；支持向上导航；浮动按钮创建子文件夹 | — |
| 18.5 | 文件组织方式设置 | 扩展 `SettingsRepository.ets` + `Constants.ets` | 可配置文件式（`work/example.org/john@doe.org.gpg`）或目录式（`work/example.org/john@doe.org/password.gpg`） | — |
| 18.6 | 移动后列出目标目录 | 扩展 `pages/PasswordListPage.ets` | 移动/重命名后自动导航到目标目录 | 18.1 |

#### PasswordFileOrganization 枚举

```typescript
export enum PasswordFileOrganization {
  FILE = 'file',       // work/example.org/john@doe.org.gpg
  DIRECTORY = 'directory'  // work/example.org/john@doe.org/password.gpg
}
```

---

### Phase 19：Git HTTPS 支持（1 周）

**目标**：解决 libgit2 TLS 缺失问题，支持 HTTPS 协议 clone/pull/push。支持 HTTP(S) 代理。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 19.1 | libgit2 链接 mbedTLS | 修改 `cpp/CMakeLists.txt` + 编译 mbedTLS | HTTPS URL 可 clone；x86_64 + arm64 双 ABI | — |
| 19.2 | HTTPS 认证 | 扩展 `utils/GitClient.ets` + libgit2 credential callback | 用户名 + Token 认证回调；HTTPS 无认证也支持 | 19.1 |
| 19.3 | HTTP(S) 代理 | 扩展 libgit2 proxy 配置 + `pages/GitConfigPage.ets` | 可配置代理 URL | 19.1 |
| 19.4 | 外部仓库导入 | 新建 `pages/ImportRepoPage.ets` + ViewModel | 从文件系统导入已有 pass 仓库目录 | — |
| 19.5 | Git 凭据缓存 | 扩展 `utils/GitClient.ets` + `SettingsRepository.ets` | 可选缓存 Git 凭据（用户名/Token） | 19.2 |
| 19.6 | HTTPS URL 端口修复 | 扩展 `utils/GitClient.ets` | 修复含自定义端口的 HTTPS URL | 19.1 |

#### libgit2 TLS 集成方案

```
方案 A：mbedTLS（推荐）
- 轻量级，纯 C，交叉编译简单
- libgit2 有内置 mbedTLS 后端（-DGIT_TLS_BACKEND=mbedtls）
- 产物体积小

方案 B：OpenSSL
- 兼容性好但体积大
- 交叉编译配置复杂

选择 mbedTLS，在 CMakeLists.txt 中：
1. 编译 mbedTLS 静态库（arm64 + x86_64）
2. libgit2 链接 mbedTLS
3. 启用 GIT_TLS_BACKEND=mbedtls
```

---

### Phase 20：安全增强（1 周）

**目标**：敏感字段标记、PGP passphrase 缓存过期、每密钥独立 PIN。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 20.1 | 敏感字段标记 | 扩展 `format/PasswordFileParser.ets` + `pages/PasswordDetailPage.ets` | `*key*:` 或 `unsafe-keys:` 标记的字段默认隐藏；需点击展开 | — |
| 20.2 | Passphrase 缓存过期 | 扩展 `crypto/PgpCrypto.ets` + `SettingsRepository.ets` | 可配置缓存有效天数（默认 3 天）；过期后需重新生物识别 | — |
| 20.3 | 每密钥独立 PIN | 扩展 `utils/PinManager.ets` | 不同 PGP ID 对应不同 PIN；安全隔离 | — |
| 20.4 | 指纹 enrollment 检测 | 扩展 `utils/BiometricHelper.ets` | 检测新增指纹后通知用户 | — |
| 20.5 | 编辑对话框超时自动关闭 | 扩展 `pages/PasswordCreatePage.ets` | 配置超时后自动关闭编辑对话框（防泄露） | — |

#### 敏感字段格式

```
# 方式 1：星号标记
*api_key*: sk-xxxxxxxxxxxx
*secret*: my_secret_value

# 方式 2：gopass 语法
unsafe-keys: api_key, secret, token
api_key: sk-xxxxxxxxxxxx
secret: my_secret_value
token: abc123
```

---

### Phase 21：UI/UX 打磨与发布准备（2 周）

**目标**：全面对齐 HarmonyOS Design，性能优化，文档完善，准备正式发布。

#### 任务分解

| 编号 | 任务 | 产出文件 | 验收标准 | 依赖 |
|------|------|----------|----------|------|
| 21.1 | 全页面设计令牌审查 | 所有 pages/ 和 views/ | 无硬编码颜色；全部使用 ThemeColors 令牌 | — |
| 21.2 | 动画/过渡优化 | 扩展 `pages/Index.ets` + 各页面 | 页面转场动画、列表项动画；60fps 流畅 | — |
| 21.3 | 大列表性能 | 验证 `common/LazyDataSource.ets` | 1000+ 条目流畅滚动 | — |
| 21.4 | 单元测试补充 | 扩展 `test/` | 核心 ViewModel 测试；关键路径覆盖 > 60% | — |
| 21.5 | README 与使用文档 | `README.md` + `docs/` | 完整使用文档 + 截图；文档可发布 | — |
| 21.6 | 隐私政策 | 新建 `pages/PrivacyPolicyPage.ets` | 隐私政策页面；合规可发布 | — |
| 21.7 | 应用图标与启动页 | `resources/` | 品牌图标 + splash；视觉完整 | — |
| 21.8 | AppGallery 发布包 | 签名配置 | 签名 HAP/App；可上架 | — |
| 21.9 | 搜索结果过滤 | 扩展 `viewmodel/PasswordListViewModel.ets` | 精确匹配 / 模糊搜索切换 | — |
| 21.10 | ASCII armored 输出切换 | 扩展 `SettingsRepository.ets` + `crypto/PgpCrypto.ets` | 可切换 ASCII armored / 二进制加密输出 | — |
| 21.11 | 主页快捷方式 | 扩展 `entryability/EntryAbility.ets` | 可将密码条目固定到桌面快捷方式 | — |

---

## 五、技术风险与应对

| 风险 | 影响 | 概率 | 应对方案 | 关联 Phase |
|------|------|:----:|----------|:----------:|
| libgit2 TLS 支持缺失 | HTTPS 克隆不可用 | 高 | Phase 19 链接 mbedTLS；过渡期引导用户使用 SSH | Phase 19 |
| russh PGP 子键做 SSH 认证 | 高级 SSH 特性不可用 | 低 | Ed25519 PGP→SSH 已验证可用（RSA 不支持） | Phase 17 |
| autoFillManager API 差异 | 自动填充行为不一致 | 中 | 真机多设备端到端验证；模拟器降级路径已有 | Phase 5 |
| HUKS 跨设备密钥迁移 | 换设备无法恢复 | 低 | PGP 私钥加密存储于 Git 仓库内（.gpg 文件） | — |
| pgp 0.20 API 变更 | 编译错误 | 中 | 已适配 0.20 API，rand 锁定 0.8 | — |
| rpgp 密钥生成 API | 密钥生成功能不可用 | 低 | SecretKeyParamsBuilder + generate 已验证可用 | Phase 16 |
| mbedTLS 交叉编译 | 双 ABI 构建失败 | 中 | 预编译静态库 + CMakeLists OHOS_ARCH 选库 | Phase 19 |
| 1000+ 条目性能 | 列表滚动卡顿 | 低 | LazyForEach + LazyDataSource 已实现 | Phase 22 |
| pass CLI 兼容性 | 格式不互通 | 低 | 严格遵循 pass 文件格式规范；定期互测 | — |

---

## 六、开发规范

### 6.1 编码规范

- **状态管理**：所有 ArkTS/ArkUI 代码使用状态管理 V2，禁止使用 V1 装饰器。
- **架构分层**：MVVM 严格分层，View 不 import Model，ViewModel 不 import View。
- **命名**：新建代码标识符使用英文，保留已有的中文注释。文件命名 PascalCase（如 `PasswordListViewModel.ets`）。常量命名 UPPER_SNAKE_CASE。
- **ArkTS 限制**：
  - 禁止匿名对象字面量（`{ key: value }`）→ 必须定义 interface/class
  - 禁止展开运算符（`...`）
  - 禁止结构化类型
  - 禁止泛型索引访问（`this.cache[key] = value`）→ 必须用 switch-case 逐字段赋值
  - import 必须在文件顶部
  - 箭头函数回调需显式返回类型（`arkts-no-implicit-return-types`）
- **@Builder 限制**：按值传参不响应 `@Trace` 状态变化，涉及动态值需传 getter 函数（`(): string => this.viewModel.xxx`）。
- **@Param 回调属性**：`@ComponentV2` 中自定义组件的回调属性必须用 `@Param` 修饰。
- **bindSheet**：options 对象必须提为稳定成员变量，内联对象字面量会在重渲染时重新弹出。
- **注释密度**：匹配周围文件的注释密度，不逐行叙述显而易见的代码。

### 6.2 开发流程

1. 开发前调用 `deveco-cli` skills 确认开发环境。
2. 开发 ArkTS/ArkUI 代码时调用 `hmos-arkui-develop-skill` skills。
3. 查询鸿蒙开发文档使用 `devecocli docs`（search/read 子命令），不用 web 搜索或凭记忆推断。
4. 状态管理严格使用 V2（`@ObservedV2`/`@Trace`/`@ComponentV2`/`@Local`/`@Param`/`@Event`）。
5. 每个 Phase 完成后用 `devecocli build` 编译验证（等价 `hvigorw assembleHap`）。
6. 安装/调试操作通过 `devecocli` skill 调用（`devecocli run`、`devecocli ui screenshot`、`devecocli ui dump`）。
7. 提交信息使用 Conventional Commit 格式，中文描述。

### 6.3 Git 提交规范

```
<type>(<scope>): <中文描述>

<详细说明>

Co-Authored-By: AtomCode (glm-5.2) <noreply@atomgit.com>
```

**type**: `feat` | `fix` | `refactor` | `docs` | `chore` | `test` | `perf`

**scope**: `crypto` | `git` | `passgen` | `autofill` | `passkey` | `ui` | `model` | `settings` | `ssh` | `native`

**示例**:
```
feat(crypto): 新增 PGP 多密钥加密支持

- 扩展 PgpCrypto 支持多公钥加密
- .gpg-id 文件递归查找最近密钥
- 兼容 pass CLI 多接收方加密格式

Co-Authored-By: AtomCode (glm-5.2) <noreply@atomgit.com>
```

### 6.4 Native 开发规范

- **Rust crate 版本**：使用前必须先确认最新版本号（crates.io），尽量用最新版。已知版本：pgp 0.20.0、russh 0.63.3。
- **CC 环境变量**：`ring` 等 C/汇编 crate 的 CC 环境变量固化在 `.cargo/config.toml [env]`（OHOS clang），防止新会话丢失导致产出 glibc ABI 对象。
- **双 ABI 构建**：模拟器 x86_64 + 真机 arm64，CMakeLists.txt 按 `OHOS_ARCH` 选库路径。
- **NAPI import**：ArkTS 侧必须静态 import `.so`，不支持 require/动态 import。
- **回调返回类型**：箭头函数回调需显式返回类型（`arkts-no-implicit-return-types`）。
- **C++ string**：`std::string` 需 `#include <string>`，`napi_get_value_string_utf8` 写缓冲用 `&out[0]`（工具链下 `data()` 返回 `const char*`）。
- **Rust 链接**：Rust std 依赖 `libtime_service_ndk.so`（`OH_TimeService_GetTimeZone`），CMakeLists.txt 需链接该库。
- **rand 版本锁定**：pgp 0.20 依赖 rand 0.8.6，升 0.10 会产生双 rand_core 版本 trait 冲突，必须保持 0.8。

### 6.5 rpgp 0.20 API 速查

```rust
// 加密
let msg = MessageBuilder::from_bytes(plaintext)
    .seipd_v1(OsRng, SymmetricKeyAlgorithm::AES256)
    .encrypt_to_key(&mut OsRng, &pubkey)?
    .to_armored_string(OsRng, ArmorOptions::default())?;

// 解密
let (msg, headers) = Message::from_armor(ciphertext_bytes)?;
let decrypted = msg.decrypt(&Password::from(pw), &seckey)?
    .decompress()?
    .as_data_vec();

// 密钥解析
let seckey = SignedSecretKey::from_armor_single(armor_bytes)?;
let seckeys = SignedSecretKey::from_armor_many(armor_bytes)?;  // 多密钥

// 从私钥提取公钥
let pubkey = seckey.to_public_key();

// passphrase 验证（用签名实现）
seckey.sign(&mut OsRng, || Password::from(pw))?;

// KeyId 格式化：直接 {}（derive_more Display）
// Fingerprint 格式化：{:x}
// EncryptionKey 非 dyn-safe，需分子键/主键两分支
```

### 6.6 russh 0.63 API 速查

```rust
// 连接
let config = russh::client::Config::default();
let mut handle = russh::client::connect(config, addr, Handler).await?;

// 公钥认证
let auth_result = handle.authenticate_publickey(
    user,
    PrivateKeyWithHashAlg::try_from(key)?,
).await?;

// Handler::check_server_key 参数是 PublicKeyOrCertificate
// AuthResult.success() 判断认证成功
```

---

## 七、里程碑时间线

| 里程碑 | 时间 | 核心交付 | 状态 | 关联 Phase |
|--------|:----:|----------|:----:|:----------:|
| **M0–M14** | 已完成 | Phase 0–14 全部完成 | ✅ | Phase 0–14 |
| **M15** 目录级密钥 | 第 1 周 | `.gpg-id` 多密钥支持/多密钥加密 | ✅ | Phase 15 |
| **M16** PGP 密钥增强 | 第 3 周 | 应用内生成/导出/备份/改密码/多密钥导入 | ✅ | Phase 16 |
| **M17** SSH 高级 | 第 4 周 | known_hosts TOFU + PGP 做 SSH + 多认证 fallback | ✅ | Phase 17 |
| **M18** 文件操作 | 第 5 周 | 移动/重命名/文件夹 CRUD/目录树选择器 | ✅ | Phase 18 |
| **M19** Git HTTPS | 第 6 周 | mbedTLS + HTTPS clone/代理/外部导入 | ✅ | Phase 19 |
| **M20** 安全增强 | 第 7 周 | 敏感字段/缓存过期/独立 PIN/指纹检测 | ✅ | Phase 20 |
| **M21** 发布就绪 | 第 9 周 | UI 打磨/性能/测试/文档/隐私政策/上架 | ✅ | Phase 21 |
| **M22** 设计规范对齐 | 第 10 周 | 令牌迁移/字号阶梯/图标统一/emoji→sys.symbol | ✅ | Phase 22 |

**总计后续约 9 周**，完成后产出可正式发布于 AppGallery 的 HarmonyOS 密码管理应用。

### 里程碑甘特图

```
Week 1  ████████████  Phase 15: 目录级密钥
Week 2  ░░░░░░░░░░░░  （缓冲/集成测试）
Week 3  ████████████  Phase 16.1-16.3: PGP 生成/导出
Week 4  ████████████  Phase 16.4-16.8 + Phase 17: PGP 备份/SSH 高级
Week 5  ████████████  Phase 18: 文件操作
Week 6  ████████████  Phase 19: Git HTTPS
Week 7  ████████████  Phase 20: 安全增强
Week 8  ░░░░░░░░░░░░  （缓冲/集成测试）
Week 9  ████████████  Phase 21: UI 打磨/发布
Week 10 ████████████  Phase 22: 设计规范对齐（令牌/字号/图标）
```

---

## 八、验证策略

### 8.1 编译验证

- 每个 Phase 完成后执行 `devecocli build`（等价 `hvigorw assembleHap`）确保 0 编译错误。
- Native 变更后同时验证 arm64 和 x86_64 双 ABI。
- `SignHap` 步骤偶发失败，重试即成功。

### 8.2 功能验证

| 验证项 | 方法 | 工具 |
|--------|------|------|
| 模拟器安装运行 | `devecocli run`（安装运行） | devecocli |
| 截图归档 | `devecocli ui screenshot` → `docs/screenshots/` | devecocli |
| UI 层级定位 | `devecocli ui dump` 定位控件坐标 | devecocli |
| 像素采样验证 | Python PIL 采样亮度/像素 | Python |
| 模拟器 shell | `hdc -t 127.0.0.1:5555`（多设备必须显式指定 -t） | hdc |

#### 模拟器环境

- 模拟器地址：`127.0.0.1:5555`（x86_64 ABI）
- bundleName：`com.github.gmg137.HarmonyPasswordStore`
- 模拟器 shell 无法写入用户 Download 目录（hmdfs 权限限制），测试密钥需通过粘贴导入路径

### 8.3 安全验证

| 验证项 | 方法 | 预期结果 |
|--------|------|----------|
| 密钥不明文落盘 | grep 应用沙箱目录 | 无明文私钥 |
| 剪贴板自动清除 | 复制后等待 30s | 剪贴板已清空 |
| PIN 安全 | HUKS AES-GCM 加密验证 | 6 位最小长度 |
| 防爆破 | 连续 5 次错误 PIN | 锁定 30 秒 |
| 日志安全 | 检查 hilog 输出 | 不含密码/密钥/明文 |
| WebAuthn 域名校验 | 测试跨域请求 | 拒绝不匹配的 rpId |

### 8.4 兼容性验证

| 验证项 | 方法 | 预期结果 |
|--------|------|----------|
| `pass` CLI 互通 | Linux 上用 `pass` 解密鸿蒙创建的 `.gpg` 文件 | 成功解密，内容一致 |
| GPG 密钥互通 | `gpg --export-secret-keys` 导出的密钥导入应用 | 成功导入并使用 |
| Git 仓库互通 | 应用 clone 的仓库在 Linux 上 `pass git pull` | 成功同步 |
| APS 格式互通 | APS 创建的 passkey 文件导入应用 | 成功解析 |
| `.gpg-id` 互通 | 应用创建的 `.gpg-id` 在 `pass` CLI 中使用 | 正确识别密钥 |

### 8.5 验证截图归档

截图存放于 `docs/screenshots/`，按功能编号：

| 编号前缀 | 含义 | 示例 |
|----------|------|------|
| `01-15` | 初始功能截图 | `01_home.jpeg` |
| `u` | UI/UX 优化验证 | `u01_home.jpeg` |
| `z` | 端到端验证 | `z1_import_key.png` |
| `f` | 功能验证 | `f1_encrypt.png` |
| `x` | PGP 链路验证 | `x1_extract_pubkey.png` |
| `y` | 状态栏/主题验证 | `y2_dark_mode.png` |
| `w` | UI dump 验证 | `w1_home_dump.png` |

---

## 九、附录

### 9.1 关键技术决策记录

| 决策 | 选择 | 理由 |
|------|------|------|
| PGP 实现 | Rust rpgp (pgp 0.20.0) | 纯 Rust，无 C 依赖（除 ring），交叉编译友好 |
| SSH 实现 | Rust russh (0.63.3) | 纯 Rust SSH 客户端，API 稳定 |
| Git 实现 | libgit2 (C) | 成熟稳定，NAPI 桥接简单 |
| 密钥存储 | HUKS | 鸿蒙硬件级密钥管理，不可导出 |
| 状态管理 | V2（@ObservedV2/@Trace） | 鸿蒙推荐，性能更好，禁止 V1/V2 混用 |
| Passkey 签名 | cryptoFramework ECC-P256 | 不依赖 HUKS，纯软件实现 |
| 密钥传递 | PEM 文本经 FFI 内存传递 | 私钥不落盘 |
| rand 版本 | 锁定 0.8 | pgp 0.20 依赖 rand 0.8.6，双版本 trait 冲突 |
| 品牌色 | `#0A59F7`（浅色）/ `#4D8CFF`（深色） | HarmonyOS 强调色 |
| 设计令牌 | 卡片 16vp 圆角 + 12vp 内边距 | HarmonyOS Design 规范 |
| 窗口状态栏 | setWindowLayoutFullScreen + expandSafeArea + getWindowAvoidArea | 沉浸式布局 + 状态栏避让 |

### 9.2 已知限制

| 限制 | 说明 | 计划解决 |
|------|------|----------|
| libgit2 无 SSH/TLS 传输层 | `git@` 克隆走 russh；`https://` 不可用 | Phase 20 |
| autoFillExtensionAbility 基类缺失 | API 26 无 AutofillExtensionAbility 基类 | 使用 autoFillManager API |
| 模拟器 hmdfs 权限 | 无法写入 Download 目录 | 通过粘贴导入路径 |
| Ed25519 密钥导出 | getEncodedDer 不支持 Ed25519 | 用 Key.getEncoded() |
| RSA 私钥导出 | getEncodedDer 需 API 26+ | 已满足 |

### 9.3 参考资源

- [pass](https://www.passwordstore.org/) — 标准 Unix 密码管理器
- [Android-Password-Store](https://github.com/agrahn/Android-Password-Store) — 参考项目
- [HarmonyOS Design](https://developer.huawei.com/consumer/cn/design/) — 鸿蒙设计规范
- [rpgp](https://github.com/rpgp/rpgp) — Rust OpenPGP 实现
- [russh](https://github.com/AspectUniq/russh) — Rust SSH 客户端
- [libgit2](https://libgit2.org/) — Git 核心库
- [WebAuthn/FIDO2](https://webauthn.guide/) — Passkey 规范

### 9.4 APS Passkey 存储规范参考

Passkey 文件命名：`path/to/{Relying Party ID}/{Credential ID (64 hex)}.gpg`

Passkey CBOR 数据结构详见 [PasskeyStorage.md](https://github.com/agrahn/Android-Password-Store/blob/develop/PasskeyStorage.md)。

本项目 Passkey 编解码由 `format/PasskeyEncoder.ets` 实现，使用纯 ArkTS CBOR 编解码，兼容 APS v2.0 格式。

### 9.5 开发环境

| 工具 | 版本 | 路径 |
|------|------|------|
| devecocli | 1.3.2 | — |
| HarmonyOS SDK | API 26 | `$DEVECO_SDK_HOME`（如 `~/.deveco-cli-clt/sdk/default`） |
| Native 工具链 | — | `$DEVECO_SDK_HOME/openharmony/native/` |
| Rust 目标 | aarch64-unknown-linux-ohos + x86_64-unknown-linux-ohos | `rustup target add` |
| 参考仓库 | HarmonyOSComponentUXExamples | `/tmp/uxref` |

---

*本文档随项目开发持续更新。最后更新：Phase 22 完成后（设计规范对齐）。*
