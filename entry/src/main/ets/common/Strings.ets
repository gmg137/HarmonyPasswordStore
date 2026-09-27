import { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLanguage } from './AppLanguage';
import { SettingsRepository } from '../model/SettingsRepository';
import { ThemeColors } from './ThemeColors';

const DOMAIN: number = 0x0001;
const TAG: string = 'Strings';

/**
 * 字符串资源与语言切换助手
 *
 * ## 为什么需要它
 *
 * `$r()` 只接受**编译期字面量**，页面里 `Text($r('app.string.xxx'))` 直接用即可；
 * 但 ViewModel / model / utils 这些非 UI 代码拿到的 key 是运行期字符串，
 * 必须经 `ResourceManager.getStringByNameSync(name, ...args)` 解析——本类统一封装，
 * 供 UI 之外的取串与带参格式化使用（类名即入口，方法均为 static）。
 *
 * ## 语言切换
 *
 * `applyLanguage` 持久化偏好并调用 `ApplicationContext.setLanguage` 钉扎应用语言。
 * 两个平台约束（SDK 文档 + 实测口径）：
 * - `setLanguage` 之后**系统语言变化不再触发** ability 的 onConfigurationUpdate 与
 *   EnvironmentCallback——所以「跟随系统」模式在启动时**绝不**钉扎（不调用
 *   setLanguage），交回系统资源匹配；从具体语言切回 system 时只能改为钉到
 *   **当前**系统语言（无解除钉扎的 API），本次运行期内不再跟随系统变化，
 *   冷启动后恢复完整跟随。
 * - `setLanguage('')` 不抛异常但会把应用语言钉成**空标签**（资源匹配落回 base），
 *   不要用它当「取消设置」。
 *
 * UI 刷新：`$r` 资源串由框架在语言变化后自动重解析；经 `Str.get` 取出的**普通字符串**
 * 不会自动刷新，`notifyLocaleChanged` 通过 `ThemeColors.locale`（@Trace，palette()
 * 读取它）让所有读调色板的页面整体重建一遍。
 */
export class Strings {
  private static appContext: common.ApplicationContext | null = null;

  /** 当前生效的语言偏好（启动时由 EntryAbility 回填） */
  private static current: string = AppLanguage.SYSTEM;

  /**
   * 初始化（EntryAbility.onCreate 调用，先于任何 UI）
   *
   * 只保存上下文，不在此处应用语言：设置未就绪（init 是异步的），读不到偏好。
   */
  static init(appContext: common.ApplicationContext): void {
    Strings.appContext = appContext;
  }

