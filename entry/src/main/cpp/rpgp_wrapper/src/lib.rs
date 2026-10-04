//! rpgp FFI wrapper for HarmonyPasswordStore
//!
//! C ABI 供 NAPI (hps_napi.cpp) 调用：
//! PGP（pgp 0.20 / rpgp）：
//! - hps_pgp_encrypt(plaintext, pubkey_armored) -> armored ciphertext
//! - hps_pgp_decrypt(ciphertext_armored, seckey_armored, passphrase) -> plaintext
//! - hps_pgp_list_keys(keyring_armored) -> JSON metadata array
//! - hps_pgp_verify_passphrase(seckey_armored, passphrase) -> 验证 passphrase
//! SSH（russh 0.63）：
//! - hps_ssh_test_auth / hps_ssh_test_password
//! 内存：
//! - hps_pgp_result_free(result) 释放

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::ffi::{CStr, CString};
use std::hash::{Hash, Hasher};
use std::os::raw::{c_char, c_int};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use pgp::composed::{
    ArmorOptions, DecryptionOptions, Deserializable, EncryptionCaps, KeyType, Message,
    MessageBuilder, SecretKeyParamsBuilder, SignedPublicKey, SignedSecretKey,
    SubkeyParamsBuilder, TheRing,
};
use pgp::crypto::ecc_curve::ECCCurve;
use pgp::crypto::sym::SymmetricKeyAlgorithm;
use pgp::types::{DecryptionKey, KeyDetails, Password, SigningKey};
use rand::rngs::OsRng;

use std::sync::{Arc, Mutex, OnceLock};
use russh::client;
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};

/// GnuPG algo 8（`ky768_cv25519` = ML-KEM-768 + X25519）互通模块。
///
/// pgp 0.20 会静默丢弃 v5 子密钥包，故该算法的密钥无法走 pgp crate，
/// 由本模块独立解析与解密（详见模块头部说明）。
pub mod gpg_pqc;

/// FFI 返回结果
#[repr(C)]
pub struct FfiResult {
    pub success: c_int,
    pub error: *mut c_char,
    pub data: *mut c_char,
}

impl FfiResult {
    fn ok(data: String) -> Self {
        let data_c = CString::new(data).unwrap_or_else(|_| CString::new("").unwrap());
        FfiResult {
            success: 0,
            error: ptr::null_mut(),
            data: data_c.into_raw(),
        }
    }

    fn err(msg: String) -> Self {
        let err_c = CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
        FfiResult {
            success: 1,
            error: err_c.into_raw(),
            data: ptr::null_mut(),
        }
    }
}

/// 在 FFI 边界拦截 panic
///
/// panic 跨越 `extern "C"` 边界是未定义行为，在 OHOS 上表现为应用直接闪退。
/// 而本模块多数函数的输入是攻击者可控的（.gpg 来自同步下来的远端仓库、
/// keyring 来自用户导入/还原），解析路径上任何意外的越界或断言都会 panic。
/// 故所有导出函数都必须经此包装，把 panic 转成正常的错误返回。
fn ffi_guard<F>(f: F) -> FfiResult
where
    F: FnOnce() -> FfiResult,
{
    match panic::catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(_) => FfiResult::err("internal panic (invalid input?)".into()),
    }
}

fn cstr_to_string(s: *const c_char) -> String {
    if s.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(s).to_string_lossy().into_owned() }
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

// ========== PGP 加密 ==========

/// 解析「单个或多个 armored 公钥拼接」的输入
///
/// **不能**用 rpgp 的 `from_armor_many`：它对连续 armor 块只解析第一块
/// （实测 `\n`/`\n\n`/无分隔/CRLF 全部如此），多接收方加密会静默丢掉
/// 除第一把外的全部接收方——`.gpg-id` 写了 N 把密钥、密文却只发给第一把，
/// 其余接收方永远解不开。改为按 BEGIN/END 切块逐把 `from_armor_single`，
/// 与 PQC 路径 `gpg_pqc::extract_public_keys_multi` 的既有做法对齐。
/// 单块解析失败**整体报错**（不静默跳过）：加密给少于请求的接收方属于
/// 必须暴露的错误，宁失败不缺员。
///
/// 本函数**不加** `#[no_mangle]`（内部辅助，不导出符号）；紧接其后的
/// `hps_pgp_encrypt` 才是 FFI 入口，属性只修饰紧随其后的第一个 item。
fn parse_public_keys_many(armored: &str) -> Result<Vec<SignedPublicKey>, String> {
    let blocks = gpg_pqc::split_armor_blocks(armored);
    if blocks.is_empty() {
        return Err("no public key block found".into());
    }
    let mut keys = Vec::with_capacity(blocks.len());
    for block in &blocks {
        let (key, _headers) = SignedPublicKey::from_armor_single(block.as_bytes())
            .map_err(|e| format!("parse public key failed: {}", e))?;
        keys.push(key);
    }
    Ok(keys)
}

#[no_mangle]
pub extern "C" fn hps_pgp_encrypt(
    plaintext: *const c_char,
    pubkey_armored: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let plaintext = cstr_to_string(plaintext);
        let pubkey_armored = cstr_to_string(pubkey_armored);

        if pubkey_armored.is_empty() {
            return FfiResult::err("public key is empty".into());
        }

        // 解析公钥证书（支持单个或多个 armored 公钥拼接）
        let pubkeys = match parse_public_keys_many(&pubkey_armored) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(e),
        };
        if pubkeys.is_empty() {
            return FfiResult::err("no valid public key found".into());
        }

        // 构建 SEIPD v1 加密消息（AES-256，兼容旧版 GPG）
        // 对每个公钥调用 encrypt_to_key（多接收方加密）
        let mut builder = MessageBuilder::from_bytes("data", plaintext.into_bytes())
            .seipd_v1(OsRng, SymmetricKeyAlgorithm::AES256);
        for pubkey in &pubkeys {
            let enc_result = match pubkey.public_subkeys.iter().find(|sk| sk.algorithm().can_encrypt()) {
                Some(subkey) => builder.encrypt_to_key(OsRng, subkey),
                None => builder.encrypt_to_key(OsRng, pubkey),
            };
            if let Err(e) = enc_result {
                return FfiResult::err(format!("encrypt failed: {}", e));
            }
        }

        // 序列化为 armored 文本
        let armored = match builder.to_armored_string(OsRng, ArmorOptions::default()) {
            Ok(s) => s,
            Err(e) => return FfiResult::err(format!("armor failed: {}", e)),
        };

        FfiResult::ok(armored)
    })
}

// ========== PGP 公钥提取 ==========

/// 从 ASCII-armored 私钥提取公钥（armor 输出）
/// hps_pgp_extract_public_key(seckey_armored) -> armored public key
#[no_mangle]
pub extern "C" fn hps_pgp_extract_public_key(seckey_armored: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let seckey_armored = cstr_to_string(seckey_armored);
        if seckey_armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }

        let (seckey, _headers) = match SignedSecretKey::from_armor_single(seckey_armored.as_bytes()) {
            Ok(result) => result,
            Err(e) => return FfiResult::err(format!("parse secret key failed: {}", e)),
        };

        // 私钥转公钥（rpgp 0.20 SignedSecretKey::to_public_key）
        let pubkey: SignedPublicKey = seckey.to_public_key();
        let armored = match pubkey.to_armored_string(ArmorOptions::default()) {
            Ok(s) => s,
            Err(e) => return FfiResult::err(format!("armor public key failed: {}", e)),
        };

        FfiResult::ok(armored)
    })
}

// ========== 已解锁私钥缓存 ==========
//
// 为什么需要：`hps_pgp_decrypt` 原先每次调用都从 armored 文本重新解析私钥，并由
// `decrypt_the_ring` 用口令跑一遍**迭代 S2K** 解锁（GnuPG 默认 count 可达 65M 哈希量，
// 单次几十毫秒）。内容搜索要逐条解密整个仓库，「每条一次解锁」会被放大成 N 倍——
// 冷缓存首搜的耗时几乎全在这里。缓存后每把密钥每会话只解锁一次。
//
// 键 = armored 文本 + 口令：换了口令（或换/改写了密钥文件）后两者都会变，
// 旧条目自然不再命中，不需要额外的失效逻辑。
//
// **值是明文私钥材料**，与 ArkTS 侧的口令缓存同级敏感：`hps_pgp_lock()` 必须清空它
// （`PgpCrypto.lock()` 在上锁/切后台时调用，见 AppLockManager.clearSensitiveCaches）。

/// 已解锁私钥缓存上限（按键数计：正常仓库只有个位数密钥；
/// 超限就整体清空，避免异常调用方塞入无限多口令把内存撑爆）
const MAX_UNLOCKED_KEYS: usize = 16;

/// 普通密钥（rpgp 路径）：`remove_password` 之后的密钥副本（私钥段已是明文）
static UNLOCKED_KEYS: OnceLock<Mutex<HashMap<u64, Arc<SignedSecretKey>>>> = OnceLock::new();

/// GnuPG algo 8 密钥：已解出的 ECC 标量 + ML-KEM 材料
static UNLOCKED_PQC_KEYS: OnceLock<Mutex<HashMap<u64, Arc<gpg_pqc::GpgPqcKey>>>> = OnceLock::new();

fn unlocked_keys() -> &'static Mutex<HashMap<u64, Arc<SignedSecretKey>>> {
    UNLOCKED_KEYS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn unlocked_pqc_keys() -> &'static Mutex<HashMap<u64, Arc<gpg_pqc::GpgPqcKey>>> {
    UNLOCKED_PQC_KEYS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 缓存键：armored 文本 + 口令的哈希
///
/// 不直接用 `armored + "\u{0}" + passphrase` 作键：
/// 1. 明文口令会因此驻留 HashMap 键字符串中（上锁才清，会话期间始终在内存）；
/// 2. `\u{0}` 假设口令不含空字节，含空字节的口令会与其它组合碰撞。
/// 改为对 (armored, passphrase) 做 SipHash（DefaultHasher），键中不再出现口令明文，
/// 也无分隔符歧义。SipHash 64 位输出对「个位数密钥 × 个位数口令」的缓存规模
/// 碰撞概率可忽略。
fn unlocked_cache_key(armored: &str, passphrase: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    armored.hash(&mut hasher);
    passphrase.hash(&mut hasher);
    hasher.finish()
}

