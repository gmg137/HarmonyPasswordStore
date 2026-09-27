import { FileUtils } from '../utils/FileUtils';
import { SettingsRepository } from './SettingsRepository';
import { PasswordFileParser } from '../format/PasswordFileParser';
import { PgpPacketParser } from '../crypto/PgpPacketParser';
import { PasswordFileFormat } from '../common/Constants';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  GPG_FILE_EXT,
  GPG_ID_FILE,
} from '../common/Constants';
import { PasswordEntry, PasswordContent } from './PasswordEntry';
import { Strings } from '../common/Strings';

const DOMAIN = 0x0001;
const TAG = 'PasswordRepository';

/**
 * 密码仓库操作结果
 */
export interface RepoResult<T> {
  success: boolean;
  data: T | null;
  error: string;
}

/**
 * 密码仓库 Repository
 *
 * 负责 pass 仓库的文件系统操作：
 * - 目录浏览（列出文件和子目录）
 * - 密码文件 CRUD（创建/读取/更新/删除）
 * - 目录管理（创建/删除目录）
 * - .gpg-id 密钥选择管理
 *
 * 加解密通过外部注入的回调完成，本类不直接依赖 PgpCrypto，
 * 以便在 native PGP 库就绪前可独立测试文件操作。
 */
export class PasswordRepository {
  private static instance: PasswordRepository | null = null;

  /** 加密回调（由外部注入，PgpCrypto 就绪后设置） */
  private encryptFn: ((plaintext: string, keyFingerprints: string[]) => Promise<string>) | null = null;
  /**
   * 解密回调
   * @param ciphertext armored 密文
   * @param candidateFingerprints 该条目所属 .gpg-id 指定的候选密钥指纹
   *        （每条密码由各自目录的密钥加密，必须按密钥逐一尝试，不能张冠李戴）
   */
  private decryptFn: ((ciphertext: string, candidateFingerprints: string[]) => Promise<string>) | null = null;

  private constructor() {
  }

  static getInstance(): PasswordRepository {
    if (!PasswordRepository.instance) {
      PasswordRepository.instance = new PasswordRepository();
    }
    return PasswordRepository.instance;
  }

  /**
   * 设置加解密回调
   * 在 PgpCrypto native 库就绪后调用。
   */
  setCryptoCallbacks(
    encryptFn: (plaintext: string, keyFingerprints: string[]) => Promise<string>,
    decryptFn: (ciphertext: string, candidateFingerprints: string[]) => Promise<string>,
  ): void {
    this.encryptFn = encryptFn;
    this.decryptFn = decryptFn;
  }

  /**
   * 检查加解密是否可用
   */
  isCryptoAvailable(): boolean {
    return this.encryptFn !== null && this.decryptFn !== null;
  }

  // ========== 仓库初始化 ==========

  /**
   * 初始化密码仓库目录
   */
  initStore(): RepoResult<string> {
    const storePath: string = this.getStorePath();
    try {
      FileUtils.ensureDir(storePath);
      return { success: true, data: storePath, error: '' };
    } catch (e) {
      return { success: false, data: null, error: `Failed to init store: ${JSON.stringify(e)}` };
    }
  }

  /**
   * 获取仓库根目录路径
   */
  getStorePath(): string {
    return SettingsRepository.getInstance().getStorePath();
  }

  /**
   * 检查仓库是否已初始化
   */
  isStoreInitialized(): boolean {
    return FileUtils.exists(this.getStorePath());
  }

  // ========== 目录浏览 ==========

