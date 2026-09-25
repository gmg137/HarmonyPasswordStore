/**
 * PGP 密钥标识信息
 */
export interface GpgKeyId {
  /** 密钥 ID（长格式，16 位十六进制） */
  keyId: string;
  /** 指纹（40 位十六进制） */
  fingerprint: string;
  /** 用户 ID（uid），如 John Doe <john@example.com> */
  userId: string;
  /** 用户名部分 */
  name: string;
  /** 邮箱部分 */
  email: string;
  /** 过期时间（毫秒时间戳，0 表示永不过期） */
  expiry: number;
  /** 是否为私钥 */
  isSecret: boolean;
  /** 是否已导入到本地 */
  isImported: boolean;
  /** 主密钥算法，如 RSA、EdDSA（多为签名/证书用途） */
  algorithm: string;
  /**
   * 实际用于加密的算法
   *
   * 优先取加密子密钥的算法（PGP 惯例：主密钥签名、子密钥加密），
   * 无加密子密钥时回退主密钥算法。列表的「加密方式」应展示此字段。
   */
  encryptionAlgorithm: string;
  /**
   * 该密钥是否含有可用于加密的密钥（主密钥或子密钥）
   *
   * false 表示这是「纯签名密钥」（如仅 ed25519 的主密钥，无加密子密钥），
   * 它能正常导入与查看，但无法用于加密新条目。
   */
  hasEncryptionKey: boolean;
  /**
   * 加密密钥是否被 native（rpgp）支持
   *
   * false 表示该密钥虽能导入，但 rpgp 无法用它加密——例如 GnuPG 私有的
   * Kyber 变体（算法号 8 / v5 子密钥），rpgp 会丢弃该子密钥。
   * 仅在 hasEncryptionKey 为 true 时有意义。
   */
  encryptionSupported: boolean;
  /**
   * 是否含 GnuPG algo 8（`ky768_cv25519` = ML-KEM-768 + X25519）加密子密钥
   *
   * rpgp 会静默丢弃 v5 子密钥包，这类密钥的加解密都必须改走独立模块
   * （native `pgpEncryptGpgPqc` / `pgpDecryptGpgPqc` / `pgpGpgPqcVerifyPassphrase`），
   * 不能只看 `encryptionSupported`。
   */
  gpgPqc: boolean;
  /**
   * 该 algo 8 密钥的经典曲线是否被 native 支持
   *
   * algo 8 是 GnuPG 的复合 KEM（ML-KEM + 经典曲线），经典部分决定能否互通：
   * native 实现了 X25519（ky768_cv25519）与 brainpoolP256r1/P384r1
   * （ky768_bp256 / ky1024_bp384）；X448、brainpoolP512r1、NIST 系尚未实现。
   * false 时加解密都会明确失败，故导入时就要说清楚，不能只说「可正常加解密」。
   */
  gpgPqcUsable: boolean;
  /**
   * **加密子密钥**的 Key ID（16 位大写十六进制；无加密子密钥时为空）
   *
   * 密文 PKESK 里的收件人 keyid 是**子密钥**的，与主密钥 `keyId` 不同：
   * 解密前要按它才能判断「这条密文到底该用哪把密钥解」，重加密时也要按它
   * 比较收件人是否已等于目标。取法与 native 选加密子密钥的顺序一致
   * （第一个 can_encrypt() 的子密钥；GnuPG algo 8 密钥则取该 v5 子密钥）。
   */
  encryptionKeyId: string;
  /** 密钥位数 */
  keySize: number;
  /** 创建时间（毫秒时间戳） */
  createdAt: number;
}

/**
 * PGP 密钥选择结果
 */
export interface GpgKeySelection {
  /** 选中的密钥指纹列表（.gpg-id 内容） */
  keyFingerprints: string[];
  /** 关联的目录路径 */
  directory: string;
}

/**
 * .gpg-id 条目校验结果
 */
export interface GpgIdValidation {
  /** 已导入密钥的标准指纹列表 */
  valid: string[];
  /** 未导入/无法识别的原始条目列表 */
  invalid: string[];
}