/// 取（未命中则解析并解锁后缓存）私钥：主键与子键都就地去除口令保护
///
/// 口令错误时由 `remove_password` 报错，错误文案保持「unlock … failed」形态，
/// 便于上层把它归为「口令不正确」。
fn cached_secret_key(armored: &str, passphrase: &str) -> Result<Arc<SignedSecretKey>, String> {
    let key = unlocked_cache_key(armored, passphrase);
    if let Some(hit) = unlocked_keys().lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return Ok(hit.clone());
    }

    let (mut seckey, _headers) = SignedSecretKey::from_armor_single(armored.as_bytes())
        .map_err(|e| format!("parse secret key failed: {}", e))?;
    let pw = Password::from(passphrase);
    seckey.primary_key.remove_password(&pw)
        .map_err(|e| format!("unlock secret key failed: {}", e))?;
    // 子键尽力而为：主键口令正确即可用（旧实现里 rpgp 也只解锁它真正用到的那把），
    // 子键口令与主键不同（gpg 允许 `--change-passphrase <subkey>`）时不能让整体失败——
    // 那把子键解不开，用到它的密文照旧失败，与旧行为一致
    for sub in seckey.secret_subkeys.iter_mut() {
        let _ = sub.key.remove_password(&pw);
    }

    let arc = Arc::new(seckey);
    let mut slot = unlocked_keys().lock().unwrap_or_else(|e| e.into_inner());
    if slot.len() >= MAX_UNLOCKED_KEYS {
        slot.clear();
    }
    slot.insert(key, arc.clone());
    Ok(arc)
}

/// 取（未命中则解出后缓存）GnuPG algo 8 的私钥材料
///
/// `gpg_pqc::extract_key` 内部的 `s2k_iterated_salted` 与 rpgp 侧同样是迭代 S2K，
/// 逐条解密时同样会被放大，故一并缓存。
fn cached_pqc_key(armored: &str, passphrase: &str) -> Result<Arc<gpg_pqc::GpgPqcKey>, String> {
    let key = unlocked_cache_key(armored, passphrase);
    if let Some(hit) = unlocked_pqc_keys().lock().unwrap_or_else(|e| e.into_inner()).get(&key) {
        return Ok(hit.clone());
    }

    let parsed = gpg_pqc::extract_key(armored, passphrase)
        .map_err(|e| format!("parse gpg pqc key failed: {}", e))?;
    let arc = Arc::new(parsed);
    let mut slot = unlocked_pqc_keys().lock().unwrap_or_else(|e| e.into_inner());
    if slot.len() >= MAX_UNLOCKED_KEYS {
        slot.clear();
    }
    slot.insert(key, arc.clone());
    Ok(arc)
}

/// 清空已解锁私钥缓存（应用上锁 / 切到后台时调用）
///
/// hps_pgp_lock()
#[no_mangle]
pub extern "C" fn hps_pgp_lock() {
    unlocked_keys().lock().unwrap_or_else(|e| e.into_inner()).clear();
    unlocked_pqc_keys().lock().unwrap_or_else(|e| e.into_inner()).clear();
}

// ========== PGP 解密 ==========
#[no_mangle]
pub extern "C" fn hps_pgp_decrypt(
    ciphertext_armored: *const c_char,
    seckey_armored: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let ciphertext = cstr_to_string(ciphertext_armored);
        let seckey_armored = cstr_to_string(seckey_armored);
        let passphrase = cstr_to_string(passphrase);

        if ciphertext.is_empty() {
            return FfiResult::err("ciphertext is empty".into());
        }
        if seckey_armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }

        // 取已解锁私钥：未命中缓存时解析并就地去除口令保护（迭代 S2K 只跑这一次，
        // 之后同一把密钥的每条密文都直接复用——内容搜索逐条解密的耗时全在这里）
        let seckey = match cached_secret_key(&seckey_armored, &passphrase) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(e),
        };

        // 解析密文消息
        let mut msg = match Message::from_armor(ciphertext.as_bytes()) {
            Ok((m, _headers2)) => m,
            Err(e) => return FfiResult::err(format!("parse ciphertext failed: {}", e)),
        };

        // 密钥已在 `cached_secret_key` 里解锁（私钥段为明文），故这里**不带口令**
        // 且 `is_locked = false`：rpgp 会直接用明文材料，跳过迭代 S2K。
        // **必须显式开启 GnuPG AEAD（tag 20）**：GnuPG 2.4+ 对「偏好里带 AEAD 的密钥」
        // 默认用这种 GnuPG 私有格式加密消息，而 rpgp 出于「非 IETF 标准」默认拒绝
        // （报 `GnuPG's AEAD packet (type 20) is non-standard, 'DecryptionOptions'
        // allows opting into it`）。不开这个开关，凡是新版 gpg 加密的条目在本应用里
        // 都解不开——而 gpg/pass 自己解得好好的，用户只会看到「解密失败」。
        // 注：`gpg_pqc`（GnuPG algo 8）那条路径自己实现了 tag 20 分块解密，与本处无关。
        let ring = TheRing {
            secret_keys: vec![&*seckey],
            key_passwords: Vec::new(),
            decrypt_options: DecryptionOptions::new().enable_gnupg_aead(),
            ..Default::default()
        };
        let mut decrypted = match msg.decrypt_the_ring(ring, false) {
            Ok((d, _)) => d,
            Err(e) => return FfiResult::err(format!("decrypt failed: {}", e)),
        };

        // 压缩层解压。rpgp 的 decompress 无输出上限，而密文可能来自同步下来的
        // 远端仓库（攻击者可控），解压炸弹会把进程拖到 OOM 被杀——
        // 故解压后校验字面数据长度，超限直接报错。
        if decrypted.is_compressed() {
            decrypted = match decrypted.decompress() {
                Ok(d) => d,
                Err(e) => return FfiResult::err(format!("decompress failed: {}", e)),
            };
        }

        // 提取明文
        let plaintext = match decrypted.as_data_vec() {
            Ok(data) => {
                if data.len() as u64 > gpg_pqc::MAX_DECOMPRESSED_BYTES {
                    return FfiResult::err(format!(
                        "decompressed data too large ({} bytes)",
                        data.len()
                    ));
                }
                String::from_utf8_lossy(&data).into_owned()
            }
            Err(e) => return FfiResult::err(format!("read literal data failed: {}", e)),
        };

        FfiResult::ok(plaintext)
    })
}

// ========== GnuPG PQC（algo 8 / ky768_cv25519）解密 ==========

/// 解密由 GnuPG 2.5 用 algo 8（`ky768_cv25519` = ML-KEM-768 + X25519）加密的报文。
///
/// pgp 0.20 会静默丢弃 v5 子密钥包，故该算法的密钥走不了 rpgp，
/// 由 `gpg_pqc` 模块独立解析（含带口令保护段）并解密。
///
/// hps_pgp_decrypt_gpg_pqc(ciphertext, seckey_armored, passphrase) -> plaintext
#[no_mangle]
pub extern "C" fn hps_pgp_decrypt_gpg_pqc(
    ciphertext: *const c_char,
    seckey_armored: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let ciphertext = cstr_to_string(ciphertext);
        let seckey_armored = cstr_to_string(seckey_armored);
        let passphrase = cstr_to_string(passphrase);

        if ciphertext.is_empty() {
            return FfiResult::err("ciphertext is empty".into());
        }
        if seckey_armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }

        // 取私钥材料（未命中缓存时才解保护段——这一步同样是迭代 S2K，
        // 逐条解密时会被放大成 N 倍）
        let key = match cached_pqc_key(&seckey_armored, &passphrase) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(e),
        };

        // 密文可能是 armored 文本，也可能是二进制 OpenPGP
        let raw = if ciphertext.contains("-----BEGIN") {
            match gpg_pqc::dearmor(&ciphertext) {
                Ok(d) => d,
                Err(e) => return FfiResult::err(format!("dearmor ciphertext failed: {}", e)),
            }
        } else {
            ciphertext.as_bytes().to_vec()
        };

        match gpg_pqc::decrypt_message(&key, &raw) {
            Ok(data) => FfiResult::ok(String::from_utf8_lossy(&data).into_owned()),
            Err(e) => FfiResult::err(format!("gpg pqc decrypt failed: {}", e)),
        }
    })
}

/// 用 GnuPG algo 8（`ky768_cv25519` = ML-KEM-768 + X25519）公钥加密明文。
///
/// rpgp 会丢弃 v5 子密钥包，无法用它加密；由 `gpg_pqc` 独立模块构造
/// PKESK(algo 8) + SEIPDv1（RFC 标准格式，gpg 可直接解密）。
///
/// `pubkey_armored` 可含**多个**拼接的 armored 块（多接收方）——注意传**私钥**
/// armored 亦可（其公钥部分足够加密），因为 rpgp 的 `to_public_key` 会丢掉
/// algo 8 的 v5 子密钥，故调用方应传原始存储的 armored 而非 rpgp 导出的公钥。
///
/// hps_pgp_encrypt_gpg_pqc(plaintext, pubkey_armored) -> armored ciphertext
#[no_mangle]
pub extern "C" fn hps_pgp_encrypt_gpg_pqc(
    plaintext: *const c_char,
    pubkey_armored: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let plaintext = cstr_to_string(plaintext);
        let pubkey_armored = cstr_to_string(pubkey_armored);

        if pubkey_armored.is_empty() {
            return FfiResult::err("public key is empty".into());
        }

        let pubkeys = gpg_pqc::extract_public_keys_multi(&pubkey_armored);
        if pubkeys.is_empty() {
            return FfiResult::err("no GnuPG algo 8 (PQC) public key found".into());
        }

        match gpg_pqc::encrypt_message_multi(&pubkeys, plaintext.as_bytes()) {
            Ok(raw) => FfiResult::ok(gpg_pqc::armor(&raw, "PGP MESSAGE")),
            Err(e) => FfiResult::err(format!("gpg pqc encrypt failed: {}", e)),
        }
    })
}

/// 校验 GnuPG algo 8（PQC）私钥的口令。
///
/// rpgp 会丢弃 v5 子密钥包，无法校验该子密钥自身的保护段，
/// 故由 gpg_pqc 模块尝试解出私钥材料来判定口令是否正确。
///
/// hps_pgp_gpg_pqc_verify_passphrase(seckey_armored, passphrase) -> "1" / "0"
#[no_mangle]
pub extern "C" fn hps_pgp_gpg_pqc_verify_passphrase(
    seckey_armored: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let armored = cstr_to_string(seckey_armored);
        let passphrase = cstr_to_string(passphrase);
        if armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }
        // 走与解密同一份缓存：口令正确时顺带把这把密钥解好（随后的逐条解密不必重复解保护段）
        match cached_pqc_key(&armored, &passphrase) {
            Ok(_) => FfiResult::ok("1".into()),
            Err(e) => FfiResult::err(format!("gpg pqc verify failed: {}", e)),
        }
    })
}

