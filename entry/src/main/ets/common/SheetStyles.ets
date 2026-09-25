/**
 * 半模态弹窗（bindSheet）统一样式
 *
 * ## 键盘避让必须用 RESIZE_ONLY
 *
 * 模拟器实测（1256×2760，软键盘顶边 y=1661）：
 *
 * | keyboardAvoidMode | 面板 | 内容布局 | 底部按钮行 |
 * |---|---|---|---|
 * | `RESIZE_ONLY` | 顶边固定 137、底边收到键盘上沿 | 按**收缩后**高度重新布局 | 稳定贴在面板底部（键盘弹起时紧贴键盘上沿） |
 * | `TRANSLATE_AND_RESIZE` | 同样收缩到 1489 | 仍按**全屏**高度布局 | 被裁到面板之外，布局树里连节点都不存在 |
 * | `NONE` | 同样收缩到 1489 | 仍按**全屏**高度布局 | 同上，按钮消失 |
 *
 * 也就是说：面板高度会被键盘压缩这件事躲不掉（应用窗口本身会缩），
 * 只有 `RESIZE_ONLY` 会连带把内容按收缩后的高度重排，按钮才留在面板底部；
 * 另外两种模式下按钮会被裁出可视区，用户既看不到也点不到。
 *
 * 因此带输入框的表单弹窗一律：`formSheetOptions()` + 根容器 `height('100%')`
 * + 字段区之后放 `Blank().layoutWeight(1)` 把按钮行撑到面板底部。
 *
 * ## 状态栏无需任何补偿
 *
 * 系统栏保持透明（`common/SystemBars.ets`），遮罩会连状态栏条带一起压暗，
 * 与页面同步。此前那套「按遮罩 alpha 换算 statusBarColor」的补偿已删除。
 */

import { ComponentSize, Spacing } from './ThemeColors';

/** 遮罩色：点击遮罩可关闭（各页统一，避免各处硬编码） */
export const SHEET_MASK_COLOR: string = '#19000000';

/**
 * 面板顶部留白：dragBar 约 16vp + 8vp 呼吸间距
 *
 * 所有半模态共用这一个值，保证「内容距面板顶部」的距离在全应用一致。
 * 曾为 40vp，配合各页自绘的内边距显得内容整体偏低。
 */
export const SHEET_PAD_TOP: number = 24;

/**
 * 面板底部留白
 *
 * 按钮行贴面板底部，再留 24vp 与屏幕下沿/键盘上沿保持距离，避免贴边。
 */
export const SHEET_PAD_BOTTOM: number = 24;

/**
 * 表单弹窗配置：撑满面板 + 键盘只 resize 内容
 *
 * `height: '100%'` 而非 FIT_CONTENT：面板必须延伸到屏幕下沿，
 * 配合 `Blank().layoutWeight(1)` 才能把按钮行固定到面板底部；
 * FIT_CONTENT 只包住内容，按钮会悬在内容下方而非底部。
 *
 * @param background 面板背景（**必须随主题更新**—— backgroundColor 是 BindOptions
 *                   的正式字段、默认 Color.White，过期颜色会在面板拉高后露出，见
 *                   `themedSheetOptions` 的说明）
 * @param onDisappear 关闭回调：必须同步复位可见状态，否则手势/点遮罩关闭后无法再次弹出
 */
export function formSheetOptions(background: string, onDisappear: () => void): SheetOptions {
  return {
    height: '100%',
    showClose: false,
    dragBar: true,
    maskColor: SHEET_MASK_COLOR,
    backgroundColor: background,
    keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
    onDisappear: onDisappear,
  };
}

/**
 * 短面板弹窗配置（动作菜单 / 二次确认 / 列表选择）
 *
 * 这类面板没有输入框，键盘不会弹起，因此无需键盘避让配置；
 * 用固定高度把面板压在屏幕下半部，保持半模态的轻量感。
 *
 * @param background 面板背景
 * @param height 面板高度（**必须固定 vp**：菜单态用 `menuSheetHeight(行数)`，
 *               列表选择态按内容算——见 `detents` 注释里百分比为什么不行）
 * @param onDisappear 关闭回调：同步复位可见状态
 */
export function panelSheetOptions(background: string, height: Length, onDisappear: () => void): SheetOptions {
  return {
    height: height,
    // **只给一个 detent，取值就是 height 本身**：面板上边缘只能拖到 detent 高度，
    // 不会再往上扩展，因此不会露出「内容盒之外」的系统默认背景
    // （曾按「多 detent 会上拉露底」把这里改成单 detent 固定高度）。
    // backgroundColor 是 BindOptions 的正式字段（**默认 Color.White**，不是多余键）——
    // 它画的范围是**整个弹窗窗口**（含内容盒之外的区域），所以面板被拉高后
    // 多出来的部分显示的正是这个颜色，而不是什么「系统默认背景」。
    // 也**不要用百分比**：`height: '30%'` 与 `detents: ['30%']` 的解析结果不一致，
    // 面板静置时底部就露一条浅色带（PGP/SSH 菜单、目录密钥面板都踩过）。
    detents: [height],
    showClose: false,
    dragBar: true,
    maskColor: SHEET_MASK_COLOR,
    backgroundColor: background,
    onDisappear: onDisappear,
  };
}

