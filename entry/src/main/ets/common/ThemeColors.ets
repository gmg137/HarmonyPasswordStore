import { SettingsRepository } from '../model/SettingsRepository';
import { ThemeMode } from './Constants';

/**
 * AppStorage 键：系统当前是否深色
 *
 * 由 EntryAbility 在 onConfigurationUpdate 写入，供 ThemeColors 的
 * SYSTEM 分支读取（"跟随系统"必须拿到真实系统色深，不能假设浅色）。
 */
export const SYSTEM_DARK_KEY: string = 'systemIsDark';

/**
 * 颜色令牌
 *
 * 统一管理深色/浅色两套调色板，页面通过 token 名称取色，
 * 不再硬编码十六进制颜色值。
 *
 * 色彩体系对齐 HarmonyOS Design 语义色（取值对齐系统令牌）：
 * - 强调色 light `#0B4ED6` / dark `#4D8DFF`（ohos_id_color_emphasize 的加深/提亮版，见下）
 * - 页面底 light `#F1F3F5`（background_secondary）/ dark `#000000`
 * - 卡片 light `#FFFFFF`（comp_background_list_card）/ dark `#1A1A1A`
 * - 主文本 light `#182431`（font_primary）/ dark `#E5E5E5`
 * - 告警 `#B3261E`（warning）/ 成功 `#256D2C`（confirm）
 *
 * ## 取值受**对比度下限**约束，不是纯观感选择（AGC 上架审核要求）
 *
 * - 图标/标题文字与背景 > **3:1**，正文文字与背景 > **4.5:1**；
 * - 因此**每一个会被当作前景色用的 token，都必须对「卡片白 / 页面底 / 输入框底 /
 *   中性按钮底」四个浅色背景（深色为对应四个深底）全部达标**——最坏情况通常是
 *   `neutralButton`（浅 `#E5E5E5`、深 `#2E2E2E`）或 `inputBackground`；
 * - 语义色（success/warning/danger）在本应用里既做**色块填充**（强度条、圆点）又做
 *   **文字/图标**，故必须按文字口径取值（浅色下要压到深绿/深褐/深红，亮绿 `#64BB5C`
 *   与橙黄 `#E8A739` 只有 1.9~2.1:1，是首轮审核被打回的直接原因）；
 * - 强调色还多一条约束：**白字落在强调色上要 >3:1**（按钮/FAB 图标），所以深色
 *   `primary` 不能一味提亮（`#5A96FF` 上白字只有 2.9:1）；
 * - 改任何一个取值都必须重跑 `scripts/check-contrast.mjs`（全矩阵校验，低于阈值即退出非零）。
 *
 * 代价：4.5:1 的下限会把灰色阶梯压得很紧（主/次/三级 = `#182431`/`#4E5563`/`#5F6672`），
 * 「提示文字明显更淡」的观感变弱。要保留更淡的提示层，只能**只在图标位**用它（3:1），
 * 正文位必须换回深一档。
 */
export interface Palette {
  /** 页面背景 */
  background: string;
  /** 卡片背景 */
  surface: string;
  /** 主文本 */
  textPrimary: string;
  /** 次要文本 */
  textSecondary: string;
  /** 弱提示文本 */
  textTertiary: string;
  /** 分隔线 */
  divider: string;
  /** 强调色（HarmonyOS 品牌蓝） */
  primary: string;
  /** 强调色淡背景（选中态/强调色底文字按钮，约 10% 不透明度） */
  primarySoft: string;
  /** 强调色背景上的文字色（按钮/标签内文字） */
  onPrimary: string;
  /** 成功色 */
  success: string;
  /** 警告色 */
  warning: string;
  /** 错误色 */
  danger: string;
  /** 错误色淡背景（错误提示卡片） */
  dangerSoft: string;
  /** 输入/键位背景 */
  inputBackground: string;
  /**
   * 次要（中性）按钮底色
   *
   * 与 `inputBackground` 分开的原因：浅色模式下页面底色本身就是 `#F1F3F5`，
   * 直接拿 inputBackground 当按钮底会**与页面融为一体、看不出是个按钮**
   * （实测初始设置页「跳过」只剩文字）。系统原生次要按钮在浅色下比页面
   * 深一档，故这里单独给值；深色下页面是纯黑，取比卡片略亮的灰。
   */
  neutralButton: string;
  /**
   * 卡片按压态底色
   *
   * ArkUI 的 Button 自带按压效果，但 Row/Column/Text 作可点区域时**默认没有任何反馈**
   * （本应用此前全部缺失）。按压态必须给**不透明复合色**而不是半透明遮罩色——
   * stateStyles 的 pressed 分支是替换背景而非叠加，用 `#19000000` 会把卡片底色替换成
   * 透出页面底色的半透明黑。
   */
  pressed: string;
  /** 告警色淡背景（需注意/风险提示卡片） */
  warningSoft: string;
  /**
   * 全模态遮罩底色（克隆等耗时操作挡住整页时用）
   *
   * 与 `pressed` 不同：这里是**半透明**遮罩，压在页面上把背景压暗，
   * 让居中的进度卡片成为唯一焦点。它不承载品牌语义，只负责
   * 「后面不可操作」的视觉表达，故深浅两套取同一族半透明黑。
   */
  overlayScrim: string;
  /** 密码强度：弱（< 40 bits 熵） */
  strengthWeak: string;
  /** 密码强度：中（< 80 bits 熵） */
  strengthFair: string;
  /** 密码强度：强（< 120 bits 熵） */
  strengthGood: string;
  /** 密码强度：极强（≥ 120 bits 熵） */
  strengthStrong: string;
}

