# HarmonyPasswordStore

[简体中文](README.md) | [English](README_en.md) | [Русский](README_ru.md) | [Deutsch](README_de.md) | [繁體中文]

[pass](https://www.passwordstore.org/) 密碼管理器的 HarmonyOS（鴻蒙）原生用戶端，相容標準 pass 儲存庫格式，設計參考 [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)。應用顯示名稱為 **PasswordStore**。

## 功能特性

| 功能 | 說明 |
|------|------|
| 完整相容 pass | 標準目錄結構與 GPG 加密條目（`.gpg`）；`.gpg-id` 支援每行一把金鑰（指紋 / Key ID / 電子郵件均可），相容行尾註解與 `!` 強制子金鑰標記，與 pass CLI 及桌面端生態互通 |
| 後量子加密（PQC） | 支援 GnuPG algo 8 金鑰（ML-KEM-768 + X25519 / brainpoolP256r1 / brainpoolP384r1）的匯入與加解密，與 gpg 2.5+ 雙向互通；普通金鑰與 PQC 金鑰可作為同一條目的混合接收方 |
| 三種搜尋模式 | 模糊 / 精確 / **內容比對**——內容比對會解密條目並檢索除主密碼以外的欄位值（永不搜尋密碼本身），命中行附片段說明 |
| 密碼產生器 | 密碼學安全隨機來源；長度、字元集、排除易混淆字元；Diceware 口令詞組與熵值評估 |
| PGP 金鑰管理 | 從文字或檔案匯入（armor 與二進位自動識別）、產生 EdDSA/RSA 金鑰、修改金鑰密碼、匯出 `.asc` 檔案、預設加密金鑰選擇 |
| Git 同步 | SSH 與 HTTPS 的 clone / pull / push / commit；主機指紋 TOFU 三態校驗（首次連線確認 / 已信任 / 同類型不匹配告警）；強制推送；拉取變基；HTTPS 代理 |
| 自動填入 | 對接系統自動填入框架，按套件名 / 網域比對憑證候選 |
| 生物辨識解鎖 | 指紋 / 面容（鎖定時自動拉起系統認證）；工作階段逾時自動上鎖；上鎖即清空記憶體中的密碼與解密快取 |
| 檔案管理 | 目錄樹瀏覽、條目移動 / 重新命名（跨金鑰目錄自動重新加密）、目錄建立與刪除 |
| 密碼檔案格式 | 二進位（與桌面 pass 輸出一致）或 ASCII armor，可隨時切換（僅影響新寫入） |
| 剪貼簿安全 | 複製密碼後定時自動清除；透過短時任務保障應用在背景時清除依然生效 |
| 多語言 | 簡體中文、繁體中文、English、Deutsch、Русский（跟隨系統，可在應用內切換） |

## 系統需求

- HarmonyOS 手機（API 26+）

## 建置與安裝

首次建置前，先從範本產生本機簽署設定（該檔含簽署材料路徑與口令，**不入庫**）：

```bash
cp build-profile.example.json5 build-profile.json5
```

再用 DevEco Studio 開啟專案，經 **File → Project Structure → Signing Configs** 勾選 Automatically generate signature 產生除錯簽署材料（命令列建置同樣依賴該檔案）。

然後即可用 [DevEco Studio](https://developer.huawei.com/consumer/harmonyos/)（含 HarmonyOS SDK）開啟專案建置，或以命令列（Hvigor）建置：

```bash
hvigorw assembleHap                                            # 除錯 HAP
hvigorw -p buildMode=release assembleHap                       # release（啟用 ArkTS 混淆）
hvigorw -p product=default -p buildMode=release assembleApp    # 發布 .app 套件
```

產物位置：HAP 在 `entry/build/default/outputs/default/`，.app 在專案根 `build/outputs/default/`。

PGP（Rust）與 Git（libgit2）的 native 靜態函式庫已隨儲存庫預先編譯（aarch64 / x86_64 雙 ABI），一般建置無需 Rust 工具鏈；如需修改 native 程式碼，見 `entry/src/main/cpp/rpgp_wrapper/`（Rust 側單元測試：`cargo test --release`）。

## pass 儲存庫格式相容性

- 條目為 `<目錄>/<名稱>.gpg`，解密後首行是密碼，後續行為 `user:` / `email:` / `phone:` / `notes:` 欄位與自由文字
- 儲存庫根（及任意子目錄）的 `.gpg-id` 指定加密公鑰，支援多把金鑰與全部 pass 寫法
- 解密按**密文實際收件人**選擇金鑰（與 `pass show` 行為一致），缺少金鑰時明確提示而不是反覆索要密碼
- 產生的密文可用桌面端 `gpg --decrypt` 直接驗證

## 安全設計

- **本機優先**：無任何雲端服務，密碼只存在於本機加密檔案與您設定的 Git 遠端
- **明文生命週期**：解密內容僅存在於記憶體；搜尋快取只儲存「除主密碼外的欄位值」的衍生文字；應用上鎖或切至背景時統一清空（含 native 側已解鎖私鑰快取）
- **憑證封裝**：Git 憑證等敏感資訊經 HUKS 加密落盤；剪貼簿內容定時自動清除
- **日誌安全**：日誌不輸出密碼、金鑰與明文內容
- **匯入強化**：armor 匯入時統一正規化（防止單行 base64 導致 native 解析失敗）；二進位密文經 CRC24 校驗後才寫入

## 單元測試

ArkTS（LocalUnit，在 DevEco Studio 中執行；新檔案須在 `List.test.ets` 手工登記）：

```
entry/src/test/
├── List.test.ets               # 測試套件入口
├── PasswordFileParser.test.ets # pass 格式解析 / 序列化往返 / 可搜尋文字與命中片段
├── PgpPacketParser.test.ets    # armor 轉換（CRC24 對照 RFC 4880 標準向量）與 gpg 指紋對照
├── PasswordGenerator.test.ets  # 產生器長度 / 字元集 / 歧義排除 / 熵值
├── CredentialMatcher.test.ets  # 自動填入套件名網域比對 / RP ID 校驗
└── PathSafety.test.ets         # 路徑穿越防護（使用者輸入與儲存庫內容雙來源）
```

Rust（27 個用例，含 gpg 端對端與 PQC 互通）：

```bash
cd entry/src/main/cpp/rpgp_wrapper && cargo test --release
```

## 相關專案

- [pass — the standard unix password manager](https://www.passwordstore.org/)
- [Android-Password-Store](https://github.com/agrahn/Android-Password-Store)

## 開源授權

GPL-3.0（第三方元件的授權資訊見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）
