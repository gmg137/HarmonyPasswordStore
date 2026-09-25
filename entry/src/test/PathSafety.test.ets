import { describe, it, expect } from '@ohos/hypium';
import { FileUtils } from '../../main/ets/utils/FileUtils';

/**
 * 路径安全单元测试
 *
 * 条目名与目录名有两个来源：用户输入，以及 git 同步下来的仓库内容（攻击者可控）。
 * 未校验时 `../` 可让读写删除逃出仓库根，递归删除会清空 pgp_keys / ssh_keys，
 * 故 safeJoin 的每一条拒绝规则都必须有回归用例。
 */
export default function pathSafetyTest() {
  describe('isSafeRelativePath', () => {
    it('rejects_parent_traversal', 0, () => {
      expect(FileUtils.isSafeRelativePath('../secret')).assertFalse();
      expect(FileUtils.isSafeRelativePath('a/../../b')).assertFalse();
      expect(FileUtils.isSafeRelativePath('..')).assertFalse();
    });

    it('rejects_absolute_and_windows_separator', 0, () => {
      expect(FileUtils.isSafeRelativePath('/etc/passwd')).assertFalse();
      expect(FileUtils.isSafeRelativePath('a\\b')).assertFalse();
    });

    it('rejects_dot_prefixed_segments', 0, () => {
      // .git / .gpg-id 属仓库内部文件，不该由条目路径触达
      expect(FileUtils.isSafeRelativePath('.git/config')).assertFalse();
      expect(FileUtils.isSafeRelativePath('a/.gpg-id')).assertFalse();
    });

    it('rejects_empty_segments', 0, () => {
      expect(FileUtils.isSafeRelativePath('a//b')).assertFalse();
      expect(FileUtils.isSafeRelativePath('a/')).assertFalse();
    });

    it('accepts_normal_nested_names', 0, () => {
      expect(FileUtils.isSafeRelativePath('')).assertTrue();
      expect(FileUtils.isSafeRelativePath('github')).assertTrue();
      // 名称带目录前缀是 pass 的常规用法（web/github）
      expect(FileUtils.isSafeRelativePath('web/github')).assertTrue();
    });
  });

  describe('safeJoin', () => {
    it('throws_on_traversal_instead_of_escaping', 0, () => {
      let threw: boolean = false;
      try {
        FileUtils.safeJoin('/data/store', '../ssh_keys/x');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('joins_normal_path', 0, () => {
      // 基目录不存在时逐段 lstat 会失败，故只验证空相对路径这一不需要 stat 的分支
      expect(FileUtils.safeJoin('/data/store', '')).assertEqual('/data/store');
    });
  });
}
