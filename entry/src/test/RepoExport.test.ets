import { describe, it, expect } from '@ohos/hypium';
import { RepoExportService } from '../../main/ets/utils/RepoExportService';

/**
 * 仓库导出文件名单元测试
 *
 * 导出文件名形如 `pass-store-YYYYMMDD-HHMMSS.zip`（本地时间）。有两类易错点：
 * `getMonth()` 是 0 基（0 = 一月，必须 +1），以及个位数需要补零——补零漏掉时
 * 文件名长度不定长、按名称排序会乱；月份错 1 则导出名与实际日期不符。
 */
export default function repoExportTest() {
  describe('buildZipName', () => {
    it('formats_two_digit_fields_and_fixed_name', 0, () => {
      // 各字段均为两位数：2024-12-31 23:59:58
      const d: Date = new Date(2024, 11, 31, 23, 59, 58);
      expect(RepoExportService.buildZipName(d)).assertEqual('pass-store-20241231-235958.zip');
    });

    it('pads_month_day_time_and_offsets_month', 0, () => {
      // getMonth 0 基 + 单位数补零：2026-01-02 03:04:05（传入 month=0 表示一月）
      const d: Date = new Date(2026, 0, 2, 3, 4, 5);
      expect(RepoExportService.buildZipName(d)).assertEqual('pass-store-20260102-030405.zip');
    });

    it('uses_same_second_for_both_suffixes', 0, () => {
      // 日期段与时间段之间以 - 分隔，且不含空格等非法文件名字符
      const d: Date = new Date(2025, 6, 15, 9, 8, 7);
      const name: string = RepoExportService.buildZipName(d);
      expect(name).assertEqual('pass-store-20250715-090807.zip');
      expect(name.includes(' ')).assertFalse();
    });
  });
}
