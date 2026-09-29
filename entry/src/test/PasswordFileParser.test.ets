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

    // ===== 内容匹配的可搜索文本（searchableText） =====
    // 需求口径：匹配「除主密码以外的字段内容」，且**不含字段名**

    it('searchable_text_excludes_password_and_labels', 0, () => {
      const raw = 'SuperSecret123\nuser: john\nemail: a@b.com\nphone: 13800000000'
        + '\nnotes: work account\nurl: https://example.org';
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse(raw));
      // 主密码（第一行）与 rawText 都不参与
      expect(text.includes('SuperSecret123')).assertFalse();
      // 字段名不参与（user/notes 由解析器剥离，url 由剥标签规则剥离）
      expect(text.includes('user')).assertFalse();
      expect(text.includes('notes')).assertFalse();
      expect(text.includes('url')).assertFalse();
      // 字段值与额外内容的值参与
      expect(text.includes('john')).assertTrue();
      expect(text.includes('a@b.com')).assertTrue();
      expect(text.includes('13800000000')).assertTrue();
      expect(text.includes('work account')).assertTrue();
      expect(text.includes('example.org')).assertTrue();
    });

    it('searchable_text_keeps_uri_and_non_label_lines', 0, () => {
      const raw = 'ZZTopSecret\nhttps://example.org/path\n营业时间 12:30\n12:30\nfree text line';
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse(raw));
      // URI 行整行保留：协议冒号不是字段分隔符
      expect(text.includes('https://example.org/path')).assertTrue();
      // 冒号落在值里的行（标签含空白）整行保留
      expect(text.includes('营业时间 12:30')).assertTrue();
      // 纯数字「标签」不是字段名（时间/比例一类）
      expect(text.includes('12:30')).assertTrue();
      expect(text.includes('free text line')).assertTrue();
      expect(text.includes('ZZTopSecret')).assertFalse();
    });

    it('searchable_text_strips_halfwidth_fullwidth_and_nospace_labels', 0, () => {
      const raw = 'pw\n用户名：张三\nTOTP: JBSWY3DPEHPK3PXP\n2fa:secretcode';
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse(raw));
      expect(text.includes('张三')).assertTrue();
      expect(text.includes('用户名')).assertFalse();
      expect(text.includes('TOTP')).assertFalse();
      expect(text.includes('JBSWY3DPEHPK3PXP')).assertTrue();
      // 无空格写法同样剥标签（标签是短单词即可）
      expect(text.includes('2fa')).assertFalse();
      expect(text.includes('secretcode')).assertTrue();
    });

    it('searchable_text_label_only_line_contributes_nothing', 0, () => {
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse('pw\nnotes:'));
      // 整行只有字段名、没有值：该行不贡献可搜索文本，
      // 否则搜「notes」会命中全库所有带该行的条目
      expect(text.includes('notes')).assertFalse();
      expect(text.length).assertEqual(0);
    });

    // ===== 命中片段（matchSnippet）：列表副标题「这条为什么命中」 =====

    it('match_snippet_returns_first_matching_line', 0, () => {
      const raw = 'pw\nuser: john\nnotes: 工作账号';
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse(raw));
      expect(PasswordFileParser.matchSnippet(text, 'john')).assertEqual('john');
      expect(PasswordFileParser.matchSnippet(text, '工作')).assertEqual('工作账号');
      // 无命中 / 空输入返回空串
      expect(PasswordFileParser.matchSnippet(text, 'nope')).assertEqual('');
      expect(PasswordFileParser.matchSnippet('', 'john')).assertEqual('');
    });

    it('match_snippet_never_contains_password', 0, () => {
      const raw = 'SuperSecret123\nuser: john';
      const text = PasswordFileParser.searchableText(PasswordFileParser.parse(raw));
      // 主密码不在可搜索文本里，拿它当关键词必然无命中（片段只可能来自字段值）
      expect(PasswordFileParser.matchSnippet(text, 'supersecret123')).assertEqual('');
    });

    it('match_snippet_flattens_and_truncates', 0, () => {
      // 行内连续空白压成单个空格
      const flatText: string = PasswordFileParser.searchableText(
        PasswordFileParser.parse('pw\nnotes: block\t  note2'));
      expect(PasswordFileParser.matchSnippet(flatText, 'block')).assertEqual('block note2');

      // 超长截断为 48 字符 + 省略号（压平后 60 字符）
      const long: string = 'a'.repeat(60);
      const longText: string = PasswordFileParser.searchableText(
        PasswordFileParser.parse(`pw\nnotes: ${long}`));
      const snippet: string = PasswordFileParser.matchSnippet(longText, 'aaa');
      expect(snippet.length).assertEqual(49);
      expect(snippet.endsWith('…')).assertTrue();
    });
  });
}