/// 判断给定 armored 私钥是否含 GnuPG algo 8（PQC）密钥，并可被本应用解密。
///
/// hps_pgp_gpg_pqc_supported(seckey_armored) -> "1" / "0"
#[no_mangle]
pub extern "C" fn hps_pgp_gpg_pqc_supported(seckey_armored: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let armored = cstr_to_string(seckey_armored);
        if armored.is_empty() {
            return FfiResult::ok("0".into());
        }
        let raw = match gpg_pqc::dearmor(&armored) {
            Ok(d) => d,
            Err(_) => return FfiResult::ok("0".into()),
        };
        let supported = match gpg_pqc::parse_packets(&raw) {
            Ok(packets) => packets
                .iter()
                .any(|p| matches!(p.tag, 5 | 6 | 7 | 14) && p.body.get(5) == Some(&8)),
            Err(_) => false,
        };
        FfiResult::ok(if supported { "1".into() } else { "0".into() })
    })
}

/// 混合加密：一次加密给「GnuPG algo 8（PQC）+ 普通密钥」两类接收方
///
/// `pass` 支持一个 `.gpg-id` 里同时列多把密钥（`gpg -e -r K1 -r K2 …`），
/// 且不限制算法是否同类——每个 PKESK 用各自接收方的算法，**共用同一个会话密钥**。
/// 本函数实现同样的语义：
/// - 普通密钥（RSA / ECDH / EdDSA 的加密子键）：交给 rpgp 的
///   `PublicKeyEncryptedSessionKey::from_session_key_v3`，算法细节由它负责；
/// - GnuPG algo 8：由 `gpg_pqc::build_pkesk_for` 自建（rpgp 看不到 v5 子密钥）；
/// - 两类 PKESK 都包裹同一个随机会话密钥，最后统一用 SEIPDv1 承载明文。
///
/// hps_pgp_encrypt_mixed(plaintext, gpgpqc_pubkeys_armored, normal_pubkeys_armored)
/// 任一侧为空时请改用对应的单一类型入口（`hps_pgp_encrypt` / `hps_pgp_encrypt_gpg_pqc`）。
#[no_mangle]
pub extern "C" fn hps_pgp_encrypt_mixed(
    plaintext: *const c_char,
    gpgpqc_pubkeys_armored: *const c_char,
    normal_pubkeys_armored: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let plaintext = cstr_to_string(plaintext);
        let pqc_armored = cstr_to_string(gpgpqc_pubkeys_armored);
        let normal_armored = cstr_to_string(normal_pubkeys_armored);
        match encrypt_mixed_core(&plaintext, &pqc_armored, &normal_armored) {
            Ok(armored) => FfiResult::ok(armored),
            Err(e) => FfiResult::err(e),
        }
    })
}

/// 混合加密的核心实现（与 FFI 分离，便于单测）
fn encrypt_mixed_core(plaintext: &str, pqc_armored: &str, normal_armored: &str) -> Result<String, String> {
    use pgp::composed::RawSessionKey;
    use pgp::packet::PublicKeyEncryptedSessionKey;
    use pgp::ser::Serialize as _;

    if pqc_armored.is_empty() || normal_armored.is_empty() {
        return Err("mixed encryption needs both key kinds".into());
    }

    // 普通公钥（可多把，rpgp 逐个作为接收方）
    let normals: Vec<SignedPublicKey> = parse_public_keys_many(normal_armored)
        .map_err(|e| format!("parse public key failed: {}", e))?;
    // GnuPG algo 8 公钥（可多把）
    let pqc_keys = gpg_pqc::extract_public_keys_multi(&pqc_armored);
    if normals.is_empty() || pqc_keys.is_empty() {
        return Err("no usable recipient key found".into());
    }

    // 同一个会话密钥贯穿所有接收方：这正是多接收方语义的核心
    let session_key = gpg_pqc::random_session_key();
    let raw_session = RawSessionKey::from(session_key.clone());

    let mut out: Vec<u8> = Vec::new();
    // ① 普通密钥：交给 rpgp 构造 PKESK（RSA/ECDH/EdDSA 子键的算法细节它负责）
    for pk in &normals {
        // 优先用加密子密钥（与列表显示、encryptionKeyId 的选取顺序一致）
        let pkesk = match pk.public_subkeys.iter().find(|sk| sk.algorithm().can_encrypt()) {
            Some(subkey) => PublicKeyEncryptedSessionKey::from_session_key_v3(
                OsRng, &raw_session, SymmetricKeyAlgorithm::AES256, subkey),
            None => PublicKeyEncryptedSessionKey::from_session_key_v3(
                OsRng, &raw_session, SymmetricKeyAlgorithm::AES256, pk),
        };
        let pkesk = match pkesk {
            Ok(p) => p,
            Err(e) => return Err(format!("build pkesk failed: {}", e)),
        };
        // rpgp 的 Serialize 只写包体，包头由本模块补（与 algo 8 路径同一写法）
        let mut body: Vec<u8> = Vec::new();
        if let Err(e) = pkesk.to_writer(&mut body) {
            return Err(format!("serialize pkesk failed: {}", e));
        }
        out.extend_from_slice(&gpg_pqc::write_packet(1, &body));
    }
    // ② GnuPG algo 8：自建 PKESK（rpgp 会丢弃其 v5 子密钥）
    for pk in &pqc_keys {
        match gpg_pqc::build_pkesk_for(pk, &session_key) {
            Ok(p) => out.extend_from_slice(&p),
            Err(e) => return Err(format!("build pkesk failed: {}", e)),
        }
    }
    // ③ 统一承载明文的 SEIPDv1
    match gpg_pqc::seipd_v1_message(&session_key, plaintext.as_bytes()) {
        Ok(seipd) => out.extend_from_slice(&seipd),
        Err(e) => return Err(format!("seipd failed: {}", e)),
    }

    Ok(gpg_pqc::armor(&out, "PGP MESSAGE"))
}

/// 提取密文的收件人 Key ID 列表（算法无关）
///
/// 用于两件事：① 解密前判断条目实际由哪把密钥加密，从而索取正确口令；
/// ② 重加密时判断条目是否已用目标密钥（相等则跳过）。
///
/// hps_pgp_recipient_keyids(ciphertext) -> 逗号分隔的大写十六进制 Key ID；
/// 无 PKESK（对称加密）或全为隐藏收件人时返回空串。
#[no_mangle]
pub extern "C" fn hps_pgp_recipient_keyids(ciphertext: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let ct = cstr_to_string(ciphertext);
        if ct.is_empty() {
            return FfiResult::err("ciphertext is empty".into());
        }
        match gpg_pqc::recipient_keyids(&ct) {
            Ok(ids) => FfiResult::ok(ids.join(",")),
            Err(e) => FfiResult::err(format!("parse recipients failed: {}", e)),
        }
    })
}

// ========== PGP 密钥列表 ==========

#[no_mangle]
pub extern "C" fn hps_pgp_list_keys(keyring_armored: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let keyring = cstr_to_string(keyring_armored);

        if keyring.is_empty() {
            return FfiResult::ok("[]".into());
        }

        let mut json = String::from("[");
        let mut first = true;

        // 尝试解析为私钥 keyring
        if let Ok((iter, _headers)) = SignedSecretKey::from_armor_many(keyring.as_bytes()) {
            for key in iter.filter_map(|k| k.ok()) {
                if !first { json.push(','); }
                first = false;

                // KeyId derive_more::Display 输出 hex；Fingerprint 用 LowerHex
                let fp = format!("{:x}", key.primary_key.fingerprint());
                let kid = format!("{}", key.primary_key.legacy_key_id());
                let algo = format!("{:?}", key.primary_key.algorithm());
                let user_id = key.details.users.iter()
                    .next()
                    .and_then(|u| u.id.as_str().map(|s| s.to_string()))
                    .unwrap_or_default();

                json.push_str(&format!(
                    "{{\"fingerprint\":\"{}\",\"keyId\":\"{}\",\"userId\":\"{}\",\"algorithm\":\"{}\",\"isSecret\":true}}",
                    fp, kid, json_escape(&user_id), algo
                ));
            }
        }

        // 尝试解析为公钥 keyring
        if let Ok((iter, _headers2)) = SignedPublicKey::from_armor_many(keyring.as_bytes()) {
            for key in iter.filter_map(|k| k.ok()) {
                if !first { json.push(','); }
                first = false;

                let fp = format!("{:x}", key.primary_key.fingerprint());
                let kid = format!("{}", key.primary_key.legacy_key_id());
                let algo = format!("{:?}", key.primary_key.algorithm());
                let user_id = key.details.users.iter()
                    .next()
                    .and_then(|u| u.id.as_str().map(|s| s.to_string()))
                    .unwrap_or_default();

                json.push_str(&format!(
                    "{{\"fingerprint\":\"{}\",\"keyId\":\"{}\",\"userId\":\"{}\",\"algorithm\":\"{}\",\"isSecret\":false}}",
                    fp, kid, json_escape(&user_id), algo
                ));
            }
        }

        json.push(']');
        FfiResult::ok(json)
    })
}

// ========== Passphrase 验证 ==========

/// 用 SigningKey::sign 做一次自签名操作来验证 passphrase
/// （pgp 0.20 没有独立的 unlock API；sign 在密码错误时返回 Err）
#[no_mangle]
pub extern "C" fn hps_pgp_verify_passphrase(
    seckey_armored: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let seckey_armored = cstr_to_string(seckey_armored);
        let passphrase = cstr_to_string(passphrase);

        if seckey_armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }

        // 走解锁缓存：口令正确时顺带把这把密钥解锁好（紧随其后的逐条解密不必再跑
        // 迭代 S2K），口令错误时由 `remove_password` 报错。
        //
        // 不要改用 sign 来验证——EdDSA 等算法的 sign 要求传入的 digest 长度
        // 与哈希算法严格匹配（SHA-256 必须恰好 32 字节），传任意短原文会报
        // "Unexpected digest length N for hash algorithm Sha256"，
        // 导致**正确口令也被误判为错误**。
        //
        // 未加密（无密码保护）的私钥：`remove_password` 对未锁定的包是 no-op，
        // 任何口令（含空串）都判定为验证通过——这是「无密码密钥免弹框」的关键判定。
        match cached_secret_key(&seckey_armored, &passphrase) {
            Ok(_) => FfiResult::ok(String::new()),
            Err(e) => FfiResult::err(format!("passphrase verification failed: {}", e)),
        }
    })
}

