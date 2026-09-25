import { ThemeColors, Palette, FontSize, Radius, Spacing, ComponentSize } from '../common/ThemeColors';

/**
 * 全模态进度遮罩（克隆等耗时操作的进度指示）
 *
 * 用在「一次操作要几十秒、且中途绝不能被别的操作打断」的场景：整页盖一层
 * 半透明遮罩 + 居中卡片（旋转图标 + 文案）。
 *
 * **必须由调用方放在页面最外层容器的最后一个子节点**，才能盖住标题栏与全部内容；
 * 只挂在某个局部容器里，标题栏的返回按钮仍可点。
 *
 * 三点约定：
 * - `.hitTestBehavior(HitTestMode.Block)` 吞掉全部触摸（含滚动、按钮），
 *   这是「禁止其它操作」的**唯一**手段——只画一层颜色是挡不住点击的；
 * - **返回键/侧滑返回不归它管**：遮罩挡不住系统返回手势，调用方必须同时在
 *   `NavDestination` 上挂 `.onBackPressed(() => busy)`（返回 true 表示消费掉返回）；
 * - 遮罩色取 `overlayScrim` 令牌（深浅两套都是半透明黑），进度卡片用 `surface`
 *   保证在两种主题下都清晰可读。
 */
@ComponentV2
export struct LoadingOverlay {
  /** 进度文案（如「正在克隆远程仓库…」） */
  @Param text: string = '';
  /**
   * 进度百分比（0-100）；**负数表示不确定态**（显示旋转图标）
   *
   * 有确定进度时渲染 `Progress` 环形 + 中心百分比文字，没有时退回旋转图标——
   * 因为有些阶段拿不到总量（例如克隆还没收到服务端 pack 头），此时画一个
   * 停在 0% 的环比旋转图标更容易被误认为卡死。
   */
  @Param percent: number = -1;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  /** 是否有确定进度 */
  private hasPercent(): boolean {
    return this.percent >= 0;
  }

  build() {
    Column() {
      Column() {
        if (this.hasPercent()) {
          // Progress **不支持子组件**，中心文字只能用 Stack 叠一层
          Stack() {
            Progress({ value: this.percent, total: 100, type: ProgressType.Ring })
              .width(ComponentSize.CONTROL * 2)
              .height(ComponentSize.CONTROL * 2)
              .color(this.colors.primary)
              .style({ strokeWidth: 6, shadow: false })

            Text(`${Math.round(this.percent)}%`)
              .fontSize(FontSize.BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors.textPrimary)
          }
          .width(ComponentSize.CONTROL * 2)
          .height(ComponentSize.CONTROL * 2)
        } else {
          LoadingProgress()
            .width(ComponentSize.CONTROL)
            .height(ComponentSize.CONTROL)
            .color(this.colors.primary)
        }

        Text(this.text)
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.textPrimary)
          .textAlign(TextAlign.Center)
          .margin({ top: Spacing.MD })
      }
      .padding(Spacing.XL)
      // 卡片宽度随文案走但给个下限，避免短文案时卡片被压成窄条
      .constraintSize({ minWidth: 160 })
      .backgroundColor(this.colors.surface)
      .borderRadius(Radius.CARD)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors.overlayScrim)
    // Block：本节点响应触摸测试，同时阻断子节点与兄弟节点的触摸测试——
    // 即遮罩之下的按钮/列表都收不到事件
    .hitTestBehavior(HitTestMode.Block)
  }
}
