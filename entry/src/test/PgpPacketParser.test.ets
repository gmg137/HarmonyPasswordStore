import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { PgpPacketParser } from '../../main/ets/crypto/PgpPacketParser';

/**
 * 真实测试公钥（Ed25519 主键 + Cv25519 加密子键，本地测试密钥、公开材料无隐私）。
 *
 * 元数据真值由 gpg --show-keys --with-colons 对拍得出：
 * - 主键 v4 指纹 83CDDBB5A77A0D1B7A06CE60D30F949E44CDFD77 / Key ID D30F949E44CDFD77
 * - 加密子键 v4 指纹 FAA475F6F30F12DBA0E704994ED2106B261FB0AA / Key ID 4ED2106B261FB0AA
 *
 * 主键指纹断言的是**v4 指纹只覆盖公钥材料**这条规则；加密子密钥 Key ID 断言的是
 * 「ECDH 点 MPI 之后还有一个变长 KDF 参数字段（RFC 6637），漏跳它会让**所有**
 * cv25519 系密钥的指纹与 Key ID 全部算错」的回归——该坑曾长期被文件名权威指纹掩盖。
 */
const TEST_PUBLIC_KEY: string = `-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEarTjqhYJKwYBBAHaRw8BAQdApAbO7brV7AULqZr0om1N6+3Mnzl6s+/JrM59
znYEWS+0G05vcm0gVGVzdCA8bm9ybUB0ZXN0LmxvY2FsPoivBBMWCgBXFiEEg83b
tad6DRt6Bs5g0w+UnkTN/XcFAmq046obFIAAAAAABAAObWFudTIsMi41KzEuMTIs
MiwyAhsDBQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJENMPlJ5Ezf13EjwA
/0R9COYpQHU/yGpYgys7LYCJUiBgUk8vxsnS9gwyuf/9AP4mqLfWfteQcTNTykyJ
W0bqFtzLyacPL0aqm3SCcGVoCLg4BGq046oSCisGAQQBl1UBBQEBB0CXJODGvaC2
8YGg1cdJP55OIGl8jFMRbJ8OWYIwmMHlWwMBCAeIkwQYFgoAPBYhBIPN27Wneg0b
egbOYNMPlJ5Ezf13BQJqtOOqGxSAAAAAAAQADm1hbnUyLDIuNSsxLjEyLDIsMgIb
DAAKCRDTD5SeRM39d+jjAP0Z5JmYp9aRSdyg9I/+gAVyWZi0082KYiDLSRwEvCOh
eAD4yai+WFLwCa3FFSjvdKSbcP9IwpcvOTMNtm4+Xwf1Ag==
=dhvN
-----END PGP PUBLIC KEY BLOCK-----`;

/** ASCII 串转字节（测试输入构造用；CRC 参考向量是字节级的） */
function strBytes(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i: number = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xFF;
  }
  return out;
}

/** 确定性字节序列（不依赖随机源，断言可精确复现）；首字节置最高位以模拟 OpenPGP 包头 */
function deterministicBytes(size: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(size);
  for (let i: number = 0; i < size; i++) {
    out[i] = (i * 37 + 11) & 0x7F;
  }
  out[0] = out[0] | 0x80;
  return out;
}

