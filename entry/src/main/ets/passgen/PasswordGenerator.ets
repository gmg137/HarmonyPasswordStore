import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, Palette } from '../common/ThemeColors';
import { Strings } from '../common/Strings';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordGenerator';

/** 强度档位阈值（bits，升序）：< 40 弱 / < 80 中 / < 120 强 / ≥ 120 极强 */
const STRENGTH_TIER_THRESHOLDS: number[] = [40, 80, 120];

/** 各档位的文案 key（下标 = `strengthTier()` 的返回值，顺序与上一行严格对应） */
const STRENGTH_TIER_LABEL_KEYS: string[] = [
  'common_strength_weak',
  'common_strength_fair',
  'common_strength_good',
  'common_strength_strong',
];

/**
 * 密码生成器
 *
 * 支持两种模式：
 * 1. 随机密码 —— 指定长度和字符集
 * 2. Diceware 口令词组 —— 基于 EFF 词表生成易记口令
 */

/**
 * 密码生成参数
 */
export interface PasswordGenParams {
  /** 密码长度 */
  length: number;
  /** 是否包含大写字母 */
  includeUppercase: boolean;
  /** 是否包含小写字母 */
  includeLowercase: boolean;
  /** 是否包含数字 */
  includeDigits: boolean;
  /** 是否包含特殊符号 */
  includeSymbols: boolean;
  /** 自定义字符集（为空时使用上述选项自动构建） */
  customCharset: string;
  /** 避免歧义字符（如 0/O, 1/l/I） */
  excludeAmbiguous: boolean;
}

/**
 * 默认密码生成参数
 */
export function createDefaultPasswordGenParams(): PasswordGenParams {
  return {
    length: 20,
    includeUppercase: true,
    includeLowercase: true,
    includeDigits: true,
    includeSymbols: true,
    customCharset: '',
    excludeAmbiguous: false,
  };
}

/** 大写字母 */
const UPPERCASE: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
/** 小写字母 */
const LOWERCASE: string = 'abcdefghijklmnopqrstuvwxyz';
/** 数字 */
const DIGITS: string = '0123456789';
/** 特殊符号 */
const SYMBOLS: string = '!@#$%^&*()_+-=[]{}|;:,.<>?';
/** 歧义字符 */
const AMBIGUOUS: string = '0O1lI|`';

/**
 * 从歧义字符集中移除指定字符
 */
function removeAmbiguous(charset: string): string {
  let result: string = charset;
  for (let i = 0; i < AMBIGUOUS.length; i++) {
    const c: string = AMBIGUOUS.charAt(i);
    result = result.split(c).join('');
  }
  return result;
}

/**
 * 使用 cryptoFramework 生成密码学安全的随机数
 * 返回 [0, max) 范围内的整数
 */
function secureRandomInt(max: number): number {
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    // 生成 4 字节随机数据
    const dataBlob: cryptoFramework.DataBlob = random.generateRandomSync(4);
    const bytes: Uint8Array = dataBlob.data;
    // 逐字节左移拼接后必须用无符号右移规范化：
    // << 8 是 32 位有符号移位，首字节最高位为 1 时 val 会变成负数，
    // 负数求模会得到负的随机索引，charAt(负数) 返回空串，导致生成长度随机变短
    let val: number = 0;
    val = (val << 8) | (bytes[0] & 0xFF);
    val = (val << 8) | (bytes[1] & 0xFF);
    val = (val << 8) | (bytes[2] & 0xFF);
    val = (val << 8) | (bytes[3] & 0xFF);
    val >>>= 0;
    // 用模运算映射到目标范围
    return Math.floor(val / 0xFFFFFFFF * max);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'secureRandomInt fallback to Math.random: %{public}s', JSON.stringify(e));
    return Math.floor(Math.random() * max);
  }
}

/**
 * 从字符集中随机选取一个字符
 */
function pickRandomChar(charset: string): string {
  if (charset.length === 0) return '';
  const idx: number = secureRandomInt(charset.length);
  return charset.charAt(idx);
}

/**
 * Fisher-Yates 洗牌（打乱字符顺序）
 */
function shuffleString(str: string): string {
  const arr: string[] = [];
  for (let i = 0; i < str.length; i++) {
    arr.push(str.charAt(i));
  }
  for (let i = arr.length - 1; i > 0; i--) {
    const j: number = secureRandomInt(i + 1);
    const tmp: string = arr[i];
    arr[i] = arr[j];
    arr[j] = tmp;
  }
  return arr.join('');
}

/**
 * 随机密码生成器
 */