// ========== 密钥生成 ==========

/// hps_pgp_generate_key(user_id, key_type, passphrase) -> armored secret key
///
/// 应用内生成 PGP 密钥对（V4 格式，兼容 GPG/pass CLI）：
/// - "eddsa"  → EdDSA(Curve25519) 主键 + ECDH(Curve25519) 加密子键（推荐）
/// - "rsa4096" → RSA-4096 主键 + RSA-4096 加密子键
/// - "rsa2048" → RSA-2048 主键 + RSA-2048 加密子键
/// passphrase 非空时同时锁定主键与子键。
#[no_mangle]
pub extern "C" fn hps_pgp_generate_key(
    user_id: *const c_char,
    key_type: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let user_id = cstr_to_string(user_id);
        let key_type = cstr_to_string(key_type);
        let passphrase = cstr_to_string(passphrase);

        if user_id.trim().is_empty() {
            return FfiResult::err("user id is empty".into());
        }

        let lock_passphrase = !passphrase.is_empty();

        // V4 密钥必须有 primary_user_id。
        //
        // 口令必须同时设在**主键与子键**上：rpgp 的子键口令取自 SubkeyParams 自己的
        // passphrase 字段，仅给主键 builder 设口令不会锁定子键。而实际加密用的是
        // 加密子键——子键未加密时任意口令都能解密（口令形同虚设），
        // 且主键解锁成功也无法反映子键的真实状态。
        let built = match key_type.as_str() {
            "eddsa" => {
                let mut sub = SubkeyParamsBuilder::default();
                sub.key_type(KeyType::ECDH(ECCCurve::Curve25519Legacy));
                sub.can_encrypt(EncryptionCaps::All);
                if lock_passphrase {
                    sub.passphrase(Some(passphrase.clone()));
                }

                let mut b = SecretKeyParamsBuilder::default();
                b.key_type(KeyType::Ed25519Legacy);
                b.can_certify(true);
                b.can_sign(true);
                b.primary_user_id(user_id.clone());
                b.subkey(sub.build().expect("subkey params"));
                if lock_passphrase {
                    b.passphrase(Some(passphrase.clone()));
                }
                b.build()
            }
            "rsa4096" | "rsa2048" => {
                let bits: u32 = if key_type == "rsa4096" { 4096 } else { 2048 };
                let mut sub = SubkeyParamsBuilder::default();
                sub.key_type(KeyType::Rsa(bits));
                sub.can_encrypt(EncryptionCaps::All);
                if lock_passphrase {
                    sub.passphrase(Some(passphrase.clone()));
                }

                let mut b = SecretKeyParamsBuilder::default();
                b.key_type(KeyType::Rsa(bits));
                b.can_certify(true);
                b.can_sign(true);
                b.primary_user_id(user_id.clone());
                b.subkey(sub.build().expect("subkey params"));
                if lock_passphrase {
                    b.passphrase(Some(passphrase.clone()));
                }
                b.build()
            }
            other => return FfiResult::err(format!("unsupported key type: {}", other)),
        };

        let params = match built {
            Ok(p) => p,
            Err(e) => return FfiResult::err(format!("key params: {}", e)),
        };

        let signed = match params.generate(OsRng) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(format!("generate key failed: {}", e)),
        };

        match signed.to_armored_string(ArmorOptions::default()) {
            Ok(armored) => FfiResult::ok(armored),
            Err(e) => FfiResult::err(format!("armor key failed: {}", e)),
        }
    })
}

/// rpgp 路径的换口令：解锁主键与全部子键，再用新密码上锁（新密码为空则去除锁定）
///
/// **只适用于纯 v4 密钥**：rpgp 解析签名私钥时会静默丢弃 v5 子密钥（algo 8），
/// 含 GnuPG PQC 子密钥的密钥直接走这条路会把它弄丢，必须先经
/// `gpg_pqc::has_algo8_secret_packets` 分流到包级手术（`change_passphrase_pqc`）。
fn rpgp_change_passphrase_armored(
    armored: &str,
    old_passphrase: &str,
    new_passphrase: &str,
) -> std::result::Result<String, String> {
    let (mut seckey, _headers) = SignedSecretKey::from_armor_single(armored.as_bytes())
        .map_err(|e| format!("parse secret key failed: {}", e))?;

    let old_pw = Password::from(old_passphrase);
    let new_pw = Password::from(new_passphrase);

    // 解锁主键（未加密的密钥 remove_password 保持不变）
    if let Err(e) = seckey.primary_key.remove_password(&old_pw) {
        return Err(format!("old passphrase incorrect or unlock failed: {}", e));
    }
    // 解锁全部子键
    for sub in seckey.secret_subkeys.iter_mut() {
        if let Err(e) = sub.key.remove_password(&old_pw) {
            return Err(format!("unlock subkey failed: {}", e));
        }
    }

    // 用新密码上锁（空密码 = 保持未加密）
    if !new_passphrase.is_empty() {
        if let Err(e) = seckey.primary_key.set_password(&mut OsRng, &new_pw) {
            return Err(format!("lock primary key failed: {}", e));
        }
        for sub in seckey.secret_subkeys.iter_mut() {
            if let Err(e) = sub.key.set_password(&mut OsRng, &new_pw) {
                return Err(format!("lock subkey failed: {}", e));
            }
        }
    }

    seckey
        .to_armored_string(ArmorOptions::default())
        .map_err(|e| format!("armor key failed: {}", e))
}

/// 换口令统一入口（FFI 与 cargo test 共用）
///
/// 含 GnuPG PQC（algo 8）子密钥的密钥：rpgp 只处理 v4 部分（会丢弃 v5 子密钥），
/// algo 8 子密钥由 gpg_pqc 从原文取出、只重建其带口令保护段后拼回；
/// 产出必须能用**新口令**完整解开（自检）才返回，失败时调用方不落盘。
pub fn run_change_passphrase(
    armored: &str,
    old_passphrase: &str,
    new_passphrase: &str,
) -> std::result::Result<String, String> {
    if armored.is_empty() {
        return Err("secret key is empty".into());
    }
    if gpg_pqc::has_algo8_secret_packets(armored) {
        if new_passphrase.is_empty() {
            return Err(
                "GnuPG PQC（ML-KEM）密钥暂不支持去除密码保护，请设置一个新密码".into(),
            );
        }
        // 旧口令预检：先确认它确实能解开现有保护段（给「旧密码错误」一个明确信号）
        if let Err(e) = gpg_pqc::extract_key(armored, old_passphrase) {
            return Err(format!("旧密钥密码不正确（{}）", e));
        }
        let v4 = rpgp_change_passphrase_armored(armored, old_passphrase, new_passphrase)?;
        let out = gpg_pqc::change_passphrase_pqc(armored, &v4, old_passphrase, new_passphrase)
            .map_err(|e| e.to_string())?;
        #[cfg(test)]
        if let Ok(p) = std::env::var("HPS_DUMP_PW") {
            std::fs::write(&p, &out).unwrap();
        }
        gpg_pqc::extract_key(&out, new_passphrase)
            .map_err(|e| format!("改口令后自检失败，已保留原密钥: {}", e))?;
        return Ok(out);
    }
    rpgp_change_passphrase_armored(armored, old_passphrase, new_passphrase)
}

/// hps_pgp_change_passphrase(seckey_armored, old_passphrase, new_passphrase) -> armored secret key
///
/// 修改私钥 passphrase：先用旧密码解锁主键与全部子键，再用新密码上锁。
/// 新密码为空时输出未加密（unlocked）的密钥（GnuPG PQC 密钥除外，见 run_change_passphrase）。
#[no_mangle]
pub extern "C" fn hps_pgp_change_passphrase(
    seckey_armored: *const c_char,
    old_passphrase: *const c_char,
    new_passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let seckey_armored = cstr_to_string(seckey_armored);
        let old_passphrase = cstr_to_string(old_passphrase);
        let new_passphrase = cstr_to_string(new_passphrase);
        match run_change_passphrase(&seckey_armored, &old_passphrase, &new_passphrase) {
            Ok(armored) => FfiResult::ok(armored),
            Err(e) => FfiResult::err(e),
        }
    })
}

/// hps_pgp_backup_key(key_armored, backup_password) -> armored 对称加密消息
///
/// 用对称密码（SKESK，iterated-salted S2K，GPG 兼容）加密任意 armored 密钥文本，
/// 生成可导出的备份文件内容。密钥文本仅作为消息数据存在，不落盘。
#[no_mangle]
pub extern "C" fn hps_pgp_backup_key(
    key_armored: *const c_char,
    backup_password: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let key_armored = cstr_to_string(key_armored);
        let backup_password = cstr_to_string(backup_password);

        if key_armored.trim().is_empty() {
            return FfiResult::err("key is empty".into());
        }
        if backup_password.is_empty() {
            return FfiResult::err("backup password is empty".into());
        }

        let mut builder = MessageBuilder::from_bytes("key", key_armored.into_bytes())
            .seipd_v1(OsRng, SymmetricKeyAlgorithm::AES256);
        if let Err(e) = builder.encrypt_with_password(
            pgp::types::StringToKey::new_iterated(&mut OsRng, pgp::crypto::hash::HashAlgorithm::Sha256, 96),
            &Password::from(backup_password.as_str()),
        ) {
            return FfiResult::err(format!("encrypt with password failed: {}", e));
        }

        match builder.to_armored_string(OsRng, ArmorOptions::default()) {
            Ok(armored) => FfiResult::ok(armored),
            Err(e) => FfiResult::err(format!("armor backup failed: {}", e)),
        }
    })
}

