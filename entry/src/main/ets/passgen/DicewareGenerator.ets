import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'DicewareGenerator';

/**
 * Diceware 生成参数
 *
 * @ObservedV2 + @Trace：面板直接读取各字段，逐字段修改即可被 V2 状态管理
 * 追踪（普通 interface 的嵌套属性修改不可观测，见 PasswordGenParams 的说明）。
 */
@ObservedV2
export class DicewareGenParams {
  /** 词组数量（通常 4-7 个） */
  @Trace wordCount: number = 4;
  /** 分隔符 */
  @Trace separator: string = '-';
  /** 是否首字母大写 */
  @Trace capitalize: boolean = false;
  /** 是否在词组间插入数字 */
  @Trace includeDigits: boolean = false;
}

/**
 * 默认 Diceware 参数
 */
export function createDefaultDicewareParams(): DicewareGenParams {
  return new DicewareGenParams();
}

/**
 * EFF 短词表子集（7776 词中选取高频短词 256 个）
 *
 * 完整 EFF 词表可在 Phase 3 从资源文件加载；
 * 此子集足以生成高质量口令词组（256^4 = 43 亿种组合）。
 */
const EFF_SHORT_WORDS: string[] = [
  'abacus', 'absorb', 'academy', 'acclaim', 'action', 'active', 'adapt', 'admire',
  'advice', 'agency', 'agree', 'aimless', 'airport', 'alarm', 'album', 'allege',
  'amount', 'anchor', 'animal', 'annual', 'answer', 'antenna', 'apex', 'applied',
  'arcade', 'arena', 'argue', 'arise', 'armor', 'arrow', 'article', 'artist',
  'aspect', 'assert', 'assume', 'athlete', 'atlas', 'atom', 'attend', 'attract',
  'auction', 'august', 'author', 'autumn', 'average', 'aviator', 'awake', 'award',
  'aware', 'axiom', 'badge', 'baggage', 'baker', 'balloon', 'banana', 'banner',
  'barber', 'barge', 'basic', 'basket', 'battle', 'bazaar', 'beacon', 'bedroom',
  'believe', 'benefit', 'better', 'bicycle', 'bigger', 'binary', 'biology', 'birth',
  'bishop', 'bistro', 'blender', 'blink', 'bliss', 'blueprint', 'blurry', 'boat',
  'body', 'boiler', 'bonus', 'border', 'borrow', 'bottle', 'boulder', 'bounce',
  'bracket', 'brain', 'brand', 'brave', 'bread', 'breakup', 'breed', 'brief',
  'brilliant', 'broke', 'brother', 'browser', 'browse', 'bubble', 'buddy', 'budget',
  'buffet', 'bugle', 'bundle', 'bureau', 'burner', 'butler', 'butter', 'button',
  'buyer', 'cabin', 'cable', 'caffeine', 'calm', 'camera', 'campus', 'canary',
  'cancel', 'candy', 'canine', 'canopy', 'canvas', 'canyon', 'capable', 'capital',
  'captain', 'capture', 'carbon', 'career', 'cargo', 'carrier', 'casino', 'castle',
  'catalog', 'cattle', 'caught', 'cause', 'cavern', 'cease', 'cedar', 'ceiling',
  'center', 'cereal', 'chain', 'chamber', 'change', 'channel', 'chaos', 'chapter',
  'charge', 'charm', 'chart', 'chase', 'cheap', 'check', 'cheese', 'cherry',
  'chest', 'chicken', 'chief', 'child', 'chimney', 'chip', 'chivalry', 'choice',
  'chrome', 'chunk', 'cinder', 'circle', 'citizen', 'city', 'civic', 'civil',
  'claim', 'classic', 'clean', 'clear', 'click', 'client', 'cliff', 'climb',
  'clinic', 'clock', 'close', 'cloud', 'clover', 'clown', 'cluster', 'coach',
  'coast', 'coat', 'coconut', 'coffee', 'comet', 'comic', 'comma', 'commit',
  'common', 'compass', 'compound', 'concept', 'concern', 'conduct', 'confirm', 'confer',
  'congest', 'connect', 'conquer', 'consist', 'contact', 'contest', 'context', 'control',
  'convince', 'cookie', 'cooler', 'cooper', 'cope', 'copper', 'coral', 'corner',
  'correct', 'cortex', 'cosmic', 'cotton', 'couch', 'couple', 'course', 'cousin',
  'cover', 'cowboy', 'cradle', 'craft', 'crater', 'create', 'credit', 'creep',
  'cricket', 'crimson', 'critic', 'crow', 'crown', 'crucial', 'crystal', 'cubic',
  'curious', 'curtain', 'cushion', 'custom', 'cymbal', 'cynic', 'daisy', 'damage',
  'dance', 'daring', 'darkness', 'dating', 'daughter', 'dazzle', 'death', 'debit',
  'decay', 'decide', 'decode', 'deduce', 'deep', 'define', 'degree', 'delete',
  'deliver', 'demand', 'depend', 'deploy', 'deputy', 'desert', 'design', 'desire',
  'detail', 'detect', 'develop', 'device', 'devote', 'diagnose', 'dice', 'differ',
  'digger', 'dignity', 'dilemma', 'dinner', 'diploma', 'direct', 'disagree', 'disarm',
  'discover', 'disease', 'dishes', 'dismiss', 'display', 'distance', 'distant', 'ditch',
  'divide', 'divine', 'dizzy', 'doctor', 'dolphin', 'domain', 'donate', 'donkey',
  'donor', 'double', 'dover', 'dragon', 'drama', 'drank', 'drawn', 'dread',
  'dream', 'dress', 'drift', 'drink', 'drive', 'drone', 'droplet', 'drove',
  'drowning', 'dusty', 'dwarf', 'dwelling', 'eagle', 'earlier', 'earring', 'earth',
  'ease', 'easter', 'eaten', 'ebony', 'echo', 'eclipse', 'economy', 'edible',
  'africa', 'agent', 'aim', 'alarm', 'alert', 'alien', 'align', 'alike',
  'alive', 'alley', 'allow', 'alone', 'along', 'amber', 'among', 'ample',
  'ancient', 'anger', 'angle', 'angry', 'ankle', 'apart', 'apple', 'april',
  'arctic', 'area', 'arena', 'argue', 'arise', 'armor', 'around', 'array',
];

