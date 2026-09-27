/**
 * OpenPGP 数据包解析器
 *
 * 从 ASCII-armored PGP 密钥块中提取元数据（指纹、密钥 ID、用户 ID、算法、创建时间）。
 * 支持 v4 密钥 + 旧格式包头（GnuPG 输出的主流格式）。
 * native rpgp 就绪后，此解析器可被替换为更完整的实现。
 */

import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GpgKeyId } from '../model/GpgKeyId';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PgpParser';

/** 包头解析结果 */
interface PacketHeader {
  tag: number;
  bodyOffset: number;
  bodyLength: number;
}

/** 指纹计算结果 */
interface FingerprintResult {
  fingerprint: string;
  keyId: string;
}

/** 密钥包（主密钥/子密钥）的算法信息 */
interface KeyAlgoInfo {
  version: number;
  algorithmId: number;
  algorithm: string;
  /** ECC 系算法的曲线名（如 X25519 / brainpoolP256r1）；非 ECC 为 '' */
  curve: string;
  /** 算法相关字段（OID/MPI）在 data 中的起点 */
  materialOffset: number;
}

export class PgpPacketParser {
  /**
   * 判断原始文件内容是否为二进制 OpenPGP 数据（而非 ASCII-armored 文本）
   *
   * gpg --export-secret-keys 默认输出二进制格式（.pgp/.gpg 常见此格式），
   * 其首字节为旧格式包标签（0x80 位置位，如 0x94/0x95）或新格式（0x40 位置位）；
   * armored 文本则以 '-'（0x2D）开头。
   */
  static isBinaryKey(data: Uint8Array): boolean {
    if (data.length === 0) return false;
    const first: number = data[0];
    if (first === 0x2D) return false;       // '-'，armored 文本
    return (first & 0x80) !== 0;            // OpenPGP 包头必须有最高位
  }

  /**
   * 将二进制 OpenPGP 数据转换为 ASCII-armored 文本
   *
   * 应用其余链路（元数据解析、native rpgp 解析）均以 armored 文本为输入，
   * 故二进制密钥须先转换。CRC24 按 RFC 4880 §6.1 计算，校验行是标准组成部分。
   * @param data 二进制 OpenPGP 数据
   * @param isSecret 是否为私钥（决定 armor 标签）
   */
  static armorBinaryKey(data: Uint8Array, isSecret: boolean): string {
    const label: string = isSecret ? 'PGP PRIVATE KEY BLOCK' : 'PGP PUBLIC KEY BLOCK';
    const base64Helper: util.Base64Helper = new util.Base64Helper();
    const b64: string = base64Helper.encodeToStringSync(data);

    // base64 主体按每行 64 字符折行（RFC 4880 建议）
    const out: string[] = [];
    out.push(`-----BEGIN ${label}-----`);
    out.push('');
    for (let i: number = 0; i < b64.length; i += 64) {
      out.push(b64.substring(i, Math.min(i + 64, b64.length)));
    }

    const crc: number = PgpPacketParser.crc24(data);
    const crcBytes: Uint8Array = new Uint8Array([
      (crc >>> 16) & 0xFF, (crc >>> 8) & 0xFF, crc & 0xFF
    ]);
    out.push(`=${base64Helper.encodeToStringSync(crcBytes)}`);
    out.push(`-----END ${label}-----`);
    return out.join('\n');
  }

  /** CRC24 校验和（RFC 4880 §6.1），多项式 0x1864CFB */
  private static crc24(data: Uint8Array): number {
    let crc: number = 0xB704CE;
    for (let i: number = 0; i < data.length; i++) {
      crc ^= (data[i] << 16);
      for (let j: number = 0; j < 8; j++) {
        crc <<= 1;
        if ((crc & 0x1000000) !== 0) {
          crc ^= 0x1864CFB;
        }
      }
    }
    return crc & 0xFFFFFF;
  }