  /**
   * 列出指定目录下的密码条目
   * @param relativeDir 相对目录路径（空字符串表示根目录）
   * @returns 条目列表（文件和子目录，按名称排序）
   */
  listEntries(relativeDir: string): RepoResult<PasswordEntry[]> {
    const basePath: string = this.getStorePath();
    let dirPath: string;
    try {
      dirPath = FileUtils.safeJoin(basePath, relativeDir);
    } catch (e) {
      return { success: false, data: [], error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }

    if (!FileUtils.exists(dirPath)) {
      return { success: false, data: [], error: 'Directory not found' };
    }

    const names: string[] = FileUtils.listDir(dirPath);
    const entries: PasswordEntry[] = [];

    for (const name of names) {
      // 跳过 .gpg-id 和隐藏文件；跳过含路径分隔符/穿越片段的异常文件名
      // （文件名来自 git 同步下来的仓库，攻击者可控，必须当作不可信输入）
      if (name.startsWith('.') || !FileUtils.isSafeRelativePath(name)) continue;

      const fullPath: string = `${dirPath}/${name}`;
      const isDir: boolean = this.isDirectory(fullPath);

      // 构建相对路径（不含 .gpg 扩展名）
      let relativePath: string;
      let displayName: string;

      if (isDir) {
        relativePath = relativeDir.length > 0 ? `${relativeDir}/${name}` : name;
        displayName = name;
      } else {
        // 文件：去掉 .gpg 扩展名
        const nameWithoutExt: string = name.endsWith(GPG_FILE_EXT)
          ? name.substring(0, name.length - GPG_FILE_EXT.length)
          : name;
        relativePath = relativeDir.length > 0 ? `${relativeDir}/${nameWithoutExt}` : nameWithoutExt;
        displayName = nameWithoutExt;
      }

      // 目录：统计真实子项数（密码 + 子目录，排除 .gpg-id 等隐藏文件）
      let childEntries: PasswordEntry[] = [];
      if (isDir) {
        const childNames: string[] = FileUtils.listDir(fullPath);
        for (const childName of childNames) {
          if (childName.startsWith('.') || !FileUtils.isSafeRelativePath(childName)) continue;
          const childPath: string = `${fullPath}/${childName}`;
          const childIsDir: boolean = this.isDirectory(childPath);
          childEntries.push({
            relativePath: childIsDir
              ? (relativeDir.length > 0 ? `${relativeDir}/${name}/${childName}` : `${name}/${childName}`)
              : (relativeDir.length > 0
                ? `${relativeDir}/${name}/${childName.substring(0, childName.length - GPG_FILE_EXT.length)}`
                : `${name}/${childName.substring(0, childName.length - GPG_FILE_EXT.length)}`),
            fullPath: childPath,
            name: childName,
            parentDir: relativeDir.length > 0 ? `${relativeDir}/${name}` : name,
            isDirectory: childIsDir,
            children: [],
            lastModified: 0,
            lastUsed: 0,
          });
        }
      }

      entries.push({
        relativePath: relativePath,
        fullPath: fullPath,
        name: displayName,
        parentDir: relativeDir,
        isDirectory: isDir,
        children: childEntries,
        lastModified: FileUtils.getLastModified(fullPath),
        lastUsed: 0,
      });
    }

    // 排序：目录在前，然后按名称字母序
    entries.sort((a: PasswordEntry, b: PasswordEntry) => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });

    return { success: true, data: entries, error: '' };
  }

  /**
   * 递归搜索所有密码文件
   * @param keyword 搜索关键词
   * @returns 匹配的条目列表
   */
  searchEntries(keyword: string, isExact: boolean = false): RepoResult<PasswordEntry[]> {
    const results: PasswordEntry[] = [];
    const lowerKeyword: string = keyword.toLowerCase();
    this.searchRecursive('', lowerKeyword, isExact, results);
    return { success: true, data: results, error: '' };
  }

  /**
   * 递归搜索辅助方法
   * @param isExact true = 精确匹配（条目名全等），false = 模糊匹配（包含）
   */
  private searchRecursive(relativeDir: string, keyword: string, isExact: boolean, results: PasswordEntry[]): void {
    const result: RepoResult<PasswordEntry[]> = this.listEntries(relativeDir);
    if (!result.success || !result.data) return;

    for (const entry of result.data) {
      if (entry.isDirectory) {
        this.searchRecursive(entry.relativePath, keyword, isExact, results);
      } else {
        if (keyword.length === 0) {
          results.push(entry);
          continue;
        }
        // 精确匹配比对条目名（末段），模糊匹配比对完整相对路径
        const target: string = isExact
          ? entry.name.toLowerCase()
          : entry.relativePath.toLowerCase();
        if (isExact ? target === keyword : target.includes(keyword)) {
          results.push(entry);
        }
      }
    }
  }