export class PasswordGenerator {
  /**
   * 获取有效字符集（根据参数构建，供 UI 显示）
   */
  static getEffectiveCharset(params: PasswordGenParams): string {
    let charset: string = params.customCharset;
    if (charset.length === 0) {
      if (params.includeUppercase) charset += UPPERCASE;
      if (params.includeLowercase) charset += LOWERCASE;
      if (params.includeDigits) charset += DIGITS;
      if (params.includeSymbols) charset += SYMBOLS;
    }
    if (params.excludeAmbiguous) {
      charset = removeAmbiguous(charset);
    }
    return charset;
  }

  /**
   * 生成随机密码
   *
   * 保证每个选中的字符集至少出现一个字符（当长度足够时）。
   */
  static generate(params: PasswordGenParams): string {
    // 确定各子集
    const sets: string[] = [];
    if (params.customCharset.length > 0) {
      let cs: string = params.customCharset;
      if (params.excludeAmbiguous) {
        cs = removeAmbiguous(cs);
      }
      sets.push(cs);
    } else {
      let upper: string = params.includeUppercase ? UPPERCASE : '';
      let lower: string = params.includeLowercase ? LOWERCASE : '';
      let digits: string = params.includeDigits ? DIGITS : '';
      let symbols: string = params.includeSymbols ? SYMBOLS : '';

      if (params.excludeAmbiguous) {
        upper = removeAmbiguous(upper);
        lower = removeAmbiguous(lower);
        digits = removeAmbiguous(digits);
        symbols = removeAmbiguous(symbols);
      }
      if (upper.length > 0) sets.push(upper);
      if (lower.length > 0) sets.push(lower);
      if (digits.length > 0) sets.push(digits);
      if (symbols.length > 0) sets.push(symbols);
    }

    // 合并字符集
    let charset: string = sets.join('');
    if (charset.length === 0) return '';

    const len: number = params.length;
    const result: string[] = [];

    // 保证每个子集至少一个字符
    const guaranteed: number = Math.min(sets.length, len);
    for (let i = 0; i < guaranteed; i++) {
      result.push(pickRandomChar(sets[i]));
    }

    // 剩余位置从完整字符集随机选取
    for (let i = guaranteed; i < len; i++) {
      result.push(pickRandomChar(charset));
    }

    // 打乱顺序，避免前几个字符固定来自各子集
    return shuffleString(result.join(''));
  }

  /**
   * 估算密码强度（熵值 bits）
   * @param password 密码字符串
   * @returns 熵值（bits）
   */
  static estimateStrength(password: string): number {
    if (password.length === 0) return 0;
    let poolSize: number = 0;
    if (/[a-z]/.test(password)) poolSize += 26;
    if (/[A-Z]/.test(password)) poolSize += 26;
    if (/[0-9]/.test(password)) poolSize += 10;
    if (/[^a-zA-Z0-9]/.test(password)) poolSize += 32;
    return Math.floor(password.length * Math.log2(poolSize > 0 ? poolSize : 1));
  }

  /**
   * 强度档位（0=弱 1=中 2=强 3=极强）
   *
   * **文案与颜色必须共用这一个判定**，各写一份阈值必然漂移：
   * `PasswordCreateViewModel.getStrengthColor` 曾把 `< 120` 误写成 `< 8`，
   * 于是 80~119 bits 的密码「标签显示『强』、颜色却是『极强』的」，且「强」
   * 这一档的颜色永远取不到——两处 if 链看着一模一样，肉眼复核根本发现不了。
   * 阈值只在本文件定义一次，ViewModel 一律转发到 `getStrengthLabel`/`getStrengthColor`。
   */
  static strengthTier(entropy: number): number {
    for (let i: number = 0; i < STRENGTH_TIER_THRESHOLDS.length; i++) {
      if (entropy < STRENGTH_TIER_THRESHOLDS[i]) {
        return i;
      }
    }
    return STRENGTH_TIER_THRESHOLDS.length;
  }

  /**
   * 获取强度等级文本
   */
  static getStrengthLabel(entropy: number): string {
    return Strings.get(STRENGTH_TIER_LABEL_KEYS[PasswordGenerator.strengthTier(entropy)]);
  }

  /**
   * 获取强度等级颜色
   */
  static getStrengthColor(entropy: number): string {
    const p: Palette = ThemeColors.getInstance().palette();
    const tierColors: string[] = [p.strengthWeak, p.strengthFair, p.strengthGood, p.strengthStrong];
    return tierColors[PasswordGenerator.strengthTier(entropy)];
  }
}
