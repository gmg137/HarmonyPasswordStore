import { describe, it, expect } from '@ohos/hypium';
import { PasswordGenerator, PasswordGenParams } from '../../main/ets/passgen/PasswordGenerator';
import { DicewareGenerator, DicewareGenParams } from '../../main/ets/passgen/DicewareGenerator';
import { Strings } from '../../main/ets/common/Strings';

/**
 * 密码生成器单元测试
 *
 * 覆盖长度/字符集约束、歧义字符排除、强度估算与 Diceware 熵值。
 */
function makeParams(length: number, upper: boolean, lower: boolean,
  digits: boolean, symbols: boolean, noAmbiguous: boolean): PasswordGenParams {
  const params: PasswordGenParams = {
    length: length,
    includeUppercase: upper,
    includeLowercase: lower,
    includeDigits: digits,
    includeSymbols: symbols,
    customCharset: '',
    excludeAmbiguous: noAmbiguous,
  };
  return params;
}

function makeDicewareParams(wordCount: number, separator: string,
  capitalize: boolean, includeDigits: boolean): DicewareGenParams {
  const params: DicewareGenParams = {
    wordCount: wordCount,
    separator: separator,
    capitalize: capitalize,
    includeDigits: includeDigits,
  };
  return params;
}

export default function generatorTest() {
  describe('PasswordGenerator', () => {
    it('generate_respects_length', 0, () => {
      const pwd = PasswordGenerator.generate(makeParams(24, true, true, true, true, false));
      expect(pwd.length).assertEqual(24);
    });

    it('generate_digits_only', 0, () => {
      const pwd = PasswordGenerator.generate(makeParams(32, false, false, true, false, false));
      expect(/^[0-9]+$/.test(pwd)).assertTrue();
    });

    it('generate_excludes_ambiguous', 0, () => {
      for (let i = 0; i < 20; i++) {
        const pwd = PasswordGenerator.generate(makeParams(24, true, true, true, true, true));
        expect(pwd.includes('0')).assertFalse();
        expect(pwd.includes('O')).assertFalse();
        expect(pwd.includes('1')).assertFalse();
        expect(pwd.includes('l')).assertFalse();
        expect(pwd.includes('I')).assertFalse();
      }
    });

    it('generate_empty_charset_returns_empty', 0, () => {
      const pwd = PasswordGenerator.generate(makeParams(16, false, false, false, false, false));
      expect(pwd).assertEqual('');
    });

    it('generate_includes_each_selected_set', 0, () => {
      // 长度足够时每个选中的字符集至少出现一个字符
      for (let i = 0; i < 10; i++) {
        const pwd = PasswordGenerator.generate(makeParams(32, true, true, true, true, false));
        expect(/[A-Z]/.test(pwd)).assertTrue();
        expect(/[a-z]/.test(pwd)).assertTrue();
        expect(/[0-9]/.test(pwd)).assertTrue();
      }
    });

    it('estimate_strength_grows_with_length', 0, () => {
      const short = PasswordGenerator.estimateStrength('abcdefgh');
      const long = PasswordGenerator.estimateStrength('abcdefghijklmnop');
      expect(long > short).assertTrue();
    });

    it('estimate_strength_empty_is_zero', 0, () => {
      expect(PasswordGenerator.estimateStrength('')).assertEqual(0);
    });

    it('strength_label_boundaries', 0, () => {
      // 强度文案已走 Strings（资源串）：断言与实现取同一来源——LocalUnit 环境
      // Strings.appContext 为 null 时两侧都返回 key 本身，设备上则同为本地化文案，
      // 因此该断言与运行环境/设备语言无关，只校验阈值分档
      expect(PasswordGenerator.getStrengthLabel(30)).assertEqual(Strings.get('common_strength_weak'));
      expect(PasswordGenerator.getStrengthLabel(60)).assertEqual(Strings.get('common_strength_fair'));
      expect(PasswordGenerator.getStrengthLabel(100)).assertEqual(Strings.get('common_strength_good'));
      expect(PasswordGenerator.getStrengthLabel(130)).assertEqual(Strings.get('common_strength_strong'));
    });
  });

  describe('DicewareGenerator', () => {
    it('generate_word_count_with_separator', 0, () => {
      const phrase = DicewareGenerator.generate(makeDicewareParams(4, '-', false, false));
      const parts: string[] = phrase.split('-');
      expect(parts.length).assertEqual(4);
    });

    it('generate_capitalize', 0, () => {
      const phrase = DicewareGenerator.generate(makeDicewareParams(3, ' ', true, false));
      const parts: string[] = phrase.split(' ');
      for (const word of parts) {
        expect(word.charAt(0)).assertEqual(word.charAt(0).toUpperCase());
      }
    });

    it('estimate_entropy_grows_with_words', 0, () => {
      const three = DicewareGenerator.estimateEntropy(makeDicewareParams(3, '-', false, false));
      const five = DicewareGenerator.estimateEntropy(makeDicewareParams(5, '-', false, false));
      expect(five > three).assertTrue();
    });
  });
}
