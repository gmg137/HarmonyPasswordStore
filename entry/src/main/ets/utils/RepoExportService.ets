import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 仓库导出服务
 *
 * 把本地密码仓库目录打包为 zip，供「仓库管理 → 导出仓库」经系统保存对话框
 * 写到用户选定的位置。三步拆开放在这里：
 * - `buildZipName`：导出文件名（纯函数，可单测）；
 * - `zipDir`：目录压缩（zlib 只认应用沙箱路径，写不了保存对话框返回的 URI，
 *   所以产物必须先落在沙箱内的临时文件）；
 * - `copyFileToUri`：把临时压缩包按 fd 复制到用户选定的目标（保存对话框
 *   返回的是 file:// URI，先 openSync 成 fd 再按 fd 复制，覆盖写）。
 */
export class RepoExportService {
  /**
   * 导出文件名：`pass-store-YYYYMMDD-HHMMSS.zip`
   *
   * 时间取调用方传入时刻的**本地时间**，月/日/时/分/秒两位补零。
   * 注意 `getMonth()` 是 0 基（0 = 一月），必须 +1。
   */
  static buildZipName(now: Date): string {
    const p2 = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `pass-store-${now.getFullYear()}${p2(now.getMonth() + 1)}${p2(now.getDate())}-` +
      `${p2(now.getHours())}${p2(now.getMinutes())}${p2(now.getSeconds())}.zip`;
  }

  /**
   * 把目录压缩为 zip
   *
   * `keepTopLevelFolder: true` 让压缩包顶层保留源目录名本身（解压得到
   * `password-store/` 一个目录，而不是把 `.gpg-id`、条目文件散落一地）。
   * 默认 false 是「只装目录内容」，那是 API 26 之前唯一的行为。
   */
  static async zipDir(sourceDir: string, destZip: string): Promise<void> {
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
      keepTopLevelFolder: true,
    };
    await zlib.compressFile(sourceDir, destZip, options);
  }

  /**
   * 把临时压缩包复制到保存对话框返回的目标 URI
   *
   * 打开 URI 时 TRUNC 覆盖写（用户选了已存在的同名文件时不留旧内容尾部）；
   * 无论复制成败都要关闭 fd，避免句柄泄漏。
   */
  static copyFileToUri(tempZip: string, targetUri: string): void {
    const file: fs.File = fs.openSync(targetUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.copyFileSync(tempZip, file.fd);
    } finally {
      fs.closeSync(file);
    }
  }
}