/** 从 armor 文本取 `=xxxx` 校验行并解码为 24bit 数值 */
function readArmorCrc(armored: string): number {
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
  expect(crcLine.startsWith('=')).assertTrue();
  const bytes: Uint8Array = new util.Base64Helper().decodeSync(crcLine.substring(1));
  expect(bytes.length).assertEqual(3);
  return (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
}

export default function pgpPacketParserTest() {
  describe('PgpPacketParserArmor', () => {

    it('is_binary_key_detects_openpgp_header', 0, () => {
      // 旧格式包标签（gpg --export 默认输出）与新格式包头
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0x94, 0x00]))).assertTrue();
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0x95, 0x01, 0x02]))).assertTrue();
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0xC6, 0x03, 0x01]))).assertTrue();
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0x80]))).assertTrue();
      // '-'（0x2D）开头 = ASCII-armored 文本
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0x2D, 0x2D, 0x2D]))).assertFalse();
      expect(PgpPacketParser.isBinaryKey(strBytes('-----BEGIN PGP-----'))).assertFalse();
      // 最高位未置位的字节不是任何 OpenPGP 包头
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([0x7F]))).assertFalse();
      expect(PgpPacketParser.isBinaryKey(new Uint8Array([]))).assertFalse();
    });

    it('armor_binary_key_uses_rfc4880_structure', 0, () => {
      const data: Uint8Array = deterministicBytes(200); // base64 主体 268 字符 → 64×4+12
      const secretArmored: string = PgpPacketParser.armorBinaryKey(data, true);
      const lines: string[] = secretArmored.split('\n');
      expect(lines[0]).assertEqual('-----BEGIN PGP PRIVATE KEY BLOCK-----');
      expect(lines[1]).assertEqual('');
      expect(lines[lines.length - 1]).assertEqual('-----END PGP PRIVATE KEY BLOCK-----');

      // 主体按 64 字符折行：268 = 64*4 + 12 → 5 行，除末行外都是 64
      const bodyLines: string[] = lines.slice(2, lines.length - 2);
      expect(bodyLines.length).assertEqual(5);
      expect(bodyLines[0].length).assertEqual(64);
      expect(bodyLines[4].length).assertEqual(12);

      // isSecret=false 时标签切换为 PUBLIC
      const publicArmored: string = PgpPacketParser.armorBinaryKey(data, false);
      expect(publicArmored.startsWith('-----BEGIN PGP PUBLIC KEY BLOCK-----')).assertTrue();
      expect(publicArmored.endsWith('-----END PGP PUBLIC KEY BLOCK-----')).assertTrue();

      // 短数据单行主体（3 字节 → 4 字符 base64）
      const shortArmored: string = PgpPacketParser.armorBinaryKey(new Uint8Array([0x01, 0x02, 0x03]), false);
      expect(shortArmored.split('\n').length).assertEqual(5); // BEGIN/空/主体/CRC/END
    });

    it('armor_crc24_matches_rfc4880_reference', 0, () => {
      // 参考值在宿主侧按 RFC 4880 §6.1 独立计算并与 CRC-24/OpenPGP 标准校验值对拍
      // （check("123456789") == 0x21CF02），防止「往返用同一实现、错了也对」
      expect(readArmorCrc(PgpPacketParser.armorBinaryKey(strBytes('123456789'), false)))
        .assertEqual(0x21CF02);
      expect(readArmorCrc(PgpPacketParser.armorBinaryKey(new Uint8Array([]), false)))
        .assertEqual(0xB704CE);
      expect(readArmorCrc(PgpPacketParser.armorBinaryKey(new Uint8Array([0x01, 0x02, 0x03]), false)))
        .assertEqual(0x676193);
      expect(readArmorCrc(PgpPacketParser.armorBinaryKey(new Uint8Array([0xFE, 0x27]), false)))
        .assertEqual(0xD175AA);
    });

    it('dearmor_round_trips_binary_key', 0, () => {
      const data: Uint8Array = deterministicBytes(120);
      const armored: string = PgpPacketParser.armorBinaryKey(data, false);
      const restored: Uint8Array | null = PgpPacketParser.dearmor(armored);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.length).assertEqual(data.length);
        let equal: boolean = true;
        for (let i: number = 0; i < data.length; i++) {
          if (restored[i] !== data[i]) {
            equal = false;
            break;
          }
        }
        expect(equal).assertTrue();
        expect(PgpPacketParser.isBinaryKey(restored)).assertTrue();
      }
    });

    it('dearmor_detects_crc_mismatch', 0, () => {
      const armored: string = PgpPacketParser.armorBinaryKey(deterministicBytes(50), false);
      // 篡改 CRC 行：base64 截断/损坏是落盘场景的真实风险，dearmor 必须拒绝
      const lines: string[] = armored.split('\n');
      for (let i: number = 0; i < lines.length; i++) {
        if (lines[i].startsWith('=') && lines[i].length === 5) {
          lines[i] = '=AAAA'; // 解码为 3 字节 0x000000，必与真 CRC 不符
        }
      }
      expect(PgpPacketParser.dearmor(lines.join('\n'))).assertNull();
    });

    it('dearmor_tolerates_missing_crc_line', 0, () => {
      // 既有口径：CRC 行缺失时跳过校验（不因宽容读取而丢内容）；
      // 断言固定该行为，防止未来误改成强校验导致旧数据读不出
      const armored: string = PgpPacketParser.armorBinaryKey(deterministicBytes(30), false);
      const noCrc: string[] = armored.split('\n').filter((l: string): boolean =>
        !(l.startsWith('=') && l.length === 5));
      const restored: Uint8Array | null = PgpPacketParser.dearmor(noCrc.join('\n'));
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.length).assertEqual(30);
      }
    });

    it('dearmor_rejects_non_armor_input', 0, () => {
      expect(PgpPacketParser.dearmor('')).assertNull();
      expect(PgpPacketParser.dearmor('hello world, not armor at all')).assertNull();
      // 有标签无主体
      expect(PgpPacketParser.dearmor(
        '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n-----END PGP PUBLIC KEY BLOCK-----')).assertNull();
    });

    it('normalize_armor_refolds_single_line_body', 0, () => {
      const standard: string = PgpPacketParser.armorBinaryKey(deterministicBytes(100), false);
      // 复刻导入链路的真实事故形态：主体被拼成单行（不折行）
      const lines: string[] = standard.split('\n');
      const begin: string = lines[0];
      const end: string = lines[lines.length - 1];
      let body: string = '';
      let crc: string = '';
      for (let i: number = 1; i < lines.length - 1; i++) {
        if (lines[i].startsWith('=')) {
          crc = lines[i];
        } else if (lines[i].length > 0) {
          body += lines[i];
        }
      }
      const singleLine: string = [begin, '', body, crc, end].join('\n');
      // 规范化后与标准 armor 逐字符一致
      expect(PgpPacketParser.normalizeArmor(singleLine)).assertEqual(standard);
      // 幂等：标准形态规范化不变
      expect(PgpPacketParser.normalizeArmor(standard)).assertEqual(standard);
    });

    it('normalize_armor_preserves_headers_and_crc', 0, () => {
      const standard: string = PgpPacketParser.armorBinaryKey(deterministicBytes(40), false);
      const lines: string[] = standard.split('\n');
      // 主体前插入 armor 头（`Key: value` 形态，如 GnuPG 的 Version 头）
      const withHeader: string[] = [lines[0], 'Version: UnitTest 1.0'];
      for (let i: number = 1; i < lines.length; i++) {
        withHeader.push(lines[i]);
      }
      const normalized: string = PgpPacketParser.normalizeArmor(withHeader.join('\n'));
      // 头保留、CRC 与 END 原样；去掉头行后与标准 armor 完全一致
      expect(normalized).assertEqual(standard.replace('-----BEGIN PGP PUBLIC KEY BLOCK-----\n',
        '-----BEGIN PGP PUBLIC KEY BLOCK-----\nVersion: UnitTest 1.0\n'));
    });

    it('normalize_armor_handles_crlf_and_blank_lines', 0, () => {
      const standard: string = PgpPacketParser.armorBinaryKey(deterministicBytes(80), false);
      // CRLF 行尾 + 主体行间混入空行：导入文本常见的两种「脏形态」
      const lines: string[] = standard.split('\n');
      const withBlanks: string[] = [];
      for (let i: number = 0; i < lines.length; i++) {
        withBlanks.push(lines[i]);
        if (i >= 2 && i < lines.length - 2) {
          withBlanks.push('');
        }
      }
      const dirty: string = withBlanks.join('\r\n');
      expect(PgpPacketParser.normalizeArmor(dirty)).assertEqual(standard);
    });

    it('normalize_armor_returns_input_without_structure', 0, () => {
      const notArmor: string = 'just some text, no armor here';
      expect(PgpPacketParser.normalizeArmor(notArmor)).assertEqual(notArmor);
      // 有 BEGIN 无 END：结构不完整，原样返回不破坏输入
      const noEnd: string = '-----BEGIN PGP PUBLIC KEY BLOCK-----\nabcd';
      expect(PgpPacketParser.normalizeArmor(noEnd)).assertEqual(noEnd);
    });
  });

  describe('PgpPacketParserParse', () => {

    it('parse_armored_key_matches_gpg_metadata', 0, async (): Promise<void> => {
      const info = await PgpPacketParser.parseArmoredKey(TEST_PUBLIC_KEY, false);
      expect(info !== null).assertTrue();
      if (info !== null) {
        // v4 指纹与 gpg 真值一致（主键指纹只覆盖公钥材料）
        expect(info.fingerprint).assertEqual('83CDDBB5A77A0D1B7A06CE60D30F949E44CDFD77');
        expect(info.keyId).assertEqual('D30F949E44CDFD77');
        // 加密子密钥 Key ID：ECDH KDF 参数字段的坑位回归
        expect(info.encryptionKeyId).assertEqual('4ED2106B261FB0AA');
        // 算法口径：主密钥 EdDSA、加密方式取加密子密钥（ECDH+X25519）
        expect(info.algorithm).assertEqual('EdDSA');
        expect(info.encryptionAlgorithm).assertEqual('ECDH (X25519)');
        expect(info.hasEncryptionKey).assertTrue();
        expect(info.isSecret).assertFalse();
        expect(info.name).assertEqual('Norm Test');
        expect(info.email).assertEqual('norm@test.local');
      }
    });
  });
}