  /**
   * 把 armored 文本解回**二进制** OpenPGP（含 CRC24 校验）
   *
   * 用途：「密码文件格式 = bin」时落盘——native 加密产出的是 armored 文本，
   * 按设置需写成二进制（与桌面 pass 的输出一致，体积也小约 1/4）。
   *
   * 校验 armor 的 `=CRC24` 行：它是标准组成部分，能确认 base64 没被截断。
   * 任何一步失败返回 null，**由调用方退回写文本**（宁可格式不符，也绝不丢内容）。
   */
  static dearmor(armored: string): Uint8Array | null {
    const body: string = PgpPacketParser.extractBase64Body(armored);
    if (body.length === 0) {
      return null;
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(body);
      if (bytes.length === 0) {
        return null;
      }
      // 取 `=xxxx` 校验行（若存在）比对 CRC24
      const lines: string[] = armored.split('\n');
      let crcLine: string = '';
      for (let i: number = 0; i < lines.length; i++) {
        const t: string = lines[i].trim();
        if (t.startsWith('-----END PGP')) {
          break;
        }
        if (t.startsWith('=')) {
          crcLine = t;
        }
      }
      if (crcLine.length > 0) {
        const crcBytes: Uint8Array = helper.decodeSync(crcLine.substring(1));
        if (crcBytes.length === 3) {
          const want: number = (crcBytes[0] << 16) | (crcBytes[1] << 8) | crcBytes[2];
          const got: number = PgpPacketParser.crc24(bytes);
          if (want !== got) {
            hilog.warn(DOMAIN, TAG, 'dearmor: CRC24 mismatch (want=%{public}d got=%{public}d)', want, got);
            return null;
          }
        }
      }
      return bytes;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'dearmor failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  /**
   * 规范化 ASCII armor：把 base64 主体按每行 64 字符重新折行
   *
   * **为什么必须做**：本文件的解析（`extractBase64Body` 等）按行取主体、对折行不敏感，
   * 而 native rpgp 严格要求标准 armor——粘贴**单行（不折行）**的 armored 密钥时，
   * 导入会「成功」（元数据解析通过、指纹也算得出来），但之后每一次 native 调用都失败
   * （`parse secret key failed: failed reading: armor header Error(... CrLf)`），
   * 连口令校验都过不去，这把密钥**永远用不了**，而用户看到的是「导入成功」。
   * 导入时统一规范化，落盘的就是 native 一定能读的标准形态。
   *
   * 保留 `Key: value` 头、`=CRC` 校验行与 BEGIN/END 标签，只重排主体；
   * 结构无法识别（缺 BEGIN/END）时**原样返回**，不破坏输入。
   */
  static normalizeArmor(armored: string): string {
    const lines: string[] = armored.replace(/\r\n/g, '\n').split('\n');
    let beginIdx: number = -1;
    let endIdx: number = -1;
    for (let i: number = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (beginIdx < 0) {
        if (t.startsWith('-----BEGIN PGP')) {
          beginIdx = i;
        }
      } else if (t.startsWith('-----END PGP')) {
        endIdx = i;
        break;
      }
    }
    if (beginIdx < 0 || endIdx <= beginIdx) {
      return armored;
    }

    const begin: string = lines[beginIdx].trim();
    const end: string = lines[endIdx].trim();
    const headers: string[] = [];
    let body: string = '';
    let crc: string = '';
    for (let i: number = beginIdx + 1; i < endIdx; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0) {
        continue;
      }
      if (t.startsWith('=')) {
        crc = t;
      } else if (t.indexOf(': ') > 0) {
        headers.push(t);   // armor 头（如 "Version: GnuPG v2"）；base64 不含 ':'，不会误判
      } else {
        body += t;
      }
    }
    if (body.length === 0) {
      return armored;
    }

    const out: string[] = [begin];
    for (let i: number = 0; i < headers.length; i++) {
      out.push(headers[i]);
    }
    out.push('');
    for (let i: number = 0; i < body.length; i += 64) {
      out.push(body.substring(i, Math.min(i + 64, body.length)));
    }
    if (crc.length > 0) {
      out.push(crc);
    }
    out.push(end);
    return out.join('\n');
  }

  /**
   * 解析 ASCII-armored PGP 密钥，提取元数据
   *
   * @param armored ASCII-armored 密钥文本
   * @param isSecret 是否为私钥
   * @returns 密钥元数据或 null
   */
  static async parseArmoredKey(armored: string, isSecret: boolean): Promise<GpgKeyId | null> {
    const base64Str: string = PgpPacketParser.extractBase64Body(armored);
    if (base64Str.length === 0) {
      hilog.error(DOMAIN, TAG, 'No base64 body found in armored key');
      return null;
    }

    // Base64 解码
    const base64Helper: util.Base64Helper = new util.Base64Helper();
    const base64Bytes: Uint8Array = new Uint8Array(base64Str.length);
    for (let i: number = 0; i < base64Str.length; i++) {
      base64Bytes[i] = base64Str.charCodeAt(i);
    }
    let binary: Uint8Array;
    try {
      binary = base64Helper.decodeSync(base64Bytes);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Base64 decode failed: %{public}s', e instanceof Error ? e.message : String(e));
      return null;
    }

    // 遍历数据包
    let keyInfo: GpgKeyId | null = null;
    let userId: string = '';
    let offset: number = 0;
    /** native 实际会选中的加密子密钥算法（首个可加密者，'' 表示无） */
    let usableEncAlgo: string = '';
    /** GnuPG 的 ML-KEM 子密钥算法（算法号 8；rpgp 用不了，仅作展示兜底） */
    let kyberAlgo: string = '';
    let kyberCurve: string = '';
    let encryptionKeyId: string = '';
    /**
     * 是否真的含私钥材料（存在 tag 5/7）
     *
     * 不能信调用方传的 isSecret：用户常误把 `gpg --export` 的公钥
     * （tag 6/14）当私钥导入，若照收会在解密时抛「缺少私钥段」，
     * 而 UI 只会显示「密钥密码错误」，误导用户反复试密码。
     */
    let hasSecretMaterial: boolean = false;

    while (offset < binary.length - 1) {
      const header: PacketHeader | null = PgpPacketParser.parsePacketHeader(binary, offset);
      if (header === null) break;

      if (header.tag === 5 || header.tag === 7) {
        hasSecretMaterial = true;
      }

      if (header.tag === 5 || header.tag === 6) {
        // 主密钥包（私钥 tag=5，公钥 tag=6）
        keyInfo = PgpPacketParser.parseKeyPacket(binary, header, isSecret);
        if (keyInfo !== null) {
          // 按密钥版本选指纹算法（RFC 9580）：
          //   v4 → SHA-1(0x99 + 2 字节长度 + 公钥部分)，KeyID 取最右 8 字节
          //   v5 → SHA-256(0x9A + 4 字节长度 + 公钥部分)，KeyID 取最左 8 字节
          //   v6 → SHA-256(0x9B + 4 字节长度 + ...)，KeyID 取最左 8 字节
          const keyVersion: number = binary[header.bodyOffset];
          let fp: FingerprintResult;
          if (keyVersion === 6) {
            fp = await PgpPacketParser.computeV6Fingerprint(binary, header);
          } else if (keyVersion === 5) {
            fp = await PgpPacketParser.computeV5Fingerprint(binary, header);
          } else {
            fp = await PgpPacketParser.computeV4Fingerprint(binary, header);
          }
          keyInfo.fingerprint = fp.fingerprint;
          keyInfo.keyId = fp.keyId;
        }
      } else if (header.tag === 7 || header.tag === 14) {
        // 子密钥包（私钥 tag=7，公钥 tag=14）
        // PGP 惯例是主密钥签名/认证、子密钥加密；只读主密钥会把混合密钥
        // （如 Ed25519 主密钥 + ML-KEM 加密子密钥）误报成主密钥的算法
        const subInfo: KeyAlgoInfo | null = PgpPacketParser.keyAlgoInfo(binary, header);
        if (subInfo !== null) {
          if (PgpPacketParser.canEncryptAlgorithm(subInfo.algorithmId)) {
            // native 取第一个 can_encrypt() 的子密钥，此处保持同样顺序
            if (usableEncAlgo.length === 0) {
              usableEncAlgo = subInfo.algorithm;
              // 记录该加密子密钥的 Key ID：PKESK 的收件人 keyid 是子密钥的，
              // 与主密钥 keyId 不同，解密/重加密都要按它匹配
              encryptionKeyId = await PgpPacketParser.subkeyKeyId(binary, header);
            }
          } else if (subInfo.algorithmId === 8 && kyberAlgo.length === 0) {
            // GnuPG 的 ML-KEM（算法号 8，v5 子密钥）：rpgp 会丢弃它，
            // 故 can_encrypt() 为 false，此处仅记录备用
            kyberAlgo = subInfo.algorithm;
            kyberCurve = subInfo.curve;
            encryptionKeyId = await PgpPacketParser.subkeyKeyId(binary, header);
          }
        }
      } else if (header.tag === 13) {
        // 用户 ID 包
        userId = PgpPacketParser.extractUserId(binary, header);
      }

      offset = header.bodyOffset + header.bodyLength;
    }

    if (keyInfo === null) {
      hilog.error(DOMAIN, TAG, 'No key packet found');
      return null;
    }

    // 导入私钥时若整份数据里没有 tag 5/7，说明用户给的是公钥
    // （常见误操作：用了 `gpg --export` 而非 `gpg --export-secret-keys`）。
    // 必须在此拒绝——否则公钥被当私钥入库，解密时才抛「缺少私钥段」，
    // 而 UI 只显示「密钥密码错误」，用户会误以为口令不对、反复重试。
    if (isSecret && !hasSecretMaterial) {
      hilog.warn(DOMAIN, TAG, 'parseArmoredKey: 私钥导入但未找到 tag 5/7（这是公钥）');
      return null;
    }

    // 列表「加密方式」应展示实际用于加密的算法：
    // 有可用加密子密钥时用子密钥（native 会选它）；否则若主密钥本身可加密则保留主密钥；
    // 仅当主密钥不能加密、且唯一加密子密钥是 GnuPG 的 ML-KEM（算法号 8）时，
    // 才展示它并标记为 gpgPqc（加解密均走独立模块，rpgp 用不了）
    if (usableEncAlgo.length > 0) {
      keyInfo.encryptionAlgorithm = usableEncAlgo;
      keyInfo.hasEncryptionKey = true;
      keyInfo.encryptionSupported = true;
    } else if (!keyInfo.hasEncryptionKey && kyberAlgo.length > 0) {
      keyInfo.encryptionAlgorithm = kyberAlgo;
      keyInfo.hasEncryptionKey = true;
      // rpgp 会丢弃 v5 子密钥，加解密都由 native 的 gpg_pqc 独立模块完成，
      // 故单独用 gpgPqc 标记（encryptionSupported 仍为 false——rpgp 用不了）
      keyInfo.encryptionSupported = false;
      keyInfo.gpgPqc = true;
      // 经典曲线决定能否互通：只有 native 实现了的曲线才真正可用
      keyInfo.gpgPqcUsable = PgpPacketParser.isGpgPqcCurveSupported(kyberCurve);
    }
    // 加密子密钥的 Key ID：无加密子密钥时保持空串
    if (encryptionKeyId.length > 0) {
      keyInfo.encryptionKeyId = encryptionKeyId;
    }

    keyInfo.userId = userId;
    const parts: UserNameParts = PgpPacketParser.splitUserId(userId);
    keyInfo.name = parts.name;
    keyInfo.email = parts.email;
    keyInfo.isImported = true;

    return keyInfo;
  }

  /**
   * 判断 armored 数据中是否含私钥材料（存在 tag 5/7）
   *
   * 供导入流程在解析前给出精确提示：用户常误用 `gpg --export` 导出公钥
   * 却当作私钥导入；若只在解密时才发现，UI 只会显示「密钥密码错误」，
   * 误导用户反复重试口令。注意**不能**只看 armor 标签——二进制文件
   * 经 armorBinaryKey 转换时标签由调用方指定，未必反映真实内容。
   */
  static containsSecretMaterial(armored: string): boolean {
    const base64Str: string = PgpPacketParser.extractBase64Body(armored);
    if (base64Str.length === 0) return false;
    const base64Helper: util.Base64Helper = new util.Base64Helper();
    const base64Bytes: Uint8Array = new Uint8Array(base64Str.length);
    for (let i: number = 0; i < base64Str.length; i++) {
      base64Bytes[i] = base64Str.charCodeAt(i);
    }
    let binary: Uint8Array;
    try {
      binary = base64Helper.decodeSync(base64Bytes);
    } catch (e) {
      return false;
    }
    let offset: number = 0;
    while (offset < binary.length - 1) {
      const header: PacketHeader | null = PgpPacketParser.parsePacketHeader(binary, offset);
      if (header === null) break;
      if (header.tag === 5 || header.tag === 7) {
        return true;
      }
      offset = header.bodyOffset + header.bodyLength;
    }
    return false;
  }

  /**
   * 从 ASCII-armored 文本中提取 base64 主体
   */
  private static extractBase64Body(armored: string): string {
    const lines: string[] = armored.split('\n');
    let inBody: boolean = false;
    let body: string = '';

    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.startsWith('-----BEGIN PGP')) {
        inBody = true;
        continue;
      }
      if (line.startsWith('-----END PGP')) {
        break;
      }
      if (!inBody) continue;
      // 跳过 header 行（key: value 格式）和空行
      if (line.length === 0) continue;
      if (line.indexOf(':') >= 0 && line.charAt(line.indexOf(':') + 1) === ' ') continue;
      // CRC 行（以 = 开头）
      if (line.startsWith('=')) continue;
      body += line;
    }
    return body;
  }

  /**
   * 解析数据包头（旧格式 + 新格式）
   */
  private static parsePacketHeader(data: Uint8Array, offset: number): PacketHeader | null {
    if (offset >= data.length) return null;

    const firstByte: number = data[offset];
    const isNewFormat: boolean = (firstByte & 0x40) !== 0;

    if (isNewFormat) {
      return PgpPacketParser.parseNewFormatHeader(data, offset);
    }
    return PgpPacketParser.parseOldFormatHeader(data, offset);
  }

  /**
   * 旧格式包头（bit7=1, bit6=0, bits5-2=tag, bits1-0=lengthType）
   */
  private static parseOldFormatHeader(data: Uint8Array, offset: number): PacketHeader | null {
    const firstByte: number = data[offset];
    const tag: number = (firstByte >> 2) & 0x0F;
    const lengthType: number = firstByte & 0x03;

    let bodyOffset: number = offset + 1;
    let bodyLength: number = 0;

    if (lengthType === 0) {
      if (bodyOffset >= data.length) return null;
      bodyLength = data[bodyOffset];
      bodyOffset += 1;
    } else if (lengthType === 1) {
      if (bodyOffset + 1 >= data.length) return null;
      bodyLength = (data[bodyOffset] << 8) | data[bodyOffset + 1];
      bodyOffset += 2;
    } else if (lengthType === 2) {
      if (bodyOffset + 3 >= data.length) return null;
      bodyLength = (data[bodyOffset] << 24) | (data[bodyOffset + 1] << 16) |
        (data[bodyOffset + 2] << 8) | data[bodyOffset + 3];
      bodyOffset += 4;
    } else {
      // 不确定长度，无法处理
      return null;
    }

    if (bodyOffset + bodyLength > data.length) return null;
    return { tag, bodyOffset, bodyLength };
  }

  /**
   * 新格式包头（bit7=1, bit6=1, bits5-0=tag）
   */
  private static parseNewFormatHeader(data: Uint8Array, offset: number): PacketHeader | null {
    const firstByte: number = data[offset];
    const tag: number = firstByte & 0x3F;
    let bodyOffset: number = offset + 1;

    if (bodyOffset >= data.length) return null;
    const lenByte: number = data[bodyOffset];
    let bodyLength: number = 0;

    if (lenByte < 192) {
      bodyLength = lenByte;
      bodyOffset += 1;
    } else if (lenByte < 224) {
      if (bodyOffset + 1 >= data.length) return null;
      bodyLength = ((lenByte - 192) << 8) + data[bodyOffset + 1] + 192;
      bodyOffset += 2;
    } else if (lenByte === 255) {
      if (bodyOffset + 4 >= data.length) return null;
      bodyLength = (data[bodyOffset + 1] << 24) | (data[bodyOffset + 2] << 16) |
        (data[bodyOffset + 3] << 8) | data[bodyOffset + 4];
      bodyOffset += 5;
    } else {
      // 部分长度，不支持
      return null;
    }

    if (bodyOffset + bodyLength > data.length) return null;
    return { tag, bodyOffset, bodyLength };
  }

  /**
   * 解析密钥包（tag 5/6），提取版本、创建时间、算法、密钥位数
   */
  private static parseKeyPacket(data: Uint8Array, header: PacketHeader, isSecret: boolean): GpgKeyId | null {
    const info: KeyAlgoInfo | null = PgpPacketParser.keyAlgoInfo(data, header);
    if (info === null) {
      hilog.warn(DOMAIN, TAG, 'Unsupported key packet version');
      return null;
    }

    const body: number = header.bodyOffset;
    // v4/v5/v6 前 6 字节布局一致：version(1) + creation_time(4) + algorithm(1)
    const creationTime: number = (data[body + 1] << 24) | (data[body + 2] << 16) |
      (data[body + 3] << 8) | data[body + 4];
    const keySize: number = PgpPacketParser.extractKeySize(data, info.materialOffset, info.algorithmId);

    return {
      keyId: '',
      fingerprint: '',
      userId: '',
      name: '',
      email: '',
      expiry: 0,
      isSecret: isSecret,
      isImported: true,
      algorithm: info.algorithm,
      // 默认与主密钥相同；若存在加密子密钥，由 parseArmoredKey 覆盖
      encryptionAlgorithm: info.algorithm,
      // 主密钥本身可加密（如 RSA）时即视为含加密密钥；否则看是否有加密子密钥
      hasEncryptionKey: PgpPacketParser.canEncryptAlgorithm(info.algorithmId),
      encryptionSupported: PgpPacketParser.canEncryptAlgorithm(info.algorithmId),
      gpgPqc: false,
      gpgPqcUsable: false,
      encryptionKeyId: '',
      keySize: keySize,
      createdAt: creationTime * 1000
    };
  }

  /**
   * 解析密钥包（主密钥 tag 5/6、子密钥 tag 7/14）的版本与算法
   *
   * v5/v6 在算法号后多一个 4 字节密钥材料长度字段，材料起点比 v4 后移 4 字节；
   * 三者的 version/creation_time/algorithm 前 6 字节布局一致。
   */
  private static keyAlgoInfo(data: Uint8Array, header: PacketHeader): KeyAlgoInfo | null {
    const body: number = header.bodyOffset;
    if (header.bodyLength < 6) return null;

    const version: number = data[body];
    if (version !== 4 && version !== 5 && version !== 6) return null;

    const algorithmId: number = data[body + 5];
    const materialOffset: number = version === 4 ? body + 6 : body + 10;
    const algorithm: string = PgpPacketParser.algorithmName(algorithmId, data, materialOffset);
    // ECC 系算法（含 GnuPG algo 8）的曲线名从 OID 取，供支持性判定使用
    const isEcc: boolean = algorithmId === 8 || (algorithmId >= 18 && algorithmId <= 22)
      || (algorithmId >= 25 && algorithmId <= 28);
    const curve: string = isEcc ? PgpPacketParser.curveName(data, materialOffset) : '';
    return { version, algorithmId, algorithm, curve, materialOffset };
  }

  /**
   * 计算某个密钥包（主密钥或子密钥）的 Key ID
   *
   * Key ID 取法随版本不同：v4 取 SHA-1 指纹**最右** 8 字节，
   * v5/v6 取 SHA-256 指纹**最左** 8 字节（与各 computeXXXFingerprint 一致）。
   * 子密钥包（tag 7/14）的指纹算法与主密钥包相同，故直接复用同一批函数。
   */
  private static async subkeyKeyId(data: Uint8Array, header: PacketHeader): Promise<string> {
    const version: number = data[header.bodyOffset];
    try {
      let fp: FingerprintResult;
      if (version === 6) {
        fp = await PgpPacketParser.computeV6Fingerprint(data, header);
      } else if (version === 5) {
        fp = await PgpPacketParser.computeV5Fingerprint(data, header);
      } else {
        fp = await PgpPacketParser.computeV4Fingerprint(data, header);
      }
      return fp.keyId;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'subkeyKeyId failed: %{public}s',
        e instanceof Error ? e.message : String(e));
      return '';
    }
  }

  /**
   * GnuPG algo 8 的经典曲线是否被 native 实现
   *
   * native（`gpg_pqc` + 自建 `bp_curve`）实现了：
   * - X25519（`ky768_cv25519`）
   * - brainpoolP256r1 / brainpoolP384r1（`ky768_bp256` / `ky1024_bp384`）
   * 未实现：X448（`ky1024_cv448`）、brainpoolP512r1、NIST P-256/384/521。
   * 这些曲线导入时就必须明确告知不可用——曾一律提示「可正常加解密」，
   * 用户到创建/解密时才失败，且错误看起来像口令问题。
   */
  static isGpgPqcCurveSupported(curve: string): boolean {
    switch (curve) {
      case 'X25519':
      case 'brainpoolP256r1':
      case 'brainpoolP384r1':
        return true;
      default:
        return false;
    }
  }

  /**
   * 该算法能否用于加密（决定它是否可能被选作加密子密钥）
   *
   * 与 native rpgp 的 PublicKeyAlgorithm::can_encrypt 保持一致：
   * RSA(1/2/3)、ElGamal(16/20)、ECDH(18)、X25519(25)、X448(26)、ML-KEM(35/36)。
   * 注意算法号 8 是 GnuPG 用于 ML-KEM 的编号（配 v5 子密钥），rpgp 会丢弃该子密钥，
   * 故不算可加密。
   */
  private static canEncryptAlgorithm(id: number): boolean {
    switch (id) {
      case 1: case 2: case 3:   // RSA
      case 16: case 20:         // ElGamal / ElGamalEncrypt
      case 18:                  // ECDH
      case 25: case 26:         // X25519 / X448
      case 35: case 36:         // ML-KEM-768+X25519 / ML-KEM-1024+X448
        return true;
      default:
        return false;
    }
  }

  /**
   * 读取算法字段起始处的 curve OID，并映射为可读曲线名
   *
   * ECC 类算法（18/19/22/25-28）与 GnuPG 的 ML-KEM(8) 都在材料开头放 OID。
   * @returns 曲线名；无 OID 或不认识时返回空串
   */
  private static curveName(data: Uint8Array, materialOffset: number): string {
    if (materialOffset >= data.length) return '';
    const oidLen: number = data[materialOffset];
    if (oidLen === 0 || materialOffset + 1 + oidLen > data.length) return '';
    let hex: string = '';
    for (let i: number = 0; i < oidLen; i++) {
      const b: number = data[materialOffset + 1 + i];
      hex += (b < 16 ? '0' : '') + b.toString(16);
    }
    switch (hex) {
      // RFC 6637 / RFC 9580 曲线
      case '2b06010401da470f01': return 'Ed25519';      // 1.3.6.1.4.1.11591.15.1
      case '2b060104019755010501': return 'Curve25519'; // 1.3.6.1.4.1.3029.1.5.1
      case '2b656e': return 'X25519';                   // 1.3.101.110
      case '2b656f': return 'X448';                     // 1.3.101.111
      case '2b6570': return 'Ed25519';                  // 1.3.101.112
      case '2b6571': return 'Ed448';                    // 1.3.101.113
      case '2a8648ce3d030107': return 'NIST P-256';     // 1.2.840.10045.3.1.7
      case '2b81040022': return 'NIST P-384';           // 1.3.132.0.34
      case '2b81040023': return 'NIST P-521';           // 1.3.132.0.35
      case '2b2403030208010107': return 'brainpoolP256r1'; // 1.3.36.3.3.2.8.1.1.7
      case '2b240303020801010b': return 'brainpoolP384r1'; // 1.3.36.3.3.2.8.1.1.11
      case '2b240303020801010d': return 'brainpoolP512r1'; // 1.3.36.3.3.2.8.1.1.13
      case '2b8104000a': return 'secp256k1';            // 1.3.132.0.10
      default: return '';
    }
  }

  /**
   * 算法 ID → 名称
   */
  private static algorithmName(id: number, data: Uint8Array, materialOffset: number): string {
    switch (id) {
      case 1: case 2: case 3: return 'RSA';
      case 17: return 'DSA';
      case 16: case 20: return 'ElGamal';
      // ECDH/ECDSA 名称本身不含曲线，补上曲线名更利于分辨实际加密强度
      case 18: {
        const curve: string = PgpPacketParser.curveName(data, materialOffset);
        return curve.length > 0 ? `ECDH (${curve})` : 'ECDH';
      }
      case 19: {
        const curve: string = PgpPacketParser.curveName(data, materialOffset);
        return curve.length > 0 ? `ECDSA (${curve})` : 'ECDSA';
      }
      case 22: return 'EdDSA';
      // RFC 9580 新增 ECC 算法号（与 18/19/22 同类，仅编号不同）
      case 25: return 'X25519';
      case 26: return 'X448';
      case 27: return 'Ed25519';
      case 28: return 'Ed448';
      // RFC 9580 后量子算法：native 未启用 draft-pqc，仅用于给出可读名称与明确拒绝
      case 30: return 'ML-DSA-65+Ed25519';
      case 31: return 'ML-DSA-87+Ed448';
      case 32: return 'SLH-DSA-SHAKE-128s';
      case 33: return 'SLH-DSA-SHAKE-128f';
      case 34: return 'SLH-DSA-SHAKE-256s';
      case 35: return 'ML-KEM-768+X25519';
      case 36: return 'ML-KEM-1024+X448';
      // 8 是 GnuPG 自 2.5 起用于 Kyber/ML-KEM 的算法号（非 RFC 9580 的 35/36）。
      // GnuPG 用「Kyber 密钥 + 经典曲线」组合，curve OID 指明经典部分：
      //   ky768_cv25519 → 1.3.101.110 (X25519)   ⇒ 等同 ML-KEM-768+X25519
      //   ky1024_cv448  → 1.3.101.111 (X448)     ⇒ 等同 ML-KEM-1024+X448
      //   ky768_bp256   → brainpoolP256r1        ⇒ ML-KEM-768+brainpoolP256r1
      //   ky1024_bp384/512 → brainpoolP384r1/512r1
      // 故此处按曲线给出与 RFC 9580 对应的名称，而非笼统的 "Kyber"。
      // 注意：GnuPG 把它编码为 v5 子密钥，rpgp 会静默丢弃该子密钥（见 AGENTS.md），
      // 因此这些密钥可以展示，但不能用于加密。
      case 8: {
        const curve: string = PgpPacketParser.curveName(data, materialOffset);
        switch (curve) {
          case 'X25519': return 'ML-KEM-768+X25519 (GnuPG)';
          case 'X448': return 'ML-KEM-1024+X448 (GnuPG)';
          case 'brainpoolP256r1': return 'ML-KEM-768+brainpoolP256r1 (GnuPG)';
          case 'brainpoolP384r1': return 'ML-KEM-1024+brainpoolP384r1 (GnuPG)';
          case 'brainpoolP512r1': return 'ML-KEM-1024+brainpoolP512r1 (GnuPG)';
          default: return curve.length > 0 ? `ML-KEM (GnuPG, ${curve})` : 'ML-KEM (GnuPG)';
        }
      }
      default: return `Unknown(${id})`;
    }
  }

  /**
   * 校验算法是否可用；不可用时返回可操作的中文提示，可用时返回空串
   *
   * 供导入流程在写盘前调用：native 无法处理的算法若照常写入，
   * 会出现「导入成功但解密失败」的静默故障，用户难以定位。
   * @param algorithm algorithmName() 产出的算法名
   */
  static unsupportedAlgorithmReason(algorithm: string): string {
    // 已支持：RSA / DSA / ElGamal / ECDH / ECDSA / EdDSA / X25519 / X448 / Ed25519 / Ed448，
    // 以及 PQC（ML-KEM / ML-DSA / SLH-DSA）——native 侧已通过 pgp-patched 启用 draft-pqc
    const supported: string[] = ['RSA', 'DSA', 'ElGamal', 'ECDH', 'ECDSA', 'EdDSA',
      'X25519', 'X448', 'Ed25519', 'Ed448'];
    // algorithmName 会为 ECDH/ECDSA 追加曲线后缀（如 'ECDH (Curve25519)'），
    // 故比较前先去掉括号部分，否则正常密钥会被误判为不支持
    const parenIdx: number = algorithm.indexOf(' (');
    const base: string = parenIdx >= 0 ? algorithm.substring(0, parenIdx) : algorithm;
    if (supported.indexOf(base) >= 0) {
      return '';
    }
    if (algorithm.startsWith('ML-KEM') || algorithm.startsWith('ML-DSA')
      || algorithm.startsWith('SLH-DSA')) {
      return '';
    }
    return Strings.fmt('pgp_unsupported_algo_reason', algorithm);
  }

  /**
   * 从密钥材料中提取密钥位数（MPI 的前 2 字节为位长度）
   */
  private static extractKeySize(data: Uint8Array, offset: number, algorithmId: number): number {
    if (offset + 1 >= data.length) return 0;

    // RSA: 第一个 MPI 是 n（模数），位长度即为密钥位数
    if (algorithmId === 1 || algorithmId === 2 || algorithmId === 3) {
      return (data[offset] << 8) | data[offset + 1];
    }
    // DSA: 第一个 MPI 是 p，位长度为密钥位数
    if (algorithmId === 17) {
      return (data[offset] << 8) | data[offset + 1];
    }
    // ECDSA/ECDH/EdDSA: 先读 curve OID，再读 point MPI
    if (algorithmId === 18 || algorithmId === 19 || algorithmId === 22) {
      // OID 长度
      if (offset >= data.length) return 0;
      const oidLen: number = data[offset];
      const pointOffset: number = offset + 1 + oidLen;
      if (pointOffset + 1 >= data.length) return 0;
      return (data[pointOffset] << 8) | data[pointOffset + 1];
    }
    return 0;
  }

  /**
   * 跳过数据 p 处的一个 MPI，返回其后偏移；越界返回 -1
   */
  private static skipMpi(data: Uint8Array, p: number, end: number): number {
    if (p + 2 > end) return -1;
    const bits: number = (data[p] << 8) | data[p + 1];
    const next: number = p + 2 + ((bits + 7) >> 3);
    return next <= end ? next : -1;
  }

  /**
   * 该算法的公钥材料由几个 MPI 组成（不含 curve OID）；未知返回 -1
   */
  private static publicMpiCount(algorithmId: number): number {
    if (algorithmId === 1 || algorithmId === 2 || algorithmId === 3) return 2;  // RSA: n, e
    if (algorithmId === 16 || algorithmId === 20) return 3;                     // ElGamal: p, g, y
    if (algorithmId === 17) return 4;                                           // DSA: p, q, g, y
    if (algorithmId === 18 || algorithmId === 19 || algorithmId === 22
      || algorithmId === 25 || algorithmId === 26) return 1;                    // ECDH/ECDSA/EdDSA/X25519/X448
    return -1;
  }

  /** 该算法的公钥材料是否以 curve OID 开头 */
  private static hasCurveOid(algorithmId: number): boolean {
    return algorithmId === 18 || algorithmId === 19 || algorithmId === 22
      || algorithmId === 25 || algorithmId === 26;
  }

  /**
   * 密钥包「公钥部分」的结束偏移
   *
   * RFC 4880/9580 规定密钥指纹**只覆盖公钥材料**，私钥材料不参与哈希。
   * 对私钥包（tag 5/7）若直接哈希整个包体，会算出与 gpg/pass 不同的指纹
   * （实测：主密钥真实指纹 9CD885D3…，错算成 47E6E50C…），破坏互操作。
   */
  private static publicMaterialEnd(data: Uint8Array, bodyOffset: number, bodyLength: number): number {
    const end: number = bodyOffset + bodyLength;
    if (bodyLength < 6) return end;
    const version: number = data[bodyOffset];

    // v5/v6：算法号后有 4 字节「密钥材料长度」，且只覆盖公钥材料
    if (version >= 5) {
      if (bodyLength < 10) return end;
      const matLen: number = (data[bodyOffset + 6] << 24) | (data[bodyOffset + 7] << 16) |
        (data[bodyOffset + 8] << 8) | data[bodyOffset + 9];
      const pubEnd: number = bodyOffset + 10 + matLen;
      return pubEnd <= end ? pubEnd : end;
    }

    // v4：无长度字段，按算法逐个跳过公钥 MPI
    const algorithmId: number = data[bodyOffset + 5];
    let p: number = bodyOffset + 6;

    // GnuPG ML-KEM（算法号 8）：OID + MPI(q) + u32(ek 长度) + ek
    if (algorithmId === 8) {
      if (p >= end) return end;
      p += 1 + data[p];                    // OID
      p = PgpPacketParser.skipMpi(data, p, end);
      if (p < 0 || p + 4 > end) return end;
      const ekLen: number = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
      p += 4 + ekLen;
      return p <= end ? p : end;
    }

    if (PgpPacketParser.hasCurveOid(algorithmId)) {
      if (p >= end) return end;
      p += 1 + data[p];                    // OID 长度字节 + OID
    }
    const mpiCount: number = PgpPacketParser.publicMpiCount(algorithmId);
    if (mpiCount < 0) return end;          // 未知算法：保守返回整包
    for (let i: number = 0; i < mpiCount; i++) {
      p = PgpPacketParser.skipMpi(data, p, end);
      if (p < 0) return end;
    }
    // RFC 6637：**ECDH（算法 18）** 的公钥在点 MPI 之后还有一个变长 KDF 参数字段
    // （1 字节长度 + 该长度的参数，标准写法是 len=3：保留位 1 + 哈希算法 + 对称算法）。
    // 漏掉这 4 字节，cv25519 等 ECDH 密钥的指纹/Key ID 会全部算错——起初看不见，
    // 因为 .gpg-id 一般写指纹（走文件名字段），而错的是 encryptionKeyId；
    // 一旦 .gpg-id 写成子密钥 ID 或邮箱，唯一能兜底的「按密文收件人匹配」也失效，
    // 条目就会莫名报「缺少解密密钥（Key ID：…）」。
    // 注意：ECDSA(19)/EdDSA(22) 没有这个字段，只有 ECDH 有。
    if (algorithmId === 18) {
      if (p < 0 || p >= end) return end;
      p += 1 + data[p];                    // KDF 长度字节 + KDF 参数
    }
    return p <= end ? p : end;
  }

  /**
   * 计算 v4 指纹：SHA-1(0x99 + 2字节长度 + 公钥部分)
   *
   * 注意长度字段与哈希范围都是**公钥部分**（私钥包须截断，见 publicMaterialEnd）。
   */
  private static async computeV4Fingerprint(data: Uint8Array, header: PacketHeader): Promise<FingerprintResult> {
    // 私钥包只取公钥部分；公钥包此处即为整个包体
    const bodyLen: number = PgpPacketParser.publicMaterialEnd(
      data, header.bodyOffset, header.bodyLength) - header.bodyOffset;
    const hashInput: Uint8Array = new Uint8Array(3 + bodyLen);
    hashInput[0] = 0x99;
    hashInput[1] = (bodyLen >> 8) & 0xFF;
    hashInput[2] = bodyLen & 0xFF;
    for (let i: number = 0; i < bodyLen; i++) {
      hashInput[3 + i] = data[header.bodyOffset + i];
    }

    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA1');
      const inputBlob: cryptoFramework.DataBlob = { data: hashInput };
      await md.update(inputBlob);
      const result: cryptoFramework.DataBlob = await md.digest();
      const hash: Uint8Array = result.data;
      const fingerprint: string = PgpPacketParser.toHex(hash);
      // Key ID = 指纹的低 8 字节（16 位十六进制）
      const keyId: string = fingerprint.substring(fingerprint.length - 16);
      return { fingerprint, keyId };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SHA-1 computation failed: %{public}s', e instanceof Error ? e.message : String(e));
      return { fingerprint: '', keyId: '' };
    }
  }

  /**
   * 计算 v5 指纹（RFC 9580 §5.5.4.2）：SHA-256(0x9A + 四字节总长 + 公钥材料)
   *
   * 与 v4 的差异：前缀 0x9A（v4 是 0x99 + 2 字节长度）、哈希 SHA-256（v4 是 SHA-1）、
   * 长度字段 4 字节（v4 是 2 字节）。与 v6 的差异：前缀 0x9A（v6 是 0x9B）。
   *
   * 关键：总长与哈希范围都只覆盖**公钥材料**（`10 + 材料长度`），不含私钥段。
   * Key ID 取指纹**最左** 8 字节（v4 取最右 8 字节）。
   */
  private static async computeV5Fingerprint(data: Uint8Array, header: PacketHeader): Promise<FingerprintResult> {
    const body: number = header.bodyOffset;
    if (body + 10 > data.length) {
      return { fingerprint: '', keyId: '' };
    }

    const materialLen: number = (data[body + 6] << 24) | (data[body + 7] << 16) |
      (data[body + 8] << 8) | data[body + 9];
    const totalLen: number = 10 + materialLen;
    if (body + totalLen > data.length) {
      return { fingerprint: '', keyId: '' };
    }

    const hashInput: Uint8Array = new Uint8Array(5 + totalLen);
    hashInput[0] = 0x9A;
    hashInput[1] = (totalLen >>> 24) & 0xFF;
    hashInput[2] = (totalLen >>> 16) & 0xFF;
    hashInput[3] = (totalLen >>> 8) & 0xFF;
    hashInput[4] = totalLen & 0xFF;
    for (let i: number = 0; i < totalLen; i++) {
      hashInput[5 + i] = data[body + i];
    }

    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const inputBlob: cryptoFramework.DataBlob = { data: hashInput };
      await md.update(inputBlob);
      const result: cryptoFramework.DataBlob = await md.digest();
      const fingerprint: string = PgpPacketParser.toHex(result.data);
      // v5 的 Key ID 取指纹最左 8 字节（v4 取最右 8 字节）
      const keyId: string = fingerprint.substring(0, 16);
      return { fingerprint, keyId };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SHA-256 computation failed: %{public}s', e instanceof Error ? e.message : String(e));
      return { fingerprint: '', keyId: '' };
    }
  }

  /**
   * 计算 v6 指纹（RFC 9580 §5.5.4.3）：SHA-256(0x9B + 四字节总长 + 版本 + 时间 + 算法 + 四字节材料长 + 公钥材料)
   *
   * 与 v4 的差异：前缀为 0x9B（v4 是 0x99 + 2 字节长度），哈希用 SHA-256（v4 用 SHA-1），
   * 且多一个「四字节密钥材料长度」字段。总长 = 1(版本) + 4(时间) + 1(算法) + 4(材料长) + 材料长。
   */
  private static async computeV6Fingerprint(data: Uint8Array, header: PacketHeader): Promise<FingerprintResult> {
    const body: number = header.bodyOffset;
    if (body + 10 > data.length) {
      return { fingerprint: '', keyId: '' };
    }

    // 公钥材料长度：v6 在算法号之后紧跟四字节长度
    const materialLen: number = (data[body + 6] << 24) | (data[body + 7] << 16) |
      (data[body + 8] << 8) | data[body + 9];
    const totalLen: number = 10 + materialLen;

    const hashInput: Uint8Array = new Uint8Array(5 + totalLen);
    hashInput[0] = 0x9B;
    hashInput[1] = (totalLen >>> 24) & 0xFF;
    hashInput[2] = (totalLen >>> 16) & 0xFF;
    hashInput[3] = (totalLen >>> 8) & 0xFF;
    hashInput[4] = totalLen & 0xFF;
    for (let i: number = 0; i < totalLen; i++) {
      hashInput[5 + i] = data[body + i];
    }

    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const inputBlob: cryptoFramework.DataBlob = { data: hashInput };
      await md.update(inputBlob);
      const result: cryptoFramework.DataBlob = await md.digest();
      const fingerprint: string = PgpPacketParser.toHex(result.data);
      // v6 的 Key ID 取指纹最左 8 字节（v4 取最右 8 字节）
      const keyId: string = fingerprint.substring(0, 16);
      return { fingerprint, keyId };
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SHA-256 computation failed: %{public}s', e instanceof Error ? e.message : String(e));
      return { fingerprint: '', keyId: '' };
    }
  }

  /**
   * 提取用户 ID 包内容（tag 13）
   */
  private static extractUserId(data: Uint8Array, header: PacketHeader): string {
    const len: number = header.bodyLength;
    const bytes: Uint8Array = new Uint8Array(len);
    for (let i: number = 0; i < len; i++) {
      bytes[i] = data[header.bodyOffset + i];
    }
    try {
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      const decoded: string = decoder.decodeToString(bytes);
      return decoded;
    } catch (e) {
      return '';
    }
  }

  /**
   * 拆分用户 ID 为姓名和邮箱
   * 格式：John Doe <john@example.com>
   */
  private static splitUserId(userId: string): UserNameParts {
    const ltIdx: number = userId.indexOf('<');
    const gtIdx: number = userId.indexOf('>');

    if (ltIdx >= 0 && gtIdx > ltIdx) {
      const email: string = userId.substring(ltIdx + 1, gtIdx).trim();
      const name: string = userId.substring(0, ltIdx).trim();
      return { name, email };
    }
    // 无邮箱格式，整体作为姓名
    return { name: userId.trim(), email: '' };
  }

  /**
   * Uint8Array → 大写十六进制字符串
   */
  private static toHex(bytes: Uint8Array): string {
    const hex: string = '0123456789ABCDEF';
    let result: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      result += hex.charAt(bytes[i] >> 4);
      result += hex.charAt(bytes[i] & 0x0F);
    }
    return result;
  }
}

/** 用户 ID 拆分结果 */
interface UserNameParts {
  name: string;
  email: string;
}
