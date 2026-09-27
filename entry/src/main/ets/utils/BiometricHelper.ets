import { userAuth } from '@kit.UserAuthenticationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Strings } from '../common/Strings';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'BiometricHelper';

/**
 * 生物识别认证结果
 */
export interface BiometricResult {
  success: boolean;
  error: string;
}

/**
 * 生物识别详细状态
 */
export interface BiometricDetail {
  /** 支持的类型描述（指纹/面容），不可用时为空 */
  type: string;
  /** 不可用时的友好原因提示 */
  reason: string;
}

/**
 * 生物识别辅助类
 *
 * 封装指纹/面容认证，用于应用快速解锁。
 * 认证通过 userAuth 系统能力完成，不涉及用户生物特征数据的读取。
 */
export class BiometricHelper {
  private static instance: BiometricHelper | null = null;

  private constructor() {
  }

  static getInstance(): BiometricHelper {
    if (!BiometricHelper.instance) {
      BiometricHelper.instance = new BiometricHelper();
    }
    return BiometricHelper.instance;
  }

  /**
   * 检查设备是否支持并已录入生物识别凭据
   * @returns 支持的生物识别类型描述，不支持时返回空字符串
   */
  checkBiometricSupport(): string {
    const detail: BiometricDetail = this.checkBiometricDetail();
    return detail.type;
  }

  /**
   * 检查生物识别详细状态（区分"不支持"与"支持但未注册"）
   * @returns 类型描述 + 不可用原因
   */
  checkBiometricDetail(): BiometricDetail {
    let hasFaceSupport: boolean = false;
    let hasFingerprintSupport: boolean = false;
    let faceNotEnrolled: boolean = false;
    let fingerprintNotEnrolled: boolean = false;

    // 指纹
    try {
      userAuth.getAvailableStatus(userAuth.UserAuthType.FINGERPRINT, userAuth.AuthTrustLevel.ATL1);
      hasFingerprintSupport = true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === 12500011) {
        // NOT_ENROLLED：设备支持但用户未注册指纹
        hasFingerprintSupport = true;
        fingerprintNotEnrolled = true;
      }
    }

    // 面容
    try {
      userAuth.getAvailableStatus(userAuth.UserAuthType.FACE, userAuth.AuthTrustLevel.ATL1);
      hasFaceSupport = true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === 12500011) {
        hasFaceSupport = true;
        faceNotEnrolled = true;
      }
    }

    if (hasFingerprintSupport && !fingerprintNotEnrolled) return { type: Strings.get('lock_type_fingerprint'), reason: '' };
    if (hasFaceSupport && !faceNotEnrolled) return { type: Strings.get('lock_type_face'), reason: '' };

    // 设备支持但未注册
    if (hasFingerprintSupport || hasFaceSupport) {
      return { type: '', reason: Strings.get('lock_reason_not_enrolled') };
    }

    return { type: '', reason: Strings.get('lock_reason_unsupported') };
  }

  /**
   * 探测本机**可用且已录入**的认证类型（顺序：面容 → 指纹 → PIN）
   *
   * 直接把 [FINGERPRINT, FACE] 交给系统，在「只录了指纹」或「只录了面容」的设备上
   * 会因为列表里含不可用类型而认证失败；按可用性过滤后再传才稳。
   * （做法与 TKeShi 的 AppLockManager.availableAuthTypes 一致。）
   */
  availableAuthTypes(): userAuth.UserAuthType[] {
    const types: userAuth.UserAuthType[] = [];
    const candidates: userAuth.UserAuthType[] = [
      userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT,
      userAuth.UserAuthType.PIN,
    ];
    for (const candidate of candidates) {
      try {
        userAuth.getAvailableStatus(candidate, userAuth.AuthTrustLevel.ATL1);
        types.push(candidate);
      } catch (e) {
        // 不支持或未录入（12500011 = NOT_ENROLLED）：跳过该类型
        hilog.info(DOMAIN, TAG, 'auth type %{public}d unavailable', candidate);
      }
    }
    return types;
  }

  /**
   * 发起生物识别认证（用于快速解锁）
   *
   * 结果**必定回调且只回调一次**：失败分支必须显式 resolve，否则（如 FAIL /
   * GENERAL_ERROR）Promise 永不结束、锁屏页静默卡住；再加超时兜底，防止系统
   * 侧既不回调也不报错时一直等下去。TKeShi 的同类实现踩过这个坑。
   *
   * @returns 认证结果
   */
  async authenticate(): Promise<BiometricResult> {
    const types: userAuth.UserAuthType[] = this.availableAuthTypes();
    if (types.length === 0) {
      return { success: false, error: Strings.get('lock_err_unavailable') };
    }
    const authParam: userAuth.AuthParam = {
      challenge: new Uint8Array([0, 1, 2, 3, 4]),
      authType: types,
      authTrustLevel: userAuth.AuthTrustLevel.ATL1,
    };
    const widgetParam: userAuth.WidgetParam = {
      title: Strings.get('lock_auth_dialog_title'),
    };

    return await new Promise<BiometricResult>((resolve: (r: BiometricResult) => void) => {
      let done: boolean = false;
      let timer: number = -1;
      let instance: userAuth.UserAuthInstance | null = null;
      const finish = (result: BiometricResult): void => {
        if (done) {
          return;
        }
        done = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        if (instance !== null) {
          try {
            instance.off('result');
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'off(result) failed: %{public}s', JSON.stringify(e));
          }
        }
        resolve(result);
      };

      try {
        instance = userAuth.getUserAuthInstance(authParam, widgetParam);
        timer = setTimeout(() => {
          hilog.info(DOMAIN, TAG, 'authenticate timeout');
          finish({ success: false, error: Strings.get('lock_err_timeout') });
        }, 60000) as number;
        instance.on('result', {
          onResult: (result: userAuth.UserAuthResult) => {
            const code: number = result.result;
            hilog.info(DOMAIN, TAG, 'auth result code=%{public}d', code);
            if (code === userAuth.UserAuthResultCode.SUCCESS) {
              finish({ success: true, error: '' });
            } else if (code === userAuth.UserAuthResultCode.CANCELED
              || code === userAuth.UserAuthResultCode.TYPE_NOT_SUPPORT) {
              finish({ success: false, error: Strings.get('lock_err_cancelled') });
            } else {
              finish({ success: false, error: Strings.fmt('lock_auth_failed_code', code) });
            }
          },
        });
        instance.start();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'authenticate start failed: %{public}s', JSON.stringify(e));
        finish({ success: false, error: Strings.get('lock_err_start_failed') });
      }
    });
  }
}