/** 浅色调色板（对齐 HarmonyOS 浅色语义；取值同时满足对比度下限，见文件头） */
const LIGHT_PALETTE: Palette = {
  background: '#F1F3F5',
  surface: '#FFFFFF',
  textPrimary: '#182431',
  // 原 #6B7280：在 neutralButton(#E5E5E5) 上仅 3.84:1、inputBackground 上 4.04:1，
  // 低于正文 4.5:1 的下限（取消按钮文字、分段控件未选中文字都落在这些底上）
  textSecondary: '#4E5563',
  // 原 #9AA0A9：仅 2.09~2.63:1，**同时**低于正文 4.5:1 与图标 3:1 —— 行尾箭头、
  // 空状态图标、行说明、输入框占位符全是这个色，是首轮审核「两处不达标」的根因
  textTertiary: '#5F6672',
  divider: '#E5E8EA',
  // 原 #0A59F7：白字在其上 5.55:1 但作为**前景**落在 neutralButton 上只有 4.40:1
  primary: '#0B4ED6',
  // ArkUI 的 8 位 hex 是 #AARRGGBB（alpha 在前）。曾误写成 '#0A59F71A'
  // ——RGB 反着读，渲染成约 4% 不透明度的黄绿色（R=0x59 G=0xF7 B=0x1A），
  // 浅色下肉眼几乎不可见，用户反馈为「按钮浅黄色太不显眼」。
  primarySoft: '#1A0B4ED6',
  onPrimary: '#FFFFFF',
  // 原 #64BB5C（2.39:1）/ #E8A739（2.10:1）/ #E84026（4.04:1）：语义色在本应用里
  // 同时是状态文字与勾选图标，必须按正文口径压暗（色块填充观感随之变深，可接受）
  success: '#256D2C',
  warning: '#8A5A00',
  danger: '#B3261E',
  dangerSoft: '#FEF2F2',
  inputBackground: '#E8EBED',
  neutralButton: '#E5E5E5',
  pressed: '#E6E7E9',
  warningSoft: '#FEF7E8',
  overlayScrim: '#66000000',
  strengthWeak: '#B3261E',
  strengthFair: '#8A5A00',
  strengthGood: '#256D2C',
  // 「极强」比「强」再深一档，保持四级阶梯可辨（同为深绿系）
  strengthStrong: '#1B5E20',
};

/** 深色调色板（对齐 HarmonyOS 深色语义，深蓝黑体系；取值同时满足对比度下限） */
const DARK_PALETTE: Palette = {
  background: '#000000',
  surface: '#1A1A1A',
  textPrimary: '#E5E5E5',
  // 原 #999999：在 neutralButton(#2E2E2E) 上 4.77:1 达标，但二级文字要**比三级更亮**
  // 才能维持层次（见下条 textTertiary 的反转说明），故整体提亮一档
  textSecondary: '#B0B0B0',
  // 原 #888888：在 inputBackground 上 4.27:1、neutralButton 上 3.83:1，低于 4.5:1。
  // 注意深色下「更弱的提示」反而要**更亮**才够对比度——层次靠与 textSecondary 的相对
  // 亮度维持（#999999 < #B0B0B0），不是靠调暗
  textTertiary: '#999999',
  divider: '#333333',
  // 原 #317AF7：作为前景落在卡片上只有 4.36:1（未达 4.5:1）；提亮到 #4D8DFF 后
  // 四个深底全达标，且白字在其上仍有 3.20:1（FAB/按钮图标不破线）
  primary: '#4D8DFF',
  // 同上，#AARRGGBB：曾写成 '#317AF733'（RGB 反读成深黄绿色）。
  primarySoft: '#334D8DFF',
  onPrimary: '#FFFFFF',
  success: '#7ED680',
  warning: '#FFB84D',
  danger: '#FF6B5E',
  dangerSoft: '#2A1A18',
  inputBackground: '#262626',
  neutralButton: '#2E2E2E',
  pressed: '#333333',
  warningSoft: '#2A2113',
  overlayScrim: '#8C000000',
  strengthWeak: '#FF6B5E',
  strengthFair: '#FFB84D',
  strengthGood: '#7ED680',
  strengthStrong: '#9CE89C',
};

