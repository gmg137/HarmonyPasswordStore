//! GnuPG PQC (algo 8, `ky768_cv25519` = ML-KEM-768 + X25519) 互通支持
//!
//! 独立模块，不依赖 pgp crate。目标：解密由 GnuPG 2.5 用 algo 8 加密的报文。
//!
//! 权威依据：
//! - `gnupg/common/kem.c`：KMAC256 组合器 `gnupg_kem_combiner`（algo 8）、
//!   ECC 共享秘密预哈希 `gnupg_ecc_kem_simple_kdf`、曲线参数表 `ecc_table`
//! - GnuPG `doc/keyformat.txt`：`openpgp-s2k3-ocb-aes` 带口令保护格式
//! - RFC 9580：v5 指纹、AEAD(OCB) 报文、PKESK 材料布局
//!
//! 实测钉死的事实：
//! - PKESK algo 8 载荷 = `MPI(ecc_ct) || u32(len) || mlkem_ct || u8(sym_algo) || u8(len) || AES-KW(session_key)`
//! - 私钥段 `0xff` 布局 = `0xff || cipher || 0x00 0x65 0x00 || "GNU" || 0x03 || u32(len) || s-expression`
//! - OCB 的 AAD = ecc 列表去掉 `protected` 元素后的 canonical s-expression
//! - tag 20（GnuPG AEAD）分块 AAD = `[0x14, 0x01, sym_alg, aead, chunk_byte, chunk_index(8B BE)]`

use aes::Aes128;
use aead::generic_array::GenericArray;
use aead::{Aead, KeyInit, Payload};
use ocb3::Ocb3;
use sha1::Sha1;
use sha2::Sha256;
use sha3::{Digest, Sha3_256, Sha3_512};

/// brainpool 曲线算术（自建素域 + RC-B 完备加法公式，见该文件头注释）
///
/// 作为 `gpg_pqc` 的子模块而非 crate 顶层模块：`src/bin/*.rs` 用
/// `#[path = "../gpg_pqc.rs"]` 直接包含本文件，子模块会随之带上，
/// 顶层模块则不会（那会导致 bins 编译失败）。
#[path = "bp_curve.rs"]
pub mod bp_curve;
use typenum::{U12, U16};

type Aes128Ocb = Ocb3<Aes128, U12, U16>;

// ===================== 错误类型 =====================

#[derive(Debug)]
pub enum GpgError {
    Parse(String),
    Crypto(String),
    Unsupported(String),
}

impl std::fmt::Display for GpgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GpgError::Parse(s) => write!(f, "解析失败: {}", s),
            GpgError::Crypto(s) => write!(f, "解密失败: {}", s),
            GpgError::Unsupported(s) => write!(f, "不支持: {}", s),
        }
    }
}

pub type Result<T> = std::result::Result<T, GpgError>;

fn be_u32(d: &[u8], p: usize) -> Result<u32> {
    if p + 4 > d.len() {
        return Err(GpgError::Parse("越界读取 u32".into()));
    }
    Ok(u32::from_be_bytes([d[p], d[p + 1], d[p + 2], d[p + 3]]))
}

// ===================== OpenPGP 包解析 =====================

/// 一个 OpenPGP 包（tag + body）
#[derive(Debug, Clone)]
pub struct Packet {
    pub tag: u8,
    pub body: Vec<u8>,
}

/// 解析包序列（同时支持新旧两种包头）
pub fn parse_packets(d: &[u8]) -> Result<Vec<Packet>> {
    let mut out = Vec::new();
    let mut off = 0usize;
    while off < d.len() {
        let b = d[off];
        let (tag, ho, ln) = if b & 0x40 != 0 {
            let tag = b & 0x3F;
            let l = d.get(off + 1).copied().ok_or_else(|| GpgError::Parse("包头截断".into()))?;
            let (ln, ho) = if l < 192 {
                (l as usize, off + 2)
            } else if l < 224 {
                let l2 = d.get(off + 2).copied().ok_or_else(|| GpgError::Parse("包头截断".into()))?;
                (((l as usize - 192) << 8) + l2 as usize + 192, off + 3)
            } else if l == 255 {
                (be_u32(d, off + 2)? as usize, off + 6)
            } else {
                return Err(GpgError::Parse("不支持的 partial body 长度".into()));
            };
            (tag, ho, ln)
        } else {
            let tag = (b >> 2) & 0x0F;
            let lt = b & 3;
            let (ln, ho) = match lt {
                0 => (
                    d.get(off + 1).copied().ok_or_else(|| GpgError::Parse("包头截断".into()))? as usize,
                    off + 2,
                ),
                1 => {
                    if off + 3 > d.len() {
                        return Err(GpgError::Parse("包头截断".into()));
                    }
                    (u16::from_be_bytes([d[off + 1], d[off + 2]]) as usize, off + 3)
                }
                2 => (be_u32(d, off + 1)? as usize, off + 5),
                _ => (d.len() - off - 1, off + 1),
            };
            (tag, ho, ln)
        };
        if ho + ln > d.len() {
            return Err(GpgError::Parse(format!("包体越界: tag={} len={}", tag, ln)));
        }
        out.push(Packet { tag, body: d[ho..ho + ln].to_vec() });
        off = ho + ln;
    }
    Ok(out)
}

// ===================== s-expression =====================

/// 极简 s-expression 节点
#[derive(Debug, Clone)]
pub enum Sexp {
    Atom(Vec<u8>),
    List(Vec<Sexp>),
}

impl Sexp {
    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Sexp::Atom(b) => Some(b),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<String> {
        self.as_bytes().map(|b| String::from_utf8_lossy(b).to_string())
    }
    /// 直接子列表（用于遍历 `(name value)` 对之外的裸列表）
    pub fn lists(&self) -> Vec<&Sexp> {
        match self {
            Sexp::List(items) => items.iter().filter(|x| matches!(x, Sexp::List(_))).collect(),
            _ => Vec::new(),
        }
    }
    pub fn atoms(&self) -> Vec<&[u8]> {
        match self {
            Sexp::List(items) => items.iter().filter_map(|x| x.as_bytes()).collect(),
            _ => Vec::new(),
        }
    }
}

/// 解析 s-expression（GnuPG canonical 形式：`<len>:<data>` 原子 + 括号）
pub fn parse_sexp(d: &[u8], pos: &mut usize) -> Result<Sexp> {
    skip_ws(d, pos);
    let c = *d.get(*pos).ok_or_else(|| GpgError::Parse("s-expr 意外结束".into()))?;
    if c == b'(' {
        *pos += 1;
        let mut items = Vec::new();
        loop {
            skip_ws(d, pos);
            let c = *d.get(*pos).ok_or_else(|| GpgError::Parse("s-expr 括号未闭合".into()))?;
            if c == b')' {
                *pos += 1;
                break;
            }
            items.push(parse_sexp(d, pos)?);
        }
        Ok(Sexp::List(items))
    } else if c.is_ascii_digit() {
        let start = *pos;
        while *pos < d.len() && d[*pos].is_ascii_digit() {
            *pos += 1;
        }
        if *pos >= d.len() || d[*pos] != b':' {
            return Err(GpgError::Parse("s-expr 原子缺少 ':'".into()));
        }
        let len: usize = std::str::from_utf8(&d[start..*pos])
            .map_err(|_| GpgError::Parse("s-expr 长度非 ASCII".into()))?
            .parse()
            .map_err(|_| GpgError::Parse("s-expr 长度非法".into()))?;
        *pos += 1;
        if *pos + len > d.len() {
            return Err(GpgError::Parse("s-expr 原子越界".into()));
        }
        let atom = d[*pos..*pos + len].to_vec();
        *pos += len;
        Ok(Sexp::Atom(atom))
    } else {
        Err(GpgError::Parse(format!("s-expr 非法字符 {:#04x}", c)))
    }
}

fn skip_ws(d: &[u8], pos: &mut usize) {
    while *pos < d.len() && matches!(d[*pos], b' ' | b'\t' | b'\n' | b'\r') {
        *pos += 1;
    }
}

// ===================== RFC 4880 S2K + AES-128-OCB =====================

/// RFC 4880 §3.7.1.3 iterated+salted S2K
///
/// 关键：待哈希数据流 = `(salt || passphrase)` **循环重复**并截断到 count 字节。
fn s2k_iterated_salted(salt: &[u8], count: usize, passphrase: &[u8], keylen: usize) -> Vec<u8> {
    let block: Vec<u8> = salt.iter().chain(passphrase.iter()).copied().collect();
    let mut out = Vec::new();
    if block.is_empty() {
        return out;
    }
    let mut round = 0usize;
    while out.len() < keylen {
        let mut h = Sha1::new();
        for _ in 0..round {
            sha1::Digest::update(&mut h, [0u8]);
        }
        let mut rem = count;
        let mut o = 0usize;
        while rem > 0 {
            let take = rem.min(block.len() - o);
            sha1::Digest::update(&mut h, &block[o..o + take]);
            rem -= take;
            o = (o + take) % block.len();
        }
        out.extend_from_slice(&sha1::Digest::finalize(h));
        round += 1;
    }
    out.truncate(keylen);
    out
}

/// 用 AES-128-OCB 解密 GnuPG 保护段（nonce 12B / tag 16B）
pub fn ocb_decrypt(key: &[u8], nonce: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    if key.len() != 16 {
        return Err(GpgError::Crypto("OCB 密钥必须 16 字节".into()));
    }
    if nonce.len() != 12 {
        return Err(GpgError::Crypto("OCB nonce 必须 12 字节".into()));
    }
    let cipher = Aes128Ocb::new_from_slice(key).map_err(|e| GpgError::Crypto(e.to_string()))?;
    let n = GenericArray::<u8, U12>::from_slice(nonce);
    cipher
        .decrypt(n, Payload { msg: ct, aad })
        .map_err(|_| GpgError::Crypto("OCB 认证标签校验失败（口令错误或 AAD 不符）".into()))
}

/// 用 AES-128-OCB 加密 GnuPG 保护段（nonce 12B / tag 16B），输出 = 密文 || tag
///
/// 与 `ocb_decrypt` 对称；换口令时用新口令派生的密钥重新保护同一段明文。
pub fn ocb_encrypt(key: &[u8], nonce: &[u8], aad: &[u8], pt: &[u8]) -> Result<Vec<u8>> {
    if key.len() != 16 {
        return Err(GpgError::Crypto("OCB 密钥必须 16 字节".into()));
    }
    if nonce.len() != 12 {
        return Err(GpgError::Crypto("OCB nonce 必须 12 字节".into()));
    }
    let cipher = Aes128Ocb::new_from_slice(key).map_err(|e| GpgError::Crypto(e.to_string()))?;
    let n = GenericArray::<u8, U12>::from_slice(nonce);
    cipher
        .encrypt(n, Payload { msg: pt, aad })
        .map_err(|e| GpgError::Crypto(format!("OCB 加密失败: {}", e)))
}

// ===================== KMAC256（NIST SP 800-185） =====================

fn left_encode(x: u64) -> Vec<u8> {
    let bytes = x.to_be_bytes();
    let mut n = 8;
    while n > 1 && bytes[8 - n] == 0 {
        n -= 1;
    }
    let mut out = vec![n as u8];
    out.extend_from_slice(&bytes[8 - n..]);
    out
}

fn right_encode(x: u64) -> Vec<u8> {
    let bytes = x.to_be_bytes();
    let mut n = 8;
    while n > 1 && bytes[8 - n] == 0 {
        n -= 1;
    }
    let mut out = bytes[8 - n..].to_vec();
    out.push(n as u8);
    out
}

/// encode_string(S) = left_encode(len(S) in bits) || S
fn encode_string(s: &[u8]) -> Vec<u8> {
    let mut out = left_encode((s.len() as u64) * 8);
    out.extend_from_slice(s);
    out
}

/// bytepad(X, w) = left_encode(w) || X || 0^pad
fn bytepad(x: &[u8], w: usize) -> Vec<u8> {
    let mut out = left_encode(w as u64);
    out.extend_from_slice(x);
    while out.len() % w != 0 {
        out.push(0);
    }
    out
}

/// 标准 KMAC256(K, X, L, S) = cSHAKE256(bytepad(encode_string(K),136) || X || right_encode(L), L, "KMAC", S)
///
/// 必须用真正的 cSHAKE256（域分隔位 0x04），不能拿 SHAKE256（0x1F）冒充。
/// sha3 的 `CShake256Core::new_with_function_name` 内部已做
/// `bytepad(encode_string(N) || encode_string(S), rate)`。
pub fn kmac256(key: &[u8], custom: &[u8], data: &[u8], outlen: usize) -> Vec<u8> {
    use sha3::digest::ExtendableOutput;
    use sha3::{CShake256, CShake256Core};

    use sha3::digest::Update;
    let core = CShake256Core::new_with_function_name(b"KMAC", custom);
    let mut h = CShake256::from_core(core);

    h.update(&bytepad(&encode_string(key), 136));
    h.update(data);
    h.update(&right_encode((outlen as u64) * 8));

    let mut out = vec![0u8; outlen];
    h.finalize_xof_into(&mut out);
    out
}

// ===================== AES-KW（RFC 3394） =====================

/// RFC 3394 AES Key Unwrap（无填充，输入须为 8 的倍数且 >= 24）
pub fn aes_kw_unwrap(kek: &[u8], wrapped: &[u8]) -> Result<Vec<u8>> {
    if kek.len() != 16 && kek.len() != 24 && kek.len() != 32 {
        return Err(GpgError::Crypto("AES-KW KEK 长度非法".into()));
    }
    if wrapped.len() < 24 || wrapped.len() % 8 != 0 {
        return Err(GpgError::Crypto("AES-KW 密文长度非法".into()));
    }
    let mut a = [0u8; 8];
    a.copy_from_slice(&wrapped[..8]);
    let mut r: Vec<[u8; 8]> = wrapped[8..].chunks(8).map(|c| {
        let mut b = [0u8; 8];
        b.copy_from_slice(c);
        b
    }).collect();

    let n = r.len();
    use aes::cipher::BlockDecrypt;

    // AES-128/192/256 KEK
    macro_rules! unwrap_with {
        ($c:expr) => {{
            for j in (0..6usize).rev() {
                for i in (0..n).rev() {
                    let t = (n as u64) * (j as u64) + (i as u64) + 1;
                    // RFC 3394：B = AES⁻¹(K, (A ⊕ t) || R[i])，计数器异或到 A 而非 R[i]
                    let mut block = [0u8; 16];
                    let tb = t.to_be_bytes();
                    for k in 0..8 {
                        block[k] = a[k] ^ tb[k];
                    }
                    block[8..].copy_from_slice(&r[i]);
                    let mut g = aes::cipher::generic_array::GenericArray::clone_from_slice(&block);
                    $c.decrypt_block(&mut g);
                    a.copy_from_slice(&g[..8]);
                    r[i].copy_from_slice(&g[8..]);
                }
            }
        }};
    }

    match kek.len() {
        16 => {
            let c = aes::Aes128::new_from_slice(kek).unwrap();
            unwrap_with!(c);
        }
        24 => {
            let c = aes::Aes192::new_from_slice(kek).unwrap();
            unwrap_with!(c);
        }
        _ => {
            let c = aes::Aes256::new_from_slice(kek).unwrap();
            unwrap_with!(c);
        }
    }

    if a != [0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6] {
        return Err(GpgError::Crypto("AES-KW 完整性校验失败（IV 不匹配）".into()));
    }
    let mut out = Vec::with_capacity(n * 8);
    for x in &r {
        out.extend_from_slice(x);
    }
    Ok(out)
}