/**
 * 动作菜单面板高度（按**行数**精确算，不要用百分比）
 *
 * `行数 × 行高 + 行间分隔 + 顶部留白 + 底部留白`；底部留白默认取动作菜单用的
 * `Spacing.LG`（列表页菜单态口径），PGP/SSH 页菜单用 `SHEET_PAD_BOTTOM`，显式传参。
 * **不要用百分比**：百分比高度与 `detents` 的百分比解析不一致，面板会比内容盒高一截，
 * 多出来的部分露出 `backgroundColor`（默认白，深色模式下就是一条浅色带）。
 * 固定 vp 高度 + `detents: [同一值]` 才是自洽的。
 */
export function menuSheetHeight(rows: number, bottomPad: number = Spacing.LG): number {
  const gaps: number = rows > 1 ? (rows - 1) * Spacing.XS : 0;
  return ComponentSize.ROW * rows + gaps + SHEET_PAD_TOP + bottomPad;
}

/**
 * 按主题缓存 SheetOptions（**缓存按传入的组件实例隔离**）
 *
 * **为什么需要它**：`SheetOptions.backgroundColor` 只在 `bindSheet` **重新挂载**时生效，
 * 而各页的 options 若写成字段初始化器（`private x = panelSheetOptions(...)`），
 * 只在组件构造时执行一次——**捕获的是构造时的颜色字符串**。首页（Navigation 根内容）
 * 组件常驻不销毁，深浅色切换后 options 里仍是旧颜色：面板本体由 builder 每帧重绘
 * （用 getter 取实时色），但**面板被上拉后多出来的区域**显示的是 options 里的过期色
 * ——深色模式下就是一条白带（真机/模拟器都实测到过）。设置系页面是 NavDestination、
 * 每次进入都重建组件，所以从未复现——这就是「首页全有、下级页面全无」的原因。
 *
 * **为什么不能每次 build 直接新建 options**：options 对象身份变化会被当作重新挂载，
 * 曾实测导致主题切换等重渲染时同步面板意外弹出（见 PasswordListPage 的历史注释）。
 * 因此按「背景色 + 高度」缓存：主题没变 → 返回同一对象（稳定引用，不会重新挂载）；
 * 主题变了 → 重建并替换。页面把字段改成 getter 调它即可：
 *
 * ```
 * private get syncSheetOptions(): SheetOptions {
 *   return themedSheetOptions(this, 'HomeSync', () => panelSheetOptions(this.colors.surface, 480, cb),
 *     this.colors.surface, 480);
 * }
 * ```
 *
 * @param scope **组件实例本身**（写 `this`）。**必须传**：缓存的 `onDisappear` 闭包
 *            绑定的是首次构建 options 的那个实例；NavDestination 页面每次进入都会
 *            重建组件，若缓存跨实例共享，上一个（已销毁的）实例的复位回调会在
 *            新实例手势收起面板时被触发——新实例自己的可见状态复位不了，
 *            面板从此再也弹不出来（实测：Git 配置页的 SSH 密钥面板，离开页面
 *            再进来后手势下滑一次即复发）。WeakMap 以实例为键，页面销毁后
 *            条目随之可回收，不会泄漏。
 * @param tag 同一实例内**唯一**的缓存标识（建议「页面+面板」命名）。同一实例里
 *            两个逻辑弹窗共用同一键就会共享 onDisappear，A 面板手势收起时触发的
 *            却是 B 面板的复位回调，状态残留后 A 再也弹不出来（实测：首页
 *            「同步存储库」与「修改此目录加密密钥」曾因同为 480vp 撞键）。
 * @param build 工厂：返回新配置（仅在缓存失效时被调用）
 * @param keyBackground 参与缓存键的背景色（随主题变化）
 * @param keyHeight 参与缓存键的高度（同一面板的多形态高度不同）
 */
const themedSheetScopes: WeakMap<object, Map<string, SheetOptions>> = new WeakMap();
export function themedSheetOptions(
  scope: object, tag: string, build: () => SheetOptions, keyBackground: string, keyHeight: Length): SheetOptions {
  let cache: Map<string, SheetOptions> | undefined = themedSheetScopes.get(scope);
  if (!cache) {
    cache = new Map();
    themedSheetScopes.set(scope, cache);
  }
  const key: string = `${tag}|${keyBackground}|${keyHeight}`;
  let cached: SheetOptions | undefined = cache.get(key);
  if (!cached) {
    cached = build();
    cache.set(key, cached);
  }
  return cached;
}
