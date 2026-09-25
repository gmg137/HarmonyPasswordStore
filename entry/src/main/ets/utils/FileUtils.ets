/**
 * 文件操作工具类
 *
 * 封装鸿蒙文件系统操作，提供密码仓库文件管理能力。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { PgpPacketParser } from '../crypto/PgpPacketParser';

/**
 * 文件工具
 */
export class FileUtils {
  private static context: common.Context | null = null;

  /**
   * 初始化上下文（在 EntryAbility 中调用）
   */
  static init(context: common.Context): void {
    FileUtils.context = context;
  }

  /**
   * 获取应用沙箱 filesDir
   */
  static getFilesDir(): string {
    if (!FileUtils.context) {
      throw new Error('FileUtils not initialized, call init() first');
    }
    return FileUtils.context.filesDir;
  }

  /**
   * 确保目录存在，不存在则创建
   */
  static ensureDir(dirPath: string): void {
    try {
      if (!fs.accessSync(dirPath)) {
        fs.mkdirSync(dirPath, true);
      }
    } catch (e) {
      // 保留抛错契约：调用方依赖异常感知目录创建失败
      throw new Error(`ensureDir failed for ${dirPath}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
  }

  /**
   * 判断文件/目录是否存在
   */
  static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /**
   * 读取文件文本内容
   */
  static readTextFile(filePath: string): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      // 保留抛错契约：调用方依赖异常感知读取失败
      throw new Error(`readTextFile failed for ${filePath}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败不影响读取结果
        }
      }
    }
  }

  /**
   * 取文件所在目录；无目录分隔符时返回空串（调用方据此跳过 ensureDir）
   */
  private static parentDirOf(filePath: string): string {
    const lastSlash: number = filePath.lastIndexOf('/');
    return lastSlash > 0 ? filePath.substring(0, lastSlash) : '';
  }

  /**
   * 写入文本文件
   */
  static writeTextFile(filePath: string, content: string): void {
    const dir: string = FileUtils.parentDirOf(filePath);
    if (dir.length > 0) {
      FileUtils.ensureDir(dir);
    }
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
    } catch (e) {
      // 保留抛错契约：调用方依赖异常感知写入失败
      throw new Error(`writeTextFile failed for ${filePath}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败不影响写入结果
        }
      }
    }
  }

  /**
   * 读取二进制文件
   */
  static readBinaryFile(filePath: string): ArrayBuffer {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return buf;
    } catch (e) {
      // 保留抛错契约：调用方依赖异常感知读取失败
      throw new Error(`readBinaryFile failed for ${filePath}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败不影响读取结果
        }
      }
    }
  }

  /**
   * 判断文本是否已是 ASCII-armored（有 BEGIN PGP 标记）
   */
  static isArmored(text: string): boolean {
    return text.includes('-----BEGIN PGP');
  }

  /**
   * 读取 OpenPGP 数据文件并统一返回 armored 文本
   *
   * 桌面 pass/gpg 产出的 `.gpg` 是**二进制**格式（首字节为 OpenPGP 包头，最高位
   * 置位，无 BEGIN PGP 标记），而 native 加解密/收件人解析链路只吃 armored 文本。
   *
   * **必须先按二进制读取再判定**：先走 UTF-8 文本读取的话，二进制里的非法
   * 字节序列会被 TextDecoder 替换成 U+FFFD，原始字节已不可恢复，之后转 armor
   * 也是坏数据（CRC24 对不上、PKESK 解析失败）。
   *
   * 判定与转换复用 `PgpPacketParser` 的字节级逻辑（isBinaryKey / armorBinaryKey）。
   */
  static readOpenPgpAsArmored(filePath: string): string {
    const buf: ArrayBuffer = FileUtils.readBinaryFile(filePath);
    const bytes: Uint8Array = new Uint8Array(buf);
    if (bytes.length === 0) {
      return '';
    }
    const first: number = bytes[0];
    if (first === 0x2D || (first & 0x80) === 0) {
      // '-' 开头＝armored 文本；非 OpenPGP 包头＝普通文本文件：按 UTF-8 解码原样返回
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    }
    // 二进制 OpenPGP → armored（密文标签用 PGP MESSAGE；armorBinaryKey 固定给
    // PUBLIC KEY BLOCK 标签，密钥文件才用它，故在此修正）
    const armored: string = PgpPacketParser.armorBinaryKey(bytes, false);
    return armored.replace('-----BEGIN PGP PUBLIC KEY BLOCK-----', '-----BEGIN PGP MESSAGE-----')
      .replace('-----END PGP PUBLIC KEY BLOCK-----', '-----END PGP MESSAGE-----');
  }

  /**
   * 写入二进制文件
   */
  static writeBinaryFile(filePath: string, data: ArrayBuffer): void {
    const dir: string = FileUtils.parentDirOf(filePath);
    if (dir.length > 0) {
      FileUtils.ensureDir(dir);
    }
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
    } catch (e) {
      // 保留抛错契约：调用方依赖异常感知写入失败
      throw new Error(`writeBinaryFile failed for ${filePath}: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 关闭失败不影响写入结果
        }
      }
    }
  }

  /**
   * 删除文件
   */
  static deleteFile(filePath: string): boolean {
    try {
      fs.unlinkSync(filePath);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 删除目录（递归）
   *
   * fs.rmdirSync 只能删空目录，必须先递归清空子项，
   * 否则删除非空仓库目录会失败。
   */
  static deleteDir(dirPath: string): boolean {
    try {
      if (!fs.accessSync(dirPath)) {
        return true;
      }
      const entries: string[] = fs.listFileSync(dirPath);
      for (let i: number = 0; i < entries.length; i++) {
        const child: string = `${dirPath}/${entries[i]}`;
        const stat: fs.Stat = fs.statSync(child);
        if (stat.isDirectory()) {
          if (!FileUtils.deleteDir(child)) {
            return false;
          }
        } else {
          fs.unlinkSync(child);
        }
      }
      fs.rmdirSync(dirPath);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 列出目录下的文件和子目录
   */
  static listDir(dirPath: string): string[] {
    try {
      return fs.listFileSync(dirPath);
    } catch (e) {
      return [];
    }
  }

  /**
   * 判断路径是否为**目录**（statSync + isDirectory，路径不存在或出错返回 false）
   *
   * 注意不要用 `exists()` 冒充：`exists()` 对文件同样返回 true，
   * 目录选择器据此判定会把**文件**也当成可选目录（实测移动页的「目标目录」
   * 里列出了 aaaaaa.gpg/test.gpg 等条目文件，选中后移动必然失败）。
   */
  static isDirectory(path: string): boolean {
    try {
      return fs.statSync(path).isDirectory();
    } catch (e) {
      return false;
    }
  }

  /**
   * 重命名/移动文件
   */
  static rename(oldPath: string, newPath: string): boolean {
    try {
      fs.renameSync(oldPath, newPath);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 获取文件最后修改时间
   */
  static getLastModified(filePath: string): number {
    try {
      const stat: fs.Stat = fs.statSync(filePath);
      return stat.mtime;
    } catch (e) {
      return 0;
    }
  }

  // ========== 路径安全 ==========

  /**
   * 校验相对路径是否可用于拼接（不含向上穿越、绝对路径、非法字符）
   *
   * 条目名与目录名有两个来源：用户输入，以及 git 同步下来的仓库内容（攻击者可控）。
   * 未校验时 `../` 可让读写删除逃出仓库根，递归删除可清空 pgp_keys / ssh_keys。
   */
  static isSafeRelativePath(relativePath: string): boolean {
    if (relativePath.length === 0) {
      return true; // 空路径表示仓库根，合法
    }
    // 绝对路径、Windows 分隔符、NUL 一律拒绝
    if (relativePath.startsWith('/') || relativePath.includes('\\') || relativePath.includes('\0')) {
      return false;
    }
    const segments: string[] = relativePath.split('/');
    for (let i: number = 0; i < segments.length; i++) {
      const seg: string = segments[i];
      // 空段（"a//b"）、当前目录、上级目录、点开头（.git / .gpg-id 等内部文件）
      if (seg.length === 0 || seg === '.' || seg === '..' || seg.startsWith('.')) {
        return false;
      }
    }
    return true;
  }

  /**
   * 将相对路径安全拼接到基目录下
   *
   * 先做词法校验（拒绝 `..`、绝对路径、`.` 开头段），再逐段用 lstat 拒绝符号链接——
   * 因为鸿蒙 fileIo 无 realpath，符号链接只能靠逐段判定拦下。
   *
   * @param basePath 基目录（必须是受信任的仓库根或沙箱目录）
   * @param relativePath 相对路径，可能来自用户输入或远端仓库
   * @returns 拼接后的绝对路径
   * @throws 路径不合法或穿越出基目录时抛错
   */
  static safeJoin(basePath: string, relativePath: string): string {
    if (!FileUtils.isSafeRelativePath(relativePath)) {
      throw new Error(`unsafe relative path: ${relativePath}`);
    }
    if (relativePath.length === 0) {
      return basePath;
    }
    // 基目录自身不能是符号链接，否则解析会跳出受控范围
    FileUtils.assertNotSymlink(basePath, basePath);

    const segments: string[] = relativePath.split('/');
    let current: string = basePath;
    for (let i: number = 0; i < segments.length; i++) {
      current = `${current}/${segments[i]}`;
      // 末段允许不存在（新建条目/目录）；已存在的任何一段都不得是符号链接
      const isLast: boolean = i === segments.length - 1;
      FileUtils.assertNotSymlink(current, current, isLast);
    }
    return current;
  }

  /**
   * 判定路径不是符号链接
   * @param allowMissing true 时路径不存在视为通过（用于新建目标）
   */
  private static assertNotSymlink(path: string, displayPath: string, allowMissing: boolean = false): void {
    try {
      const stat: fs.Stat = fs.lstatSync(path);
      if (stat.isSymbolicLink()) {
        throw new Error(`refusing symlink in path: ${displayPath}`);
      }
    } catch (e) {
      if (e instanceof Error && e.message.startsWith('refusing symlink')) {
        throw e;
      }
      if (!allowMissing) {
        throw new Error(`cannot stat path segment: ${displayPath}`);
      }
    }
  }
}