/** 圆角令牌（对齐 HarmonyOS 圆角阶梯） */
export class Radius {
  /** 小组件（按钮/标签） */
  static readonly SM: number = 8;
  /** 输入框 */
  static readonly MD: number = 12;
  /** 卡片 */
  static readonly CARD: number = 16;
  /** 浮动按钮/大面板 */
  static readonly LG: number = 24;
  /** 圆形 */
  static readonly FULL: number = 999;
  /** 小图标/图片容器（对齐 corner_radius_level3 = 6vp） */
  static readonly GLYPH: number = 6;
}

/** 图标尺寸令牌（对齐 HarmonyOS 图标阶梯） */
export class IconSize {
  /** 列表项内小图标 / 目录树展开 */
  static readonly XS: number = 16;
  /** 操作按钮图标（复制/眼睛） */
  static readonly SM: number = 22;
  /** 标准图标（导航箭头） */
  static readonly MD: number = 24;
  /** 卡片主图标 */
  static readonly LG: number = 32;
  /** 空状态 / 大图标 / 应用图标 */
  static readonly XL: number = 48;
  /** 浮动按钮尺寸 */
  static readonly FAB: number = 56;
  /** 列表行尾箭头（chevron_right） */
  static readonly CHEVRON: number = 20;
  /** 返回按钮图标 */
  static readonly BACK: number = 24;
  /** 返回按钮可点区域直径（鸿蒙规范：40vp 圆形） */
  static readonly BACK_BUTTON: number = 40;
  /** 面板动作项 / 菜单项图标 */
  static readonly ACTION: number = 20;
  /** 浮动按钮内的 + 号 */
  static readonly FAB_GLYPH: number = 28;
  /** 空状态插图 */
  static readonly EMPTY: number = 56;
  /** 初始设置步骤指示器：当前步骤圆点（活跃） */
  static readonly STEP_DOT_ACTIVE: number = 10;
  /** 初始设置步骤指示器：非当前步骤圆点 */
  static readonly STEP_DOT: number = 8;
}

/** 间距令牌（4 的倍数阶梯） */
export class Spacing {
  static readonly XS: number = 4;
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 16;
  static readonly XL: number = 24;
  /** 页面水平内边距 */
  static readonly PAGE_H: number = 16;
  /** 卡片内边距（对齐 HarmonyOS 规范 16vp） */
  static readonly CARD: number = 16;
  /**
   * 分组标题上方间距
   *
   * 与下方间距（= `CARD_GAP`）构成 2:1 —— 标题要**贴近它所属的卡片**、
   * 离上一张卡片更远，分组才读得出来。原先取规范值 28，与下方 8 一起显得
   * 标题上下都松、且更靠近上一组（视觉上像是上一组的尾巴）。
   */
  static readonly SECTION_TOP: number = 24;
  /**
   * **首个**分组标题的上方间距
   *
   * 它紧跟在标题栏之后，用 SECTION_TOP 会显得内容整体偏低（标题栏自身已有 8vp 底距，
   * 叠起来 32vp）。页面正文第一个分组一律用它。
   */
  static readonly SECTION_TOP_FIRST: number = 12;
  /** 卡片之间的间距（列表项间距 12vp） */
  static readonly CARD_GAP: number = 12;
  /** 列表行内水平内边距 */
  static readonly ROW_H: number = 16;
}

