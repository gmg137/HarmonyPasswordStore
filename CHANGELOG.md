# 变更记录

本文件记录 HarmonyPasswordStore 各 Phase 的变更。版本号遵循 `主.次.阶段` 格式。

## 未发布（v1.0.0 之后）

- 修复 AGC 上架审核报出的两处问题：
  - **色彩对比度**：浅色 `textTertiary`（原 `#9AA0A9`，仅 2.09~2.63:1）同时低于「正文 >4.5:1」与「图标/标题 >3:1」两条线，而它既做行说明/占位符又做行尾箭头与空状态图标；语义色 success/warning/danger 也按色块取值（亮绿 2.39:1、橙黄 2.10:1）却被当状态文字与图标用。两套调色板重新取值，并新增 `scripts/check-contrast.mjs` 全矩阵校验防回归
  - **底部导航条适配**：Git 配置页底栏与初始设置页按钮行硬编码 24vp 底部留白（未避让导航条），三处 FAB 用 `y:'88%'` 百分比定位（矮窗口/高导航条下会落进导航条区或顶出屏幕），多个滚动页面末尾元素可被导航条压住——统一改为按 `SystemInsets.bottomVp()` 避让
- 修复新建密码页的强度分级：`getStrengthColor` 把阈值抄成 `< 8`（应为 `< 120`），80~119 bits 的密码「标签显示强、颜色却是极强」，且「强」这一档的颜色永远取不到。阈值与分档收敛到 `PasswordGenerator.strengthTier()` 一处，两个 ViewModel 改为转发，并补分档回归用例
- 新增 GnuPG algo 8（ML-KEM 后量子混合）密钥支持：`ky768_cv25519` / `ky768_bp256` / `ky1024_bp384` 的导入、加解密与改口令，与 gpg 2.5+ 双向互通；普通密钥与 PQC 密钥可混合作为同一条目的收件人
- 新增「内容匹配」搜索模式：解密检索除主密码外的字段值（密码永不成为搜索目标），命中行附片段说明
- `.gpg-id` 兼容性增强：支持行尾注释、`!` 强制子密钥标记、邮箱 / `0x` Key ID / 短 Key ID 写法；解密按密文实际收件人选密钥（对齐 `pass show`）
- SSH 主机密钥 TOFU 升级为「类型 + 指纹」多条目三态校验（已信任 / 未信任 / 同类型不匹配告警）
- 条目移动 / 重命名到其他密钥目录时自动重加密
- 密码文件密文格式可配（二进制 / ASCII armor，仅影响新写入）
- 新增繁體中文 / Deutsch / Русский 界面语言（应用内可切换）
- Git 提交跳过无变化的情况（不再产生空提交）；提交后写回 index 并在同步摘要中显示 ahead/behind
- 移除 Passkey（WebAuthn/FIDO2）功能
- 移除 PIN 解锁，应用锁仅保留生物识别（设备不可用时置灰并显示原因）

## v1.0.0 — Phase 0–21 完成（2026-09）

### Phase 21：发布就绪
- 编写 README.md（功能特性/架构/构建/安全设计/里程碑总览全面更新）
- 编写 CHANGELOG.md（Phase 0–21 完整变更记录）
- 新增隐私政策页（PrivacyPolicyPage：路由 + 设置入口）
- 新增关于页面（AboutPage：版本号/开源协议/仓库链接）
- UI 全局主题一致性检查与打磨
- 模拟器端到端回归验证

### Phase 20：安全增强
- 密码详情页敏感字段遮罩：password/notes/extraContent 默认显示 `••••••••`，点击 eye/eye_slash 图标切换可见性
- 内存缓存过期机制：SshKeyManager/PasskeyManager 新增 `clearCache()`，AppLockManager `onBackground()`/`lock()` 自动调用
- 独立 PIN 锁核实：PinManager（HUKS salt+混淆摘要）与生物识别完全分离，已完整实现
- 指纹检测增强：`checkBiometricDetail()` 区分三态（可用/支持但未注册/不支持），设置页红字友好提示
- 清理遗留 `Constants.APP_LOCK_TIMEOUT`（已无引用）

### Phase 19：Git HTTPS 支持
- mbedTLS 2.28.8 交叉编译：双 ABI（arm64 + x86_64）fPIC 静态库
- libgit2 重编译：`USE_HTTPS=mbedTLS` + PIC + 全量归档（含 util/xdiff/reftable/llhttp/pcre2）
- NAPI 认证回调：`git_credential_userpass_plaintext_new`（新 API），gitClone/Pull/Push 接入凭据参数
- GitClient HTTPS 协议预检测改为 `supported: true`；clone/pull/push 自动从 GitConfig 传用户名/Token
- HTTP(S) 代理配置：`GitNetOpts` + `GIT_PROXY_SPECIFIED`；GitConfig 新增 proxyUrl 字段 + UI 输入框
- GitClonePage 新增"粘贴"按钮（剪贴板导入仓库地址，校验 URL 前缀）
- CMakeLists 显式链接 mbedtls + mbedx509 + mbedcrypto 三个 IMPORTED 目标