/// hps_pgp_restore_backup(backup_armored, backup_password) -> armored 密钥文本
///
/// 解密对称加密的备份消息，还原出 armored 密钥文本（供导入流程使用）。
#[no_mangle]
pub extern "C" fn hps_pgp_restore_backup(
    backup_armored: *const c_char,
    backup_password: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let backup_armored = cstr_to_string(backup_armored);
        let backup_password = cstr_to_string(backup_password);

        if backup_armored.is_empty() || backup_password.is_empty() {
            return FfiResult::err("backup or password is empty".into());
        }

        let (mut msg, _headers) = match Message::from_armor(backup_armored.as_bytes()) {
            Ok(result) => result,
            Err(e) => return FfiResult::err(format!("parse backup failed: {}", e)),
        };

        let mut decrypted = match msg.decrypt_with_password(&Password::from(backup_password.as_str())) {
            Ok(d) => d,
            Err(e) => return FfiResult::err(format!("wrong backup password or corrupt backup: {}", e)),
        };
        // 备份虽通常由用户自己生成，但还原入口同样面向不可信输入（备份文件可被篡改），
        // 解压炸弹防护与 hps_pgp_decrypt 对齐：先判压缩再解压，再校验字面数据长度。
        if decrypted.is_compressed() {
            decrypted = match decrypted.decompress() {
                Ok(d) => d,
                Err(e) => return FfiResult::err(format!("decompress failed: {}", e)),
            };
        }

        match decrypted.as_data_vec() {
            Ok(data) => {
                if data.len() as u64 > gpg_pqc::MAX_DECOMPRESSED_BYTES {
                    return FfiResult::err(format!(
                        "decompressed backup too large ({} bytes)",
                        data.len()
                    ));
                }
                match String::from_utf8(data) {
                    Ok(text) => FfiResult::ok(text),
                    Err(_) => FfiResult::err("backup content is not valid UTF-8".into()),
                }
            }
            Err(e) => FfiResult::err(format!("read backup data failed: {}", e)),
        }
    })
}

/// hps_pgp_split_keyring(keyring_armored) -> JSON 字符串数组（每个元素为单个密钥的 armored 文本）
///
/// 解析包含多个密钥的 armored 文本（gpg --export-secret-keys 导出的 keyring、
/// 本应用多密钥备份的还原结果），拆分为单个密钥便于逐个存储。
#[no_mangle]
pub extern "C" fn hps_pgp_split_keyring(keyring_armored: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let keyring = cstr_to_string(keyring_armored);

        if keyring.trim().is_empty() {
            return FfiResult::err("keyring is empty".into());
        }

        let mut armored_keys: Vec<String> = Vec::new();

        // 先按私钥 keyring 解析
        if let Ok((iter, _headers)) = SignedSecretKey::from_armor_many(keyring.as_bytes()) {
            for key in iter.filter_map(|k| k.ok()) {
                if let Ok(armored) = key.to_armored_string(ArmorOptions::default()) {
                    armored_keys.push(armored);
                }
            }
        }

        // 私钥解析为空时尝试公钥 keyring
        if armored_keys.is_empty() {
            if let Ok((iter, _headers)) = SignedPublicKey::from_armor_many(keyring.as_bytes()) {
                for key in iter.filter_map(|k| k.ok()) {
                    if let Ok(armored) = key.to_armored_string(ArmorOptions::default()) {
                        armored_keys.push(armored);
                    }
                }
            }
        }

        if armored_keys.is_empty() {
            return FfiResult::err("no parsable key found in armored text".into());
        }

        // 序列化为 JSON 字符串数组（转义引号/反斜杠/控制字符）
        let mut json = String::from("[");
        for (i, key) in armored_keys.iter().enumerate() {
            if i > 0 {
                json.push(',');
            }
            json.push('"');
            for ch in key.chars() {
                match ch {
                    '"' => json.push_str("\\\""),
                    '\\' => json.push_str("\\\\"),
                    '\n' => json.push_str("\\n"),
                    '\r' => json.push_str("\\r"),
                    '\t' => json.push_str("\\t"),
                    c if (c as u32) < 0x20 => json.push_str(&format!("\\u{:04x}", c as u32)),
                    c => json.push(c),
                }
            }
            json.push('"');
        }
        json.push(']');

        FfiResult::ok(json)
    })
}

// ========== SSH（russh） ==========

/// hps_pgp_key_as_ssh(seckey_armored, passphrase) -> OpenSSH PEM 私钥
///
/// 将 PGP 私钥（主键或签名子键）的 Ed25519 密钥材料转换为 SSH 私钥（OpenSSH PEM），
/// 供 russh authenticate_publickey 做 Git SSH 认证（PGP 密钥即 SSH 密钥）。
/// passphrase 用于解锁 PGP 私钥；输出未经加密（仅在内存中短暂存在）。
#[no_mangle]
pub extern "C" fn hps_pgp_key_as_ssh(
    seckey_armored: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        use pgp::types::PlainSecretParams;
        use pgp::errors::Error as PgpError;
        use pgp::ser::Serialize;

        let seckey_armored = cstr_to_string(seckey_armored);
        let passphrase = cstr_to_string(passphrase);

        if seckey_armored.is_empty() {
            return FfiResult::err("secret key is empty".into());
        }

        let (seckey, _headers) = match SignedSecretKey::from_armor_single(seckey_armored.as_bytes()) {
            Ok(result) => result,
            Err(e) => return FfiResult::err(format!("parse secret key failed: {}", e)),
        };

        let pw = Password::from(passphrase.as_str());

        // 用 unlock 回调提取主键的明文密钥材料（Ed25519 种子 32 字节）
        // unlock 返回 Result<Result<T>>：外层为 S2K 解密，内层为闭包结果
        let unlocked: pgp::errors::Result<pgp::errors::Result<[u8; 32]>> =
            seckey.unlock(&pw, |public_params, plain| -> pgp::errors::Result<[u8; 32]> {
                let _ = public_params;
                match plain {
                    PlainSecretParams::Ed25519(sk) => {
                        let mut bytes = [0u8; 32];
                        bytes.copy_from_slice(sk.as_bytes());
                        Ok(bytes)
                    }
                    PlainSecretParams::EdDSALegacy(sk) => {
                        // Serialize::to_bytes 返回 MPIS 字节流，Ed25519 种子在前 32 字节
                        let raw: Vec<u8> = sk.to_bytes()?;
                        if raw.len() < 32 {
                            return Err(PgpError::InvalidInput { backtrace: None });
                        }
                        let mut bytes = [0u8; 32];
                        bytes.copy_from_slice(&raw[..32]);
                        Ok(bytes)
                    }
                    _ => Err(PgpError::InvalidInput { backtrace: None }),
                }
            });

        let seed: std::result::Result<[u8; 32], String> = match unlocked {
            Ok(inner) => inner.map_err(|_| "only Ed25519 PGP keys can be used for SSH".to_string()),
            Err(e) => Err(format!("unlock failed: {}", e)),
        };

        let seed: [u8; 32] = match seed {
            Ok(s) => s,
            Err(e) => return FfiResult::err(format!("extract key material failed: {}", e)),
        };

        // Ed25519 keypair：私钥种子 + 公钥（由种子推导）；ssh_key 经 russh 重导出
        use russh::keys::ssh_key;
        let keypair = ssh_key::private::Ed25519Keypair::from_seed(&seed);

        let private_key = match ssh_key::PrivateKey::new(
            ssh_key::private::KeypairData::Ed25519(keypair),
            "hps-pgp-ssh",
        ) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(format!("build ssh key failed: {}", e)),
        };

        match private_key.to_openssh(ssh_key::LineEnding::LF) {
            Ok(pem) => FfiResult::ok(pem.to_string()),
            Err(e) => FfiResult::err(format!("openssh encode failed: {}", e)),
        }
    })
}

/// hps_ssh_key_status(private_key_pem) -> JSON 状态
///
/// 用于把「私钥已加密但未输口令」与「文件损坏/格式无效」区分开，
/// 避免用户把缺口令误看成文件损坏。
/// 返回：{"valid":bool,"encrypted":bool,"error":string}
///   valid=false                    → 不是有效私钥（格式无效/已损坏）
///   valid=true && encrypted=true   → 私钥有效且已加密（需口令）
///   valid=true && encrypted=false  → 私钥有效且无口令
#[no_mangle]
pub extern "C" fn hps_ssh_key_status(private_key_pem: *const c_char) -> FfiResult {
    ffi_guard(|| {
        let pem = cstr_to_string(private_key_pem);
        let mut valid = false;
        let mut encrypted = false;
        let mut error = String::new();

        if pem.trim().is_empty() {
            return FfiResult::ok(
                "{\"valid\":false,\"encrypted\":false,\"error\":\"private key is empty\"}".to_string(),
            );
        }

        // 先用无口令解析：成功即未加密；返回 KeyIsEncrypted 即已加密且有效
        match decode_secret_key(&pem, None) {
            Ok(_) => {
                valid = true;
                encrypted = false;
            }
            Err(e) => {
                match &e {
                    russh::keys::Error::KeyIsEncrypted => {
                        valid = true;
                        encrypted = true;
                    }
                    _ => {
                        // 部分加密私钥（如 PKCS8 加密）无口令时不会返回 KeyIsEncrypted，
                        // 这里按 PEM 标记兜底判定，避免误报成文件损坏
                        if pem.contains("BEGIN ENCRYPTED PRIVATE KEY")
                            || pem.contains("Proc-Type: 4,ENCRYPTED")
                        {
                            valid = true;
                            encrypted = true;
                        } else {
                            valid = false;
                            encrypted = false;
                            error = format!("{}", e);
                        }
                    }
                }
            }
        }

        let json = format!(
            "{{\"valid\":{},\"encrypted\":{},\"error\":\"{}\"}}",
            valid,
            encrypted,
            error.replace('\\', "\\\\").replace('"', "\\\"")
        );
        FfiResult::ok(json)
    })
}

/// hps_ssh_public_from_private(private_key_pem, passphrase) -> OpenSSH 公钥（authorized_keys 单行格式）
///
/// 从 OpenSSH 私钥 PEM 提取公钥并输出 "ssh-ed25519 AAAA... comment" 单行格式，
/// 可直接粘贴到服务器的 authorized_keys 或 Git 平台 SSH Keys 设置。
///
/// passphrase 用于解析带口令保护的私钥（空串表示无口令）；
/// 该调用同时充当私钥格式校验：解析失败即说明文件不是有效私钥或口令错误。
#[no_mangle]
pub extern "C" fn hps_ssh_public_from_private(
    private_key_pem: *const c_char,
    passphrase: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let pem = cstr_to_string(private_key_pem);
        if pem.is_empty() {
            return FfiResult::err("private key is empty".into());
        }
        let passphrase = cstr_to_string(passphrase);

        let pw = if passphrase.is_empty() { None } else { Some(passphrase.as_str()) };
        let key = match decode_secret_key(&pem, pw) {
            Ok(k) => k,
            Err(e) => return FfiResult::err(format!("load key failed: {}", e)),
        };

        match key.public_key().to_openssh() {
            Ok(line) => FfiResult::ok(line),
            Err(e) => FfiResult::err(format!("encode public key failed: {}", e)),
        }
    })
}

