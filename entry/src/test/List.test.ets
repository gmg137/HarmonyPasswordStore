import { parserTest } from './PasswordFileParser.test';
import { generatorTest } from './PasswordGenerator.test';
import { matcherTest } from './CredentialMatcher.test';
import { pathSafetyTest } from './PathSafety.test';
import { pgpPacketParserTest } from './PgpPacketParser.test';
import { repoExportTest } from './RepoExport.test';

/**
 * 本地单元测试入口
 *
 * 汇总全部测试套件，由 hypium 框架在 LocalUnit 测试任务中执行。
 *
 * 注意：没有自动发现机制，新增测试文件必须在此登记，否则静默不执行。
 */
export default function testsuite() {
  parserTest();
  generatorTest();
  matcherTest();
  pathSafetyTest();
  pgpPacketParserTest();
  repoExportTest();
}