  // ========== 密码文件 CRUD ==========

  /**
   * 读取密码文件（解密）
   * @param relativePath 相对路径（不含 .gpg 扩展名）
   * @returns 解密后的密码内容
   */
  async readPassword(relativePath: string): Promise<RepoResult<PasswordContent>> {
    let filePath: string;
    try {
      filePath = this.getFullPath(relativePath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }

    if (!FileUtils.exists(filePath)) {
      return { success: false, data: null, error: 'Password file not found' };
    }

    if (!this.isCryptoAvailable()) {
      return { success: false, data: null, error: 'PGP crypto not available' };
    }

    try {
      // 二进制 .gpg（桌面 pass/gpg 产出）自动转 armored；native 链路只吃 armored 文本
      const ciphertext: string = FileUtils.readOpenPgpAsArmored(filePath);
      // 该条目所属目录 .gpg-id 指定的密钥即首选候选（每条密码由各自密钥加密）
      const candidateFingerprints: string[] = this.getGpgIdForPath(relativePath);
      const plaintext: string = await this.decryptFn!(ciphertext, candidateFingerprints);
      const content: PasswordContent = PasswordFileParser.parse(plaintext);
      return { success: true, data: content, error: '' };
    } catch (e) {
      const errMsg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e) + ` (code=${(e as Record<string, number>)?.code ?? 'n/a'})`;
      hilog.error(DOMAIN, TAG, 'readPassword failed for %{public}s: %{public}s', relativePath, errMsg);
      return { success: false, data: null, error: `Failed to read password: ${errMsg}` };
    }
  }

