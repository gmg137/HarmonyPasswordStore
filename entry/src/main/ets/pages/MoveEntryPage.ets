import { MoveEntryViewModel } from '../viewmodel/MoveEntryViewModel';
import { AppTitleBar } from '../views/AppTitleBar';
import { FormRow } from '../views/FormRow';
import { RouteManager } from '../common/RouteManager';
import { PasswordRepository } from '../model/PasswordRepository';
import { FolderTreeView } from '../views/FolderTreeView';
import { SystemInsets } from '../utils/SystemInsets';
import { SHEET_MASK_COLOR } from '../common/SheetStyles';
import {
  ThemeColors, Palette, Radius, Spacing, FontSize, ButtonSpec, ComponentSize,
} from '../common/ThemeColors';

/** 卡片内标签列宽（与密码详情页的字段行同口径，保证跨页观感一致） */
const MOVE_LABEL_W: number = 72;

/**
 * 移动/重命名密码条目页
 *
 * 「原位置」与「名称」用卡片行呈现（与密码详情页的字段行同一套尺寸：
 * `ROW_TWO_LINE` 高 + `ROW_H` 内边距，内容自顶向下、左对齐），目标目录用目录树选择；
 * 保存按钮**固定在页面底部**（不随内容滚动），距底留白与详情页底部按钮一致。
 */
@ComponentV2
export struct MoveEntryPage {
  @Local viewModel: MoveEntryViewModel = new MoveEntryViewModel();
  /** 底部系统栏高度（vp）：底部固定按钮栏据此避让 */
  @Local bottomInset: number = 0;

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    // 沉浸式布局下底部操作栏要避开系统导航条（px→vp 换算集中见 SystemInsets）
    this.bottomInset = SystemInsets.bottomVp();
    const param: Object | undefined = RouteManager.getInstance().takeLastParam();
    if (param) {
      const p = param as Record<string, string>;
      this.viewModel.init(p['path'] ?? '');
    }
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          AppTitleBar({ title: '移动 / 重命名' })

