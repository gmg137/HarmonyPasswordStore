import { describe, it, expect } from '@ohos/hypium';
import { PasswordFileParser } from '../../main/ets/format/PasswordFileParser';

/**
 * PasswordFileParser 单元测试
 *
 * 覆盖 pass 文件格式的解析与序列化往返一致性。
 */
export default function parserTest() {
  describe('PasswordFileParser', () => {
    it('parse_simple_password', 0, () => {
      const result = PasswordFileParser.parse('hunter2');
      expect(result.password).assertEqual('hunter2');
      expect(result.username).assertEqual('');
      expect(result.notes).assertEqual('');
    });

    it('parse_with_fields', 0, () => {
      const raw = 'hunter2\nuser: john\nurl: https://example.org\nnotes: work account';
      const result = PasswordFileParser.parse(raw);
      expect(result.password).assertEqual('hunter2');
      expect(result.username).assertEqual('john');
      expect(result.notes).assertEqual('work account');
      // url: 行**不再**是结构化字段——它就是额外内容的一部分（编辑表单没有 URL 输入框，
      // 曾因 URL 单独成字段导致详情页有 URL 卡片而编辑页改不了）
      expect(result.extraContent.includes('url: https://example.org')).assertTrue();
    });

    it('parse_multiline_password_first_line_only', 0, () => {
      const raw = 'first-line-is-password\nuser: a\ntrailing free text\nmore text';
      const result = PasswordFileParser.parse(raw);
      expect(result.password).assertEqual('first-line-is-password');
      // 额外行全部进入 extraContent
      expect(result.extraContent.includes('trailing free text')).assertTrue();
    });

    it('parse_empty_input', 0, () => {
      const result = PasswordFileParser.parse('');
      expect(result.password).assertEqual('');
    });

    it('serialize_fields_roundtrip', 0, () => {
      const serialized = PasswordFileParser.serialize('pw', 'john', 'a@b.com', '13800000000',
        'note', '');
      const parsed = PasswordFileParser.parse(serialized);
      expect(parsed.password).assertEqual('pw');
      expect(parsed.username).assertEqual('john');
      expect(parsed.email).assertEqual('a@b.com');
      expect(parsed.phone).assertEqual('13800000000');
      expect(parsed.notes).assertEqual('note');
    });

    it('serialize_preserves_extra_content', 0, () => {
      const serialized = PasswordFileParser.serialize('pw', '', '', '', '', '', 'custom: line1\nline2');
      expect(serialized.startsWith('pw\n')).assertTrue();
      expect(serialized.includes('custom: line1')).assertTrue();
    });

    it('serialize_keeps_fields_and_extra_content', 0, () => {
      // 回归：曾写成「extraContent 非空时丢弃结构化字段」，于是编辑带自由文本行的
      // 条目时，表单里填的备注/用户名被静默丢弃
      const serialized = PasswordFileParser.serialize('pw', 'john', '', '', '', 'my note',
        'free text from desktop pass');
      const parsed = PasswordFileParser.parse(serialized);
      expect(parsed.username).assertEqual('john');
      expect(parsed.notes).assertEqual('my note');
      expect(parsed.extraContent.includes('free text from desktop pass')).assertTrue();
    });
  });
}
