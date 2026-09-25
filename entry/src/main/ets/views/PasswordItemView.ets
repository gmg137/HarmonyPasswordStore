import { PasswordEntryVM } from '../viewmodel/PasswordListViewModel';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';

/**
 * 密码条目列表项组件
 *
 * 显示单个密码条目或目录（主标题 + 目录数量 + 右箭头）。
 * 对齐鸿蒙列表规范：
 * - 行高 56vp（`ComponentSize.ROW`）、圆角 16vp（`Radius.CARD`）、卡片底色 `surface`；
 * - 行内水平内边距 16vp（卡片外已有页面级 16vp 内边距，行内再给 16vp 才是规范的 16+16）；
 * - 标题 Subtitle(16) Medium 主文本色，右侧数量 Caption(12) 弱化色，箭头 20vp 弱化色；
 * - **按压反馈**：`stateStyles` 的 pressed 分支给不透明复合色（Row 作可点区域默认无反馈）。
 */
@ComponentV2
export struct PasswordItemView {
  @Param entry: PasswordEntryVM = {
    name: '',
    relativePath: '',
    isDirectory: false,
    childCount: 0,
    lastModified: 0,
  };
  /** 点击回调（进入目录或打开密码详情） */
  @Param onItemClicked: (entry: PasswordEntryVM) => void = (entry: PasswordEntryVM): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row() {
      // 主标题
      Text(this.entry.name)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 目录：右侧显示子条目数量 + 右箭头；密码条目无箭头
      if (this.entry.isDirectory) {
        Text(`${this.entry.childCount}`)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ left: Spacing.SM })

        // SymbolGlyph 渲染 sys.symbol（Image 不支持 symbol 资源着色，会不可见）
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(IconSize.CHEVRON)
          .fontColor([this.colors.textTertiary])
          .margin({ left: Spacing.XS })
      }
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .alignItems(VerticalAlign.Center)
    .stateStyles({
      normal: { .backgroundColor(this.colors.surface) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => {
      if (this.onItemClicked) {
        this.onItemClicked(this.entry);
      }
    })
  }
}
