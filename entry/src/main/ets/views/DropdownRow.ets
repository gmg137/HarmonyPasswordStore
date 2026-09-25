import { LengthMetrics } from '@kit.ArkUI';
import {
  ThemeColors, Palette, Spacing, FontSize, ComponentSize, Radius, IconSize,
} from '../common/ThemeColors';

/** 下拉选项：显示文本 + 回传值（两者分开，值可以是枚举序号） */
export interface DropdownOption {
  label: string;
  value: string;
}

/**
 * 菜单项最小宽度
 *
 * 系统菜单没有最小宽度约定，宽度随最宽选项走；本应用最短的选项是「bin」，
 * 自然宽只有 ~30vp，窄条菜单不好点也不好看。取 160vp 兜底。
 */
const MENU_MIN_WIDTH: number = 160;

/**
 * 设置项下拉菜单行（标题 + 说明 + 右侧当前值 + 向下三角）
 *
 * 按 HarmonyOS 官方 UX 样例（`HarmonyOSComponentUXExamples` 的
 * `products/phone/.../action/menu/components/DropdownMenu.ets`）实现：
 * - 右侧值区用**次要灰**（`sys.color.font_secondary`）显示当前值，
 *   指示符是**向下三角**（`arrowtriangle_down_fill`，官方样例用 `sys.color.icon_fourth`）
 *   而不是右箭头——右箭头表示「进入下一页」，三角才表示「就地展开选择」；
 * - 点整行用 `bindMenu` 弹出**锚定在行下方**的菜单（不是底部半模态面板），
 *   菜单项按官方写法用 `Menu()` + `MenuItem()` + `menuItemDivider`。
 *
 * 之所以不用 `bindSheet`：半模态是「面板」，用于表单/动作列表；设置项的取值应当
 * 就地展开（菜单锚定在行旁边），这是官方样例与系统设置页的一致做法。
 *
 * ## 菜单项尺寸取自**实测的系统默认菜单**，不是猜的
 *
 * 用系统默认 `MenuItem({ content })` 跑一遍并 dump 布局树（模拟器 1256×2760 @3.5px/vp），
 * 量到：菜单项 `MenuItem` 高 **168px = 48vp**、项内文字左内边距 **42px = 12vp**、
 * 文字字面高 **52px ≈ 16fp（Body_L）**、菜单容器**没有**额外上下内边距
 * （3 项 144vp + 2 条分隔线 = 实测 508px）。换成自定义 `MenuItem(CustomBuilder)` 后
 * 系统**不再**代劳这些尺寸——只放一个 `Text` 会让行高塌到 ~24vp（比系统菜单项矮一半），
 * 故此处显式 `.height(ComponentSize.MENU_ITEM)` + 左右 12vp。
 *
 * 菜单项文字用**官方次要灰**而非主文本色：这是产品要求（深色菜单里主文本偏亮），
 * 且菜单底色由系统绘制、应用改不了，故项内文字/图标/分隔线一律用 `sys.*` 官方令牌，
 * 与系统菜单底色天然同源（行内触发器仍用调色板令牌，那是卡片上的 UI）。
 *
 * 必须是独立 @ComponentV2 子组件（与 FormRow/ToggleRow 同因）：@Builder 按值传参
 * 在参数变化时不会刷新，而这里的「当前值」在首帧之后才由设置异步载入。
 *
 * @Param label 标题
 * @Param sublabel 说明（可选）
 * @Param currentValue 当前值（对应 options[].value）
 * @Param options 可选项
 * @Param onSelect 选中回调（回传 value）
 */
@ComponentV2
export struct DropdownRow {
  @Param label: string = '';
  @Param sublabel: string = '';
  @Param currentValue: string = '';
  @Param options: DropdownOption[] = [];
  @Param onSelect: (v: string) => void = (v: string): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 当前值对应的显示文本（找不到时为空串，不显示半截内容） */
  private currentLabel(): string {
    for (let i: number = 0; i < this.options.length; i++) {
      if (this.options[i].value === this.currentValue) {
        return this.options[i].label;
      }
    }
    return '';
  }

  /**
   * 菜单项内容：官方次要灰 + 官方 Body_L，当前项在右侧加一个同色对勾
   *
   * 高度/内边距对齐系统默认菜单项（48vp / 左右 12vp，见文件头实测记录）。
   */
  @Builder
  menuItemContent(opt: DropdownOption) {
    Row() {
      Text(opt.label)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (opt.value === this.currentValue) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(IconSize.MD)
          .fontColor([$r('sys.color.font_secondary')])
          .margin({ left: Spacing.SM })
      }
    }
    // 不给 width('100%')：菜单宽度由「最宽选项」自然决定（对齐系统菜单行为），
    // 给 100% 会让菜单撑到系统允许的最大宽度（实测 303vp，几乎占满屏，与系统菜单不像）
    .constraintSize({ minWidth: MENU_MIN_WIDTH })
    .height(ComponentSize.MENU_ITEM)
    .padding({ left: Spacing.MD, right: Spacing.MD })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  menuBuilder() {
    Menu() {
      ForEach(this.options, (opt: DropdownOption) => {
        MenuItem(this.menuItemContent(opt))
          .onClick(() => {
            this.onSelect(opt.value);
          })
      }, (opt: DropdownOption) => opt.value)
    }
    // 分隔线用官方令牌：菜单底色由系统绘制，本应用的 divider 令牌是给卡片用的
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: $r('sys.color.comp_background_tertiary'),
      mode: DividerMode.EMBEDDED_IN_MENU,
    })
  }

  build() {
    Row() {
      Column() {
        Text(this.label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)

        if (this.sublabel.length > 0) {
          Text(this.sublabel)
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .margin({ top: Spacing.XS })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右侧值区：次要灰 + 向下三角（官方样例同款），菜单锚定在整行下方右侧
      Text(this.currentLabel())
        .fontSize(FontSize.BODY)
        .fontColor(this.colors.textSecondary)
        .margin({ right: Spacing.SM })

      SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
        .fontSize(FontSize.BODY)
        .fontColor([$r('sys.color.icon_fourth')])
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H, top: Spacing.MD, bottom: Spacing.MD })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .margin({ top: Spacing.CARD_GAP })
    .alignItems(VerticalAlign.Center)
    // 整行可点（不用只点值区：用户习惯点行内任意处），菜单锚到行右下角
    .stateStyles({
      normal: { .backgroundColor(this.colors.surface) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .bindMenu(this.menuBuilder(), { placement: Placement.BottomRight })
  }
}