/// 共享 tokio current-thread runtime（FFI 边界内同步执行 async 代码）
fn tokio_runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}

/// 客户端 Handler：捕获服务器主机密钥指纹（SHA256），可选期望指纹校验
///
/// - expected_fp 为 None：接受任意主机密钥（TOFU 首次探测场景），指纹存入 captured
/// - expected_fp 为 Some（可含多行 "类型|指纹"，兼容旧格式裸指纹）：
///   三态判定（与 git_ssh_creds.h 的 GitCertCheckCallback 一致）——
///   ① 指纹匹配任意一条 → 信任；
///   ② 同类型、指纹不同 → 拒绝（该类型密钥真的变了，可能中间人）；
///   ③ 类型从未见过 → 拒绝（按未信任处理，回报指纹走一次 TOFU 确认后追加），
///      服务器本就同时提供多把不同类型的主机密钥，②③ 的区分决定提示文案与
///      「覆盖记录」还是「追加记录」。
struct ClientHandler {
    captured: Arc<std::sync::Mutex<Option<String>>>,
    expected_fp: Option<String>,
}

/// 把 russh 算法名（ssh-ed25519 / ssh-rsa / ecdsa-sha2-nistp256…）规约成
/// 与 libssh2 侧（git_ssh_creds.h）一致的展示名（RSA/ECDSA/Ed25519）
fn normalize_key_type(algo: &str) -> String {
    if algo.contains("ed25519") {
        "Ed25519".to_string()
    } else if algo.contains("ecdsa") {
        "ECDSA".to_string()
    } else if algo.contains("rsa") {
        "RSA".to_string()
    } else {
        String::new()
    }
}

impl ClientHandler {
    fn new(expected_fp: Option<String>) -> Self {
        ClientHandler {
            captured: Arc::new(std::sync::Mutex::new(None)),
            expected_fp,
        }
    }

    fn take_fingerprint(&self) -> Option<String> {
        self.captured.lock().ok().and_then(|mut g| g.take())
    }
}

/// 解析一行信任条目 "类型|指纹" → (类型(可空), 指纹)
fn parse_hostkey_trust(line: &str) -> (Option<String>, &str) {
    match line.find('|') {
        Some(i) => (Some(line[..i].to_string()), &line[i + 1..]),
        None => (None, line),
    }
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        // SHA256 指纹，OpenSSH known_hosts 格式（"SHA256:Base64"）
        let fp = server_public_key
            .public_key()
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();

        // 本算法的 russh 名称（ssh-ed25519 / ssh-rsa / ecdsa-sha2-nistp256…）
        let algo_name: String = server_public_key
            .public_key()
            .algorithm()
            .as_str()
            .to_string();

        // captured 存 "指纹|类型"（类型供上层写入信任库，与 libssh2 侧格式一致）
        if let Ok(mut slot) = self.captured.lock() {
            *slot = Some(format!("{}|{}", fp, normalize_key_type(&algo_name)));
        }

        let expected = match &self.expected_fp {
            Some(e) => e,
            None => return Ok(true),
        };

        let mut mismatch_same_type = false;
        for line in expected.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let (typ, f) = parse_hostkey_trust(line);
            if f == fp {
                return Ok(true);
            }
            if typ.as_deref() == Some(normalize_key_type(&algo_name).as_str())
                && !algo_name.is_empty() {
                mismatch_same_type = true;
            }
        }
        // 区分「同类型指纹变了」与「没见过的类型」由上层完成（captured 里的指纹
        // 与信任列表比对即可），russh 侧两种都只是拒绝连接
        let _ = mismatch_same_type;
        Ok(false)
    }
}

/// hps_ssh_generate_key(comment) -> { success, data = JSON { privateKeyPem, publicKey } }
///
/// 用 russh 的 ssh-key 生成 Ed25519 密钥并导出 **OpenSSH 格式**。
///
/// 为什么不在 ArkTS 侧用 cryptoFramework 生成：那样得到的 PriKey 是内存里的软件密钥，
/// 而 Ed25519 **不支持** `getEncoded()` / `getEncodedDer('PKCS8')`，根本导不出来——
/// 应用重启后私钥就没了（生成路径曾因此只留下 `.pub`，用户手里的密钥形同废纸，
/// 且已注册到远端的公钥再也无法配对）。在 native 侧生成可直接拿到 OpenSSH PEM，
/// 落盘（HUKS 封装）后长期可用，也能被 libssh2 直接用于 git over SSH。
#[no_mangle]
pub extern "C" fn hps_ssh_generate_key(comment: *const c_char) -> FfiResult {
    ffi_guard(|| {
        use russh::keys::ssh_key::private::Ed25519Keypair;
        use russh::keys::ssh_key::{Algorithm, LineEnding, PrivateKey};

        let comment = cstr_to_string(comment);
        // 不调用 PrivateKey::random：ssh-key 0.7-rc 的 CryptoRng 来自 ml-kem 0.3 依赖的
        // rand_core 0.10，与本项目的 rand 0.8（rand_core 0.6）不是同一 trait，编译不过。
        // 自供 32 字节随机种子走 from_seed，效果等价（见 AGENTS.md 的同类记录）。
        let mut seed = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut seed);
        let key: PrivateKey = Ed25519Keypair::from_seed(&seed).into();
        let pem = match key.to_openssh(LineEnding::LF) {
            Ok(p) => p.to_string(),
            Err(e) => return FfiResult::err(format!("export private key failed: {}", e)),
        };
        let pubkey = match key.public_key().to_openssh() {
            Ok(p) => p,
            Err(e) => return FfiResult::err(format!("export public key failed: {}", e)),
        };
        // russh 导出的公钥不带注释，注释只作展示用（与 OpenSSH 习惯一致）
        let pub_line = if comment.is_empty() {
            pubkey.trim_end().to_string()
        } else {
            format!("{} {}", pubkey.trim_end(), comment)
        };
        FfiResult::ok(format!(
            "{{\"privateKeyPem\":\"{}\",\"publicKey\":\"{}\"}}",
            json_escape(&pem),
            json_escape(&pub_line)
        ))
    })
}

/// hps_ssh_fingerprint(host, port) -> SHA256 主机密钥指纹（"SHA256:Base64"）
///
/// 建立连接并立即断开，仅返回服务器主机密钥指纹。
/// 用于 TOFU 首次连接：用户确认指纹后再发起真实认证连接。
#[no_mangle]
pub extern "C" fn hps_ssh_fingerprint(
    host: *const c_char,
    port: u16,
) -> FfiResult {
    ffi_guard(|| {
        let host = cstr_to_string(host);
        if host.is_empty() {
            return FfiResult::err("host is empty".into());
        }

        let handler = ClientHandler::new(None);
        let captured = handler.captured.clone();

        let result: std::result::Result<String, String> = tokio_runtime().block_on(async move {
            let config = Arc::new(client::Config {
                inactivity_timeout: Some(std::time::Duration::from_secs(10)),
                ..Default::default()
            });
            let addr = (host.as_str(), port);
            let mut session = client::connect(config, addr, handler)
                .await
                .map_err(|e| format!("connect: {}", e))?;
            let _ = session
                .disconnect(russh::Disconnect::ByApplication, "bye", "en")
                .await;
            Ok(String::new())
        });

        let captured = captured.lock().ok().and_then(|mut g| g.take());
        // captured 为 "指纹|类型"：完整返回（类型供上层写入信任库；缺失时上层按空处理）
        match (result, captured) {
            (_, Some(fp)) => FfiResult::ok(fp),
            (Err(e), _) => FfiResult::err(format!("ssh fingerprint failed: {}", e)),
            (Ok(_), None) => FfiResult::err("no server key captured".into()),
        }
    })
}

/// hps_ssh_test_auth(host, port, username, private_key_pem, passphrase) -> FfiResult
///
/// 建立 SSH 连接并测试公钥认证（不执行任何命令）。
/// 私钥以 PKCS8/OpenSSH PEM 文本传入（内存传递，不落盘）。
/// expected_fp 非空时校验服务器主机密钥指纹（known_hosts TOFU），不匹配则拒绝连接。
#[no_mangle]
pub extern "C" fn hps_ssh_test_auth(
    host: *const c_char,
    port: u16,
    username: *const c_char,
    private_key_pem: *const c_char,
    passphrase: *const c_char,
    expected_fp: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let host = cstr_to_string(host);
        let username = cstr_to_string(username);
        let key_pem = cstr_to_string(private_key_pem);
        let passphrase = cstr_to_string(passphrase);
        let expected_fp_raw = cstr_to_string(expected_fp);
        // 空字符串视为不校验（TOFU 首次连接场景）
        let expected = if expected_fp_raw.is_empty() { None } else { Some(expected_fp_raw) };

        if host.is_empty() || key_pem.is_empty() {
            return FfiResult::err("host or key is empty".into());
        }

        let handler = ClientHandler::new(expected);
        let captured = handler.captured.clone();

        let result = tokio_runtime().block_on(async move {
            let config = Arc::new(client::Config {
                inactivity_timeout: Some(std::time::Duration::from_secs(10)),
                ..Default::default()
            });

            let addr = (host.as_str(), port);
            let mut session = client::connect(config, addr, handler)
                .await
                .map_err(|e| format!("connect: {}", e))?;

            // 解析私钥 PEM 文本（带可选 passphrase 解密）
            let pw = if passphrase.is_empty() { None } else { Some(passphrase.as_str()) };
            let key = decode_secret_key(&key_pem, pw)
                .map_err(|e| format!("load key: {}", e))?;
            let key = PrivateKeyWithHashAlg::new(Arc::new(key), None);

            let auth = session.authenticate_publickey(username, key)
                .await
                .map_err(|e| format!("auth: {}", e))?;
            let _ = session
                .disconnect(russh::Disconnect::ByApplication, "bye", "en")
                .await;

            if auth.success() {
                Ok(())
            } else {
                Err("auth rejected".to_string())
            }
        });

        // 指纹校验失败时 connect 会先报错，此处补充明确的 host-key 错误信息
        if result.is_err() {
            let captured_fp: Option<String> = captured.lock().ok().and_then(|mut g| g.take());
            // captured 为 "指纹|类型"；错误信息里带全串，上层解析时按指纹在前处理
            if let (Some(fp), true) = (captured_fp, result.as_ref().is_err()) {
                let err_text = result.as_ref().unwrap_err().clone();
                if err_text.contains("connect") {
                    return FfiResult::err(format!(
                        "server host key mismatch (captured {})", fp));
                }
            }
        }

        match result {
            Ok(()) => FfiResult::ok("auth ok".into()),
            Err(e) => FfiResult::err(format!("ssh auth failed: {}", e)),
        }
    })
}