        Scroll() {
          Column() {
            // 原位置（只读卡片：高度与「名称」卡片一致 = ROW，
            // 值用灰色字体现不可编辑；同时是 ROW_TWO_LINE 会高出一截）
            Row() {
              Text('原位置')
                .fontSize(FontSize.BODY)
                .fontColor(this.colors.textSecondary)
                .width(MOVE_LABEL_W)
              Text(this.viewModel.oldPath)
                .fontSize(FontSize.SUBTITLE)
                .fontColor(this.colors.textTertiary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(ComponentSize.ROW)
            .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .alignItems(VerticalAlign.Center)

            // 名称（可编辑卡片）：用 FormRow 而非按值传参的 @Builder，
            // 后者在 init() 异步填入原名称后不会刷新，输入框会显示空白
            Column() {
              FormRow({
                label: '名称',
                placeholder: '输入新名称',
                value: this.viewModel.newName,
                labelWidth: MOVE_LABEL_W,
                onInput: (v: string): void => {
                  this.viewModel.newName = v;
                },
              })
            }
            .width('100%')
            .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H })
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .margin({ top: Spacing.CARD_GAP })

            // 目标目录
            Text('目标目录')
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textSecondary)
              .margin({ top: Spacing.SECTION_TOP, bottom: Spacing.SM })

            FolderTreeView({
              selectedPath: this.viewModel.targetDir,
              onSelected: (path: string): void => {
                this.viewModel.onDirSelected(path);
              },
              storePath: PasswordRepository.getInstance().getStorePath(),
            })
          }
          .width('100%')
          // 内容自顶向下、左对齐（Column 默认水平居中，会把标签缩到中间）
          .alignItems(HorizontalAlign.Start)
          .padding({
            left: Spacing.PAGE_H, right: Spacing.PAGE_H,
            top: Spacing.SECTION_TOP_FIRST, bottom: Spacing.LG,
          })
        }
        .layoutWeight(1)
        // 内容比视口矮时 Scroll 默认**垂直居中**，必须显式顶到左上，
        // 否则卡片会被推到页面中间（详情页的 Scroll 同样挂了这一行）
        .align(Alignment.TopStart)
        .scrollBar(BarState.Auto)

        // ===== 固定底部操作栏（不随内容滚动）=====
        Column() {
          if (this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.danger)
              .width('100%')
              .margin({ bottom: Spacing.SM })
          }

          if (this.viewModel.toast.length > 0) {
            Text(this.viewModel.toast)
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.success)
              .width('100%')
              .margin({ bottom: Spacing.SM })
          }

          Button(this.viewModel.isSaving ? '保存中...' : '保存')
            .width('100%')
            .height(ButtonSpec.PRIMARY_HEIGHT)
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.PRIMARY_RADIUS)
            .backgroundColor(this.colors.primary)
            .fontColor(this.colors.onPrimary)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .enabled(!this.viewModel.isSaving)
            .onClick(() => {
              this.viewModel.save();
            })
        }
        .width('100%')
        .padding({
          left: Spacing.PAGE_H, right: Spacing.PAGE_H, top: Spacing.MD,
          // 与密码详情页底部按钮**完全同口径**：只留系统导航条高度，不要再加
          // SHEET_PAD_BOTTOM——那会让按钮比详情页高 24vp（实测 52vp vs 28vp）
          bottom: this.bottomInset,
        })
        .backgroundColor(this.colors.background)
        }
        .width('100%')
        .height('100%')

        // ===== 密钥口令弹窗（目标目录密钥不同、旧密钥未解锁时才出现）=====
        // 用页内遮罩而非 bindSheet/AlertDialog：与详情页的口令提示同一观感，
        // 且不涉及「面板未关时 AlertDialog 不进布局树」那类坑
        if (this.viewModel.passphraseVisible) {
          Column() {
            Column() {
              Text('请输入密钥密码')
                .fontSize(FontSize.SUBTITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.colors.textPrimary)

              Text(this.viewModel.candidateLabels.length > 0
                ? `目标目录使用其他密钥，需先用原密钥解密。PGP ID：${this.viewModel.candidateLabels}`
                : '目标目录使用其他密钥，需先用原密钥解密后重新加密')
                .fontSize(FontSize.CAPTION)
                .fontColor(this.colors.textTertiary)
                .margin({ top: Spacing.SM })

              TextInput({ placeholder: '密钥密码' })
                .type(InputType.Password)
                .fontSize(FontSize.BODY)
                .width('100%')
                .height(ComponentSize.CONTROL)
                .borderRadius(Radius.CARD)
                .backgroundColor(this.colors.inputBackground)
                .margin({ top: Spacing.LG })
                .onChange((v: string) => {
                  this.viewModel.dialogPassphrase = v;
                })

              if (this.viewModel.dialogError.length > 0) {
                Text(this.viewModel.dialogError)
                  .fontSize(FontSize.CAPTION)
                  .fontColor(this.colors.danger)
                  .width('100%')
                  .margin({ top: Spacing.SM })
              }

              Row({ space: Spacing.SM }) {
                Button('取消')
                  .type(ButtonType.Normal)
                  .borderRadius(ButtonSpec.SECONDARY_RADIUS)
                  .layoutWeight(1)
                  .height(ButtonSpec.SECONDARY_HEIGHT)
                  .backgroundColor(this.colors.neutralButton)
                  .fontColor(this.colors.textSecondary)
                  .fontSize(ButtonSpec.FONT_SIZE)
                  .onClick(() => {
                    this.viewModel.cancelPassphrase();
                  })

                Button(this.viewModel.isUnlocking ? '处理中...' : '确认')
                  .type(ButtonType.Normal)
                  .borderRadius(ButtonSpec.PRIMARY_RADIUS)
                  .layoutWeight(1)
                  .height(ButtonSpec.PRIMARY_HEIGHT)
                  .backgroundColor(this.colors.primary)
                  .fontColor(this.colors.onPrimary)
                  .fontSize(ButtonSpec.FONT_SIZE)
                  .fontWeight(ButtonSpec.FONT_WEIGHT)
                  .enabled(!this.viewModel.isUnlocking)
                  .onClick(() => {
                    this.viewModel.confirmPassphrase();
                  })
              }
              .width('100%')
              .margin({ top: Spacing.LG })
            }
            .width('100%')
            .padding(Spacing.XL)
            .backgroundColor(this.colors.surface)
            .borderRadius(Radius.CARD)
            .margin({ left: Spacing.XL, right: Spacing.XL })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(SHEET_MASK_COLOR)
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.colors.background)
  }
}
