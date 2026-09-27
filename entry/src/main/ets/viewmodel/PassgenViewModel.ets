import { PasswordGenerator, PasswordGenParams, createDefaultPasswordGenParams } from '../passgen/PasswordGenerator';
import { DicewareGenerator, DicewareGenParams, createDefaultDicewareParams } from '../passgen/DicewareGenerator';
import { ClipboardHelper } from '../utils/ClipboardHelper';
import { Strings } from '../common/Strings';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PassgenVM';

/**
 * 生成模式枚举
 */
export enum GenMode {
  RANDOM = 'random',
  DICEWARE = 'diceware',
}

/**
 * 密码生成器视图模型
 *
 * 管理随机密码和 Diceware 口令词组的生成、预览、复制。
 */
@ObservedV2
export class PassgenViewModel {
  /** 当前模式 */
  @Trace mode: GenMode = GenMode.RANDOM;
  /** 生成的密码结果 */
  @Trace result: string = '';
  /** 密码熵值 */
  @Trace entropy: number = 0;
  /** 密码是否已复制 */
  @Trace isCopied: boolean = false;
  /** 复制提示 */
  @Trace copyToast: string = '';
  /** 随机密码参数 */
  @Trace randomParams: PasswordGenParams = createDefaultPasswordGenParams();
  /** Diceware 参数 */
  @Trace dicewareParams: DicewareGenParams = createDefaultDicewareParams();

  /**
   * 切换生成模式
   */
  setMode(mode: GenMode): void {
    this.mode = mode;
    this.result = '';
    this.entropy = 0;
    this.isCopied = false;
  }

  /**
   * 生成密码
   */
  generate(): void {
    if (this.mode === GenMode.RANDOM) {
      this.result = PasswordGenerator.generate(this.randomParams);
      this.entropy = PasswordGenerator.estimateStrength(this.result);
    } else {
      this.result = DicewareGenerator.generate(this.dicewareParams);
      this.entropy = DicewareGenerator.estimateEntropy(this.dicewareParams);
    }
    this.isCopied = false;
  }

  /**
   * 更新随机密码参数
   */
  updateRandomParam(key: string, value: boolean | number | string): void {
    // 先保存所有旧值（避免修改后引用同一对象导致值丢失）
    const params: PasswordGenParams = {
      length: this.randomParams.length,
      includeUppercase: this.randomParams.includeUppercase,
      includeLowercase: this.randomParams.includeLowercase,
      includeDigits: this.randomParams.includeDigits,
      includeSymbols: this.randomParams.includeSymbols,
      customCharset: this.randomParams.customCharset,
      excludeAmbiguous: this.randomParams.excludeAmbiguous,
    };

    if (key === 'length' && typeof value === 'number') {
      params.length = value;
    } else if (key === 'includeUppercase' && typeof value === 'boolean') {
      params.includeUppercase = value;
    } else if (key === 'includeLowercase' && typeof value === 'boolean') {
      params.includeLowercase = value;
    } else if (key === 'includeDigits' && typeof value === 'boolean') {
      params.includeDigits = value;
    } else if (key === 'includeSymbols' && typeof value === 'boolean') {
      params.includeSymbols = value;
    } else if (key === 'customCharset' && typeof value === 'string') {
      params.customCharset = value;
    } else if (key === 'excludeAmbiguous' && typeof value === 'boolean') {
      params.excludeAmbiguous = value;
    }

    // 用新对象触发 @Trace 刷新
    this.randomParams = params;
  }

  /**
   * 更新 Diceware 参数
   */
  updateDicewareParam(key: string, value: boolean | number | string): void {
    if (key === 'wordCount' && typeof value === 'number') {
      this.dicewareParams.wordCount = value;
    } else if (key === 'separator' && typeof value === 'string') {
      this.dicewareParams.separator = value;
    } else if (key === 'capitalize' && typeof value === 'boolean') {
      this.dicewareParams.capitalize = value;
    } else if (key === 'includeDigits' && typeof value === 'boolean') {
      this.dicewareParams.includeDigits = value;
    }
    // 触发 @Trace 刷新
    const old: DicewareGenParams = this.dicewareParams;
    this.dicewareParams = {
      wordCount: old.wordCount,
      separator: old.separator,
      capitalize: old.capitalize,
      includeDigits: old.includeDigits,
    };
  }

  /**
   * 复制结果到剪贴板
   */
  async copyResult(): Promise<void> {
    if (this.result.length === 0) return;
    // 走 ClipboardHelper：生成的密码是敏感数据，复制后必须排定自动清除
    const ok: boolean = await ClipboardHelper.getInstance().copy(this.result);
    this.isCopied = ok;
    this.copyToast = ok ? Strings.get('passgen_copied_clipboard') : Strings.get('common_copy_failed');
    setTimeout(() => { this.copyToast = ''; }, 2000);
  }

  /**
   * 获取强度文本
   *
   * 阈值与 PasswordGenerator.getStrengthLabel 保持一致（<40 弱 / <80 中 / <120 强）：
   * 两处都经 Strings.get('common_strength_*') 取本地化文案，改阈值时须两处同步。
   */
  getStrengthLabel(): string {
    if (this.entropy < 40) return Strings.get('common_strength_weak');
    if (this.entropy < 80) return Strings.get('common_strength_fair');
    if (this.entropy < 120) return Strings.get('common_strength_good');
    return Strings.get('common_strength_strong');
  }

  /**
   * 获取强度颜色
   */
  getStrengthColor(): string {
    return PasswordGenerator.getStrengthColor(this.entropy);
  }
}