/// hps_ssh_test_password(host, port, username, password) -> FfiResult
///
/// 建立 SSH 连接并测试密码认证（不执行任何命令）。
#[no_mangle]
pub extern "C" fn hps_ssh_test_password(
    host: *const c_char,
    port: u16,
    username: *const c_char,
    password: *const c_char,
    expected_fp: *const c_char,
) -> FfiResult {
    ffi_guard(|| {
        let host = cstr_to_string(host);
        let username = cstr_to_string(username);
        let password = cstr_to_string(password);
        let expected_fp_raw = cstr_to_string(expected_fp);
        let expected = if expected_fp_raw.is_empty() { None } else { Some(expected_fp_raw) };

        if host.is_empty() {
            return FfiResult::err("host is empty".into());
        }

        let handler = ClientHandler::new(expected);

        let result = tokio_runtime().block_on(async move {
            let config = Arc::new(client::Config {
                inactivity_timeout: Some(std::time::Duration::from_secs(10)),
                ..Default::default()
            });

            let addr = (host.as_str(), port);
            let mut session = client::connect(config, addr, handler)
                .await
                .map_err(|e| format!("connect: {}", e))?;

            let auth = session.authenticate_password(username, password)
                .await
                .map_err(|e| format!("auth: {}", e))?;
            let _ = session
                .disconnect(russh::Disconnect::ByApplication, "bye", "en")
                .await;

            if auth.success() {
                Ok(())
            } else {
                Err("auth rejected".to_string())
            }
        });

        match result {
            Ok(()) => FfiResult::ok("auth ok".into()),
            Err(e) => FfiResult::err(format!("ssh auth failed: {}", e)),
        }
    })
}

// ========== 内存释放 ==========

