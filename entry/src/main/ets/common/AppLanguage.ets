/**
 * 应用语言选项
 *
 * 值持久化在 `AppSettings.appLanguage`：
 * - `system`（默认）= 跟随系统：启动时**不**调用 `setLanguage` 钉死语言，
 *   由系统资源匹配自动决定；从具体语言切回它时才需要解除钉扎（见 Strings.applyLanguage）。
 * - 具体语言 = 调用 `ApplicationContext.setLanguage` 钉扎应用语言。
 *
 * 选项标题用**各自语言**书写（语言名不该被翻译——用户要靠它认出自己认识的那个），
 * 因此不走资源表；只有「系统默认」这个动作的标题随应用语言翻译。
 */
export interface AppLanguageOption {
  /** 持久化值（AppSettings.appLanguage） */
  value: string;
  /** 选项标题（各语言原生写法） */
  nativeTitle: string;
}

export class AppLanguage {
  /** 跟随系统 */
  static readonly SYSTEM: string = 'system';
  static readonly ZH_CN: string = 'zh-CN';
  static readonly ZH_TW: string = 'zh-TW';
  static readonly EN_US: string = 'en-US';
  static readonly RU_RU: string = 'ru-RU';
  static readonly DE_DE: string = 'de-DE';

  /** 语言选择弹窗的候选项（顺序即展示顺序） */
  static readonly OPTIONS: AppLanguageOption[] = [
    { value: AppLanguage.SYSTEM, nativeTitle: '' },
    { value: AppLanguage.ZH_CN, nativeTitle: '简体中文' },
    { value: AppLanguage.ZH_TW, nativeTitle: '繁體中文' },
    { value: AppLanguage.EN_US, nativeTitle: 'English' },
    { value: AppLanguage.RU_RU, nativeTitle: 'Русский' },
    { value: AppLanguage.DE_DE, nativeTitle: 'Deutsch' },
  ];

  /** 当前值对应的显示标题（system 的标题由调用方用资源表取，这里返回空串） */
  static optionTitle(value: string): string {
    for (let i: number = 0; i < AppLanguage.OPTIONS.length; i++) {
      if (AppLanguage.OPTIONS[i].value === value) {
        return AppLanguage.OPTIONS[i].nativeTitle;
      }
    }
    return value;
  }
}