// ===================== v5 指纹 =====================

/// RFC 9580 v5 指纹：`SHA-256(0x9A || u32(len) || 公钥部分字节)`，输出 **32 字节**
///
/// 注意：`0x9A` 只是**哈希输入**的前缀（用于区分 v5 密钥），**不是**输出的一部分。
/// `body` 必须是**公钥部分**（`10 + matlen` 字节，不含私钥段）。
/// Key ID = 指纹最左 8 字节。实测与 gpg 的 keyid 逐字节一致。
pub fn v5_fingerprint(body: &[u8]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(5 + body.len());
    buf.push(0x9A);
    buf.extend_from_slice(&(body.len() as u32).to_be_bytes());
    buf.extend_from_slice(body);
    Sha256::digest(&buf).to_vec()
}

// ===================== 密钥材料 =====================

/// 从 GnuPG algo 8 私钥中提取的全部材料
#[derive(Debug, Clone)]
pub struct GpgPqcKey {
    /// 曲线名（s-expr `curve` 字段，如 Curve25519 / brainpoolP256r1）
    pub curve: String,
    /// 解析后的曲线（无法识别时为 None，加解密会被明确拒绝）
    pub ecc: Option<EccCurve>,
    /// ECC 公钥点（MPI 材料，Curve25519 为 33B，带 0x40 前缀）
    pub ecc_q: Vec<u8>,
    /// ML-KEM 封装公钥（1184B）
    pub mlkem_ek: Vec<u8>,
    /// X25519 静态私钥（32B，已从保护段解出）
    pub ecc_d: Vec<u8>,
    /// ML-KEM 解封装种子（64B = d||z）
    pub mlkem_secret: Vec<u8>,
    /// v5 指纹（33B：0x9A + 32B）
    pub fingerprint: Vec<u8>,
    /// Key ID（指纹左起 8 字节，即 33B 中的 [1..9]）
    pub keyid: Vec<u8>,
}

fn mpi_read(d: &[u8], p: &mut usize) -> Result<Vec<u8>> {
    let bits = u16::from_be_bytes([
        *d.get(*p).ok_or_else(|| GpgError::Parse("MPI 截断".into()))?,
        *d.get(*p + 1).ok_or_else(|| GpgError::Parse("MPI 截断".into()))?,
    ]) as usize;
    *p += 2;
    let n = (bits + 7) / 8;
    if *p + n > d.len() {
        return Err(GpgError::Parse("MPI 越界".into()));
    }
    let v = d[*p..*p + n].to_vec();
    *p += n;
    Ok(v)
}

/// 解析 GnuPG `openpgp-s2k3-ocb-aes` 保护段，并提取 ECC 私钥 `d`
fn decrypt_protected(
    sexp_bytes: &[u8],
    protected_start: usize,
    protected_end: usize,
    passphrase: &str,
) -> Result<Vec<u8>> {
    let pt = decrypt_protected_raw(sexp_bytes, protected_start, protected_end, passphrase)?;
    // 明文是 s-expression，含 `(1:d32:<32 字节>)`
    let mut q = 0usize;
    let doc = parse_sexp(&pt, &mut q)?;
    let d = find_atom(&doc, "d")
        .ok_or_else(|| GpgError::Parse("保护段内未找到私钥 d".into()))?;
    Ok(d.to_vec())
}

/// 解密 protected 段，返回**明文 s-expression 字节**（不做字段提取）
///
/// AAD = 「容器列表去掉 protected 元素」后的 canonical s-expression；
/// 该定义对 ecc 段与 kyber 段同样成立，故 ECC 与 ML-KEM 两条路径共用本函数。
fn decrypt_protected_raw(
    sexp_bytes: &[u8],
    protected_start: usize,
    protected_end: usize,
    passphrase: &str,
) -> Result<Vec<u8>> {
    // AAD = 去掉 protected 元素后的容器列表
    let mut aad = Vec::with_capacity(sexp_bytes.len());
    aad.extend_from_slice(&sexp_bytes[..protected_start]);
    aad.extend_from_slice(&sexp_bytes[protected_end..]);

    // protected 元素内部：((sha1 <salt> <count>) <nonce>) <ct>
    let inner = &sexp_bytes[protected_start..protected_end];
    let mut p = 0usize;
    let node = parse_sexp(inner, &mut p)?;
    let items = match &node {
        Sexp::List(v) => v.clone(),
        _ => return Err(GpgError::Parse("protected 结构异常".into())),
    };
    // 结构：`(protected <算法名> ((<hash> <salt> <count>) <nonce>) <ct>)`
    // items[0] 是字面量 "protected"，算法名在其后
    let name = items.get(0).and_then(|x| x.as_str()).unwrap_or_default();
    let (algo_idx, params_idx, ct_idx) = if name == "protected" {
        (1usize, 2usize, 3usize)
    } else {
        (0usize, 1usize, 2usize)
    };
    let algo_node = items
        .get(algo_idx)
        .ok_or_else(|| GpgError::Parse("protected 缺少算法名".into()))?;
    if algo_node.as_str().as_deref() != Some("openpgp-s2k3-ocb-aes") {
        return Err(GpgError::Unsupported(format!(
            "不支持的私钥保护算法: {:?}",
            algo_node.as_str()
        )));
    }
    let params = items.get(params_idx).and_then(|x| match x {
        Sexp::List(v) => Some(v.clone()),
        _ => None,
    }).ok_or_else(|| GpgError::Parse("protected 缺少参数".into()))?;
    // params = [ (sha1 salt count), nonce ]
    let s2k = params.get(0).and_then(|x| match x {
        Sexp::List(v) => Some(v.clone()),
        _ => None,
    }).ok_or_else(|| GpgError::Parse("protected 缺少 S2K 参数".into()))?;
    let hash_name = s2k.get(0).and_then(|x| x.as_str()).unwrap_or_default();
    if hash_name != "sha1" {
        return Err(GpgError::Unsupported(format!("不支持的 S2K 哈希: {}", hash_name)));
    }
    let salt = s2k.get(1).and_then(|x| x.as_bytes()).ok_or_else(|| GpgError::Parse("缺少 salt".into()))?;
    let count: usize = s2k
        .get(2)
        .and_then(|x| x.as_str())
        .and_then(|s| s.trim().parse().ok())
        .ok_or_else(|| GpgError::Parse("缺少迭代次数".into()))?;
    let nonce = params.get(1).and_then(|x| x.as_bytes()).ok_or_else(|| GpgError::Parse("缺少 nonce".into()))?;
    let ct = items.get(ct_idx).and_then(|x| x.as_bytes()).ok_or_else(|| GpgError::Parse("缺少密文".into()))?;

    let key = s2k_iterated_salted(salt, count, passphrase.as_bytes(), 16);
    let pt = ocb_decrypt(&key, nonce, &aad, ct)?;
    Ok(pt)
}

/// 从 protected 元素字节中解析 S2K 迭代次数（十进制字符串原子）
///
/// 换口令重建保护段时沿用原次数（次数本身没有格式约束，只影响 KDF 耗时）。
fn protected_s2k_count(inner: &[u8]) -> Result<usize> {
    let mut p = 0usize;
    let node = parse_sexp(inner, &mut p)?;
    let items = match &node {
        Sexp::List(v) => v.clone(),
        _ => return Err(GpgError::Parse("protected 结构异常".into())),
    };
    // 结构：`(protected <算法名> ((<hash> <salt> <count>) <nonce>) <ct>)`
    let name = items.get(0).and_then(|x| x.as_str()).unwrap_or_default();
    let params_idx = if name == "protected" { 2usize } else { 1usize };
    let params = items.get(params_idx).and_then(|x| match x {
        Sexp::List(v) => Some(v.clone()),
        _ => None,
    }).ok_or_else(|| GpgError::Parse("protected 缺少参数".into()))?;
    let s2k = params.get(0).and_then(|x| match x {
        Sexp::List(v) => Some(v.clone()),
        _ => None,
    }).ok_or_else(|| GpgError::Parse("protected 缺少 S2K 参数".into()))?;
    s2k.get(2)
        .and_then(|x| x.as_str())
        .and_then(|s| s.trim().parse().ok())
        .ok_or_else(|| GpgError::Parse("缺少迭代次数".into()))
}

/// 递归查找 `(name <atom>)` 并返回该原子的字节
fn find_atom<'a>(node: &'a Sexp, name: &str) -> Option<&'a [u8]> {
    match node {
        Sexp::Atom(_) => None,
        Sexp::List(items) => {
            let mut i = 0;
            while i < items.len() {
                if items[i].as_str().as_deref() == Some(name) {
                    if let Some(v) = items.get(i + 1).and_then(|x| x.as_bytes()) {
                        return Some(v);
                    }
                }
                i += 1;
            }
            items.iter().find_map(|it| find_atom(it, name))
        }
    }
}

/// GnuPG algo 8 的**公钥**材料（加密所需，无需口令）
#[derive(Debug, Clone)]
pub struct GpgPqcPublicKey {
    /// 曲线名（如 Curve25519 / brainpoolP256r1）
    pub curve: String,
    /// 解析后的曲线（无法识别时为 None，加密会被明确拒绝）
    pub ecc: Option<EccCurve>,
    /// ECC 公钥点（MPI 材料，Curve25519 为 33B，带 0x40 前缀）
    pub ecc_q: Vec<u8>,
    /// ML-KEM 封装公钥（1184B）
    pub mlkem_ek: Vec<u8>,
    /// v5 指纹（32B）
    pub fingerprint: Vec<u8>,
    /// Key ID（指纹最左 8 字节）
    pub keyid: Vec<u8>,
}

/// 解析 algo 8 密钥包的公钥部分
///
/// 公钥包（tag 6/14）与私钥包（tag 5/7）的公钥部分布局完全一致：
/// `ver || ctime(4) || algo(1) || [v5+: u32 材料长度] || OID || q(MPI) || u32(eklen) || ek`
///
/// 返回 `(公钥材料, 公钥部分结束偏移)`
pub(crate) fn parse_public_material(b: &[u8]) -> Result<(GpgPqcPublicKey, usize)> {
    if b.len() < 6 {
        return Err(GpgError::Parse("密钥包过短".into()));
    }
    let ver = b[0];
    let mut p = 6usize;
    if ver >= 5 {
        let _matlen = be_u32(b, p)?;
        p += 4;
    }
    // OID
    let oidlen = *b.get(p).ok_or_else(|| GpgError::Parse("缺少 OID".into()))? as usize;
    p += 1;
    let oid = b.get(p..p + oidlen).ok_or_else(|| GpgError::Parse("OID 越界".into()))?;
    p += oidlen;
    let curve = oid_to_curve(oid);
    let ecc = EccCurve::from_name(&curve);
    // ECC 公钥 q
    let ecc_q = mpi_read(b, &mut p)?;
    // ML-KEM ek（4 字节长度前缀）
    let eklen = be_u32(b, p)? as usize;
    p += 4;
    let mlkem_ek = b.get(p..p + eklen).ok_or_else(|| GpgError::Parse("ek 越界".into()))?.to_vec();
    p += eklen;

    // 公钥部分 = 包体前 p 字节（私钥包在此之后还有私钥段）
    let pub_end = p.min(b.len());
    let fp = v5_fingerprint(&b[..pub_end]);
    let keyid = fp[..8].to_vec();
    Ok((
        GpgPqcPublicKey { curve, ecc, ecc_q, mlkem_ek, fingerprint: fp, keyid },
        pub_end,
    ))
}

/// 从 armored 公钥或私钥中提取 GnuPG algo 8（`ky768_cv25519`）公钥材料（无需口令）
///
/// 用于加密：应用要用该密钥加密新条目时，先取出其公钥材料，
/// 再走 `encrypt_message` 构造 PKESK(algo 8)。
pub fn extract_public_key(armored: &str) -> Result<GpgPqcPublicKey> {
    let raw = dearmor(armored)?;
    let packets = parse_packets(&raw)?;
    for pkt in packets.iter().filter(|p| matches!(p.tag, 5 | 6 | 7 | 14)) {
        let b = &pkt.body;
        if b.len() < 6 || b[5] != 8 {
            continue;
        }
        return parse_public_material(b).map(|(pk, _)| pk);
    }
    Err(GpgError::Unsupported("未找到 GnuPG algo 8（PQC）密钥包".into()))
}

/// 从可能拼接了多个 armored 块的文本中，提取全部 GnuPG algo 8 公钥材料
///
/// 多接收方场景下 `.gpg-id` 可能指定多把密钥，调用方把各自 armored 拼接传入；
/// 非 algo 8 的块会被跳过（由调用方另行处理）。
pub fn extract_public_keys_multi(armored: &str) -> Vec<GpgPqcPublicKey> {
    let mut out = Vec::new();
    for block in split_armor_blocks(armored) {
        if let Ok(pk) = extract_public_key(&block) {
            out.push(pk);
        }
    }
    out
}

/// 按 `-----BEGIN ...-----` / `-----END ...-----` 切分拼接的 armored 文本
///
/// crate 内公开：lib.rs 的普通密钥多接收方解析也用它（rpgp 0.20 的
/// `from_armor_many` 对连续 armor 块只解析第一块，实测任何分隔符都如此）。
pub(crate) fn split_armor_blocks(armored: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Vec<&str> = Vec::new();
    let mut in_block = false;
    for line in armored.lines() {
        let t = line.trim();
        if t.starts_with("-----BEGIN ") {
            // 容错：上一块未正常结束也先收尾
            if in_block && !cur.is_empty() {
                out.push(cur.join("\n"));
                cur.clear();
            }
            in_block = true;
            cur.push(line);
        } else if in_block {
            cur.push(line);
            if t.starts_with("-----END ") {
                out.push(cur.join("\n"));
                cur.clear();
                in_block = false;
            }
        }
    }
    if !cur.is_empty() {
        out.push(cur.join("\n"));
    }
    out
}

