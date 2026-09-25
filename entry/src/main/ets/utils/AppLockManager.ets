import { SettingsRepository } from '../model/SettingsRepository';
import { SshKeyManager } from '../crypto/SshKeyManager';
import { PgpCrypto } from '../crypto/PgpCrypto';
import { BiometricHelper, BiometricDetail } from './BiometricHelper';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AppLockManager';

/**
 * 应用锁定管理器
 *
 * 维护应用锁定状态（手动锁定 / 解锁失败触发），
 * 在 EntryAbility 的 onForeground/onBackground 中调用对应方法。
 */
export class AppLockManager {
  private static instance: AppLockManager | null = null;

  /** 是否处于锁定状态 */
  private locked: boolean = false;
  /** 最近一次成功的解锁时刻（毫秒）；0 表示从未解锁 */
  private lastUnlockAt: number = 0;

  private constructor() {
  }

  static getInstance(): AppLockManager {
    if (!AppLockManager.instance) {
      AppLockManager.instance = new AppLockManager();
    }
    return AppLockManager.instance;
  }

  /**
   * 应用进入后台：清除内存中的解密私钥缓存（安全措施）
   *
   * PGP 口令缓存也必须清：它持有明文口令，只清 SSH 而留下它，
   * 等于锁上了门却把钥匙留在锁孔里——重新解锁后无需口令即可解密全部条目。
   */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground: clearing sensitive caches');
    this.clearSensitiveCaches();
  }

  /**
   * 应用回到前台：按会话超时决定是否重新上锁
   *
   * 只看 locked 标志是不够的：杀进程重进后标志复位， unlocking 状态就永久丢失，
   * 任何人拿到设备都能直接看到密码库。故改为按「距上次解锁的时长」判断。
   *
   * @returns 是否需要显示解锁页
   */
  onForeground(): boolean {
    if (!this.hasUnlockMethod()) {
      return false; // 未配置解锁方式时不拦截
    }
    if (this.locked) {
      return true;
    }
    // 从未解锁过（冷启动）也要验证
    if (this.lastUnlockAt === 0) {
      return true;
    }
    const timeoutMs: number = SettingsRepository.getInstance().getSettings().unlockSessionTimeout * 1000;
    if (timeoutMs <= 0) {
      return false; // 0 = 永不自动锁定，用户显式选择
    }
    if (Date.now() - this.lastUnlockAt >= timeoutMs) {
      hilog.info(DOMAIN, TAG, 'onForeground: session timeout, locking');
      this.lock();
      return true;
    }
    return false;
  }

  /**
   * 是否处于锁定状态
   */
  isLocked(): boolean {
    return this.locked;
  }

  /**
   * 手动上锁（如用户主动锁定）：同时清除敏感缓存
   */
  lock(): void {
    this.locked = true;
    hilog.info(DOMAIN, TAG, 'lock: clearing sensitive caches');
    this.clearSensitiveCaches();
  }

  /**
   * 清除全部内存敏感缓存
   *
   * 新增敏感缓存类型时必须在此登记，否则锁定会留下缺口。
   */
  private clearSensitiveCaches(): void {
    SshKeyManager.getInstance().clearCache();
    PgpCrypto.getInstance().lock();
  }

  /**
   * 解锁成功后调用
   *
   * 记录时刻，供 onForeground 判断是否超出会话时长。
   */
  unlock(): void {
    this.locked = false;
    this.lastUnlockAt = Date.now();
  }

  /**
   * 是否已配置可用的解锁方式
   *
   * PIN 已彻底移除，应用锁只剩生物识别一种：必须同时满足「开关打开」与
   * 「设备可用且已录入」。只看开关会把「开了生物识别但设备不支持/未录入」
   * 当成可解锁，用户会看到解锁页却无法操作。
   *
   * 同步实现：读的是内存设置缓存 + 同步的系统能力探测，onForeground（UI 就绪前
   * 触发、不能 await）也能直接用。
   */
  hasUnlockMethod(): boolean {
    if (!SettingsRepository.getInstance().getSettings().biometricUnlockEnabled) {
      return false;
    }
    const detail: BiometricDetail = BiometricHelper.getInstance().checkBiometricDetail();
    return detail.type.length > 0;
  }
}