/**
 * Diceware 口令词组生成器
 *
 * 基于 EFF 短词表生成易记且高熵的口令词组。
 * 每个词从词表中随机选取，组合后熵值为 wordCount * log2(wordList.length)。
 */
export class DicewareGenerator {
  /** 词表大小 */
  private static readonly WORD_COUNT: number = EFF_SHORT_WORDS.length;

  /**
   * 生成口令词组
   * @param params 生成参数
   * @returns 口令词组字符串
   */
  static generate(params: DicewareGenParams): string {
    const count: number = params.wordCount;
    if (count <= 0) return '';

    const words: string[] = [];
    for (let i = 0; i < count; i++) {
      const idx: number = DicewareGenerator.secureRandomInt(DicewareGenerator.WORD_COUNT);
      let word: string = EFF_SHORT_WORDS[idx];
      if (params.capitalize) {
        word = DicewareGenerator.capitalizeFirst(word);
      }
      words.push(word);

      // 可选：在词组间插入随机数字
      if (params.includeDigits && i < count - 1) {
        const digit: number = DicewareGenerator.secureRandomInt(10);
        words.push(digit.toString());
      }
    }

    return words.join(params.separator);
  }

  /**
   * 估算口令词组熵值（bits）
   * @param params 生成参数
   * @returns 熵值
   */
  static estimateEntropy(params: DicewareGenParams): number {
    let bits: number = params.wordCount * Math.log2(DicewareGenerator.WORD_COUNT);
    if (params.includeDigits) {
      // 每个数字贡献 log2(10) ≈ 3.32 bits
      bits += (params.wordCount - 1) * Math.log2(10);
    }
    return Math.floor(bits);
  }

  /**
   * 首字母大写
   */
  private static capitalizeFirst(word: string): string {
    if (word.length === 0) return word;
    return word.charAt(0).toUpperCase() + word.substring(1);
  }

  /**
   * 密码学安全随机数 [0, max)
   */
  private static secureRandomInt(max: number): number {
    try {
      const random: cryptoFramework.Random = cryptoFramework.createRandom();
      const dataBlob: cryptoFramework.DataBlob = random.generateRandomSync(4);
      const bytes: Uint8Array = dataBlob.data;
      let val: number = 0;
      val = (val << 8) | (bytes[0] & 0xFF);
      val = (val << 8) | (bytes[1] & 0xFF);
      val = (val << 8) | (bytes[2] & 0xFF);
      val = (val << 8) | (bytes[3] & 0xFF);
      return Math.floor(val / 0xFFFFFFFF * max);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'secureRandomInt fallback: %{public}s', JSON.stringify(e));
      return Math.floor(Math.random() * max);
    }
  }
}