/// 解析 armored 私钥（GnuPG algo 8），提取全部材料
pub fn extract_key(armored: &str, passphrase: &str) -> Result<GpgPqcKey> {
    let raw = dearmor(armored)?;
    let packets = parse_packets(&raw)?;

    // 找 algo 8 的私钥包（tag 5/6 主键 或 7/14 子键）
    for pkt in packets.iter().filter(|p| matches!(p.tag, 5 | 6 | 7 | 14)) {
        let b = &pkt.body;
        if b.len() < 6 {
            continue;
        }
        let algo = b[5];
        if algo != 8 {
            continue;
        }
        // 公钥部分（与公钥包布局一致）
        let (pubkey, p) = parse_public_material(b)?;

        // 私钥段
        let usage = *b.get(p).ok_or_else(|| GpgError::Parse("缺少私钥段".into()))?;
        let (ecc_d, mlkem_secret) = match usage {
            0 => {
                // 明文 s-expression
                let rest = &b[p + 1..];
                let s = find_sexp(rest)?;
                let mut q2 = 0usize;
                let doc = parse_sexp(s, &mut q2)?;
                let d = find_atom(&doc, "d")
                    .ok_or_else(|| GpgError::Parse("未找到 d".into()))?
                    .to_vec();
                (d, extract_mlkem_secret(s, &doc, passphrase)?)
            }
            0xff | 254 | 253 => {
                let s = find_sexp(&b[p..])?;
                // 定位 ecc 列表与其 protected 元素
                let (ecc_start, ecc_end, prot_start, prot_end) = locate_ecc_protected(s)?;
                let ecc_bytes = &s[ecc_start..ecc_end];
                // 分段标注失败位置：ecc 段用口令解开，它失败才可能是口令错；
                // 若 ecc 段已解开而 ML-KEM 段失败，则**口令一定是对的**（同一口令），
                // 属密钥编码/格式问题——ArkTS 侧据此区分「口令错误」与「材料读不出」，
                // 否则正确口令会被反复报成错误（本 bug 曾因此消耗数轮排查）。
                let ecc_d = decrypt_protected(
                    ecc_bytes,
                    prot_start - ecc_start,
                    prot_end - ecc_start,
                    passphrase,
                )
                .map_err(|e| GpgError::Parse(format!("ECC 段解密失败: {}", e)))?;
                let mut q2 = 0usize;
                let doc = parse_sexp(s, &mut q2)?;
                let mlkem = extract_mlkem_secret(s, &doc, passphrase)
                    .map_err(|e| GpgError::Parse(format!("ML-KEM 段解密失败: {}", e)))?;
                (ecc_d, mlkem)
            }
            other => {
                return Err(GpgError::Unsupported(format!("不支持的私钥保护方式: {:#04x}", other)));
            }
        };

        // 私钥标量的字节序按曲线定：GnuPG `ecc_table` 的 `scalar_reverse` 只有
        // Curve25519 为 1（MPI 大端 → 原生小端须反转）；brainpool/NIST 系为 0，
        // **不能反转**——曾无条件反转，导致 brainpool 密钥的 d 被字节倒置，
        // 共享秘密全错，且表现为「AES-KW 完整性校验失败」，看着像口令或 KDF 问题。
        let mut ecc_d = ecc_d;
        if pubkey.ecc == Some(EccCurve::Curve25519) {
            ecc_d.reverse();
        }
        return Ok(GpgPqcKey {
            curve: pubkey.curve,
            ecc: pubkey.ecc,
            ecc_q: pubkey.ecc_q,
            mlkem_ek: pubkey.mlkem_ek,
            ecc_d,
            mlkem_secret,
            fingerprint: pubkey.fingerprint,
            keyid: pubkey.keyid,
        });
    }
    Err(GpgError::Unsupported("未找到 GnuPG algo 8（PQC）私钥包".into()))
}

fn find_sexp(d: &[u8]) -> Result<&[u8]> {
    let i = d
        .iter()
        .position(|&c| c == b'(')
        .ok_or_else(|| GpgError::Parse("未找到 s-expression".into()))?;
    Ok(&d[i..])
}

/// 在 s-expression 中定位 ecc 列表区间，以及其 `protected` 元素区间
fn locate_ecc_protected(s: &[u8]) -> Result<(usize, usize, usize, usize)> {
    // 找 "(3:ecc" 起点
    let mut search = 0usize;
    let ecc_start = loop {
        let i = find_sub(&s[search..], b"ecc").ok_or_else(|| GpgError::Parse("未找到 ecc 列表".into()))?;
        let abs = search + i;
        // 往前找到该原子的 '('
        let lp = s[..abs].iter().rposition(|&c| c == b'(')
            .ok_or_else(|| GpgError::Parse("ecc 缺少 '('".into()))?;
        // 确认 '(' 后紧跟长度前缀 "3:"
        if s.get(lp + 1) == Some(&b'3') && s.get(lp + 2) == Some(&b':') {
            break lp;
        }
        search = abs + 3;
    };
    let ecc_end = match_paren(s, ecc_start)?;
    // 在 ecc 区间内找 "(9:protected"（精确匹配：裸 "protected" 会命中 protected-at）
    let rel = find_sub(&s[ecc_start..ecc_end], b"(9:protected")
        .ok_or_else(|| GpgError::Parse("ecc 内未找到 protected".into()))?;
    let prot_start = ecc_start + rel;
    let prot_end = match_paren(s, prot_start)?;
    Ok((ecc_start, ecc_end, prot_start, prot_end))
}

fn find_sub(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    (0..=hay.len() - needle.len()).find(|&i| &hay[i..i + needle.len()] == needle)
}

/// 返回与 pos 处 '(' 配对的 ')' 之后一位
fn match_paren(d: &[u8], pos: usize) -> Result<usize> {
    if d.get(pos) != Some(&b'(') {
        return Err(GpgError::Parse("match_paren: 起点非 '('".into()));
    }
    let mut depth = 0i32;
    let mut i = pos;
    let mut in_atom = false;
    let mut atom_left = 0usize;
    while i < d.len() {
        let c = d[i];
        if in_atom {
            if atom_left > 0 {
                atom_left -= 1;
                i += 1;
                continue;
            }
            in_atom = false;
            continue;
        }
        match c {
            b'(' => {
                depth += 1;
                i += 1;
            }
            b')' => {
                depth -= 1;
                i += 1;
                if depth == 0 {
                    return Ok(i);
                }
            }
            b'0'..=b'9' => {
                let start = i;
                while i < d.len() && d[i].is_ascii_digit() {
                    i += 1;
                }
                if d.get(i) == Some(&b':') {
                    let n: usize = std::str::from_utf8(&d[start..i]).unwrap_or("0").parse().unwrap_or(0);
                    in_atom = true;
                    atom_left = n;
                    i += 1;
                }
            }
            _ => {
                i += 1;
            }
        }
    }
    Err(GpgError::Parse("括号未闭合".into()))
}

/// 递归查找「首原子等于 name」的子列表
fn find_list<'a>(node: &'a Sexp, name: &str) -> Option<&'a Sexp> {
    match node {
        Sexp::Atom(_) => None,
        Sexp::List(items) => {
            if items.first().and_then(|x| x.as_str()).as_deref() == Some(name) {
                return Some(node);
            }
            items.iter().find_map(|it| find_list(it, name))
        }
    }
}

/// 从解析后的 s-expression 中取 ML-KEM 种子
/// 定位 kyber 容器的 protected 段（**仅加密编码**有此段）
///
/// gpg 2.5.x 对 ML-KEM 私钥有两种编码（实测同版本区间内并存）：
/// - 明文：`(composite-key (protected-private-key (ecc ..)) (11:private-key (8:kyber768 (1:p..) (1:s..) (4:seed..))))`
/// - 加密：`(composite-key (protected-private-key (ecc ..)) (21:protected-private-key (8:kyber768 (1:p..) (9:protected ..) (12:protected-at ..))))`
///
/// **AAD 必须是「形成公钥参数的那个列表」本身**——GnuPG `doc/keyformat.txt` 对
/// `openpgp-s2k3-ocb-aes` 的原话：*"The associated data required for this protection
/// mode is the list forming the public key parameters"*，其示例 AAD 即内层参数列表
/// `(rsa (n ..) (e ..) (protected-at ..))`。`protected-private-key` 外壳由 gpg 事后
/// 添加、不参与 AAD（ecc 段同理：AAD 是 ecc 列表，不是外壳）。
///
/// 曾把外壳当作容器 → 真实加密编码密钥的 OCB 校验必然失败，而错误里没有
/// ML-KEM/kyber 关键字，被 ArkTS 的 describeVerifyError 归为「密钥密码错误」，
/// 用户输入**正确**口令仍被拒且无从定位（明文编码的密钥却正常，故极易误判为口令问题）。
///
/// 仅明文编码无 protected：此时返回 Err，由调用方按明文结构处理。
fn locate_kyber_protected(s: &[u8]) -> Result<(usize, usize, usize, usize)> {
    // 找 "(8:kyber" 的 '('
    let mut search = 0usize;
    let kyber_lp = loop {
        let i = find_sub(&s[search..], b"kyber")
            .ok_or_else(|| GpgError::Parse("未找到 kyber 节点".into()))?;
        let abs = search + i;
        let lp = s[..abs]
            .iter()
            .rposition(|&c| c == b'(')
            .ok_or_else(|| GpgError::Parse("kyber 缺少 '('".into()))?;
        if s.get(lp + 1) == Some(&b'8') && s.get(lp + 2) == Some(&b':') {
            break lp;
        }
        search = abs + 5;
    };
    let kyber_end = match_paren(s, kyber_lp)?;
    // 真实布局：protected 在 kyber768 列表**内部** → 容器就是 kyber768 列表（即 AAD）
    // 用 "(9:protected" 而非裸 "protected"：既避开 1184 字节 p 材料里的偶然命中，
    // 也天然跳过外壳名 "protected-private-key"
    if let Some(rel) = find_sub(&s[kyber_lp..kyber_end], b"(9:protected") {
        let prot_start = kyber_lp + rel;
        let prot_end = match_paren(s, prot_start)?;
        return Ok((kyber_lp, kyber_end, prot_start, prot_end));
    }
    // 兼容：protected 作为 kyber 列表的兄弟放在 protected-private-key 外壳内
    let container_start = s[..kyber_lp]
        .iter()
        .rposition(|&c| c == b'(')
        .ok_or_else(|| GpgError::Parse("kyber 容器缺少 '('".into()))?;
    if !s[container_start..].starts_with(b"(21:protected-private-key") {
        return Err(GpgError::Parse("kyber 为明文编码（无 protected）".into()));
    }
    let container_end = match_paren(s, container_start)?;
    let rel = find_sub(&s[kyber_lp..container_end], b"(9:protected")
        .ok_or_else(|| GpgError::Parse("kyber 容器内未找到 protected".into()))?;
    let prot_start = kyber_lp + rel;
    let prot_end = match_paren(s, prot_start)?;
    Ok((container_start, container_end, prot_start, prot_end))
}

/// 在 kyber 节点内取指定原子（限定作用域，避免与其它同名原子混淆）
fn find_kyber_atom<'a>(doc: &'a Sexp, name: &str) -> Option<&'a [u8]> {
    let kyber = find_list(doc, "kyber768")
        .or_else(|| find_list(doc, "kyber1024"))
        .or_else(|| find_list(doc, "kyber512"))?;
    find_atom(kyber, name)
}

/// 提取 ML-KEM 私钥材料（64 字节 seed 或 2400 字节展开私钥）
///
/// 兼容上述两种编码。曾只认明文 `(11:private-key ...)`：遇到加密编码时
/// `find_list(doc, "private-key")` 落空，报「缺少 private-key」，而 ArkTS 侧
/// `describeVerifyError` 把它归为「密钥密码错误」——用户输入**正确**口令仍被拒，
/// 且错误信息指向口令，无从定位。故此处必须两种编码都支持。
fn extract_mlkem_secret(s: &[u8], doc: &Sexp, passphrase: &str) -> Result<Vec<u8>> {
    // 加密编码：解密 kyber 容器的 protected 段
    if let Ok((cs, ce, ps, pe)) = locate_kyber_protected(s) {
        let pt = decrypt_protected_raw(&s[cs..ce], ps - cs, pe - cs, passphrase)?;
        return mlkem_secret_from_plaintext(&pt);
    }
    // 明文编码：优先 64 字节 seed，其次 2400 字节展开私钥
    if let Some(seed) = find_kyber_atom(doc, "seed") {
        return Ok(seed.to_vec());
    }
    if let Some(expanded) = find_kyber_atom(doc, "s") {
        return Ok(expanded.to_vec());
    }
    Err(GpgError::Parse(
        "kyber 节点内未找到 ML-KEM 私钥材料（seed/s）".into(),
    ))
}

/// 从解密后的明文提取 ML-KEM 私钥材料
///
/// 明文形态未知（gpg 可能只放 `(1:s 2400:..)`，也可能保留完整 kyber 包装），
/// 故用递归查找而非限定 kyber 作用域。
fn mlkem_secret_from_plaintext(pt: &[u8]) -> Result<Vec<u8>> {
    let mut q = 0usize;
    if let Ok(doc) = parse_sexp(pt, &mut q) {
        if let Some(seed) = find_atom(&doc, "seed") {
            return Ok(seed.to_vec());
        }
        if let Some(expanded) = find_atom(&doc, "s") {
            return Ok(expanded.to_vec());
        }
    }
    // 非 s-expression：长度本身即材料时直接使用
    if pt.len() == 64 || pt.len() == 2400 {
        return Ok(pt.to_vec());
    }
    Err(GpgError::Parse(format!(
        "ML-KEM 私钥材料无法识别（{} 字节）",
        pt.len()
    )))
}

// ===================== 换口令（保留 GnuPG algo 8 子密钥） =====================
//
// rpgp 解析私钥时会**静默丢弃** v5 子密钥（algo 8），直接用它改口令等于把
// gpgPqc 密钥降级成纯签名密钥（ML-KEM 材料永久丢失，存量密文再也解不开）。
// 因此 algo 8 子密钥必须做**包级手术**：公钥部分、用户 ID、签名逐字节保留，
// 只重建带口令保护的 s-expression 段（明文不变，只换盐值/nonce/密文）。
// 整个流程的逐字节依据见真实 fixture 的结构：GNU 头 `ff 07 00 65 00 "GNU" 03`
// + u32(长度) + s-expression；ecc 列表内含 (protected ...) 与 (protected-at ...)。

/// canonical s-expression 原子：`<十进制长度>:<字节>`
fn sexp_atom(data: &[u8]) -> Vec<u8> {
    let mut out = format!("{}:", data.len()).into_bytes();
    out.extend_from_slice(data);
    out
}

/// armored 私钥中是否存在 algo 8 的密钥包（tag 5/6/7/14，公钥段第 6 字节 = 算法号）
pub fn has_algo8_secret_packets(armored: &str) -> bool {
    match dearmor(armored).and_then(|raw| parse_packets(&raw)) {
        Ok(packets) => packets
            .iter()
            .any(|p| matches!(p.tag, 5 | 6 | 7 | 14) && p.body.len() > 6 && p.body[5] == 8),
        Err(_) => false,
    }
}

