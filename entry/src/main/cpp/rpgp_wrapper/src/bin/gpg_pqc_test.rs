//! GnuPG algo 8 解密链路设备端自测（模拟器/真机实跑）
//!
//! 用法：gpg_pqc_test <私钥.asc> <口令> <密文> <期望明文>
//! 退出码 0 = 成功
#[path = "../gpg_pqc.rs"]
mod gpg_pqc;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 5 {
        eprintln!("用法: gpg_pqc_test <私钥.asc> <口令> <密文> <期望明文>");
        std::process::exit(2);
    }
    let armored = std::fs::read_to_string(&a[1]).expect("读私钥失败");
    let passphrase = &a[2];
    let cipher = std::fs::read(&a[3]).expect("读密文失败");
    let expected = std::fs::read(&a[4]).expect("读明文失败");

    println!("[1] 提取私钥材料（含带口令保护段）");
    let key = match gpg_pqc::extract_key(&armored, passphrase) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("  ✗ {}", e);
            std::process::exit(1);
        }
    };
    println!("  ✓ keyid = {}", hex(&key.keyid));
    println!("  ✓ 指纹长度 = {}（应为 32）", key.fingerprint.len());
    println!("  ✓ mlkem_ek = {}B，seed = {}B，ecc_d = {}B",
        key.mlkem_ek.len(), key.mlkem_secret.len(), key.ecc_d.len());

    println!("[2] 解密报文");
    let pt = match gpg_pqc::decrypt_message(&key, &cipher) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("  ✗ {}", e);
            std::process::exit(1);
        }
    };
    println!("  ✓ 解出 {}B: {:?}", pt.len(), String::from_utf8_lossy(&pt));

    if pt == expected {
        println!("✅ 端到端成功：与 gpg 明文逐字节一致");
    } else {
        eprintln!("✗ 与期望明文不符");
        std::process::exit(1);
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