  /**
   * 读取条目的**原始密文**（不解密），统一转成 armored 文本
   *
   * 用途：解析密文的收件人 Key ID，从而判断该条目实际由哪把密钥加密
   * （换过 .gpg-id 后 .gpg-id 会指向别的密钥，只有密文才是权威依据）。
   * 读取失败返回空串，调用方退回 .gpg-id 逻辑。
   */
  readCiphertext(relativePath: string): string {
    try {
      // 二进制 .gpg（桌面 pass/gpg 产出）自动转 armored；见 readOpenPgpAsArmored
      return FileUtils.readOpenPgpAsArmored(this.getFullPath(relativePath));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'readCiphertext failed for %{public}s', relativePath);
      return '';
    }
  }

  /**
   * 按「密码文件格式」设置落盘密文
   *
   * `armor`：写 armored 文本（历史行为）；`bin`：解 armor 后写**二进制**
   * （与桌面 pass 输出一致）。加密侧一律产出 armored，转换只在这一处做，
   * 新建/编辑、移动重加密、换目录密钥三条写路径共用。
   *
   * 解 armor 失败（CRC 不符/格式异常）时**退回写文本**并记日志：宁可格式与设置
   * 不符，也不能把内容写坏或丢掉。
   */
  private writeCiphertextByFormat(filePath: string, ciphertext: string): void {
    const format: PasswordFileFormat =
      SettingsRepository.getInstance().getSettings().passwordFileFormat;
    if (format === PasswordFileFormat.BIN) {
      const bytes: Uint8Array | null = PgpPacketParser.dearmor(ciphertext);
      if (bytes !== null) {
        // 只写视图覆盖的字节（buffer 可能比视图大）
        FileUtils.writeBinaryFile(filePath,
          bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
        return;
      }
      hilog.warn(DOMAIN, TAG, 'writeCiphertextByFormat: dearmor failed, falling back to armored text');
    }
    FileUtils.writeTextFile(filePath, ciphertext);
  }

  /**
   * 把**已经加密好的**密文写到指定路径，必要时创建父目录
   *
   * 供「移动并按目标目录密钥重加密」使用：先写新位置、再删旧文件，中途失败不丢数据。
   * 不能直接用 `overwriteCiphertext`——它只调 `writeTextFile`，而 `getFullPath`
   * 走的 `safeJoin` 要求**中间路径段已存在**（只允许末段缺失），跨目录写入会失败。
   */
  writeCiphertextAt(relativePath: string, ciphertext: string): RepoResult<void> {
    try {
      const lastSlash: number = relativePath.lastIndexOf('/');
      if (lastSlash > 0) {
        FileUtils.ensureDir(this.getFullDirPath(relativePath.substring(0, lastSlash)));
      }
      this.writeCiphertextByFormat(this.getFullPath(relativePath), ciphertext);
      return { success: true, data: null, error: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'writeCiphertextAt failed for %{public}s: %{public}s', relativePath, msg);
      return { success: false, data: null, error: msg };
    }
  }

  /**
   * 用给定密文覆盖条目文件（重加密用）
   *
   * 与 `writePassword` 的区别：这里写入的是**已经加密好的密文**（重加密时由
   * `PgpCrypto.encrypt` 产出），不再走一遍加密与 `.gpg-id` 解析。
   * 仍走 `getFullPath`（内含 `safeJoin` 路径校验），失败返回错误而非抛出。
   */
  overwriteCiphertext(relativePath: string, ciphertext: string): RepoResult<void> {
    try {
      this.writeCiphertextByFormat(this.getFullPath(relativePath), ciphertext);
      return { success: true, data: null, error: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'overwriteCiphertext failed for %{public}s: %{public}s',
        relativePath, msg);
      return { success: false, data: null, error: msg };
    }
  }

  /**
   * 创建/更新密码文件（加密写入）
   * @param relativePath 相对路径（不含 .gpg 扩展名）
   * @param content 明文内容
   * @returns 操作结果
   */
  async writePassword(relativePath: string, content: string): Promise<RepoResult<void>> {
    let filePath: string;
    try {
      filePath = this.getFullPath(relativePath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }

    if (!this.isCryptoAvailable()) {
      return { success: false, data: null, error: 'PGP crypto not available' };
    }

    try {
      // 获取该目录的加密密钥
      const keyFingerprints: string[] = this.getGpgIdForPath(relativePath);
      if (keyFingerprints.length === 0) {
        return { success: false, data: null, error: 'No PGP key selected for this directory' };
      }

      const ciphertext: string = await this.encryptFn!(content, keyFingerprints);
      // 确保父目录存在：名称带新目录前缀（如 "web/github"）时目录尚未创建，
      // 直接写入会抛异常导致 "Failed to write password"。
      // 走 getFullDirPath 而非裸拼，避免父目录段落逃出仓库根。
      const lastSlash: number = relativePath.lastIndexOf('/');
      if (lastSlash > 0) {
        FileUtils.ensureDir(this.getFullDirPath(relativePath.substring(0, lastSlash)));
      }
      this.writeCiphertextByFormat(filePath, ciphertext);
      return { success: true, data: null, error: '' };
    } catch (e) {
      // 注意：JSON.stringify(Error) 恒为 "{}"，必须提取 message 才能看到真实错误
      const msg: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'writePassword failed: %{public}s', msg);
      return { success: false, data: null, error: `Failed to write password: ${msg}` };
    }
  }

  /**
   * 删除密码文件
   * @param relativePath 相对路径（不含 .gpg 扩展名）
   */
  deletePassword(relativePath: string): RepoResult<void> {
    let filePath: string;
    try {
      filePath = this.getFullPath(relativePath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }
    const success: boolean = FileUtils.deleteFile(filePath);
    if (!success) {
      return { success, data: null, error: 'Failed to delete file' };
    }
    // 删除后级联清理空目录分组（向上逐级，直到仓库根）
    this.pruneEmptyParentDirs(relativePath);
    return { success, data: null, error: '' };
  }

  /**
   * 向上清理空目录：密码删除后若其所在目录分组为空，自动删除该目录（逐级向上）
   * @param relativePath 已删除文件的相对路径
   */
  private pruneEmptyParentDirs(relativePath: string): void {
    const basePath: string = this.getStorePath();
    let dir: string = relativePath.includes('/')
      ? relativePath.substring(0, relativePath.lastIndexOf('/'))
      : '';
    while (dir.length > 0) {
      let dirPath: string;
      try {
        dirPath = FileUtils.safeJoin(basePath, dir);
      } catch (e) {
        return; // 路径不合法时不再向上清理，避免越出仓库根
      }
      if (!FileUtils.exists(dirPath)) {
        break;
      }
      if (FileUtils.listDir(dirPath).length > 0) {
        break; // 目录非空，停止清理
      }
      FileUtils.deleteDir(dirPath);
      hilog.info(DOMAIN, TAG, 'pruned empty dir: %{public}s', dir);
      const lastSlash: number = dir.lastIndexOf('/');
      dir = lastSlash >= 0 ? dir.substring(0, lastSlash) : '';
    }
  }

  /**
   * 重命名/移动密码文件（加密内容不变，仅文件系统层移动 .gpg 文件）
   * @param oldPath 旧相对路径（不含 .gpg 扩展名）
   * @param newPath 新相对路径（不含 .gpg 扩展名）
   */
  renamePassword(oldPath: string, newPath: string): RepoResult<void> {
    let oldFullPath: string;
    let newFullPath: string;
    try {
      oldFullPath = this.getFullPath(oldPath);
      newFullPath = this.getFullPath(newPath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }
    if (!FileUtils.exists(oldFullPath)) {
      return { success: false, data: null, error: Strings.get('repo_src_entry_missing') };
    }
    if (oldPath === newPath) {
      return { success: true, data: null, error: '' };
    }
    if (FileUtils.exists(newFullPath)) {
      return { success: false, data: null, error: Strings.get('repo_dst_entry_exists') };
    }

    // 确保目标目录存在（跨目录移动时目标目录可能尚未创建）
    const newDir: string = newPath.includes('/')
      ? newPath.substring(0, newPath.lastIndexOf('/'))
      : '';
    if (newDir.length > 0) {
      try {
        FileUtils.ensureDir(this.getFullDirPath(newDir));
      } catch (e) {
        return { success: false, data: null, error: `Invalid target path: ${e instanceof Error ? e.message : String(e)}` };
      }
    }

    const success: boolean = FileUtils.rename(oldFullPath, newFullPath);
    if (!success) {
      return { success, data: null, error: Strings.get('repo_rename_failed') };
    }
    // 移走后源目录若为空则级联清理
    this.pruneEmptyParentDirs(oldPath);
    hilog.info(DOMAIN, TAG, 'renamed %{public}s -> %{public}s', oldPath, newPath);
    return { success: true, data: null, error: '' };
  }

  // ========== 目录管理 ==========

  /**
   * 创建目录
   * @param relativePath 相对路径
   */
  createDirectory(relativePath: string): RepoResult<void> {
    try {
      const dirPath: string = this.getFullDirPath(relativePath);
      FileUtils.ensureDir(dirPath);
      return { success: true, data: null, error: '' };
    } catch (e) {
      return { success: false, data: null, error: `Failed to create directory: ${e instanceof Error ? e.message : String(e)}` };
    }
  }

  /**
   * 删除目录
   * @param relativePath 相对路径
   */
  deleteDirectory(relativePath: string): RepoResult<void> {
    let dirPath: string;
    try {
      dirPath = this.getFullDirPath(relativePath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }
    const success: boolean = FileUtils.deleteDir(dirPath);
    return { success, data: null, error: success ? '' : 'Failed to delete directory' };
  }

  /**
   * 重命名/移动目录（fs.renameSync 对目录同样适用，目录内 .gpg 文件整体随迁）
   * @param oldPath 旧相对目录路径
   * @param newPath 新相对目录路径
   */
  renameDirectory(oldPath: string, newPath: string): RepoResult<void> {
    let oldDirPath: string;
    let newDirPath: string;
    try {
      oldDirPath = this.getFullDirPath(oldPath);
      newDirPath = this.getFullDirPath(newPath);
    } catch (e) {
      return { success: false, data: null, error: `Invalid path: ${e instanceof Error ? e.message : String(e)}` };
    }
    if (!FileUtils.exists(oldDirPath)) {
      return { success: false, data: null, error: Strings.get('repo_src_dir_missing') };
    }
    if (oldPath === newPath) {
      return { success: true, data: null, error: '' };
    }
    if (FileUtils.exists(newDirPath)) {
      return { success: false, data: null, error: Strings.get('repo_dst_dir_exists') };
    }
    // 目标父目录可能不存在
    const newParent: string = newPath.includes('/')
      ? newPath.substring(0, newPath.lastIndexOf('/'))
      : '';
    if (newParent.length > 0) {
      try {
        FileUtils.ensureDir(this.getFullDirPath(newParent));
      } catch (e) {
        return { success: false, data: null, error: `Invalid target path: ${e instanceof Error ? e.message : String(e)}` };
      }
    }

    const success: boolean = FileUtils.rename(oldDirPath, newDirPath);
    if (!success) {
      return { success, data: null, error: Strings.get('repo_dir_rename_failed') };
    }
    // 随迁的子目录级 .gpg-id 不受影响（相对路径内文件未动）
    hilog.info(DOMAIN, TAG, 'renamed dir %{public}s -> %{public}s', oldPath, newPath);
    return { success: true, data: null, error: '' };
  }

  // ========== .gpg-id 密钥选择 ==========

  /**
   * 获取指定路径对应的 .gpg-id（向上查找最近的 .gpg-id 文件）
   * @param relativePath 相对路径
   * @returns 密钥指纹列表
   */
  getGpgIdForPath(relativePath: string): string[] {
    const basePath: string = this.getStorePath();

    // 从目标路径向上查找 .gpg-id。safeJoin 失败（路径来自远端仓库，可能不合法）
    // 时退化为从仓库根查找，绝不拼出越界路径。
    let dir: string = basePath;
    if (relativePath.length > 0) {
      try {
        dir = FileUtils.safeJoin(basePath, relativePath);
      } catch (e) {
        dir = basePath;
      }
    }

    // 如果是文件路径，取其目录
    if (!this.isDirectory(dir)) {
      const lastSlash: number = dir.lastIndexOf('/');
      dir = lastSlash >= basePath.length ? dir.substring(0, lastSlash) : basePath;
    }

    // 逐级向上查找
    while (dir.startsWith(basePath)) {
      const gpgIdPath: string = `${dir}/${GPG_ID_FILE}`;
      if (FileUtils.exists(gpgIdPath)) {
        const content: string = FileUtils.readTextFile(gpgIdPath);
        return content.split('\n')
          .map((s: string) => PasswordRepository.parseGpgIdLine(s))
          .filter((s: string) => s.length > 0);
      }
      // 上级目录
      const lastSlash: number = dir.lastIndexOf('/');
      if (lastSlash <= basePath.length - 1) break;
      dir = dir.substring(0, lastSlash);
    }

    return [];
  }

  /**
   * 查找管辖该路径的 .gpg-id 所在目录（相对路径，根目录返回 ''）
   * 与 getGpgIdForPath 使用相同的向上遍历规则，供修复 .gpg-id 时定位写回位置
   * @param relativePath 相对路径（文件或目录）
   */
  findGpgIdDir(relativePath: string): string {
    const basePath: string = this.getStorePath();

    let dir: string = basePath;
    if (relativePath.length > 0) {
      try {
        dir = FileUtils.safeJoin(basePath, relativePath);
      } catch (e) {
        dir = basePath;
      }
    }

    if (!this.isDirectory(dir)) {
      const lastSlash: number = dir.lastIndexOf('/');
      dir = lastSlash >= basePath.length ? dir.substring(0, lastSlash) : basePath;
    }

    while (dir.startsWith(basePath)) {
      if (FileUtils.exists(`${dir}/${GPG_ID_FILE}`)) {
        return dir === basePath ? '' : dir.substring(basePath.length + 1);
      }
      const lastSlash: number = dir.lastIndexOf('/');
      if (lastSlash <= basePath.length - 1) break;
      dir = dir.substring(0, lastSlash);
    }

    return '';
  }

  /**
   * 解析 `.gpg-id` 的一行，返回纯密钥标识（无内容时返回空串）
   *
   * 兼容 `pass` 的写法：`pass` 把每行原样交给 gpg 作接收方参数，因此实际仓库里常见
   * - **行尾注释**：`ABCD… # 备用密钥`
   * - **强制子密钥标记**：`ABCD…!`（告诉 gpg 就用这把、不要自动选子密钥）
   * 不剥离这两者会把它们当成标识的一部分，导致解析不到密钥（agrahn fork 同样剥离）。
   */
  private static parseGpgIdLine(raw: string): string {
    let s: string = raw.trim();
    if (s.length === 0 || s.startsWith('#')) {
      return '';
    }
    // 注释与强制标记都截断（指纹/KeyID 本身不含 '#' 与 '!'）
    const hashAt: number = s.indexOf('#');
    if (hashAt >= 0) {
      s = s.substring(0, hashAt).trim();
    }
    const bangAt: number = s.indexOf('!');
    if (bangAt >= 0) {
      s = s.substring(0, bangAt).trim();
    }
    return s;
  }

  /**
   * 设置目录的 .gpg-id
   * @param relativeDir 相对目录路径
   * @param keyFingerprints 密钥指纹列表
   */
  setGpgIdForDir(relativeDir: string, keyFingerprints: string[]): RepoResult<void> {
    try {
      const dirPath: string = this.getFullDirPath(relativeDir);
      FileUtils.ensureDir(dirPath);
      const gpgIdPath: string = `${dirPath}/${GPG_ID_FILE}`;
      // 每行以换行结尾，与 `pass init` 的 `printf "%s\n"` 保持一致
      // （缺末尾换行时 pass 仍能读，但 git diff 会与桌面端写法不一致）
      FileUtils.writeTextFile(gpgIdPath, keyFingerprints.join('\n') + '\n');
      return { success: true, data: null, error: '' };
    } catch (e) {
      return { success: false, data: null, error: `Failed to set .gpg-id: ${e instanceof Error ? e.message : String(e)}` };
    }
  }

  // ========== 辅助方法 ==========

  /**
   * 判断指定相对路径是否存在同名目录（用于创建密码时与目录名冲突校验）
   */
  directoryExists(relativePath: string): boolean {
    try {
      return this.isDirectory(this.getFullDirPath(relativePath));
    } catch (e) {
      return false; // 路径不合法视为不存在，避免越界探测
    }
  }

  /**
   * safeJoin 的统一包装
   *
   * `FileUtils.safeJoin` 遇到 `../`、绝对路径或符号链接会抛异常（这是它的安全契约）。
   * 这里显式捕获并转成带上下文的错误，既满足 ArkTS「函数可能抛异常需特殊处理」的检查，
   * 也让日志能区分是哪条路径被拒。
   */
  private safeJoinOrThrow(basePath: string, relativePath: string): string {
    try {
      return FileUtils.safeJoin(basePath, relativePath);
    } catch (e) {
      const reason: string = e instanceof Error ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'safeJoin rejected "%{public}s": %{public}s', relativePath, reason);
      throw new Error(Strings.fmt('repo_invalid_path', relativePath, reason));
    }
  }

  /**
   * 获取密码文件的完整路径
   *
   * 经 safeJoin 校验：拒绝 `../`、绝对路径与符号链接，防止读写逃出仓库根。
   */
  private getFullPath(relativePath: string): string {
    // safeJoin 对非法路径会 throw（这是它的契约），此处显式转成业务错误
    return `${this.safeJoinOrThrow(this.getStorePath(), relativePath)}${GPG_FILE_EXT}`;
  }

  /**
   * 获取目录的完整路径（同样经 safeJoin 校验）
   */
  private getFullDirPath(relativePath: string): string {
    return this.safeJoinOrThrow(this.getStorePath(), relativePath);
  }

  /**
   * 判断路径是否为目录
   */
  private isDirectory(path: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isDirectory();
    } catch (e) {
      return false;
    }
  }
}