#[no_mangle]
pub extern "C" fn hps_pgp_result_free(result: *mut FfiResult) {
    if result.is_null() {
        return;
    }
    unsafe {
        let result = &mut *result;
        if !result.error.is_null() {
            let _ = CString::from_raw(result.error);
            result.error = ptr::null_mut();
        }
        if !result.data.is_null() {
            let _ = CString::from_raw(result.data);
            result.data = ptr::null_mut();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// fixture 目录：默认 /tmp/fx，可用 HPS_FIXTURE_DIR 覆盖（与 gpg_pqc 用例一致）
    fn fixture_dir() -> std::path::PathBuf {
        std::env::var("HPS_FIXTURE_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("/tmp/fx"))
    }

    /// 生成的 SSH 密钥必须是**可持久化、可再次使用**的标准 OpenSSH PEM
    ///
    /// 回归的是「生成后私钥丢失」那个坑：改用 native 生成前，ArkTS 侧用
    /// cryptoFramework 生成的 Ed25519 私钥导不出来（不支持 PKCS8 编码），
    /// 应用重启后只剩公钥，用户注册到远端的钥匙再也配不上对。
    #[test]
    fn ssh_generate_key_produces_usable_openssh_pem() {
        let comment = CString::new("testpass").unwrap();
        let r = hps_ssh_generate_key(comment.as_ptr());
        assert_eq!(r.success, 0, "generate failed");
        let json = unsafe { CStr::from_ptr(r.data) }.to_string_lossy().into_owned();
        assert!(json.contains("BEGIN OPENSSH PRIVATE KEY"), "私钥不是 OpenSSH PEM: {}", json);

        // 解出 JSON 里的两个字段
        let pem_start = json.find("privateKeyPem\":\"").unwrap() + "privateKeyPem\":\"".len();
        let pem_end = json[pem_start..].find("\"").unwrap() + pem_start;
        let pem = json[pem_start..pem_end].replace("\\n", "\n");
        let pub_start = json.find("publicKey\":\"").unwrap() + "publicKey\":\"".len();
        let pub_end = json[pub_start..].find("\"").unwrap() + pub_start;
        let pubkey = json[pub_start..pub_end].to_string();

        // ① PEM 能被 russh 解析回来（等价于应用「导入」这把密钥时的路径）
        let decoded = russh::keys::decode_secret_key(&pem, None).expect("decode generated pem");
        // ② 公钥一致
        let expected_pub = format!("{}", decoded.public_key().to_openssh().unwrap());
        assert_eq!(expected_pub.trim_end(), pubkey.split(' ').take(2).collect::<Vec<_>>().join(" "));
        // ③ 注释按要求带上
        assert!(pubkey.ends_with("testpass"), "注释未写入公钥: {}", pubkey);
    }

    /// 混合加密：同一份密文同时发给 gpgPqc（algo 8）与普通密钥，两类接收方都能解密。
    ///
    /// 这是「同一目录同时设置两把不同算法密钥」的互操作基线——只验证本侧往返不够，
    /// 还必须验证普通密钥那一侧（rpgp 解析 + 解密）能读到同一会话密钥，
    /// 否则说明 PKESK 包头/包体拼接有误，而 gpg 只会报「无有效加密密钥」。
    #[test]
    fn mixed_recipients_gpgpqc_and_normal() {
        let pqc_secret = match std::fs::read_to_string(fixture_dir().join("sec_protected.asc")) {
            Ok(v) => v,
            Err(_) => {
                println!("SKIP: fixture 缺失 sec_protected.asc（设 HPS_FIXTURE_DIR 指定目录）");
                return;
            }
        };
        let norm_pub = match std::fs::read_to_string(fixture_dir().join("norm_pub.asc")) {
            Ok(v) => v,
            Err(_) => {
                println!("SKIP: fixture 缺失 norm_pub.asc（设 HPS_FIXTURE_DIR 指定目录）");
                return;
            }
        };
        let norm_secret = match std::fs::read_to_string(fixture_dir().join("norm_sec.asc")) {
            Ok(v) => v,
            Err(_) => {
                println!("SKIP: fixture 缺失 norm_sec.asc（设 HPS_FIXTURE_DIR 指定目录）");
                return;
            }
        };

        let msg = "MIXED-RECIPIENTS-往返";
        let armored = encrypt_mixed_core(msg, &pqc_secret, &norm_pub).expect("mixed encrypt");

        // 便于人工用 gpg 复核「普通接收方」方向：
        //   HPS_DUMP_MIXED=/tmp/mixed.asc cargo test --release mixed_recipients -- --nocapture
        if let Ok(p) = std::env::var("HPS_DUMP_MIXED") {
            let _ = std::fs::write(&p, &armored);
            println!("已写出混合密文到 {}（可用 gpg 复核）", p);
        }

        // 结构断言：两个 PKESK（各一个接收方）+ 一个 SEIPDv1
        let raw = gpg_pqc::dearmor(&armored).expect("dearmor");
        let packets = gpg_pqc::parse_packets(&raw).expect("parse");
        let pkesks: Vec<_> = packets.iter().filter(|p| p.tag == 1).collect();
        assert_eq!(pkesks.len(), 2, "应有 2 个 PKESK");
        assert_eq!(packets.iter().filter(|p| p.tag == 18).count(), 1, "应只有 1 个 SEIPDv1");

        // PKESK 体 = version(1) || keyid(8) || algo(1) || …
        let mut algos: Vec<u8> = pkesks.iter().map(|p| p.body[9]).collect();
        algos.sort_unstable();
        assert_eq!(algos, vec![8, 18], "两个 PKESK 应分别为 algo 8 与 algo 18(ECDH)");

        // ① gpgPqc 接收方（本模块解密）
        let key = gpg_pqc::extract_key(&pqc_secret, "testpw123").expect("extract pqc key");
        let got = gpg_pqc::decrypt_message(&key, &raw).expect("pqc decrypt");
        assert_eq!(String::from_utf8_lossy(&got), msg);

        // ② 普通接收方（rpgp 解密——与应用内 hps_pgp_decrypt 同一条路径）
        let (seckey, _h) =
            SignedSecretKey::from_armor_single(norm_secret.as_bytes()).expect("parse normal key");
        let (mut parsed, _h2) = Message::from_armor(armored.as_bytes()).expect("parse message");
        let mut decrypted = parsed
            .decrypt(&Password::from("testpw123"), &seckey)
            .expect("normal decrypt");
        if decrypted.is_compressed() {
            decrypted = decrypted.decompress().expect("decompress");
        }
        let data = decrypted.as_data_vec().expect("literal data");
        assert_eq!(String::from_utf8_lossy(&data), msg);
    }

// ========== 换口令端到端（gpgPqc 密钥） ==========

/// gpgPqc 密钥换口令端到端：**v5 子密钥不得丢失**（曾用 rpgp 直接换口令，
/// algo 8 子密钥被静默丢弃，密钥变成纯 EdDSA、存量密文永远解不开）
///
/// 断言链：旧口令可解 → 换口令 → 新口令可解且仍能解开原文加密的报文 →
/// 旧口令失效 → algo 8 包仍在且 v5 指纹逐字节不变 → uid/签名包数量一致。
#[test]
fn change_passphrase_pqc_round_trip() {
    let armored = match std::fs::read_to_string(fixture_dir().join("sec_protected.asc")) {
        Ok(v) => v,
        Err(_) => {
            println!("SKIP: fixture 缺失 sec_protected.asc（设 HPS_FIXTURE_DIR 指定目录）");
            return;
        }
    };
    let raw_msg = match std::fs::read(fixture_dir().join("mixed_from_gpg.gpg")) {
        Ok(v) => v,
        Err(_) => {
            println!("SKIP: fixture 缺失 mixed_from_gpg.gpg（二进制，需 std::fs::read）");
            return;
        }
    };

    // 前置：旧口令能解材料、能解密样例报文
    let key0 = gpg_pqc::extract_key(&armored, "testpw123").expect("旧口令应可解");
    let plain0 = gpg_pqc::decrypt_message(&key0, &raw_msg).expect("旧口令应可解密样例报文");
    assert!(!plain0.is_empty());

    let out = match run_change_passphrase(&armored, "testpw123", "newpw-456") {
        Ok(v) => v,
        Err(e) => {
            panic!("换口令应成功: {}", e);
        }
    };
    if let Ok(p) = std::env::var("HPS_DUMP_PW") {
        std::fs::write(&p, &out).unwrap();
        println!("已写出换口令后的密钥到 {}", p);
    }

    let key1 = gpg_pqc::extract_key(&out, "newpw-456").expect("新口令应可解");
    let plain1 = gpg_pqc::decrypt_message(&key1, &raw_msg).expect("换口令后应仍可解密原报文");
    assert_eq!(plain0, plain1, "解密结果应逐字节一致");
    assert!(gpg_pqc::extract_key(&out, "testpw123").is_err(), "旧口令应失效");

    let orig = gpg_pqc::dearmor(&armored).and_then(|r| gpg_pqc::parse_packets(&r)).expect("orig parse");
    let done = gpg_pqc::dearmor(&out).and_then(|r| gpg_pqc::parse_packets(&r)).expect("out parse");
    let mut fp_found = false;
    for pkt in done.iter().filter(|p| matches!(p.tag, 5 | 6 | 7 | 14)) {
        if pkt.body.len() > 6 && pkt.body[5] == 8 {
            let (pubkey, _) = gpg_pqc::parse_public_material(&pkt.body).expect("public material");
            assert_eq!(
                pubkey.fingerprint,
                key0.fingerprint,
                "v5 指纹不得变化"
            );
            fp_found = true;
        }
    }
    assert!(fp_found, "换口令后必须保留 algo 8 子密钥");
    assert_eq!(
        orig.iter().filter(|p| p.tag == 13).count(),
        done.iter().filter(|p| p.tag == 13).count(),
        "用户 ID 包数量应一致"
    );
    assert_eq!(
        orig.iter().filter(|p| p.tag == 2).count(),
        done.iter().filter(|p| p.tag == 2).count(),
        "签名包数量应一致"
    );
}

/// 换口令时旧口令写错必须明确失败，而不是产出一把解不开的密钥
#[test]
fn change_passphrase_wrong_old_passphrase_fails() {
    let armored = match std::fs::read_to_string(fixture_dir().join("sec_protected.asc")) {
        Ok(v) => v,
        Err(_) => {
            println!("SKIP: fixture 缺失 sec_protected.asc（设 HPS_FIXTURE_DIR 指定目录）");
            return;
        }
    };
    let result = run_change_passphrase(&armored, "wrong-pw", "newpw-456");
    assert!(result.is_err(), "旧口令错误必须失败");
    let msg = result.err().unwrap_or_default();
    assert!(msg.contains("旧密钥密码不正确"), "错误应指明旧口令问题: {}", msg);
}

/// GnuPG PQC 密钥换口令为空（去除保护）必须拒绝，而不是丢掉 ML-KEM 材料
#[test]
fn change_passphrase_pqc_empty_new_passphrase_rejected() {
    let armored = match std::fs::read_to_string(fixture_dir().join("sec_protected.asc")) {
        Ok(v) => v,
        Err(_) => {
            println!("SKIP: fixture 缺失 sec_protected.asc（设 HPS_FIXTURE_DIR 指定目录）");
            return;
        }
    };
    let result = run_change_passphrase(&armored, "testpw123", "");
    assert!(result.is_err(), "PQC 密钥去除密码保护应被拒绝");
    }

    /// 普通密钥多接收方回归：**每把接收方都必须有一个 PKESK，且每把都能解密**
    ///
    /// 回归的是 `from_armor_many` 陷阱：rpgp 0.20 对连续 armor 块只解析第一块，
    /// 曾导致「.gpg-id 写了 N 把普通密钥、密文却只发给第一把」——其余接收方
    /// 永远解不开，而用户毫无感知（PQC 路径因自带逐块解析从未受影响）。
    /// 用内存生成的无口令密钥（与模拟器实测同构：Ed25519 主键 + Cv25519 子键），
    /// 不依赖 fixture。
    #[test]
    fn multi_normal_recipients_round_trip() {
        fn gen_passphraseless_key(user_id: &str) -> String {
            let sub = SubkeyParamsBuilder::default()
                .key_type(KeyType::ECDH(ECCCurve::Curve25519Legacy))
                .can_encrypt(EncryptionCaps::All)
                .build()
                .expect("subkey params");
            let params = SecretKeyParamsBuilder::default()
                .key_type(KeyType::Ed25519Legacy)
                .can_certify(true)
                .can_sign(true)
                .primary_user_id(user_id.to_string())
                .subkey(sub)
                .build()
                .expect("key params");
            let signed = params.generate(OsRng).expect("generate key");
            signed
                .to_armored_string(ArmorOptions::default())
                .expect("armor key")
        }

        fn extract_public(seckey_armored: &str) -> String {
            let (seckey, _headers) =
                SignedSecretKey::from_armor_single(seckey_armored.as_bytes()).expect("parse seckey");
            seckey
                .to_public_key()
                .to_armored_string(ArmorOptions::default())
                .expect("armor pubkey")
        }

        let sec1 = gen_passphraseless_key("multi-rcpt-1 <m1@test>");
        let sec2 = gen_passphraseless_key("multi-rcpt-2 <m2@test>");
        let joined_pub = format!("{}\n{}", extract_public(&sec1), extract_public(&sec2));

        // 走 FFI（与 ArkTS 同一条入口）：两把公钥必须产出 2 个 PKESK
        let pt = CString::new("MULTI-NORMAL-往返").unwrap();
        let pubs = CString::new(joined_pub).unwrap();
        let r = hps_pgp_encrypt(pt.as_ptr(), pubs.as_ptr());
        assert_eq!(r.success, 0, "encrypt failed: {}",
            unsafe { CStr::from_ptr(r.error) }.to_string_lossy());
        let armored = unsafe { CStr::from_ptr(r.data) }.to_string_lossy().into_owned();

        let ids = gpg_pqc::recipient_keyids(&armored).expect("recipient_keyids");
        assert_eq!(ids.len(), 2, "两把接收方都应有 PKESK，实际 {:?}", ids);

        // 两把接收方各自都能解出同一明文
        let msg = "MULTI-NORMAL-往返";
        for (label, sec) in [("rcpt-1", &sec1), ("rcpt-2", &sec2)] {
            let (seckey, _h) =
                SignedSecretKey::from_armor_single(sec.as_bytes()).expect("parse seckey");
            let (mut parsed, _h2) = Message::from_armor(armored.as_bytes()).expect("parse message");
            let mut decrypted = parsed
                .decrypt(&Password::empty(), &seckey)
                .expect("decrypt with each recipient");
            if decrypted.is_compressed() {
                decrypted = decrypted.decompress().expect("decompress");
            }
            let data = decrypted.as_data_vec().expect("literal data");
            assert_eq!(String::from_utf8_lossy(&data), msg, "{} 应能解密", label);
        }
    }

    /// FFI 结果 → Result（ok 取 data，失败取 error）
    fn ffi_outcome(r: FfiResult) -> Result<String, String> {
        let data = if r.data.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(r.data) }.to_string_lossy().into_owned()
        };
        let error = if r.error.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(r.error) }.to_string_lossy().into_owned()
        };
        if r.success == 0 {
            Ok(data)
        } else {
            Err(error)
        }
    }

    /// 生成一把带口令的测试密钥（内存，不依赖 fixture），返回 armored 私钥
    fn locked_test_key(passphrase: &str) -> String {
        let uid = CString::new("Cache Test <cache@example.org>").unwrap();
        let kind = CString::new("eddsa").unwrap();
        let pw = CString::new(passphrase).unwrap();
        ffi_outcome(hps_pgp_generate_key(uid.as_ptr(), kind.as_ptr(), pw.as_ptr()))
            .expect("generate key")
    }

    /// 已解锁私钥缓存：同密钥同口令第二次取用命中缓存（同一实例），上锁后重新解锁
    ///
    /// 回归的是「内容搜索冷缓存首搜慢」的根因：解密原先每条密文都重新解析私钥并跑
    /// 一遍**迭代 S2K**（GnuPG 默认 count 可达 65M 哈希量），逐条解密时被放大成 N 倍。
    #[test]
    fn unlocked_key_cache_reuses_instance_and_lock_clears() {
        let armored = locked_test_key("cache-pw-123");

        let first = cached_secret_key(&armored, "cache-pw-123").expect("首次解锁");
        let second = cached_secret_key(&armored, "cache-pw-123").expect("二次取用");
        assert!(Arc::ptr_eq(&first, &second), "同密钥同口令应命中缓存（同一实例）");

        // 缓存键含口令：错误口令不得命中，必须失败
        assert!(cached_secret_key(&armored, "wrong-pw").is_err(), "错误口令必须失败");

        // 上锁（切后台）清空缓存：重新解锁得到新实例，且仍能用
        hps_pgp_lock();
        let after_lock = cached_secret_key(&armored, "cache-pw-123").expect("上锁后重新解锁");
        assert!(!Arc::ptr_eq(&first, &after_lock), "上锁后应重新解锁（非缓存实例）");
    }

    /// `hps_pgp_decrypt` 的「已解锁密钥 + 无口令」路径回归
    ///
    /// 接入缓存后解密不再把口令交给 rpgp（`decrypt_the_ring(ring, false)` + 明文私钥段），
    /// 这条用例覆盖三条路径：首次（未命中缓存）、二次（命中缓存）、上锁后（重新解锁），
    /// 并确认错误口令仍然失败。
    #[test]
    fn decrypt_uses_unlocked_cache_and_survives_lock() {
        let secret = locked_test_key("decrypt-pw-456");
        let public = ffi_outcome(hps_pgp_extract_public_key(
            CString::new(secret.clone()).unwrap().as_ptr(),
        ))
        .expect("extract public key");
        let plain = "cache integration";
        let cipher = ffi_outcome(hps_pgp_encrypt(
            CString::new(plain).unwrap().as_ptr(),
            CString::new(public).unwrap().as_ptr(),
        ))
        .expect("encrypt");

        let decrypt = |pw: &str| -> Result<String, String> {
            ffi_outcome(hps_pgp_decrypt(
                CString::new(cipher.clone()).unwrap().as_ptr(),
                CString::new(secret.clone()).unwrap().as_ptr(),
                CString::new(pw).unwrap().as_ptr(),
            ))
        };

        // ① 首次：未命中缓存（解析 + 迭代 S2K 解锁）
        assert_eq!(decrypt("decrypt-pw-456").expect("first decrypt"), plain);
        // ② 二次：命中缓存，结果必须一致
        assert_eq!(decrypt("decrypt-pw-456").expect("cached decrypt"), plain);
        // ③ 错误口令：不得命中缓存，必须失败
        assert!(decrypt("bad-pw").is_err(), "错误口令必须失败");
        // ④ 上锁清空缓存后仍能解（重新解锁一次）
        hps_pgp_lock();
        assert_eq!(decrypt("decrypt-pw-456").expect("decrypt after lock"), plain);
    }
}