/** 字号令牌（对齐 HarmonyOS Design 字号阶梯） */
export class FontSize {
  /** Headline 1（大号展示 / 引导页主标题） */
  static readonly HEADLINE: number = 36;
  /** 大号展示（Hero / 页面大标题） */
  static readonly DISPLAY_LG: number = 28;
  /** 中号展示（Headline 3 / 生成结果） */
  static readonly DISPLAY_MD: number = 24;
  /** 标题（Title 2） */
  static readonly TITLE: number = 20;
  /** 副标题（Subtitle 1） */
  static readonly SUBTITLE: number = 16;
  /** 正文（Body 2） */
  static readonly BODY: number = 14;
  /** 分组标题（Subtitle_S，次要色 Medium） */
  static readonly SECTION: number = 14;
  /** 说明文字（Caption 1） */
  static readonly CAPTION: number = 12;
  /** 超小字（Caption 2） */
  static readonly OVERLINE: number = 10;
}

/**
 * 组件尺寸令牌（对齐 HarmonyOS 控件高度规范）
 *
 * 取值来自系统尺寸阶梯：控件高度 40vp、列表行 56/64/72vp。
 */
export class ComponentSize {
  /** 标准控件高度（按钮/输入框，对齐规范 40vp） */
  static readonly CONTROL: number = 40;
  /** 小号控件（32vp） */
  static readonly CONTROL_SMALL: number = 32;
  /** 单行列表项 / 设置行（56vp） */
  static readonly ROW: number = 56;
  /** 双行列表项（标题 + 副标题，64vp） */
  static readonly ROW_TWO_LINE: number = 64;
  /** 三行列表项（标题 + 两行说明，80vp） */
  static readonly ROW_THREE_LINE: number = 80;
  /**
   * 系统菜单项高度（48vp）
   *
   * 实测值：用系统默认 `MenuItem({ content })` 渲染后 dump 布局树，
   * `MenuItem` 节点高 168px @3.5px/vp = 48vp（`Menu` 容器本身无上下内边距）。
   * 自定义 `MenuItem(CustomBuilder)` 时系统不再代劳高度，必须显式给这个值，
   * 否则行高会塌到文字自身高度（约 24vp，只有系统菜单项的一半）。
   */
  static readonly MENU_ITEM: number = 48;
  /** 页面标题栏高度（56vp） */
  static readonly TITLE_BAR: number = 56;
  /** 搜索框高度（40vp） */
  static readonly SEARCH: number = 40;
  /** 空状态插图尺寸 */
  static readonly EMPTY_ICON: number = 56;
  /** 下拉菜单 / 动作菜单宽度 */
  static readonly MENU_WIDTH: number = 220;
}

/** 分隔线令牌（对齐 comp_divider：1px + 图标行起始缩进 40vp） */
export class DividerSpec {
  /** 线宽 */
  static readonly STROKE: number = 1;
  /**
   * 图标行分隔线的起始缩进（与行内标题文字起点对齐）
   *
   * 设置页分组行的布局：行首图标 24vp（`IconSize.MD`）+ 图标文字间距 16vp
   * （`Spacing.LG`）= 40vp 处开始文字，分隔线与之对齐。分隔线 margin 相对
   * ListItem（行）边缘；组的横向内边距由 `ListItemGroup.padding` 承担、不在其中。
   */
  static readonly INSET_ICON: number = 40;
  /** 文本行分隔线的起始缩进 */
  static readonly INSET_TEXT: number = 16;
  /** 选中卡片描边宽度（初始设置方式选择卡片） */
  static readonly SELECTED_STROKE: number = 2;
}

/** 按钮规范令牌（对齐 HarmonyOS 按钮设计规范） */
export class ButtonSpec {
  /**
   * 标准按钮高度
   *
   * 对齐鸿蒙控件规范 40vp（曾用 44vp，与规范不符且与 32vp 的小按钮不成阶梯）。
   */
  static readonly HEIGHT: number = ComponentSize.CONTROL;
  /** 标准按钮圆角（胶囊形：取高度一半） */
  static readonly RADIUS: number = ComponentSize.CONTROL / 2;
  /** 主操作按钮高度（同标准高度，保留旧名以免大范围改名） */
  static readonly PRIMARY_HEIGHT: number = ComponentSize.CONTROL;
  /** 主操作按钮圆角（胶囊形） */
  static readonly PRIMARY_RADIUS: number = ComponentSize.CONTROL / 2;
  /** 次操作按钮高度 */
  static readonly SECONDARY_HEIGHT: number = ComponentSize.CONTROL;
  /** 次操作按钮圆角（同为胶囊形——规范里按钮默认就是胶囊，圆角矩形只用于特例） */
  static readonly SECONDARY_RADIUS: number = ComponentSize.CONTROL / 2;
  /** 小型按钮高度 */
  static readonly SMALL_HEIGHT: number = ComponentSize.CONTROL_SMALL;
  /** 小型按钮圆角（胶囊形） */
  static readonly SMALL_RADIUS: number = ComponentSize.CONTROL_SMALL / 2;
  /** 危险按钮高度 */
  static readonly DANGER_HEIGHT: number = ComponentSize.CONTROL;
  /** 危险按钮圆角（胶囊形） */
  static readonly DANGER_RADIUS: number = ComponentSize.CONTROL / 2;
  /** 按钮字号 */
  static readonly FONT_SIZE: number = FontSize.SUBTITLE;
  /** 按钮字重 */
  static readonly FONT_WEIGHT: number = FontWeight.Medium;
  /** 同行按钮之间的间距 */
  static readonly ROW_GAP: number = Spacing.MD;
}