  /** 取字符串资源（key 为 string.json 里的 name，运行期给定） */
  static get(key: string): string {
    if (Strings.appContext === null) {
      // EntryAbility.onCreate 之前不会有人取串；防御性兜底返回 key 本身
      return key;
    }
    try {
      return Strings.appContext.resourceManager.getStringByNameSync(key);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getStringByNameSync %{public}s failed: %{public}s',
        key, e instanceof Error ? e.message : String(e));
      return key;
    }
  }

  /** 取带参格式化串（资源值里写 %s / %d，参数按顺序填充） */
  static fmt(key: string, ...args: Array<string | number>): string {
    if (Strings.appContext === null) {
      return key;
    }
    try {
      return Strings.appContext.resourceManager.getStringByNameSync(key, ...args);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getStringByNameSync %{public}s failed: %{public}s',
        key, e instanceof Error ? e.message : String(e));
      return key;
    }
  }

  /**
   * 当前**生效**的语言（system 偏好下取系统语言）
   *
   * 供「按语言调整 UI 度量」使用（见 `labelWidth`）：`Strings.current` 只记录偏好，
   * 为 `system` 时不知道实际落到哪种语言，必须再问一次系统。
   */
  static effectiveLanguage(): string {
    if (Strings.current !== AppLanguage.SYSTEM) {
      return Strings.current;
    }
    try {
      return i18n.System.getSystemLanguage();
    } catch (e) {
      return Strings.current;
    }
  }

  /** 是否宽字形文字（中日韩）：决定固定宽度标签列取窄值还是宽值 */
  static isWideScript(): boolean {
    const lang: string = Strings.effectiveLanguage().toLowerCase();
    return lang.startsWith('zh') || lang.startsWith('ja') || lang.startsWith('ko');
  }

  /**
   * 固定宽度标签列的宽度（按当前语言缩放）
   *
   * 这类列宽原本按「3–4 个汉字」定死（72/84vp），而拉丁与西里尔字母同字数约占
   * 1.5 倍宽度——直接沿用会让「用户名 / 私钥口令」这类标签在英德俄下折行、把整行
   * 撑高（实测德 `Benutzername`、俄 `Имя пользователя` 在 72vp 列里都会换行）。
   * 汉字保持原值（不动中文版式），其余语言按倍率放大。
   */
  static labelWidth(base: number): number {
    return Strings.isWideScript() ? base : Math.round(base * 1.5);
  }

  /**
   * 应用语言：持久化 + 钉扎/解除钉扎 + 通知 UI 刷新
   *
   * @param context 任一 UIAbility 上下文（设置页传入 hostContext）
   * @param value AppLanguage 常量之一
   */
  static applyLanguage(context: common.Context | undefined, value: string): void {
    const repository: SettingsRepository = SettingsRepository.getInstance();
    repository.updateSetting('appLanguage', value);
    Strings.current = value;
    if (context === undefined) {
      return;
    }
    const appContext: common.ApplicationContext = context.getApplicationContext();
    Strings.appContext = appContext;
    try {
      if (value === AppLanguage.SYSTEM) {
        // 「跟随系统」= 钉到系统当前语言。实测不能传 '' 来「取消钉扎」：'' 不抛
        // 异常但把应用语言钉成空标签，资源匹配落回 base（英文）。副作用：本次
        // 运行期内系统语言再变化不会跟随（setLanguage 之后系统环境回调被抑制）；
        // 冷启动读到 system 偏好时不钉扎（applyStoredLanguage 直接 return），
        // 恢复真实跟随。
        appContext.setLanguage(i18n.System.getSystemLanguage());
      } else {
        appContext.setLanguage(Strings.resolveLanguageTag(value));
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setLanguage %{public}s failed: %{public}s',
        value, e instanceof Error ? e.message : String(e));
    }
    Strings.notifyLocaleChanged();
  }

  /**
   * 启动时应用已保存的语言偏好（EntryAbility 在设置就绪后调用）
   *
   * 仅具体语言才钉扎；system 交给系统资源匹配（见类注释的钉扎副作用）。
   *
   * **必须 notifyLocaleChanged**：`onCreate` 里那次调用早于窗口就绪，`setLanguage`
   * 可能不生效；窗口加载完成后 EntryAbility 会再调一次（幂等），若这次才真正生效，
   * `$r` 资源由框架自动重解析，而页面 build 里经 `Strings.get` 取出的**普通字符串**
   * 不会重算，也没有别的东西触发重渲染——首屏就会停留在系统语言。
   */
  static applyStoredLanguage(context: common.Context): void {
    const value: string = SettingsRepository.getInstance().getSettings().appLanguage;
    Strings.current = value;
    Strings.appContext = context.getApplicationContext();
    if (value === AppLanguage.SYSTEM) {
      return;
    }
    try {
      Strings.appContext.setLanguage(Strings.resolveLanguageTag(value));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyStoredLanguage %{public}s failed: %{public}s',
        value, e instanceof Error ? e.message : String(e));
    }
    Strings.notifyLocaleChanged();
  }

  /**
   * 把偏好值解析成 setLanguage 接受的语言标签
   *
   * 偏好存的是 `zh-CN` 这类 language-region 简写，而 setLanguage 的合法值来自
   * `i18n.System.getSystemLanguages()`（可能带 script，如 `zh-Hans-CN`）。
   * 先精确匹配，再按 language+region 兜底匹配（zh-CN → zh-Hans-CN）。
   */
  private static resolveLanguageTag(value: string): string {
    let candidates: Array<string> = [];
    try {
      candidates = i18n.System.getSystemLanguages();
    } catch (e) {
      return value;
    }
    for (let i: number = 0; i < candidates.length; i++) {
      if (candidates[i] === value) {
        return candidates[i];
      }
    }
    const parts: Array<string> = value.split('-');
    const lang: string = parts[0] ?? value;
    const region: string = parts.length > 1 ? (parts[1] as string) : '';
    for (let i: number = 0; i < candidates.length; i++) {
      const seg: Array<string> = candidates[i].split('-');
      if (seg[0] === lang && region.length > 0 && seg[seg.length - 1] === region) {
        return candidates[i];
      }
    }
    return value;
  }

  /** 通知 UI：语言已变（ThemeColors.locale 为 @Trace，读调色板的页面会整体重建） */
  static notifyLocaleChanged(): void {
    ThemeColors.getInstance().bumpLocale();
  }
}
