//! 加密方向验证：应用加密 → 写文件（供 gpg 解密）
//!
//! 用法：gpg_pqc_enc <公钥.asc> <明文文件> <输出文件>
#[path = "../gpg_pqc.rs"]
mod gpg_pqc;
use gpg_pqc::*;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("用法: gpg_pqc_enc <公钥.asc> <明文文件> <输出文件>");
        std::process::exit(2);
    }
    let armored = std::fs::read_to_string(&a[1]).expect("读公钥失败");
    let plaintext = std::fs::read(&a[2]).expect("读明文失败");

    let pks = extract_public_keys_multi(&armored);
    if pks.is_empty() {
        eprintln!("✗ 未找到 GnuPG algo 8 公钥");
        std::process::exit(1);
    }
    for (i, pk) in pks.iter().enumerate() {
        println!("[1] 接收方{}: curve={} ek={}B keyid={}", i + 1, pk.curve, pk.mlkem_ek.len(),
            pk.keyid.iter().map(|b| format!("{:02x}", b)).collect::<String>());
    }

    let raw = match encrypt_message_multi(&pks, &plaintext) {
        Ok(v) => v,
        Err(e) => { eprintln!("✗ 加密失败: {}", e); std::process::exit(1); }
    };
    println!("[2] 加密产出 {}B 二进制", raw.len());

    // 自洽校验：用自己的解密器解回来（需私钥，此处仅验证结构可解析）
    let packets = parse_packets(&raw).expect("解析产出包");
    println!("[3] 包结构: {}", packets.iter()
        .map(|p| format!("tag{}({}B)", p.tag, p.body.len()))
        .collect::<Vec<_>>().join(" "));

    std::fs::write(&a[3], &raw).expect("写输出失败");
    println!("✅ 已写出 {}", &a[3]);
}