/// 把容器内 [ps, pe) 的 `(9:protected ...)` 元素替换成用 `new_passphrase` 重建的新元素
///
/// 明文用旧口令解出后**逐字节不变**；AAD = 容器去掉 protected 元素后的字节，
/// 与解密时的 AAD 定义完全一致——因此除 protected 元素外的所有字节
/// （含 `protected-at`）都必须原样保留。迭代次数沿用原值。
/// 返回**换掉 protected 后的整个容器**（调用方按容器区间回填）。
fn replace_protected_element(
    container: &[u8],
    ps: usize,
    pe: usize,
    old_passphrase: &str,
    new_passphrase: &str,
) -> Result<Vec<u8>> {
    let pt = decrypt_protected_raw(container, ps, pe, old_passphrase)?;
    let count = protected_s2k_count(&container[ps..pe])?;

    let mut aad = Vec::with_capacity(container.len());
    aad.extend_from_slice(&container[..ps]);
    aad.extend_from_slice(&container[pe..]);

    use rand::RngCore;
    let mut salt = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut salt);
    let mut nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce);
    let key = s2k_iterated_salted(&salt, count, new_passphrase.as_bytes(), 16);
    let ct = ocb_encrypt(&key, &nonce, &aad, &pt)?;

    // `(protected <算法> ((sha1 <salt> <count>) <nonce>) <ct>)`，canonical 编码
    let count_atom = format!("{}", count).into_bytes();
    let mut elem: Vec<u8> = Vec::with_capacity(pe - ps + 64);
    elem.extend_from_slice(b"(9:protected");
    elem.extend_from_slice(&sexp_atom(b"openpgp-s2k3-ocb-aes"));
    elem.extend_from_slice(b"((4:sha1");
    elem.extend_from_slice(&sexp_atom(&salt));
    elem.extend_from_slice(&sexp_atom(&count_atom));
    elem.push(b')');
    elem.extend_from_slice(&sexp_atom(&nonce));
    elem.push(b')');
    elem.extend_from_slice(&sexp_atom(&ct));
    elem.push(b')');

    // 容器 = protected 之前 + 新 protected 元素 + protected 之后
    let mut out = Vec::with_capacity(container.len() + elem.len());
    out.extend_from_slice(&container[..ps]);
    out.extend_from_slice(&elem);
    out.extend_from_slice(&container[pe..]);
    Ok(out)
}

/// 对单个 algo 8（GnuPG PQC）私钥包体换口令
///
/// 公钥部分逐字节保留；s-expression 内的 protected 元素（ecc 列表内必有，
/// 旧版 gpg 的 kyber 容器内可能还有一处）逐一重建，并修正 GNU 头的 u32 总长。
fn reprotect_algo8_body(body: &[u8], old_passphrase: &str, new_passphrase: &str) -> Result<Vec<u8>> {
    let (_pubkey, p) = parse_public_material(body)?;
    let usage = *body.get(p).ok_or_else(|| GpgError::Parse("缺少私钥段".into()))?;
    if usage == 0 {
        return Err(GpgError::Unsupported(
            "该密钥的 GnuPG PQC 子密钥未设密码保护，应用内暂不支持为它新增密码".into(),
        ));
    }
    // s-expression 起点：GNU 头部是二进制，首个 '(' 之前
    let sec = &body[p..];
    let rel = sec
        .iter()
        .position(|&c| c == b'(')
        .ok_or_else(|| GpgError::Parse("私钥段未找到 s-expression".into()))?;
    let sexp_start = p + rel;
    // GNU 头部末 4 字节 = s-expression 长度（u32 BE）。先核对布局再动手，
    // 长度不符说明遇到了未知结构，宁可拒绝也不能破坏密钥
    let declared = be_u32(body, sexp_start - 4)? as usize;
    if declared != body.len() - sexp_start {
        return Err(GpgError::Parse(format!(
            "GNU 头部长度不符（声明 {}，实际 {}）",
            declared,
            body.len() - sexp_start
        )));
    }
    let s = &body[sexp_start..];

    // 两处 protected（ecc 列表内 + kyber 容器内）按出现位置**从后往前**替换，
    // 否则前一处替换会让后一处的偏移失效
    let mut spans: Vec<(usize, usize, usize, usize)> = Vec::new(); // (cs, ce, ps, pe)
    if let Ok(span) = locate_ecc_protected(s) {
        spans.push(span);
    }
    if let Ok(span) = locate_kyber_protected(s) {
        spans.push(span);
    }
    if spans.is_empty() {
        return Err(GpgError::Parse("私钥段内未找到 protected 保护段".into()));
    }
    spans.sort_by(|a, b| a.2.cmp(&b.2));
    let mut new_s = s.to_vec();
    for &(cs, ce, ps, pe) in spans.iter().rev() {
        let container = new_s[cs..ce].to_vec();
        let replaced =
            replace_protected_element(&container, ps - cs, pe - cs, old_passphrase, new_passphrase)?;
        new_s.splice(cs..ce, replaced);
    }

    let mut out = body[..sexp_start - 4].to_vec();
    out.extend_from_slice(&(new_s.len() as u32).to_be_bytes());
    out.extend_from_slice(&new_s);
    Ok(out)
}

