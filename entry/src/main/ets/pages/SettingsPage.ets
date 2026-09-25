import { SettingsViewModel } from '../viewmodel/SettingsViewModel';
import { ToggleRow } from '../views/ToggleRow';
import { DropdownRow, DropdownOption } from '../views/DropdownRow';
import { PasswordFileFormat, ThemeMode, SearchMode, RouteNames } from '../common/Constants';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { RouteManager } from '../common/RouteManager';
import { AppTitleBar } from '../views/AppTitleBar';

/**
 * 设置页
 *
 * 通用设置（主题/剪贴板超时/应用锁定）、搜索模式、
 * PGP 密钥管理、Git 同步配置入口。
 * 布局对齐 HarmonyOS Design：分组卡片（16vp 圆角 + 列表卡片背景）、
 * 主题分段控件、导航行/开关行统一样式。
 */
@ComponentV2
export struct SettingsPage {
  @Local viewModel: SettingsViewModel = new SettingsViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.load();
  }

  /**
   * 分组标题
   *
   * **下间距必须为 0**：本页标题之后的每一行都是**自带 `margin-top: CARD_GAP`** 的共享
   * 组件（`DropdownRow` / `ToggleRow` / `navRow` / `sliderCardInline`），标题再给下内边距
   * 就会叠加成 24vp——实测真机：标题框底边到卡片顶边 42px(12vp) 全部来自行组件的外边距，
   * 标题自己那 12vp 又加在其上，于是「标题到卡片」与「卡片到下一个标题」都是 24vp，
   * 上下一样、标题读不出归属（曾把这里改成 CARD_GAP，观感「毫无变化」正是因为
   * 那 12vp 不是它给的）。注意 Git 配置页 / 仓库管理页的卡片是手写 `Column`、**不带**
   * 外边距，那两页必须由标题给 `bottom: CARD_GAP`——同一个 12vp 只能由一侧承担，
   * 改任一处前先确认卡片是否自带 margin。
   */
  @Builder
  sectionTitle(title: string, isFirst: boolean) {
    Text(title)
      .fontSize(FontSize.SECTION)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors.textSecondary)
      .width('100%')
      .padding({
        top: isFirst ? Spacing.SECTION_TOP_FIRST : Spacing.SECTION_TOP,
        bottom: 0,
        left: Spacing.ROW_H,
      })
  }



  @Builder
  navRow(label: string, sublabel: string, onTapped: () => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
        Text(sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(IconSize.CHEVRON)
        .fontColor([this.colors.textTertiary])
        .margin({ left: Spacing.SM })
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H, top: Spacing.MD, bottom: Spacing.MD })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .margin({ top: Spacing.CARD_GAP })
    .stateStyles({
      normal: { .backgroundColor(this.colors.surface) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(() => onTapped())
  }

  @Builder
  toggleRow(label: string, sublabel: string, isOn: boolean, onToggle: (v: boolean) => void,
            enabled: boolean = true) {
    Row() {
      Column() {
        Text(label)
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          // 禁用时整行转次要色，避免「看着能点却没反应」
          .fontColor(enabled ? this.colors.textPrimary : this.colors.textTertiary)
        Text(sublabel)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
          .margin({ top: Spacing.XS })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn && enabled })
        .selectedColor(this.colors.primary)
        .enabled(enabled)
        .onChange((v: boolean) => onToggle(v))
    }
    .width('100%')
    .constraintSize({ minHeight: ComponentSize.ROW_TWO_LINE })
    .padding({ left: Spacing.ROW_H, right: Spacing.ROW_H, top: Spacing.MD, bottom: Spacing.MD })
    .borderRadius(Radius.CARD)
    .backgroundColor(this.colors.surface)
    .margin({ top: Spacing.CARD_GAP })
  }

  /**
   * 剪贴板自动清除的可选项
   *
   * 固定四档（15s / 30s / 1min / 2min）。**存量值不在四档内时必须把它补进列表**：
   * 旧版是 10–120s 的滑杆，用户可能停在 45s 这类中间值上，而 `DropdownRow` 找不到
   * 匹配项时当前值区会渲染成空白（看起来像控件坏了）。补一项既显示了真实值，
   * 也让用户能改到四档之一。
   */
  private clipboardTimeoutOptions(): DropdownOption[] {
    const opts: DropdownOption[] = [
      { label: '15s', value: '15' },
      { label: '30s', value: '30' },
      { label: '1min', value: '60' },
      { label: '2min', value: '120' },
    ];
    const current: string = `${this.viewModel.clipboardTimeout}`;
    let matched: boolean = false;
    for (let i: number = 0; i < opts.length; i++) {
      if (opts[i].value === current) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      opts.push({ label: `${current}s`, value: current });
    }
    return opts;
  }

  /** 分段选择控件（单选 pill 组） */

  build() {
    NavDestination() {
      Column() {
        // ===== 标题栏（共享组件：40vp 圆形返回按钮 + 24fp 标题） =====
        AppTitleBar({ title: '设置' })

        Scroll() {
        Column() {
          // ===== 通用 =====
          this.sectionTitle('通用', true)

          DropdownRow({
            label: '主题',
            currentValue: `${this.viewModel.themeMode}`,
            options: [
              { label: '跟随系统', value: `${ThemeMode.SYSTEM}` },
              { label: '浅色', value: `${ThemeMode.LIGHT}` },
              { label: '深色', value: `${ThemeMode.DARK}` },
            ],
            onSelect: (v: string): void => {
              this.viewModel.setThemeMode(Number.parseInt(v) as ThemeMode);
            },
          })

          this.sectionTitle('安全', false)

          ToggleRow({
            label: '生物识别解锁',
            // 不可用时把原因放在副标题里（与「启动时自动同步」一致）
            sublabel: this.viewModel.biometricReason.length > 0
              ? this.viewModel.biometricReason
              : '使用指纹/面容快速解锁应用',
            isOn: this.viewModel.biometricUnlockEnabled,
            // PIN 已彻底移除，应用锁只剩生物识别：设备不支持/未录入时开关置灰，
            // 否则用户打开它却永远不会被锁（或反之被锁住却无法解锁）
            isEnabled: this.viewModel.biometricReason.length === 0,
            onToggle: (v: boolean): void => { this.viewModel.setBiometricEnabled(v); },
          })

          DropdownRow({
            label: '剪贴板自动清除',
            sublabel: '复制密码后，到点自动清空系统剪贴板',
            currentValue: `${this.viewModel.clipboardTimeout}`,
            options: this.clipboardTimeoutOptions(),
            onSelect: (v: string): void => {
              this.viewModel.setClipboardTimeout(Number.parseInt(v));
            },
          })

          // ===== 密码仓库 =====
          this.sectionTitle('密码仓库', false)

          DropdownRow({
            label: '搜索模式',
            currentValue: `${this.viewModel.searchMode}`,
            options: [
              { label: '模糊匹配', value: `${SearchMode.FUZZY}` },
              { label: '精确匹配', value: `${SearchMode.EXACT}` },
            ],
            onSelect: (v: string): void => {
              this.viewModel.setSearchMode(Number.parseInt(v) as SearchMode);
            },
          })

          this.navRow('重新运行初始设置', '初始化仓库 / 克隆 / 导入密钥',
            () => {
              this.viewModel.navigateToOnboarding();
            })

          // ===== Git 同步 =====
          this.sectionTitle('Git 同步', false)

          ToggleRow({
            label: '启动时自动同步',
            sublabel: this.viewModel.autoSyncAvailable
              ? '应用启动时自动执行拉取+推送'
              : this.viewModel.autoSyncDisabledReason,
            isOn: this.viewModel.autoSyncOnLaunch,
            isEnabled: this.viewModel.autoSyncAvailable,
            onToggle: (v: boolean): void => { this.viewModel.setAutoSync(v); },
          })

          this.navRow('仓库管理', 'Git 配置 / 拉取变基 / 删除本地仓库',
            () => {
              this.viewModel.navigateToRepoManage();
            })

          // ===== 加密与凭据 =====
          this.sectionTitle('加密与凭据', false)

          this.navRow('PGP 密钥管理', '导入密钥 / 选择默认加密密钥',
            () => {
              this.viewModel.navigateToPgpKeys();
            })

          this.navRow('SSH 密钥管理', '生成 / 导入公钥 / 删除密钥',
            () => {
              this.viewModel.navigateToSshKeys();
            })

          DropdownRow({
            label: '密码文件格式',
            sublabel: '仅影响之后新建/编辑的密码',
            currentValue: `${this.viewModel.passwordFileFormat}`,
            options: [
              { label: 'bin', value: `${PasswordFileFormat.BIN}` },
              { label: 'armor', value: `${PasswordFileFormat.ARMOR}` },
            ],
            onSelect: (v: string): void => {
              this.viewModel.setPasswordFileFormat(Number.parseInt(v) as PasswordFileFormat);
            },
          })

          // ===== 关于 =====
          this.sectionTitle('关于', false)

          this.navRow('隐私政策', '数据存储与处理说明',
            () => {
              RouteManager.getInstance().pushPath(RouteNames.PRIVACY_POLICY);
            })

          this.navRow('关于本应用', '版本 / 开源协议 / 仓库链接',
            () => {
              RouteManager.getInstance().pushPath(RouteNames.ABOUT);
            })

          Blank()
            .height(Spacing.XL)
          Blank()
            .height(Spacing.XL)
        }
        // 顶部不留白：首个分组标题自身已有 SECTION_TOP_FIRST(12vp) 上边距，
        // 再叠加容器顶部内边距会让「通用」离标题栏过远（曾为 16+12=28vp）
        .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, bottom: Spacing.PAGE_H })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .backgroundColor(this.colors.background)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors.background)
    }
    .hideTitleBar(true)
    // 从「Git 配置 / 仓库管理」返回时重新判断自动同步是否可用：
    // 用户可能刚填好远程地址或刚克隆完，开关该随之解除禁用
    .onShown(() => {
      this.viewModel.refreshAutoSyncAvailability();
    })
  }
}
