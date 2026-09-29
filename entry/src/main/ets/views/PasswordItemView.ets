import { PasswordEntryVM } from '../viewmodel/PasswordListViewModel';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';
import { Strings } from '../common/Strings';

/**
 * 密码条目列表项组件
 *
 * 显示单个密码条目或目录（主标题 + 目录数量 + 右箭头）。
 * 对齐鸿蒙列表规范：
 * - 行高 56vp（`ComponentSize.ROW`）、圆角 16vp（`Radius.CARD`）、卡片底色 `surface`；
 * - 行内水平内边距 16vp（卡片外已有页面级 16vp 内边距，行内再给 16vp 才是规范的 16+16）；
 * - 标题 Subtitle(16) Medium 主文本色，右侧数量 Caption(12) 弱化色，箭头 20vp 弱化色；
 * - **按压反馈**：`stateStyles` 的 pressed 分支给不透明复合色（Row 作可点区域默认无反馈）。
 *
 * 「内容匹配」搜出来的条目还会带一行副标题（`entry.contentSnippet`），说明它为什么命中——
 * 此时行高切到双行 64vp（`ComponentSize.ROW_TWO_LINE`，官方列表阶梯）。
 */
@ComponentV2
export struct PasswordItemView {
  @Param entry: PasswordEntryVM = {
    name: '',
    relativePath: '',
    isDirectory: false,
    childCount: 0,
    lastModified: 0,
    contentSnippet: '',
  };
  /** 点击回调（进入目录或打开密码详情） */
  @Param onItemClicked: (entry: PasswordEntryVM) => void = (entry: PasswordEntryVM): void => {};

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  build() {
    Row() {
      Column() {
        // 主标题
        Text(this.entry.name)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 内容匹配的命中片段（不含主密码）：说明这条为什么出现在结果里
        if (this.entry.contentSnippet.length > 0) {
          Text(Strings.fmt('home_search_content_hit', this.entry.contentSnippet))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: Spacing.XS })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

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
    // 有命中片段时用双行行高（官方列表阶梯 64vp），否则单行 56vp
    .height(this.entry.contentSnippet.length > 0 ? ComponentSize.ROW_TWO_LINE : ComponentSize.ROW)
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