### Phase 18：文件操作增强
- `renamePassword` 增强：源文件校验、目标重名拒绝、跨目录移动自动创建目标目录、源目录级联清理
- 补齐 `renameDirectory`（fs.renameSync 对目录整体随迁，子目录级 .gpg-id 不受影响）
- 新建 `FolderTreeView` 组件：展开式目录树（根目录常驻可选）、懒加载子目录、隐藏文件过滤、选中高亮
- 新建 `MoveEntryViewModel` + `MoveEntryPage`：名称输入 + 目录树选择 + 保存执行
- 路由 `MOVE_ENTRY` 注册；详情页新增"移动 / 重命名"入口按钮
- 保存成功后 RepoChangeNotifier 自动刷新 + 800ms 后 pop 返回

### Phase 17：SSH 高级特性
- FFI 新增 `hps_ssh_fingerprint`（主机指纹探测）、`hps_pgp_key_as_ssh`（Ed25519 种子→OpenSSH PEM）、`hps_ssh_public_from_private`（authorized_keys 单行）
- `hps_ssh_test_auth`/`hps_ssh_test_password` 改造：ClientHandler 结构体捕获指纹 + 期望指纹校验（不匹配拒绝连接）
- 新建 `KnownHostsStore`（preferences 持久化 host[:port]→指纹）
- SshClient TOFU 三态：unknown（探测返回 UI 确认）/ trusted（带期望指纹直连）/ mismatch（拒绝提示中间人）
- GitConfigViewModel TOFU 状态管理 + GitConfigPage 指纹确认对话框

### Phase 16：PGP 密钥生成与管理增强
- FFI 新增 5 函数：`hps_pgp_generate_key`（V4 EdDSA/ECDH 或 RSA）、`hps_pgp_change_passphrase`、`hps_pgp_backup_key`（GPG 兼容 SKESK + iterated-salted S2K AES-256）、`hps_pgp_restore_backup`、`hps_pgp_split_keyring`
- PgpKeyManager 新增 generateKey/changePassphrase/backupKey/backupAllKeys/importSecretKeysFromArmored
- UI：PgpKeyManagerPage 生成面板（算法 chips + User ID + 密码 + Loading）；过期密钥红色徽标

### Phase 15：目录级 `.gpg-id` 多密钥
- `getGpgIdForPath` 补 `#` 注释行过滤 + `findGpgIdDir`
- 多密钥加密：Rust `hps_pgp_encrypt` 改用 `from_armor_many` 解析拼接公钥逐一 `encrypt_to_key`
- PgpCrypto.encrypt 收集 .gpg-id 全部指纹公钥
- 新建 FolderCreateViewModel + FolderCreatePage（密钥多选 Set<string> + toggleKey/isKeySelected）
- 主页新增📁浮动按钮入口；路由 FolderCreate 注册
- 无效 .gpg-id 修复：resolveKeyByIdEntry（KeyID/小写指纹大小写不敏感）+ validateFingerprints

### Phase 0–14：基础架构（已完成）
- Phase 0：项目初始化、MVVM 骨架、ThemeColors 令牌层
- Phase 1：密码 CRUD（创建/查看/编辑/删除）+ PasswordFileParser pass 格式
- Phase 2：密码生成器（字符集/Diceware）+ 搜索排序
- Phase 3：Git 同步层（libgit2 桥接 clone/pull/push/commitAll）
- Phase 4：设置与生物识别/PIN 锁
- Phase 5：自动填充（autoFillManager + 凭据匹配）
- Phase 6：Passkey（WebAuthn/FIDO2 ES256/Ed25519/RS256）
- Phase 7：UI 打磨（沉浸式布局、SafeArea 避让、主题深浅切换）
- Phase 8：i18n 国际化（中/英）
- Phase 9：单元测试（PasswordFileParser/PasswordGenerator/CredentialMatcher）
- Phase 10：Native 桥接层骨架（NAPI/CMakeLists/双 ABI）
- Phase 11：PGP native（rpgp encrypt/decrypt/extractPublicKey）
- Phase 12：SSH native（russh 握手 + 公钥/密码认证）
- Phase 13：Git native 增强（commitAll/log/status）
- Phase 14：双 ABI 完善（模拟器 x86_64 + 真机 arm64）

## 开源协议

GPL-3.0