/// 从原始 armored 私钥中取出 algo 8 子密钥**块**（子密钥包 + 其后直到下一个
/// 密钥包之前的所有包，绑定签名必须跟着子密钥走），换口令后返回 raw 字节
fn reprotected_algo8_blocks(original_armored: &str, old: &str, new: &str) -> Result<Vec<u8>> {
    let raw = dearmor(original_armored)?;
    let packets = parse_packets(&raw)?;
    let mut out: Vec<u8> = Vec::new();
    let mut i = 0usize;
    while i < packets.len() {
        let pkt = &packets[i];
        if matches!(pkt.tag, 5 | 6 | 7 | 14) && pkt.body.len() > 6 && pkt.body[5] == 8 {
            if matches!(pkt.tag, 5 | 6) {
                return Err(GpgError::Unsupported(
                    "不支持以 GnuPG PQC 密钥为主密钥的私钥（算法号 8 应为加密子密钥）".into(),
                ));
            }
            let new_body = reprotect_algo8_body(&pkt.body, old, new)?;
            out.extend_from_slice(&write_packet(pkt.tag, &new_body));
            i += 1;
            while i < packets.len() && !matches!(packets[i].tag, 5 | 6 | 7 | 14) {
                out.extend_from_slice(&write_packet(packets[i].tag, &packets[i].body));
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    if out.is_empty() {
        return Err(GpgError::Unsupported("未找到 GnuPG algo 8（PQC）子密钥包".into()));
    }
    Ok(out)
}

/// GnuPG PQC（algo 8）密钥换口令的包级拼装
///
/// `v4_armored` 是 rpgp 解锁/上锁后的输出（algo 8 子密钥已被它丢弃）：
/// 把它的全部包逐字节接上「原文取出并重新保护的 algo 8 子密钥块」，
/// 再整体 armor。产出的结构自检（algo 8 包数量一致）通过后才交给调用方。
pub fn change_passphrase_pqc(
    original_armored: &str,
    v4_armored: &str,
    old: &str,
    new: &str,
) -> Result<String> {
    let orig_raw = dearmor(original_armored)?;
    let orig_packets = parse_packets(&orig_raw)?;
    let orig_algo8 = orig_packets
        .iter()
        .filter(|p| matches!(p.tag, 5 | 6 | 7 | 14) && p.body.len() > 6 && p.body[5] == 8)
        .count();
    if orig_algo8 == 0 {
        return Err(GpgError::Unsupported("未找到 GnuPG algo 8（PQC）子密钥包".into()));
    }

    let v4_raw = dearmor(v4_armored)?;
    let v4_packets = parse_packets(&v4_raw)?;
    // 防御：rpgp 未来版本若开始保留 algo 8 包，直接拼会产出重复子密钥
    if v4_packets
        .iter()
        .any(|p| matches!(p.tag, 5 | 6 | 7 | 14) && p.body.len() > 6 && p.body[5] == 8)
    {
        return Err(GpgError::Unsupported(
            "rpgp 输出仍含 algo 8 子密钥，拼接逻辑需复核".into(),
        ));
    }

    let mut out: Vec<u8> = Vec::with_capacity(orig_raw.len() + 64);
    for p in &v4_packets {
        out.extend_from_slice(&write_packet(p.tag, &p.body));
    }
    out.extend_from_slice(&reprotected_algo8_blocks(original_armored, old, new)?);

    let out_packets = parse_packets(&out)?;
    let out_algo8 = out_packets
        .iter()
        .filter(|p| matches!(p.tag, 5 | 6 | 7 | 14) && p.body.len() > 6 && p.body[5] == 8)
        .count();
    if out_algo8 != orig_algo8 {
        return Err(GpgError::Parse(format!(
            "改口令后 algo 8 包数量不符（原 {}，现 {}）",
            orig_algo8, out_algo8
        )));
    }
    Ok(armor(&out, "PGP PRIVATE KEY BLOCK"))
}

fn oid_to_curve(oid: &[u8]) -> String {
    match oid {
        // 1.3.101.110 = X25519；1.3.101.111 = X448
        [0x2b, 0x65, 0x6e] => "Curve25519".into(),
        [0x2b, 0x65, 0x6f] => "X448".into(),
        // 1.3.36.3.3.2.8.1.1.7 / .11 / .13 = brainpoolP256r1 / P384r1 / P512r1
        [0x2b, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x07] => "brainpoolP256r1".into(),
        [0x2b, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0b] => "brainpoolP384r1".into(),
        [0x2b, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0d] => "brainpoolP512r1".into(),
        // NIST P-256/384/521（GnuPG 的 ky768_p256 / ky1024_p384 / _p521）
        [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07] => "NIST P-256".into(),
        [0x2b, 0x81, 0x04, 0x00, 0x22] => "NIST P-384".into(),
        [0x2b, 0x81, 0x04, 0x00, 0x23] => "NIST P-521".into(),
        _ => format!("OID({})", oid.iter().map(|b| format!("{:02x}", b)).collect::<String>()),
    }
}

// ===================== 经典曲线（GnuPG composite KEM 的 ECC 部分） =====================

/// 曲线标识：与 GnuPG `common/kem.c` 的 `ecc_table` 一一对应
///
/// GnuPG 按曲线名查表取参数（pubkey_len / scalar_len / point_len / hash_algo /
/// scalar_reverse / may_have_prefix / is_weierstrauss）。composite KEM（algo 8）
/// 用的是 **encap/decap 的原始输出**，不做 Weierstrass 的 x 坐标截断——
/// 那个截断只发生在普通 ECDH（algo 18，`g10/pkglue.c:1034`）。
/// 混淆两者会让 brainpool 密钥算出错误的共享秘密，且失败表现为「口令/解密失败」，
/// 极难定位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EccCurve {
    /// X25519（ky768_cv25519）。MPISecret 大端 ⇒ 须反转
    Curve25519,
    /// brainpoolP256r1（ky768_bp256）。点 65B、标量 32B、不反转
    BrainpoolP256,
    /// brainpoolP384r1（ky1024_bp384）。点 97B、标量 48B、不反转
    BrainpoolP384,
}

impl EccCurve {
    /// 从 s-expression 的 `curve` 字段解析（GnuPG 的 canonical 名）
    pub fn from_name(name: &str) -> Option<EccCurve> {
        match name {
            "Curve25519" => Some(EccCurve::Curve25519),
            "brainpoolP256r1" => Some(EccCurve::BrainpoolP256),
            "brainpoolP384r1" => Some(EccCurve::BrainpoolP384),
            _ => None,
        }
    }

    /// 公钥点编码长度（含 0x04 前缀；X25519 的 33 字节含 0x40 前缀）
    pub fn point_len(self) -> usize {
        match self {
            EccCurve::Curve25519 => 32,
            EccCurve::BrainpoolP256 => 65,
            EccCurve::BrainpoolP384 => 97,
        }
    }

    /// 私钥标量长度（大端 MPI 的字节数）
    pub fn scalar_len(self) -> usize {
        match self {
            EccCurve::Curve25519 => 32,
            EccCurve::BrainpoolP256 => 32,
            EccCurve::BrainpoolP384 => 48,
        }
    }

    /// `simple_kdf` 用的哈希：bp256→SHA3-256、bp384→SHA3-512（GnuPG ecc_table）
    fn hash(self) -> EccHash {
        match self {
            EccCurve::Curve25519 => EccHash::Sha3_256,
            EccCurve::BrainpoolP256 => EccHash::Sha3_256,
            EccCurve::BrainpoolP384 => EccHash::Sha3_512,
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum EccHash {
    Sha3_256,
    Sha3_512,
}

/// `gnupg_ecc_kem_simple_kdf`：SHA3(ecdh || ecc_ct || ecc_pk)
///
/// 哈希按曲线选（bp256 用 SHA3-256、bp384 用 SHA3-512），
/// 曾统一用 SHA3-256 —— X25519 碰巧也是 SHA3-256 所以看不出问题。
fn ecc_simple_kdf_for(curve: EccCurve, ecdh: &[u8], ecc_ct: &[u8], ecc_pk: &[u8]) -> Vec<u8> {
    let mut iov: Vec<u8> = Vec::with_capacity(ecdh.len() + ecc_ct.len() + ecc_pk.len());
    iov.extend_from_slice(ecdh);
    iov.extend_from_slice(ecc_ct);
    iov.extend_from_slice(ecc_pk);
    match curve.hash() {
        EccHash::Sha3_256 => {
            let mut h = Sha3_256::new();
            Digest::update(&mut h, &iov);
            h.finalize().to_vec()
        }
        EccHash::Sha3_512 => {
            let mut h = Sha3_512::new();
            Digest::update(&mut h, &iov);
            h.finalize().to_vec()
        }
    }
}

/// 把 `EccCurve` 映射到 `bp_curve` 的曲线族
///
/// 调用方总是先按曲线分流（Curve25519 走 X25519 路径），故不会用到
/// `Curve25519` 分支；给出该分支只为让匹配穷尽。
fn bp_curve_of(curve: EccCurve) -> bp_curve::WeierstrassCurve {
    match curve {
        EccCurve::BrainpoolP256 => bp_curve::WeierstrassCurve::Bp256,
        EccCurve::BrainpoolP384 => bp_curve::WeierstrassCurve::Bp384,
        EccCurve::Curve25519 => bp_curve::WeierstrassCurve::Bp256,
    }
}

/// Weierstrass 点编码长度（未压缩，含 0x04 前缀）
fn weierstrass_point_len(curve: EccCurve) -> usize {
    bp_curve_of(curve).point_len()
}

/// Weierstrass ECDH（解密侧）：`d · peer_point` 的未压缩点编码
///
/// 曲线算术在 `bp_curve` 模块（自建 Montgomery 素域 + RC-B 完备加法公式），
/// 这里只做错误类型转换。
fn weierstrass_shared(curve: EccCurve, d: &[u8], peer_point: &[u8]) -> Result<Vec<u8>> {
    bp_curve::scalar_mul(bp_curve_of(curve), d, peer_point)
        .map_err(GpgError::Parse)
}

/// Weierstrass 临时密钥对（加密侧）：返回 `(临时公钥点, 共享点)`
fn weierstrass_ephemeral(curve: EccCurve, peer_point: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    use rand::RngCore;
    let scalar_len = curve.scalar_len();
    let mut k = vec![0u8; scalar_len];
    // 临时标量只要求不可预测且非零（scalar_mul 对标量取值范围无要求）
    loop {
        rand::thread_rng().fill_bytes(&mut k);
        if k.iter().any(|b| *b != 0) {
            break;
        }
    }
    bp_curve::ephemeral(bp_curve_of(curve), &k, peer_point)
    .map_err(GpgError::Parse)
}

/// X25519 ECDH（d 与对方公钥均为 32B 原始小端）
fn x25519_shared(d: &[u8], peer: &[u8]) -> Result<[u8; 32]> {
    if d.len() != 32 || peer.len() != 32 {
        return Err(GpgError::Crypto("X25519 材料长度必须 32".into()));
    }
    let mut dk = [0u8; 32];
    dk.copy_from_slice(d);
    let mut pk = [0u8; 32];
    pk.copy_from_slice(peer);
    let secret = x25519_dalek::StaticSecret::from(dk);
    let public = x25519_dalek::PublicKey::from(pk);
    Ok(secret.diffie_hellman(&public).to_bytes())
}

/// ML-KEM-768 解封装（seed 64B = d||z）
fn mlkem768_decaps(secret: &[u8], ct: &[u8]) -> Result<[u8; 32]> {
    use ml_kem::kem::Decapsulate;
    use ml_kem::{DecapsulationKey, ExpandedDecapsulationKey, MlKem768};
    // 私钥材料有两种形态，取决于 gpg 编码 ML-KEM 私钥的方式：
    // - 64 字节 seed（明文编码的 `(4:seed 64:..)`）
    // - 2400 字节展开私钥（FIPS 203 dk，加密编码的 `(1:s 2400:..)`）
    let dk = match secret.len() {
        64 => {
            let mut s = ml_kem::Seed::default();
            s.copy_from_slice(secret);
            DecapsulationKey::<MlKem768>::from_seed(s)
        }
        2400 => {
            let expanded = ExpandedDecapsulationKey::<MlKem768>::try_from(secret)
                .map_err(|_| GpgError::Crypto("ML-KEM 展开私钥长度非法".into()))?;
            DecapsulationKey::<MlKem768>::from_expanded(&expanded)
                .map_err(|e| GpgError::Crypto(format!("ML-KEM 展开私钥无效: {:?}", e)))?
        }
        n => {
            return Err(GpgError::Crypto(format!(
                "ML-KEM 私钥材料长度 {} 不受支持（须 64 字节 seed 或 2400 字节展开私钥）",
                n
            )))
        }
    };
    let ss = dk
        .decapsulate_slice(ct)
        .map_err(|_| GpgError::Crypto(format!("ML-KEM 密文长度非法: {}", ct.len())))?;
    let mut out = [0u8; 32];
    out.copy_from_slice(&ss);
    Ok(out)
}

/// GnuPG algo 8 组合 KDF（`gnupg_kem_combiner`）
///
/// 输入 = counter(0x00000001) || ecc_ss || ecc_ct || mlkem_ss || mlkem_ct || fixedinfo
/// KMAC256(K="OpenPGPCompositeKeyDerivationFunction", S="KDF")
fn kem_combiner(
    ecc_ss: &[u8],
    ecc_ct: &[u8],
    mlkem_ss: &[u8],
    mlkem_ct: &[u8],
    fixedinfo: &[u8],
    outlen: usize,
) -> Vec<u8> {
    let mut data = Vec::new();
    data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
    data.extend_from_slice(ecc_ss);
    data.extend_from_slice(ecc_ct);
    data.extend_from_slice(mlkem_ss);
    data.extend_from_slice(mlkem_ct);
    data.extend_from_slice(fixedinfo);
    kmac256(b"OpenPGPCompositeKeyDerivationFunction", b"KDF", &data, outlen)
}

/// ECC 共享秘密预哈希（`gnupg_ecc_kem_simple_kdf`）：SHA3-256(ecdh || ecc_ct || ecc_pk)
fn ecc_simple_kdf(ecdh: &[u8], ecc_ct: &[u8], ecc_pk: &[u8]) -> Vec<u8> {
    let mut h = Sha3_256::new();
    Digest::update(&mut h, ecdh);
    Digest::update(&mut h, ecc_ct);
    Digest::update(&mut h, ecc_pk);
    h.finalize().to_vec()
}

// ===================== PKESK（algo 8）解析与解密 =====================

/// 解析出的 PKESK 载荷
#[derive(Debug, Clone)]
pub struct PkeskAlgo8 {
    pub ecc_ct: Vec<u8>,
    pub mlkem_ct: Vec<u8>,
    pub sym_algo: u8,
    pub wrapped_key: Vec<u8>,
}

/// 从密文中提取所有 PKESK（tag 1）的收件人 Key ID
///
/// **算法无关**：PKESK 的 Key ID 是固定字段，与公钥算法无关，
/// 因此该函数对 RSA/ECDH/EdDSA/GnuPG algo 8 一律适用。
///
/// 布局（RFC 4880 §5.1，v3 PKESK，gpg 与 rpgp 产出均为此形态）：
/// `version(1)=3 || keyid(8) || pubkey_algo(1) || 加密的会话密钥`
/// RFC 9580 的 v6 PKESK 无 Key ID 字段，改放 32 字节指纹；
/// 此时取指纹最左 8 字节（与 Key ID 的取法一致）作为等价标识。
///
/// 全零 Key ID（`--hidden-recipient`）会被跳过——那种情况下无法从密文
/// 判断收件人，调用方需退回「尝试全部密钥」。
///
/// 用途：
/// 1. 解密前判断该条目**实际**由哪把密钥加密（`pass` 的
///    `gpg --decrypt --list-only` 同理），从而向用户索取正确的口令；
/// 2. 重加密时判断条目当前收件人是否已等于目标收件人（相等则跳过，
///    既省去无谓工作，也避免为已正确的条目索要口令）。
pub fn recipient_keyids(ciphertext: &str) -> Result<Vec<String>> {
    // armored 文本（本应用存储的形态）先解码；否则按原样当作二进制。
    // 注意：C 字符串无法安全承载任意二进制，故**二进制密文请用 recipient_keyids_raw**。
    if ciphertext.contains("-----BEGIN PGP") {
        let raw = dearmor(ciphertext)?;
        recipient_keyids_raw(&raw)
    } else {
        recipient_keyids_raw(ciphertext.as_bytes())
    }
}

/// 同 [`recipient_keyids`]，但接受原始字节（二进制密文用）
pub fn recipient_keyids_raw(raw: &[u8]) -> Result<Vec<String>> {
    let packets = parse_packets(raw)?;
    let mut out: Vec<String> = Vec::new();
    for pkt in packets.iter().filter(|p| p.tag == 1) {
        let b = &pkt.body;
        if b.len() < 9 {
            continue;
        }
        let keyid: &[u8] = match b[0] {
            3 => &b[1..9],
            6 => {
                // v6 PKESK：version(1) || 指纹(32) || algo(1) || …
                // 指纹最左 8 字节即等价 Key ID
                if b.len() < 33 {
                    continue;
                }
                &b[1..9]
            }
            _ => continue,
        };
        if keyid.iter().all(|x| *x == 0) {
            continue; // 隐藏收件人：无法判定
        }
        let hex: String = keyid.iter().map(|x| format!("{:02X}", x)).collect();
        if !out.contains(&hex) {
            out.push(hex);
        }
    }
    Ok(out)
}

/// 解析 algo 8 的 PKESK 载荷
pub fn parse_pkesk_algo8(body: &[u8]) -> Result<PkeskAlgo8> {
    if body.len() < 10 {
        return Err(GpgError::Parse("PKESK 过短".into()));
    }
    let algo = body[9];
    if algo != 8 {
        return Err(GpgError::Unsupported(format!("PKESK 算法 {} 不是 8", algo)));
    }
    let pl = &body[10..];
    let mut p = 0usize;
    let ecc_ct = mpi_read(pl, &mut p)?;
    let eklen = be_u32(pl, p)? as usize;
    p += 4;
    let mlkem_ct = pl.get(p..p + eklen)
        .ok_or_else(|| GpgError::Parse("mlkem_ct 越界".into()))?
        .to_vec();
    p += eklen;
    let sym_algo = *pl.get(p).ok_or_else(|| GpgError::Parse("缺少会话密钥算法".into()))?;
    p += 1;
    let wlen = *pl.get(p).ok_or_else(|| GpgError::Parse("缺少包裹长度".into()))? as usize;
    p += 1;
    let wrapped_key = pl.get(p..p + wlen)
        .ok_or_else(|| GpgError::Parse("包裹密钥越界".into()))?
        .to_vec();
    Ok(PkeskAlgo8 { ecc_ct, mlkem_ct, sym_algo, wrapped_key })
}

/// 会话密钥长度（字节）
fn sym_key_len(algo: u8) -> Result<usize> {
    match algo {
        7 => Ok(16),  // AES-128
        8 => Ok(24),  // AES-192
        9 => Ok(32),  // AES-256
        other => Err(GpgError::Unsupported(format!("不支持的对称算法 {}", other))),
    }
}

/// 用 GnuPG algo 8 私钥解开 PKESK，得到会话密钥
pub fn unwrap_session_key(key: &GpgPqcKey, pkesk: &PkeskAlgo8) -> Result<Vec<u8>> {
    let kek_len = sym_key_len(pkesk.sym_algo)?;
    let curve = key
        .ecc
        .ok_or_else(|| GpgError::Unsupported(format!("不支持的经典曲线: {}", key.curve)))?;

    // ECC 部分：共享秘密 + 参与 simple_kdf 的三个输入，均按曲线各自的编码长度。
    // simple_kdf 的输入是 **encap/decap 的原始输出**（Weierstrass 为未压缩点编码），
    // 不是 x 坐标——那只是普通 ECDH（algo 18）的做法，混用会算出错误的共享秘密。
    let (ecdh, ecc_pk) = match curve {
        EccCurve::Curve25519 => {
            // X25519：d 与 ecc_ct 均为 32B 原始小端
            (
                x25519_shared(&key.ecc_d, &pkesk.ecc_ct)?.to_vec(),
                ecc_pub_raw(&key.ecc_q)?,
            )
        }
        _ => {
            let pk = ecc_pub_point(curve, &key.ecc_q)?;
            (weierstrass_shared(curve, &key.ecc_d, &pkesk.ecc_ct)?, pk)
        }
    };
    let ecc_ss = ecc_simple_kdf_for(curve, &ecdh, &pkesk.ecc_ct, &ecc_pk);

    // ML-KEM 部分
    let mlkem_ss = mlkem768_decaps(&key.mlkem_secret, &pkesk.mlkem_ct)?;

    // fixedinfo = 会话密钥算法号(1B) || v5 指纹(32B)
    let mut fixedinfo = Vec::with_capacity(33);
    fixedinfo.push(pkesk.sym_algo);
    fixedinfo.extend_from_slice(&key.fingerprint);

    let kek = kem_combiner(&ecc_ss, &pkesk.ecc_ct, &mlkem_ss, &pkesk.mlkem_ct, &fixedinfo, kek_len);
    aes_kw_unwrap(&kek, &pkesk.wrapped_key)
}

/// 由 MPI 编码的公钥点得到参与 simple_kdf 的点编码
///
/// - X25519：去 `0x40` 前缀后的 32B 原生小端
/// - Weierstrass：65/97B 未压缩点编码（`0x04 || X || Y`），原样使用
fn ecc_pub_point(curve: EccCurve, q: &[u8]) -> Result<Vec<u8>> {
    match curve {
        EccCurve::Curve25519 => ecc_pub_raw(q),
        _ => {
            let expect = weierstrass_point_len(curve);
            if q.len() != expect {
                return Err(GpgError::Parse(format!(
                    "{} 公钥点长度异常: {}（应为 {}）",
                    match curve {
                        EccCurve::BrainpoolP256 => "brainpoolP256r1",
                        EccCurve::BrainpoolP384 => "brainpoolP384r1",
                        EccCurve::Curve25519 => "Curve25519",
                    },
                    q.len(),
                    expect
                )));
            }
            if q[0] != 0x04 {
                return Err(GpgError::Parse("Weierstrass 公钥点须为未压缩编码（0x04 前缀）".into()));
            }
            Ok(q.to_vec())
        }
    }
}

/// 由 MPI 编码的公钥点得到原始 32 字节（去 0x40 前缀）
fn ecc_pub_raw(q: &[u8]) -> Result<Vec<u8>> {
    let raw: Vec<u8> = if q.len() == 33 && q[0] == 0x40 {
        q[1..].to_vec()
    } else if q.len() == 32 {
        q.to_vec()
    } else {
        return Err(GpgError::Parse(format!("ECC 公钥点长度异常: {}", q.len())));
    };
    // q 去掉 0x40 前缀后即为原生小端，**不要**反转
    Ok(raw)
}

// ===================== tag 20（GnuPG AEAD）解密 =====================

/// 解密 GnuPG AEAD（tag 20）报文段
pub fn decrypt_gnupg_aead(body: &[u8], session_key: &[u8]) -> Result<Vec<u8>> {
    if body.len() < 20 {
        return Err(GpgError::Parse("AEAD 报文过短".into()));
    }
    if body[0] != 1 {
        return Err(GpgError::Unsupported(format!("AEAD 版本 {} 不支持", body[0])));
    }
    let sym_alg = body[1];
    let aead = body[2];
    if aead != 2 {
        return Err(GpgError::Unsupported(format!("仅支持 OCB(2)，实际 {}", aead)));
    }
    let chunk_byte = body[3];
    let iv = &body[4..19];
    let data = &body[19..];

    let chunk_size_expanded = 1usize << ((chunk_byte & 15) as usize + 6);
    // 会话密钥长度须与报文声明的算法一致，否则后续 OCB 会报出误导性的长度错误
    let expected_key_len = sym_key_len(sym_alg)?;
    if session_key.len() != expected_key_len {
        return Err(GpgError::Crypto(format!(
            "会话密钥长度 {} 与算法 {} 声明的 {} 不符",
            session_key.len(),
            sym_alg,
            expected_key_len
        )));
    }

    // AAD = [tag, version, sym_alg, aead, chunk_byte, chunk_index(8B BE)]
    // 首字节是 Tag::GnupgAeadData.encode() = 0xC0 | 20 = 0xD4（不是 20/0x14）
    let mut info = [0u8; 13];
    info[0] = 0xC0 | 20;
    info[1] = 0x01;
    info[2] = sym_alg;
    info[3] = aead;
    info[4] = chunk_byte;

    if data.len() < 16 {
        return Err(GpgError::Parse("AEAD 数据不足".into()));
    }
    // 末尾 16 字节为最终认证标签
    let (stream, final_tag) = data.split_at(data.len() - 16);

    let mut out = Vec::new();
    let mut chunk_index: u64 = 0;
    let mut rest = stream;
    while !rest.is_empty() {
        let take = (chunk_size_expanded + 16).min(rest.len());
        let (chunk, tail) = rest.split_at(take);
        if chunk.len() < 16 {
            return Err(GpgError::Parse("AEAD 分块不足一个标签".into()));
        }
        // nonce = IV，低 8 字节与 chunk_index 异或
        let mut nonce = [0u8; 15];
        nonce.copy_from_slice(iv);
        let idx = chunk_index.to_be_bytes();
        for i in 0..8 {
            nonce[15 - 8 + i] ^= idx[i];
        }
        info[5..13].copy_from_slice(&idx);
        let pt = ocb_decrypt_15(session_key, &nonce, &info, chunk)?;
        out.extend_from_slice(&pt);
        chunk_index += 1;
        rest = tail;
    }

    // 校验最终认证标签：AAD 需追加已解出明文的总字节数（u64 BE）
    let mut nonce = [0u8; 15];
    nonce.copy_from_slice(iv);
    let idx = chunk_index.to_be_bytes();
    for i in 0..8 {
        nonce[15 - 8 + i] ^= idx[i];
    }
    info[5..13].copy_from_slice(&idx);
    let mut final_info = info.to_vec();
    final_info.extend_from_slice(&(out.len() as u64).to_be_bytes());
    let check = ocb_decrypt_15(session_key, &nonce, &final_info, final_tag)?;
    if !check.is_empty() {
        return Err(GpgError::Crypto("最终认证标签异常".into()));
    }
    Ok(out)
}

/// AES-OCB（15 字节 nonce）解密
///
/// 按会话密钥长度选用 AES-128/192/256：gpg 的会话密钥算法由报文头 sym_alg 决定，
/// 并不总是 AES-256，写死 256 会让 AES-128/192 报文一律解不开。
fn ocb_decrypt_15(key: &[u8], nonce: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    use aes::{Aes128, Aes192, Aes256};
    use typenum::U15;
    type Aes128Ocb = Ocb3<Aes128, U15, U16>;
    type Aes192Ocb = Ocb3<Aes192, U15, U16>;
    type Aes256Ocb = Ocb3<Aes256, U15, U16>;
    if nonce.len() != 15 {
        return Err(GpgError::Crypto("AEAD nonce 须 15 字节".into()));
    }
    let n = GenericArray::<u8, U15>::from_slice(nonce);
    let payload = Payload { msg: ct, aad };
    match key.len() {
        16 => Aes128Ocb::new_from_slice(key)
            .map_err(|e| GpgError::Crypto(e.to_string()))?
            .decrypt(n, payload)
            .map_err(|_| GpgError::Crypto("AEAD 认证失败".into())),
        24 => Aes192Ocb::new_from_slice(key)
            .map_err(|e| GpgError::Crypto(e.to_string()))?
            .decrypt(n, payload)
            .map_err(|_| GpgError::Crypto("AEAD 认证失败".into())),
        32 => Aes256Ocb::new_from_slice(key)
            .map_err(|e| GpgError::Crypto(e.to_string()))?
            .decrypt(n, payload)
            .map_err(|_| GpgError::Crypto("AEAD 认证失败".into())),
        other => Err(GpgError::Crypto(format!("AEAD 会话密钥长度异常: {}", other))),
    }
}

// ===================== armor 解码 =====================

/// 解码 ASCII armor，返回二进制包数据（跳过头部与 CRC 校验行）
pub fn dearmor(armored: &str) -> Result<Vec<u8>> {
    use base64::Engine;
    let mut b64 = String::new();
    let mut in_body = false;
    for line in armored.lines() {
        let t = line.trim();
        if t.starts_with("-----BEGIN") {
            in_body = true;
            continue;
        }
        if t.starts_with("-----END") {
            break;
        }
        if !in_body || t.is_empty() || t.contains(':') {
            continue;
        }
        if t.starts_with('=') {
            continue;
        }
        b64.push_str(t);
    }
    base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .map_err(|e| GpgError::Parse(format!("armor base64 解码失败: {}", e)))
}

// ===================== 压缩数据（tag 8）解压 =====================

/// 解压单个包体的输出上限（1 MiB）
///
/// 密文可能来自同步下来的远端仓库（攻击者可控），几 KB 的压缩包可展开成 GB 级，
/// 不加限制会把进程拖到 OOM 被杀。pass 条目实际远小于此，1 MiB 留足余量。
pub const MAX_DECOMPRESSED_BYTES: u64 = 1024 * 1024;

/// 解压 OpenPGP 压缩数据包体（首字节为压缩算法号）
///
/// 1=ZIP(raw deflate) 2=ZLIB 3=BZip2（不支持）
pub fn decompress(body: &[u8]) -> Result<Vec<u8>> {
    use std::io::Read;
    let algo = *body.first().ok_or_else(|| GpgError::Parse("压缩包为空".into()))?;
    let data = &body[1..];
    match algo {
        0 => Ok(data.to_vec()),
        1 => {
            let mut out = Vec::new();
            flate2::read::DeflateDecoder::new(data)
                .take(MAX_DECOMPRESSED_BYTES)
                .read_to_end(&mut out)
                .map_err(|e| GpgError::Parse(format!("deflate 解压失败: {}", e)))?;
            Ok(out)
        }
        2 => {
            let mut out = Vec::new();
            flate2::read::ZlibDecoder::new(data)
                .take(MAX_DECOMPRESSED_BYTES)
                .read_to_end(&mut out)
                .map_err(|e| GpgError::Parse(format!("zlib 解压失败: {}", e)))?;
            Ok(out)
        }
        other => Err(GpgError::Unsupported(format!("不支持的压缩算法 {}", other))),
    }
}

/// 从（已解压的）包序列中提取字面数据（tag 11）内容
pub fn extract_literal(packets: &[Packet]) -> Result<Vec<u8>> {
    for p in packets.iter().filter(|p| p.tag == 11) {
        let b = &p.body;
        // format(1) || namelen(1) || name || mtime(4) || data
        let namelen = *b.get(1).ok_or_else(|| GpgError::Parse("字面数据包头过短".into()))? as usize;
        let off = 2 + namelen + 4;
        if off > b.len() {
            return Err(GpgError::Parse("字面数据包越界".into()));
        }
        return Ok(b[off..].to_vec());
    }
    Err(GpgError::Parse("未找到字面数据包".into()))
}

/// OpenPGP CFB 解密（全块 CFB，IV 全零），就地覆盖
///
/// 与 `cfb_encrypt` 对称；密钥长度决定 AES 变体。
fn cfb_decrypt(key: &[u8], data: &mut [u8]) -> Result<()> {
    use cfb_mode::cipher::KeyIvInit;
    use cfb_mode::BufDecryptor;

    let iv = [0u8; 16];
    match key.len() {
        32 => {
            let mut mode = <BufDecryptor<aes::Aes256> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.decrypt(data);
        }
        24 => {
            let mut mode = <BufDecryptor<aes::Aes192> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.decrypt(data);
        }
        16 => {
            let mut mode = <BufDecryptor<aes::Aes128> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.decrypt(data);
        }
        n => return Err(GpgError::Crypto(format!("不支持的会话密钥长度 {}", n))),
    }
    Ok(())
}

/// SEIPDv1（tag 18，version 1）对称解密
///
/// 包体 = `version(1) || 密文`；密文解密后为
/// `随机前缀(bs) || quick check(2) || 明文 || 0xD3 0x14 || SHA1(...)`。
/// 会校验 quick check 与 MDC 摘要（防篡改 / 防口令错误）。
pub fn seipd_v1_decrypt(body: &[u8], session_key: &[u8]) -> Result<Vec<u8>> {
    let ver = *body.first().ok_or_else(|| GpgError::Parse("SEIPD 包为空".into()))?;
    if ver != 1 {
        return Err(GpgError::Unsupported(format!(
            "SEIPD 版本 {} 不支持（仅支持 v1）",
            ver
        )));
    }
    let mut buf = body[1..].to_vec();
    let bs = 16usize;
    // 前缀(bs) + quick check(2) + 至少 22 字节 MDC
    if buf.len() < bs + 2 + 22 {
        return Err(GpgError::Parse("SEIPDv1 数据过短".into()));
    }
    cfb_decrypt(session_key, &mut buf)?;

    // quick check：前缀末 2 字节应重复一次
    if buf[bs - 2] != buf[bs] || buf[bs - 1] != buf[bs + 1] {
        return Err(GpgError::Crypto(
            "SEIPDv1 quick check 失败（会话密钥错误）".into(),
        ));
    }

    // MDC 在末尾 22 字节：0xD3 0x14 || SHA1(前缀 || 明文 || 0xD3 0x14)
    let mdc_off = buf.len() - 22;
    if buf[mdc_off] != 0xD3 || buf[mdc_off + 1] != 0x14 {
        return Err(GpgError::Parse("SEIPDv1 MDC 标记异常".into()));
    }
    let expect = Sha1::digest(&buf[..mdc_off + 2]);
    if expect.as_slice() != &buf[mdc_off + 2..] {
        return Err(GpgError::Crypto("SEIPDv1 MDC 校验失败（数据被篡改）".into()));
    }

    Ok(buf[bs + 2..mdc_off].to_vec())
}

/// 完整解密：PKESK(algo 8) → 会话密钥 → 对称加密层（tag 18/20/9）→ 压缩 → 字面数据
pub fn decrypt_message(key: &GpgPqcKey, raw: &[u8]) -> Result<Vec<u8>> {
    let packets = parse_packets(raw)?;

    // 多接收方：优先挑 keyid 与本密钥匹配的 PKESK；没有匹配的再退回第一个
    // （gpg 会把 PKESK 按接收方顺序排列，盲取第一个在共享密钥文件场景下会白跑）
    let mut pkesk_pkt = packets
        .iter()
        .filter(|p| p.tag == 1)
        .find(|p| p.body.len() >= 9 && p.body[1..9] == key.keyid[..])
        .or_else(|| packets.iter().find(|p| p.tag == 1))
        .ok_or_else(|| GpgError::Parse("缺少 PKESK 包".into()))?;
    // 上面 or_else 已保证非空；仅为借用检查重取
    let _ = &mut pkesk_pkt;

    let pkesk = parse_pkesk_algo8(&pkesk_pkt.body)?;
    let session_key = unwrap_session_key(key, &pkesk)?;

    // 对称加密层：tag 20（GnuPG AEAD）/ tag 18（SEIPDv1/v2）/ tag 9（旧 SEIPD，无 MDC）
    if let Some(p) = packets.iter().find(|p| p.tag == 20) {
        let inner = decrypt_gnupg_aead(&p.body, &session_key)?;
        return finish_packets(&parse_packets(&inner)?);
    }
    if let Some(p) = packets.iter().find(|p| p.tag == 18) {
        let inner = seipd_v1_decrypt(&p.body, &session_key)?;
        return finish_packets(&parse_packets(&inner)?);
    }
    if let Some(p) = packets.iter().find(|p| p.tag == 9) {
        // 旧格式：无 MDC，直接 CFB 解密后即包数据
        let mut buf = p.body.clone();
        cfb_decrypt(&session_key, &mut buf)?;
        return finish_packets(&parse_packets(&buf)?);
    }
    Err(GpgError::Unsupported(
        "报文不含受支持的对称加密层（tag 18/20/9）".into(),
    ))
}

fn finish_packets(packets: &[Packet]) -> Result<Vec<u8>> {
    for p in packets {
        if p.tag == 8 {
            let d = decompress(&p.body)?;
            let inner = parse_packets(&d)?;
            return finish_packets(&inner);
        }
        if p.tag == 11 {
            return extract_literal(&[p.clone()]);
        }
    }
    Err(GpgError::Parse("未找到字面数据".into()))
}

// ===================== MPI 编码 =====================

/// MPI 最小化编码（bitlen(u16 BE) || 去掉前导零的字节）
///
/// 与 GnuPG 一致：X25519 的 32 字节值若首字节 < 0x80，bitlen 为 255；
/// 解密侧按 `(bits+7)/8` 取字节并左补零到 32，故此处保持最小化编码即可。
fn mpi_encode(data: &[u8]) -> Vec<u8> {
    let mut i = 0usize;
    while i < data.len() && data[i] == 0 {
        i += 1;
    }
    let d = &data[i..];
    if d.is_empty() {
        return vec![0x00, 0x00];
    }
    let bits = (d.len() - 1) * 8 + (8 - d[0].leading_zeros() as usize);
    let mut out = (bits as u16).to_be_bytes().to_vec();
    out.extend_from_slice(d);
    out
}

// ===================== AES-KW 包裹（RFC 3394） =====================

/// RFC 3394 AES Key Wrap（无填充，明文须为 8 的倍数且 >= 16）
pub fn aes_kw_wrap(kek: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    if kek.len() != 16 && kek.len() != 24 && kek.len() != 32 {
        return Err(GpgError::Crypto("AES-KW KEK 长度非法".into()));
    }
    if plaintext.len() < 16 || plaintext.len() % 8 != 0 {
        return Err(GpgError::Crypto("AES-KW 明文长度非法".into()));
    }
    let mut a = [0xA6u8; 8];
    let mut r: Vec<[u8; 8]> = plaintext
        .chunks(8)
        .map(|c| {
            let mut b = [0u8; 8];
            b.copy_from_slice(c);
            b
        })
        .collect();
    let n = r.len();
    use aes::cipher::BlockEncrypt;

    macro_rules! wrap_with {
        ($c:expr) => {{
            for j in 0..6u64 {
                for i in 0..n {
                    let t = (n as u64) * j + (i as u64) + 1;
                    let mut block = [0u8; 16];
                    block[..8].copy_from_slice(&a);
                    block[8..].copy_from_slice(&r[i]);
                    let mut g = aes::cipher::generic_array::GenericArray::clone_from_slice(&block);
                    $c.encrypt_block(&mut g);
                    // A = MSB64(B) ⊕ t，计数器异或到 A
                    let tb = t.to_be_bytes();
                    for k in 0..8 {
                        a[k] = g[k] ^ tb[k];
                    }
                    r[i].copy_from_slice(&g[8..]);
                }
            }
        }};
    }

    match kek.len() {
        16 => {
            let c = aes::Aes128::new_from_slice(kek).unwrap();
            wrap_with!(c);
        }
        24 => {
            let c = aes::Aes192::new_from_slice(kek).unwrap();
            wrap_with!(c);
        }
        _ => {
            let c = aes::Aes256::new_from_slice(kek).unwrap();
            wrap_with!(c);
        }
    }

    let mut out = a.to_vec();
    for x in &r {
        out.extend_from_slice(x);
    }
    Ok(out)
}

// ===================== 对称加密（SEIPDv1） =====================

/// OpenPGP CFB 加密（全块 CFB，IV 全零），就地覆盖
///
/// 与 rpgp 的 `encrypt_with_iv` 等价：整个缓冲区（前缀 + 数据）连续走同一个 CFB 流。
fn cfb_encrypt(key: &[u8], data: &mut [u8]) -> Result<()> {
    use cfb_mode::cipher::KeyIvInit;
    use cfb_mode::BufEncryptor;

    let iv = [0u8; 16];
    match key.len() {
        32 => {
            let mut mode = <BufEncryptor<aes::Aes256> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.encrypt(data);
        }
        24 => {
            let mut mode = <BufEncryptor<aes::Aes192> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.encrypt(data);
        }
        16 => {
            let mut mode = <BufEncryptor<aes::Aes128> as KeyIvInit>::new_from_slices(key, &iv)
                .map_err(|e| GpgError::Crypto(format!("CFB 初始化失败: {}", e)))?;
            mode.encrypt(data);
        }
        n => return Err(GpgError::Crypto(format!("不支持的会话密钥长度 {}", n))),
    }
    Ok(())
}

/// SEIPDv1（tag 18，version 1）对称加密：`前缀(bs+2) || 明文 || MDC(22)`
///
/// 格式依据 RFC 9580 §5.13.2：随机前缀 bs 字节，后跟其末 2 字节作为 quick check；
/// 末尾是 `0xD3 0x14 || SHA1(前缀||明文||0xD3 0x14)`。
pub fn seipd_v1_encrypt(session_key: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    use rand::RngCore;
    let bs = 16usize;
    let mut buf = Vec::with_capacity(bs + 2 + plaintext.len() + 22);
    // 随机前缀 + quick check（末 2 字节重复）
    let mut prefix = vec![0u8; bs];
    rand::thread_rng().fill_bytes(&mut prefix);
    buf.extend_from_slice(&prefix);
    buf.push(prefix[bs - 2]);
    buf.push(prefix[bs - 1]);
    // 明文
    buf.extend_from_slice(plaintext);
    // MDC
    buf.push(0xD3);
    buf.push(0x14);
    let checksum = Sha1::digest(&buf);
    buf.extend_from_slice(&checksum);

    cfb_encrypt(session_key, &mut buf)?;
    Ok(buf)
}

// ===================== 包构造 =====================

/// 新格式包头（tag + 长度）
pub(crate) fn write_packet(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![0xC0 | tag];
    let len = body.len();
    if len < 192 {
        out.push(len as u8);
    } else if len < 8384 {
        let l = len - 192;
        out.push(((l >> 8) as u8) + 192);
        out.push((l & 0xFF) as u8);
    } else {
        out.push(255);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    }
    out.extend_from_slice(body);
    out
}

/// 字面数据包（tag 11）：`'b' || 文件名长(1) || 文件名 || mtime(4) || 数据`
pub(crate) fn literal_data_packet(name: &str, data: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(6 + name.len() + data.len());
    body.push(b'b'); // Binary
    body.push(name.len() as u8);
    body.extend_from_slice(name.as_bytes());
    body.extend_from_slice(&0u32.to_be_bytes()); // mtime = 0（不定）
    body.extend_from_slice(data);
    write_packet(11, &body)
}

/// 构造 algo 8 的 PKESK 包（tag 1）
fn build_pkesk_algo8(keyid: &[u8], pkesk: &PkeskAlgo8) -> Result<Vec<u8>> {
    if keyid.len() != 8 {
        return Err(GpgError::Crypto("Key ID 必须 8 字节".into()));
    }
    let mut body = Vec::with_capacity(12 + pkesk.ecc_ct.len() + 4 + pkesk.mlkem_ct.len() + 2 + pkesk.wrapped_key.len());
    body.push(3); // 版本
    body.extend_from_slice(keyid);
    body.push(8); // algo 8
    body.extend_from_slice(&mpi_encode(&pkesk.ecc_ct));
    body.extend_from_slice(&(pkesk.mlkem_ct.len() as u32).to_be_bytes());
    body.extend_from_slice(&pkesk.mlkem_ct);
    body.push(pkesk.sym_algo);
    body.push(pkesk.wrapped_key.len() as u8);
    body.extend_from_slice(&pkesk.wrapped_key);
    Ok(write_packet(1, &body))
}

// ===================== 加密入口 =====================

/// 为单个接收方构造 PKESK(algo 8) 包（共用给定会话密钥）
///
/// 多接收方加密时对每个接收方各调一次，产出多个 PKESK，
/// 但**共用同一个会话密钥**（这是 OpenPGP 多接收方的标准做法）。
pub(crate) fn build_pkesk_for(pubkey: &GpgPqcPublicKey, session_key: &[u8]) -> Result<Vec<u8>> {
    use ml_kem::kem::Encapsulate;
    use ml_kem::{EncapsulationKey, MlKem768};
    use rand::RngCore;

    let sym_algo: u8 = 9; // AES-256

    let curve = pubkey
        .ecc
        .ok_or_else(|| GpgError::Unsupported(format!("不支持的经典曲线: {}", pubkey.curve)))?;
    let ecc_pk = ecc_pub_point(curve, &pubkey.ecc_q)?;

    // ---- ECC 部分：临时密钥对 ----
    // X25519：ecc_ct 即 32B 临时公钥；Weierstrass：65/97B 未压缩点。
    // 共享秘密同 simple_kdf 的输入口径（原始 encap 输出，非 x 坐标）。
    let (ecc_ct, ecdh) = match curve {
        EccCurve::Curve25519 => {
            use rand::RngCore;
            let mut eph = [0u8; 32];
            rand::thread_rng().fill_bytes(&mut eph);
            let eph_secret = x25519_dalek::StaticSecret::from(eph);
            let ct = x25519_dalek::PublicKey::from(&eph_secret).to_bytes().to_vec();
            let mut pk_arr = [0u8; 32];
            pk_arr.copy_from_slice(&ecc_pk);
            let shared = eph_secret
                .diffie_hellman(&x25519_dalek::PublicKey::from(pk_arr))
                .to_bytes();
            (ct, shared.to_vec())
        }
        _ => weierstrass_ephemeral(curve, &ecc_pk)?,
    };
    // ECC 共享秘密须先预哈希（哈希按曲线选：bp256→SHA3-256、bp384→SHA3-512）
    let ecc_ss = ecc_simple_kdf_for(curve, &ecdh, &ecc_ct, &ecc_pk);

    // ---- ML-KEM 部分 ----
    let ek_raw: [u8; 1184] = pubkey.mlkem_ek.as_slice().try_into().map_err(|_| {
        GpgError::Crypto(format!("ML-KEM ek 长度非法: {}（应为 1184）", pubkey.mlkem_ek.len()))
    })?;
    let ek = EncapsulationKey::<MlKem768>::new(&ek_raw.into())
        .map_err(|_| GpgError::Crypto("ML-KEM ek 编码无效".into()))?;
    // ml-kem 0.3 的 encapsulate_with_rng 要 rand_core 0.10，与本项目 rand 0.8
    // 不同 trait，故用 encapsulate_deterministic 自行供 32 字节随机数（语义等价）
    let mut m = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut m);
    let (mlkem_ct_arr, mlkem_ss_arr) = ek.encapsulate_deterministic(&ml_kem::B32::from(m));
    let mlkem_ct = mlkem_ct_arr.as_slice().to_vec();
    let mlkem_ss = mlkem_ss_arr.as_slice().to_vec();

    // ---- 组合 KDF（fixedinfo = 会话密钥算法号 || v5 指纹）----
    let mut fixedinfo = Vec::with_capacity(33);
    fixedinfo.push(sym_algo);
    fixedinfo.extend_from_slice(&pubkey.fingerprint);
    let kek = kem_combiner(&ecc_ss, &ecc_ct, &mlkem_ss, &mlkem_ct, &fixedinfo, session_key.len());

    let wrapped_key = aes_kw_wrap(&kek, session_key)?;
    build_pkesk_algo8(
        &pubkey.keyid,
        &PkeskAlgo8 { ecc_ct, mlkem_ct, sym_algo, wrapped_key },
    )
}

/// 用多把 GnuPG algo 8 公钥加密明文（多接收方，共用同一会话密钥）
///
/// 流程：生成随机会话密钥（AES-256）→ 对每个接收方构造一个 PKESK(algo 8) →
/// 字面数据包经 SEIPDv1（tag 18，CFB+MDC）加密。
///
/// 注意：输出用 SEIPDv1 而非 GnuPG 私有的 tag 20 AEAD——两者 gpg 都能解，
/// 且 SEIPDv1 是 RFC 标准格式，实现面更小。
pub fn encrypt_message_multi(pubkeys: &[GpgPqcPublicKey], plaintext: &[u8]) -> Result<Vec<u8>> {
    use rand::RngCore;
    if pubkeys.is_empty() {
        return Err(GpgError::Crypto("没有可用的 GnuPG algo 8 接收方公钥".into()));
    }

    let mut session_key = vec![0u8; 32];
    rand::thread_rng().fill_bytes(&mut session_key);

    // 每个接收方一个 PKESK，共用会话密钥
    let mut out = Vec::new();
    for pk in pubkeys {
        out.extend_from_slice(&build_pkesk_for(pk, &session_key)?);
    }

    out.extend_from_slice(&seipd_v1_message(&session_key, plaintext)?);
    Ok(out)
}

/// 构造 SEIPDv1 报文（tag 18：版本字节 1 + CFB 加密的字面数据）
///
/// 抽出来供「纯 algo 8」与「algo 8 + 普通密钥混用」两条路径共用：
/// 混用时要让两类接收方的 PKESK 共用同一个会话密钥，因此报文必须独立构造。
pub(crate) fn seipd_v1_message(session_key: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let literal = literal_data_packet("data", plaintext);
    let encrypted = seipd_v1_encrypt(session_key, &literal)?;
    let mut body = Vec::with_capacity(1 + encrypted.len());
    body.push(1); // SEIPDv1
    body.extend_from_slice(&encrypted);
    Ok(write_packet(18, &body))
}

/// 生成随机会话密钥（AES-256 → 32 字节），混用路径与纯 algo 8 路径共用
pub(crate) fn random_session_key() -> Vec<u8> {
    use rand::RngCore;
    let mut k = vec![0u8; 32];
    rand::thread_rng().fill_bytes(&mut k);
    k
}

/// 用单把 GnuPG algo 8 公钥加密明文（`encrypt_message_multi` 的单接收方包装）
pub fn encrypt_message(pubkey: &GpgPqcPublicKey, plaintext: &[u8]) -> Result<Vec<u8>> {
    encrypt_message_multi(std::slice::from_ref(pubkey), plaintext)
}

// ===================== ASCII armor =====================

/// RFC 4880 CRC24
fn crc24(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xB704CE;
    for &b in data {
        crc ^= (b as u32) << 16;
        for _ in 0..8 {
            crc <<= 1;
            if crc & 0x100_0000 != 0 {
                crc ^= 0x1864CFB;
            }
        }
    }
    crc & 0xFF_FFFF
}

/// 输出 ASCII armor（默认 `PGP MESSAGE`）
pub fn armor(data: &[u8], kind: &str) -> String {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(data);
    let mut out = String::with_capacity(b64.len() + 128);
    out.push_str(&format!("-----BEGIN {}-----\n\n", kind));
    for chunk in b64.as_bytes().chunks(64) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        out.push('\n');
    }
    let crc = crc24(data);
    let crc_b64 = base64::engine::general_purpose::STANDARD.encode([
        ((crc >> 16) & 0xFF) as u8,
        ((crc >> 8) & 0xFF) as u8,
        (crc & 0xFF) as u8,
    ]);
    out.push('=');
    out.push_str(&crc_b64);
    out.push('\n');
    out.push_str(&format!("-----END {}-----\n", kind));
    out
}

// ===================== 测试 =====================

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{:02x}", x)).collect()
    }

    fn hexd(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }

    /// fixture 目录：默认 /tmp/fx，可用 HPS_FIXTURE_DIR 覆盖
    fn fixture_dir() -> std::path::PathBuf {
        std::env::var("HPS_FIXTURE_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("/tmp/fx"))
    }

    /// 读 fixture；缺失时打印醒目提示并跳过
    ///
    /// 曾静默 `return`，于是 `cargo test` 报 6 passed 而其中 4 个什么都没验证——
    /// 包括 AGENTS.md 要求"改动加解密务必跑"的 seipd_v1_round_trip。
    /// 现在跳过会明确出现在测试输出里。
    macro_rules! need_fixture {
        ($name:expr) => {{
            let path = fixture_dir().join($name);
            match std::fs::read_to_string(&path) {
                Ok(v) => v,
                Err(_) => {
                    println!(
                        "SKIP: fixture 缺失 {}（设 HPS_FIXTURE_DIR 指定目录）",
                        path.display()
                    );
                    return;
                }
            }
        }};
    }

    /// kyber 容器的 protected 定位：两种编码必须正确分流，且 AAD 不得含外壳
    ///
    /// gpg 2.5.x 对 ML-KEM 私钥有两种编码，早前只支持明文编码，
    /// 遇到加密编码会报「缺少 private-key」，被 UI 误报为「密钥密码错误」。
    #[test]
    fn locate_kyber_protected_handles_both_encodings() {
        // 明文编码（较新 gpg）：容器名 private-key，无 protected → 必须返回 Err，
        // 否则会去解一段并不存在的密文
        let mut plain = Vec::from(&b"(11:private-key(8:kyber768(1:p1184:"[..]);
        plain.extend_from_slice(&[0x41u8; 1184]);
        plain.extend_from_slice(b")(4:seed64:");
        plain.extend_from_slice(&[0x42u8; 64]);
        plain.extend_from_slice(b")))");
        assert!(locate_kyber_protected(&plain).is_err(), "明文编码应走明文分支");

        // 加密编码（旧版 gpg 实测形态，protected 在 kyber768 列表**内部**）：
        //   (composite-key
        //     (protected-private-key (ecc ..))                       ← ecc 段
        //     (protected-private-key (kyber768 (p ..) (protected ..) (protected-at ..))))
        // AAD 必须是 kyber768 列表本身（GnuPG doc/keyformat.txt：
        // "the list forming the public key parameters"），**不含** protected-private-key 外壳。
        // 曾把外壳当容器 → 真实密钥 OCB 校验必然失败，且被 UI 报成「密钥密码错误」。
        //
        // protected 内部布局与真实密钥一致：
        //   (9:protected 20:<算法> ( (4:sha1 8:<salt> 8:<count>) 12:<nonce> ) <ct> )
        fn push_protected(v: &mut Vec<u8>, salt: u8, nonce: u8, ct_len: usize) {
            v.extend_from_slice(b"(9:protected20:openpgp-s2k3-ocb-aes((4:sha1");
            v.extend_from_slice(&[salt; 8]);
            v.extend_from_slice(b"8:45343744)12:");
            v.extend_from_slice(&[nonce; 12]);
            v.extend_from_slice(b")");
            v.extend_from_slice(format!("{}:", ct_len).as_bytes());
            v.extend_from_slice(&vec![0x45u8; ct_len]);
            v.push(b')');
        }

        let mut enc = Vec::from(
            &b"(13:composite-key(21:protected-private-key(3:ecc(1:c1:x)(1:q1:y)))(21:protected-private-key(8:kyber768(1:p1184:"[..],
        );
        enc.extend_from_slice(&[0x41u8; 1184]);
        enc.push(b')');
        push_protected(&mut enc, 0x43, 0x44, 16);
        enc.extend_from_slice(b"(12:protected-at15:20260114T140906)))");
        let (cs, ce, ps, pe) = locate_kyber_protected(&enc).expect("加密编码应定位成功");
        assert!(
            enc[cs..].starts_with(b"(8:kyber768"),
            "容器必须是 kyber768 列表（AAD 不含 protected-private-key 外壳）"
        );
        assert!(enc[ps..].starts_with(b"(9:protected"), "protected 起点错误");
        assert!(ps > cs && pe <= ce, "protected 必须落在容器内");
        // AAD = 容器去掉 protected 元素：必须保留 p 与 protected-at
        let mut aad: Vec<u8> = Vec::new();
        aad.extend_from_slice(&enc[cs..ps]);
        aad.extend_from_slice(&enc[pe..ce]);
        assert!(aad.starts_with(b"(8:kyber768"), "AAD 不应含外壳");
        assert!(
            find_sub(&aad, b"(12:protected-at").is_some(),
            "AAD 应保留 protected-at（GnuPG 示例 AAD 含该项）"
        );

        // 旧兼容分支：protected 作为 kyber 列表的兄弟放在外壳内
        let mut sib = Vec::from(&b"(21:protected-private-key(8:kyber768(1:p1184:"[..]);
        sib.extend_from_slice(&[0x41u8; 1184]);
        sib.extend_from_slice(b"))");
        push_protected(&mut sib, 0x43, 0x44, 16);
        sib.push(b')');
        let (cs2, _ce2, ps2, _pe2) = locate_kyber_protected(&sib).expect("兄弟布局仍应支持");
        assert!(
            sib[cs2..].starts_with(b"(21:protected-private-key"),
            "兄弟布局的容器是外壳"
        );
        assert!(ps2 > cs2, "protected 必须在外壳内");
    }

    /// 真实旧版编码（protected 在 kyber768 列表**内部**）的 AAD 容器定位
    ///
    /// 该形态由旧版 gpg 产出（新版 gpg 改为明文 `(4:seed ..)`），本地 gpg 无法再造，
    /// 故用 fixture 固定：把任一把该形态的私钥放进 fixture 目录即可复跑。
    /// 只做结构断言（**不需要口令**）：AAD 容器必须是 kyber768 列表本身，
    /// 而不是 protected-private-key 外壳——用外壳会算错 AAD，令正确口令被判为错误。
    #[test]
    fn locate_kyber_protected_real_old_encoding() {
        let armored = need_fixture!("sec_protected_old_kyber.asc");
        let raw = dearmor(&armored).expect("dearmor");
        let packets = parse_packets(&raw).expect("parse packets");
        let mut found = false;
        for pkt in packets.iter().filter(|p| matches!(p.tag, 5 | 6 | 7 | 14)) {
            let b = &pkt.body;
            if b.len() < 6 || b[5] != 8 {
                continue;
            }
            let (_pubkey, p) = parse_public_material(b).expect("public material");
            if b[p] == 0 {
                continue; // 明文编码，由 locate_kyber_protected_handles_both_encodings 覆盖
            }
            let s = find_sexp(&b[p..]).expect("sexp");
            let (cs, ce, ps, pe) = locate_kyber_protected(s).expect("旧版加密编码应定位成功");
            let head_len = 24usize.min(ce - cs);
            assert!(
                s[cs..].starts_with(b"(8:kyber768"),
                "AAD 容器必须是 kyber768 列表，实际前缀: {:?}",
                String::from_utf8_lossy(&s[cs..cs + head_len])
            );
            assert!(s[ps..].starts_with(b"(9:protected"), "protected 起点错误");
            assert!(ps > cs && pe <= ce, "protected 必须落在容器内");
            found = true;
        }
        assert!(found, "fixture 内应有 algo 8 的加密编码私钥段");
    }

    /// ML-KEM 私钥材料提取：两种明文形态都要能识别
    #[test]
    fn mlkem_secret_from_plaintext_variants() {
        // (4:seed64:<64B>) —— 较新 gpg 的明文编码
        let mut seed_form = Vec::from(&b"(4:seed64:"[..]);
        seed_form.extend_from_slice(&[0xABu8; 64]);
        seed_form.push(b')');
        assert_eq!(
            mlkem_secret_from_plaintext(&seed_form).expect("seed 形态").len(),
            64
        );

        // (1:s2400:<2400B>) —— 加密编码解密后的展开私钥
        let mut s_form = Vec::from(&b"(1:s2400:"[..]);
        s_form.extend_from_slice(&[0xCDu8; 2400]);
        s_form.push(b')');
        assert_eq!(
            mlkem_secret_from_plaintext(&s_form).expect("展开私钥形态").len(),
            2400
        );

        // 裸字节：长度本身即材料
        assert_eq!(
            mlkem_secret_from_plaintext(&vec![0x11u8; 2400]).expect("裸 2400").len(),
            2400
        );

        // 无法识别时必须报错，而不是把垃圾当私钥用
        assert!(mlkem_secret_from_plaintext(&[0u8; 100]).is_err());
    }

    /// 解封装对不受支持的材料长度必须报错而非静默产出错误结果
    #[test]
    fn mlkem_decaps_rejects_unsupported_length() {
        let err = mlkem768_decaps(&[0u8; 100], &[0u8; 1088]).unwrap_err();
        let msg = format!("{}", err);
        assert!(msg.contains("不受支持"), "got: {}", msg);
    }

    /// AES-KW 解开 RFC 3394 §4.1 官方测试向量
    #[test]
    fn aes_kw_rfc3394_vector() {
        let kek = hexd("000102030405060708090a0b0c0d0e0f");
        let wrapped = hexd("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5");
        let pt = aes_kw_unwrap(&kek, &wrapped).expect("unwrap");
        assert_eq!(hex(&pt), "00112233445566778899aabbccddeeff");
    }

    /// KMAC256 匹配 NIST SP 800-185 Sample #4
    #[test]
    fn kmac256_nist_sample4() {
        let k = hexd("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f");
        let x = hexd("00010203");
        let out = kmac256(&k, b"My Tagged Application", &x, 64);
        assert_eq!(
            hex(&out),
            "20c570c31346f703c9ac36c61c03cb64c3970d0cfc787e9b79599d273a68d2f7\
             f69d4cc3de9d104a351689f27cf6f5951f0103f33f4f24871024d9c27773a8dd"
        );
    }

    /// 自洽 round-trip：本应用加密（PKESK algo 8 + SEIPDv1）→ 本应用解密
    ///
    /// 关键回归：加密产出 tag 18（SEIPDv1），解密必须支持它，
    /// 否则应用解不开自己新建的条目。
    #[test]
    fn seipd_v1_round_trip() {
        let armored = need_fixture!("sec_protected.asc");
        let pk = extract_public_key(&armored).expect("extract public key");
        let key = extract_key(&armored, "testpw123").expect("extract key");

        let msg = b"ROUND-TRIP-PLAINTEXT";
        let raw = encrypt_message_multi(std::slice::from_ref(&pk), msg).expect("encrypt");

        // 产出结构应为 PKESK(1) + SEIPDv1(18)
        let packets = parse_packets(&raw).expect("parse");
        assert!(packets.iter().any(|p| p.tag == 1), "应含 PKESK");
        assert!(packets.iter().any(|p| p.tag == 18), "应含 SEIPDv1");

        let pt = decrypt_message(&key, &raw).expect("decrypt own output");
        assert_eq!(pt, msg);
    }

    /// 多接收方 round-trip：两把密钥各自都能解开同一密文
    #[test]
    fn multi_recipient_round_trip() {
        let a1 = need_fixture!("sec_protected.asc");
        let a2 = need_fixture!("sec2.asc");
        let pk1 = extract_public_key(&a1).expect("pk1");
        let pk2 = extract_public_key(&a2).expect("pk2");
        let k1 = extract_key(&a1, "testpw123").expect("k1");
        let k2 = extract_key(&a2, "testpw123").expect("k2");

        let msg = b"MULTI-ROUND-TRIP";
        let raw = encrypt_message_multi(&[pk1, pk2], msg).expect("encrypt");
        // 两个 PKESK + 一个 SEIPDv1
        let packets = parse_packets(&raw).expect("parse");
        assert_eq!(packets.iter().filter(|p| p.tag == 1).count(), 2);

        assert_eq!(decrypt_message(&k1, &raw).expect("decrypt by k1"), msg);
        assert_eq!(decrypt_message(&k2, &raw).expect("decrypt by k2"), msg);
    }

    /// gpg 产出的**双接收方**（algo 18 普通密钥 + algo 8 gpgPqc）密文，
    /// 本模块必须挑中 algo 8 的 PKESK 解出——盲取第一个 PKESK 会白跑。
    ///
    /// 用例固化自真实 gpg 输出：
    ///   gpg --encrypt -r <cv25519 keyid> -r <ky768_cv25519 keyid> -o mixed_from_gpg.gpg plain.txt
    /// 注意 gpg 默认内层是压缩包（tag 8）+ tag 20 AEAD，本用例同时覆盖这两条分支。
    #[test]
    fn gpg_mixed_ciphertext_decrypts_with_pqc_key() {
        let armored = need_fixture!("sec_protected.asc");
        let raw = match std::fs::read(fixture_dir().join("mixed_from_gpg.gpg")) {
            Ok(v) => v,
            Err(_) => {
                println!("SKIP: fixture 缺失 mixed_from_gpg.gpg（二进制，需 std::fs::read）");
                return;
            }
        };
        let key = extract_key(&armored, "testpw123").expect("extract key");
        let got = decrypt_message(&key, &raw).expect("decrypt gpg mixed ciphertext");
        assert_eq!(String::from_utf8_lossy(&got).trim(), "GPG-MIXED-TO-APP");
    }

    /// 公钥材料提取：从私钥（无需口令）与从公钥文件提取的结果必须一致
    #[test]
    fn extract_public_key_matches_secret() {
        let armored = need_fixture!("sec_protected.asc");
        // 从私钥提取公钥材料（不需要口令）
        let from_secret = extract_public_key(&armored).expect("extract from secret");
        // 与 extract_key 的公钥字段逐字节比对
        let full = extract_key(&armored, "testpw123").expect("extract key");
        assert_eq!(from_secret.ecc_q, full.ecc_q);
        assert_eq!(from_secret.mlkem_ek, full.mlkem_ek);
        assert_eq!(from_secret.fingerprint, full.fingerprint);
        assert_eq!(from_secret.keyid, full.keyid);
        assert_eq!(from_secret.mlkem_ek.len(), 1184);
        assert_eq!(from_secret.fingerprint.len(), 32);

        // 从公钥文件提取亦应成功且一致
        if let Ok(pub_armored) = std::fs::read_to_string(fixture_dir().join("pub.asc")) {
            let from_pub = extract_public_key(&pub_armored).expect("extract from public");
            assert_eq!(from_pub.mlkem_ek, full.mlkem_ek);
            assert_eq!(from_pub.ecc_q, full.ecc_q);
            assert_eq!(from_pub.fingerprint, full.fingerprint);
        }
    }

    /// 端到端：GnuPG 2.5 用 ky768_cv25519（algo 8）加密的报文能解回原文。
    ///
    /// fixture 由 GnuPG 2.5.22 生成（带口令私钥 + 匹配密文），
    /// 缺失时跳过（CI 无 fixture）。
    #[test]
    fn gpg_pqc_end_to_end() {
        let armored = need_fixture!("sec_protected.asc");
        let enc = std::fs::read(fixture_dir().join("enc.gpg")).expect("read ciphertext");
        let plain = std::fs::read(fixture_dir().join("plain.txt")).expect("read plaintext");

        // 口令错误必须失败（保护段 OCB 认证标签校验）
        assert!(extract_key(&armored, "wrong-pass").is_err());

        let key = extract_key(&armored, "testpw123").expect("extract key");
        let pt = decrypt_message(&key, &enc).expect("decrypt");
        assert_eq!(pt, plain);
    }

    /// brainpool 端到端：gpg 用 `ky768_bp256` 加密的密文必须能解开
    ///
    /// 该用例覆盖「Weierstrass 经典曲线」这条与 X25519 完全不同的分支：
    /// 点运算自建（`bp_curve`）、共享秘密是**未压缩点**而非 x 坐标、
    /// 哈希按曲线选（bp256→SHA3-256）、私钥标量**不反转**。
    /// 这四个点任一弄错都只表现为「AES-KW 完整性校验失败」，无法区分，
    /// 故必须用真实 gpg 产物固定住。
    #[test]
    fn brainpool_end_to_end() {
        let armored = need_fixture!("bp256_sec.asc");
        let enc = std::fs::read(fixture_dir().join("bp256_enc.gpg")).expect("read ciphertext");
        let plain = std::fs::read(fixture_dir().join("bp256_plain.txt")).expect("read plaintext");

        // 口令错误必须失败（保护段 OCB 认证标签校验）
        assert!(extract_key(&armored, "wrong-pass").is_err());

        let key = extract_key(&armored, "testpw123").expect("extract brainpool key");
        assert_eq!(key.curve, "brainpoolP256r1", "fixture 应为 bp256 密钥");
        let pt = decrypt_message(&key, &enc).expect("decrypt gpg brainpool ciphertext");
        assert_eq!(pt, plain);
    }

    /// 收件人 Key ID 提取：必须与 gpg 报告的加密密钥一致
    ///
    /// 该能力用于①解密前选对密钥（`pass` 的 `gpg --decrypt --list-only` 同理）
    /// ②重加密时判断条目是否已是目标收件人。算法无关，故对 gpgPqc 与普通密钥都成立。
    #[test]
    fn recipient_keyids_matches_gpg() {
        // gpg 用 ky768_bp256 加密（fixture 由 `gpg --encrypt -r <bp256 key>` 产出）
        let enc = std::fs::read(fixture_dir().join("bp256_enc.gpg")).ok();
        if let Some(enc) = enc {
            let ids = recipient_keyids_raw(&enc).expect("parse");
            assert_eq!(ids.len(), 1, "单接收方应只解析出 1 个 Key ID");
            assert_eq!(ids[0], "14EE280CB4FD94CC", "应等于 bp256 加密子密钥的 Key ID");
        }
        // 本应用自己加密的产出（cv25519 fixture）
        let armored = need_fixture!("sec_protected.asc");
        let pks = extract_public_keys_multi(&armored);
        let raw = encrypt_message_multi(&pks, b"recipients").expect("encrypt");
        let ids = recipient_keyids_raw(&raw).expect("parse own output");
        let expect: String = pks[0].keyid.iter().map(|b| format!("{:02X}", b)).collect();
        assert_eq!(ids, vec![expect], "自产密文的 Key ID 应等于公钥 keyid");
    }

    /// 隐藏收件人（`--hidden-recipient`）时 Key ID 全零 → 必须返回空（调用方退回尝试全部密钥）
    #[test]
    fn recipient_keyids_skips_hidden_recipient() {
        // 手工构造 v3 PKESK：包头(tag1,len=10) || ver(3) || keyid(全零) || algo(1)
        let mut pkt: Vec<u8> = vec![0xC1, 10, 3];
        pkt.extend_from_slice(&[0u8; 8]);
        pkt.push(1);
        let ids = recipient_keyids_raw(&pkt).expect("parse");
        assert!(ids.is_empty(), "隐藏收件人不应返回 Key ID");
    }

    /// 本应用加密 → 结构自洽（gpg 侧解密由开发流程人工验证）
    #[test]
    fn brainpool_encrypt_produces_pkesk_algo8() {
        let armored = need_fixture!("bp256_sec.asc");
        let pks = extract_public_keys_multi(&armored);
        assert_eq!(pks.len(), 1, "应提取到 1 个 algo 8 公钥");
        assert_eq!(pks[0].curve, "brainpoolP256r1");
        let raw = encrypt_message_multi(&pks, b"BRAINPOOL-ROUND-TRIP").expect("encrypt");
        let packets = parse_packets(&raw).expect("parse");
        assert!(packets.iter().any(|p| p.tag == 1), "应含 PKESK");
        assert!(packets.iter().any(|p| p.tag == 18), "应含 SEIPDv1");
        // PKESK 里的 ecc_ct 必须是 65 字节未压缩点
        let pk = parse_pkesk_algo8(&packets.iter().find(|p| p.tag == 1).unwrap().body)
            .expect("parse pkesk");
        assert_eq!(pk.ecc_ct.len(), 65, "brainpool 的 ecc_ct 应为 65 字节未压缩点");
        assert_eq!(pk.ecc_ct[0], 0x04, "ecc_ct 应带 0x04 前缀");
        assert_eq!(pk.mlkem_ct.len(), 1088, "ML-KEM-768 密文长度");
    }

    // 换口令端到端用例在 lib.rs 的 tests 里（run_change_passphrase 在 lib 根；
    // src/bin/* 用 #[path] 直接内嵌本模块，引用 crate:: 会让 bin 测试编不过）
}
