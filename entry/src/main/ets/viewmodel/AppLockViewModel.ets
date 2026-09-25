import { BiometricHelper, BiometricDetail } from '../utils/BiometricHelper';
import { AppLockManager } from '../utils/AppLockManager';
import { SettingsRepository } from '../model/SettingsRepository';
import { RouteManager } from '../common/RouteManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'AppLockVM';

/**
 * 应用解锁视图模型
 *
 * PIN 已彻底移除，解锁方式只有生物识别：进入锁屏页即自动拉起系统认证，
 * 用户取消/失败后可以点按钮重试。失败次数与锁定由系统侧负责，
 * 应用不再自己做失败计数与倒计时（PIN 时代的防爆破逻辑随 PIN 一并移除）。
 */
@ObservedV2
export class AppLockViewModel {
  /** 生物识别类型描述（指纹/面容），空表示不可用 */
  @Trace biometricType: string = '';
  /** 生物识别不可用时的友好原因（空表示可用） */
  @Trace biometricReason: string = '';
  /** 生物识别开关是否开启 */
  @Trace biometricEnabled: boolean = false;
  /** 错误提示 */
  @Trace errorMessage: string = '';
  /** 是否正在认证 */
  @Trace isVerifying: boolean = false;

  /** 本次锁屏是否已自动拉起过生物识别（避免重复弹系统框） */
  private autoPrompted: boolean = false;

  private biometric: BiometricHelper = BiometricHelper.getInstance();
  private appLock: AppLockManager = AppLockManager.getInstance();

  /**
   * 初始化：读取生物识别开关与设备能力，并自动发起认证
   */
  async init(): Promise<void> {
    const settings = SettingsRepository.getInstance().getSettings();
    this.biometricEnabled = settings.biometricUnlockEnabled;
    const detail: BiometricDetail = this.biometric.checkBiometricDetail();
    this.biometricType = detail.type;
    this.biometricReason = detail.reason;
    this.errorMessage = '';
    this.autoPromptBiometric();
  }

  /**
   * 是否有可用解锁方式
   */
  hasUnlockMethod(): boolean {
    return this.biometricEnabled && this.biometricType.length > 0;
  }

  /**
   * 自动拉起系统生物识别认证
   *
   * 已开启生物识别时，锁屏页出现就该直接弹系统认证框——否则真机上的体验是
   * 「回到前台只看到解锁页」，用户会以为生物识别解锁没生效（还得再点一下按钮）。
   * 只自动拉一次：用户取消后不重复弹，避免连环弹窗。
   */
  private autoPromptBiometric(): void {
    if (this.autoPrompted) {
      return;
    }
    if (!this.hasUnlockMethod()) {
      return;
    }
    this.autoPrompted = true;
    hilog.info(DOMAIN, TAG, 'auto prompt biometric (%{public}s)', this.biometricType);
    this.authenticateBiometric();
  }

  /**
   * 发起生物识别认证（用户点按钮重试时也走这里）
   */
  async authenticateBiometric(): Promise<void> {
    if (!this.hasUnlockMethod()) {
      this.errorMessage = this.biometricReason;
      return;
    }
    if (this.isVerifying) {
      return;
    }

    this.errorMessage = '';
    this.isVerifying = true;
    const result = await this.biometric.authenticate();
    this.isVerifying = false;
    if (result.success) {
      this.onUnlockSuccess();
    } else {
      this.errorMessage = result.error;
    }
  }

  /**
   * 解锁成功处理
   */
  private onUnlockSuccess(): void {
    this.appLock.unlock();
    hilog.info(DOMAIN, TAG, 'unlock succeeded');
    // 解锁页只是临时覆盖层，pop 回列表页
    RouteManager.getInstance().pop();
  }
}