/**
 * 主题颜色访问器
 *
 * 根据 ThemeMode 返回对应调色板；
 * SYSTEM 模式下读取系统深色模式状态。
 *
 * @ObservedV2 + @Trace 使调色板切换可被 V2 状态管理追踪：
 * 页面通过 palette() 方法读取（UI 中调用），深浅色切换时自动刷新。
 */
@ObservedV2
export class ThemeColors {
  private static instance: ThemeColors | null = null;

  /** 是否处于深色模式（由外部在应用启动/切换时同步） */
  @Trace isDark: boolean = false;

  /**
   * 当前语言（i18n 触发器，取值没有语义）
   *
   * `palette()` 故意读取它：页面 build 里都经 `colors` getter 取调色板，
   * 于是都注册了对这个 @Trace 的依赖——语言切换后 Strings.notifyLocaleChanged()
   * 改写它，**所有页面整体重建**，`Str.get` 取出的普通字符串（不随 $r 自动
   * 重解析）随之刷新。
   */
  @Trace locale: string = '';

  /** 语言变更后的全局重渲染入口（Strings.applyLanguage 调用） */
  bumpLocale(): void {
    this.locale = `${this.locale}·`;
  }

  /** 主题变更回调列表（外部注册，用于同步状态栏颜色等非 UI 侧效果） */
  private changeCallbacks: Array<() => void> = [];

  private constructor() {
  }

  static getInstance(): ThemeColors {
    if (!ThemeColors.instance) {
      ThemeColors.instance = new ThemeColors();
    }
    return ThemeColors.instance;
  }

  /** 注册主题变更回调 */
  addChangeListener(callback: () => void): void {
    this.changeCallbacks.push(callback);
  }

  /** 移除主题变更回调 */
  removeChangeListener(callback: () => void): void {
    const idx: number = this.changeCallbacks.indexOf(callback);
    if (idx >= 0) {
      this.changeCallbacks.splice(idx, 1);
    }
  }

  private fireChange(): void {
    for (let i = 0; i < this.changeCallbacks.length; i++) {
      this.changeCallbacks[i]();
    }
  }

  /**
   * 同步当前模式：根据设置中的 ThemeMode 更新深色状态
   *
   * SYSTEM 分支读 AppStorage 中由 EntryAbility 写入的系统色深；
   * 该键未就绪时回退参数值。
   *
   * @param systemDark 系统当前是否深色（仅 SYSTEM 模式且 AppStorage 未就绪时使用）
   */
  syncMode(systemDark: boolean): void {
    const mode: ThemeMode = SettingsRepository.getInstance().getSettings().themeMode;
    if (mode === ThemeMode.DARK) {
      this.isDark = true;
    } else if (mode === ThemeMode.LIGHT) {
      this.isDark = false;
    } else {
      // EntryAbility 在 onConfigurationUpdate / onCreate 时把系统色深写入该键。
      // 曾硬编码 false，结果"跟随系统"永远表现为浅色。
      const stored: boolean | undefined = AppStorage.get<boolean>(SYSTEM_DARK_KEY);
      this.isDark = stored === undefined ? systemDark : stored;
    }
    this.fireChange();
  }

  /**
   * 直接设置深色状态（测试或手动切换用）
   */
  setDark(isDark: boolean): void {
    this.isDark = isDark;
    this.fireChange();
  }

  /**
   * 当前是否深色模式
   */
  isDarkMode(): boolean {
    return this.isDark;
  }
  /**
   * 获取当前调色板
   */
  palette(): Palette {
    // 读取 locale 纯粹为了在语言切换后触发所有页面的依赖（见字段注释）
    const _localeSignal: string = this.locale;
    return this.isDark ? DARK_PALETTE : LIGHT_PALETTE;
  }
}
