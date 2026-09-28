import { PasswordListViewModel, PasswordEntryVM, PasswordDetailNavParam, PasswordCreateNavParam } from '../viewmodel/PasswordListViewModel';
import { showToastSafe } from '../utils/ToastUtil';
import { SyncViewModel } from '../viewmodel/SyncViewModel';
import { FolderCreateViewModel } from '../viewmodel/FolderCreateViewModel';
import { SyncSheet } from '../views/SyncSheet';
import { PasswordItemView } from '../views/PasswordItemView';
import { RouteManager } from '../common/RouteManager';
import { RouteNames } from '../common/Constants';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ButtonSpec, ComponentSize, DividerSpec } from '../common/ThemeColors';
import { AppFab } from '../views/AppFab';
import { EmptyState } from '../views/EmptyState';
import { RepoChangeNotifier } from '../common/RepoChangeNotifier';
import { BackHandler } from '../common/BackHandler';
import { PgpCrypto, UnlockResult } from '../crypto/PgpCrypto';
import { PgpKeyManager } from '../crypto/PgpKeyManager';
import { PasswordRepository } from '../model/PasswordRepository';
import { GpgKeyId } from '../model/GpgKeyId';
import { SettingsRepository } from '../model/SettingsRepository';
import { GitConfig } from '../model/GitConfig';
import { GitClient } from '../utils/GitClient';
import { formSheetOptions, menuSheetHeight, panelSheetOptions, themedSheetOptions, SHEET_PAD_TOP, SHEET_PAD_BOTTOM } from '../common/SheetStyles';
import { ReencryptService, ReencryptPlan, ReencryptOutcome } from '../utils/ReencryptService';
import { LoadingOverlay } from '../views/LoadingOverlay';
import { Strings } from '../common/Strings';
import { SystemInsets } from '../utils/SystemInsets';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 待执行的目录密钥变更（旧密钥口令在弹窗里解锁后继续） */
interface ReencryptPending {
  dirPath: string;
  /** 目标接收方（可多把：pass 的 .gpg-id 每行一把，混合算法亦支持） */
  fingerprints: string[];
  plan: ReencryptPlan;
}

/** hilog 域 */
const DOMAIN: number = 0x0001;
/** hilog 标签 */
const TAG: string = 'PasswordListPage';
/**
 * 首页动作菜单面板高度（vp）
 *
 * 3 行动作（创建新密码 / 创建新目录 / 修改此目录加密密钥）按行数算，
 * 与 PGP/SSH 页菜单共用 `menuSheetHeight()`；底距用菜单态口径 `Spacing.LG`。
 * 原先用 '33%'（约 260vp）比内容高一截，底部留出大片空白。
 */
const MENU_SHEET_HEIGHT: number = menuSheetHeight(3, Spacing.LG);

/**
 * 搜索输入框的组件 id
 *
 * 供 `FocusController.requestFocus()` 定位——点搜索按钮后要把焦点落进输入框，
 * 否则用户还得再点一下才能打字（键盘也不会自动弹起）。
 */
const SEARCH_INPUT_ID: string = 'passwordSearchInput';

/**
 * 密码列表主页
 *
 * 展示密码仓库的目录/条目列表，支持搜索、排序、同步入口。
 * 布局对齐 HarmonyOS Design：搜索栏卡片化、列表卡片背景、
 * 强调色浮动添加按钮。
 */
@ComponentV2
export struct PasswordListPage {
  @Local viewModel: PasswordListViewModel = new PasswordListViewModel();
  @Local syncViewModel: SyncViewModel = new SyncViewModel();
  @Local isSyncSheetVisible: boolean = false;
  /** 新建底部菜单（创建新目录/创建新密码） */
  @Local isCreateSheetVisible: boolean = false;
  /** 创建新目录表单可见（在 create sheet 内切换显示） */
  @Local isCreateDirFormVisible: boolean = false;
  /** 创建目录 VM（sheet 内复用 FolderCreateViewModel 逻辑） */
  folderCreateVM: FolderCreateViewModel = new FolderCreateViewModel();
  /** 搜索模式：顶栏应用名隐藏、显示搜索框 */
  @Local isSearchBarVisible: boolean = false;
  /** 设置下拉菜单可见 */
  @Local isMenuVisible: boolean = false;
  /** 仓库变更通知器（子页面保存/删除后 bump 触发刷新；@Local 使 @Monitor 可观察） */
  @Local notifier: RepoChangeNotifier = RepoChangeNotifier.connect();

  // ===== 解密密码原生弹窗状态 =====
  @Local isPassphraseDialogVisible: boolean = false;
  @Local dialogPassphrase: string = '';
  @Local dialogError: string = '';
  @Local isUnlocking: boolean = false;
  /** 待解密条目对应的加密密钥 ID（弹窗中展示，提示用户需使用哪把密钥） */
  @Local dialogKeyId: string = '';
  /** 待解密的密码条目（弹窗确认后跳详情） */
  private pendingEntry: PasswordEntryVM | null = null;
  /**
   * 列表滚动控制器：左滑删除后需 closeAllSwipeActions() 收起已展开的按钮
   *
   * 类型必须是 ListScroller（继承 Scroller），`closeAllSwipeActions` 只在 ListScroller 上
   */
  private listScroller: ListScroller = new ListScroller();
  /** 当前弹窗 id（openCustomDialog 返回，用于关闭） */
  private passphraseDialogId: number = -1;

  /** 当前调色板（getter 每次构建求值；ThemeColors.isDark 为 @Trace，深浅色切换自动刷新） */
  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {

    this.viewModel.loadEntries();
    // 根内容非 NavDestination：返回键经 Index.onBackPress 转发到此
    BackHandler.set((): boolean => {
      // 目录密钥重加密（预扫/执行）期间吞掉返回：进度遮罩挡不住系统返回，
      // 中途退出会让逐条重加密的结果无人接收（同克隆进度遮罩的约定）
      if (this.reencryptBusy) {
        return true;
      }
      if (this.viewModel.currentDir.length > 0) {
        this.viewModel.navigateUp();
        return true;
      }
      return false;
    });
  }

  aboutToDisappear(): void {
    BackHandler.set(null);
  }

  /**
   * notifier.nonce 变化时自动刷新（子页面保存/删除后调用
   * RepoChangeNotifier.connect().bump() 通知根页面）
   */
  @Monitor('notifier.nonce')
  onRepoChange(): void {
    this.viewModel.loadEntries();
  }

  /**
   * 检查是否已配置远程 Git 仓库地址；未配置时弹窗引导前往 Git 配置页。
   *
   * 同步/拉取/推送都依赖远程地址，未配置时直接调用只会静默失败，
   * 用户看不到任何反馈；这里先判断并给出可操作的引导。
   * @returns true = 已配置，可以继续执行同步操作
   */
  private async ensureRemoteConfigured(): Promise<boolean> {
    const config: GitConfig = await SettingsRepository.getInstance().loadGitConfig();
    if (config.remoteUrl.trim().length > 0) {
      return true;
    }

    this.getUIContext().showAlertDialog({
      title: $r('app.string.sync_no_remote_title'),
      message: $r('app.string.sync_no_remote_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      // primaryButton 在左、secondaryButton 在右 → 取消 / 配置
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.common_configure'),
        fontColor: this.colors.primary,
        action: (): void => {
          RouteManager.getInstance().pushPath(RouteNames.GIT_CONFIG);
        },
      },
    });
    return false;
  }

  /** 打开同步面板（未配置远程仓库时先弹窗引导） */
  private async openSyncSheet(): Promise<void> {
    if (!(await this.ensureRemoteConfigured())) {
      return;
    }
    this.isSyncSheetVisible = true;
  }

  /**
   * 执行一键同步，并以系统 Toast 反馈结果
   *
   * 一键同步 = 拉取 → 提交 → 推送（见 SyncViewModel.syncAll）。
   * 列表刷新由 GitClient.pull 成功后的 RepoChangeNotifier.bump() 负责，
   * 这里不再手动重载，避免同一次操作触发两遍。
   */
  private async runSyncOperation(kind: string): Promise<void> {
    if (!(await this.ensureRemoteConfigured())) {
      return;
    }
    if (kind === 'sync') {
      await this.syncViewModel.syncAll();
    } else if (kind === 'pull') {
      await this.syncViewModel.pull();
    } else {
      await this.syncViewModel.push();
    }
    const ok: boolean = this.syncViewModel.lastOperationSuccess;
    const doneLabel: string = kind === 'sync' ? Strings.get('sync_done')
      : (kind === 'pull' ? Strings.get('sync_pull_done') : Strings.get('sync_push_done'));
    showToastSafe(this.getUIContext(), ok ? doneLabel : this.syncViewModel.resultToast, 2500);
  }

  /**
   * bindSheet 配置（**必须走 getter + themedSheetOptions**，不能写成字段初始化器）：
   * 首页是 Navigation 根内容、组件常驻不销毁，字段初始化器捕获的 backgroundColor
   * 停留在构造时的主题色——深浅色切换后 options 里仍是旧色，面板被上拉后多出的
   * 区域露出的正是这个过期色（深色下是白带，实测复现过）。themedSheetOptions
   * 按背景色+高度缓存：主题没变返回同一对象（稳定引用，不会因重渲染意外弹出），
   * 主题变了才重建。
   *
   * 不传 options.title：SyncSheet 内部已渲染「Git 同步」标题，
   * 再给原生标题栏会重复显示两遍。
   */
  private get syncSheetOptions(): SheetOptions {
    return themedSheetOptions(this, 'HomeSync', (): SheetOptions => panelSheetOptions(
      this.colors.surface, 480,
      // 关闭时同步状态：否则手势/返回关闭后 isSyncSheetVisible 仍为 true，
      // 再次置 true 不触发状态变化，面板无法第二次打开
      (): void => {
        this.isSyncSheetVisible = false;
      }), this.colors.surface, 480);
  }

  @Builder
  syncSheetBuilder() {
    SyncSheet({ viewModel: this.syncViewModel })
  }

  /** 新建底部菜单公共 onDisappear（复位状态，保证可再次弹出） */
  private resetCreateSheet(): void {
    // 菜单→表单切换期间跳过复位（否则切 options 会关闭 sheet 并清掉表单态）
    if (this.isSwitchingToForm) {
      this.isSwitchingToForm = false;
      return;
    }
    // 手势下滑/点遮罩关闭后复位状态与表单，保证可再次弹出
    this.isCreateSheetVisible = false;
    this.isCreateDirFormVisible = false;
    this.dirKeyMode = false;
    this.dirKeySelectedFps = [];
    this.folderCreateVM.folderName = '';
    this.folderCreateVM.errorMessage = '';
  }

  /** 菜单→表单切换中（跳过 onDisappear 复位） */
  @Local isSwitchingToForm: boolean = false;

  /** 是否处于「修改此目录加密密钥」模式 */
  @Local dirKeyMode: boolean = false;
  /** 可选密钥列表（进入该模式时加载） */
  @Local dirKeyCandidates: GpgKeyId[] = [];
  /** 当前目录 .gpg-id 指向的密钥（空 = 继承父目录/默认密钥） */
  @Local dirKeyCurrent: string = '';
  /** 目录密钥面板中已勾选的密钥指纹（多选；确认后才写 .gpg-id 并重加密） */
  @Local dirKeySelectedFps: string[] = [];
  /** 重加密进行中：禁用重复点击 */
  @Local reencryptBusy: boolean = false;
  /**
   * 重加密**执行期**遮罩可见性（与 reencryptBusy 分开）：
   * busy 覆盖预扫 + 执行两段（预扫时面板还开着，用面板按钮忙碌态反馈），
   * 遮罩只在确认后真正逐条重加密时出现——避免口令弹窗期间闪遮罩
   */
  @Local reencryptRunning: boolean = false;
  /** 重加密进度（已处理 / 需重加密条数），驱动 LoadingOverlay 进度环 */
  @Local reencryptDone: number = 0;
  @Local reencryptTotal: number = 0;
  /** 待执行的重加密（口令弹窗解锁成功后继续） */
  private pendingReencrypt: ReencryptPending | null = null;

  /** 菜单态：屏幕高度 1/3（三项动作：创建目录 / 修改目录密钥 / 创建密码）——getter 随主题刷新，见 syncSheetOptions */
  private get createSheetMenuOptions(): SheetOptions {
    return themedSheetOptions(this, 'CreateMenu', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, MENU_SHEET_HEIGHT,
        (): void => this.resetCreateSheet()),
      this.colors.surface, MENU_SHEET_HEIGHT);
  }

  /** 表单态：撑满面板，键盘只 resize 内容（按钮留在面板底部）——getter 随主题刷新，见 syncSheetOptions */
  private get createSheetFormOptions(): SheetOptions {
    return themedSheetOptions(this, 'CreateForm', 
      (): SheetOptions => formSheetOptions(this.colors.surface, (): void => this.resetCreateSheet()),
      this.colors.surface, 'form');
  }

  /**
   * 修改目录密钥态：密钥列表（无需键盘）
   *
   * 固定 480vp（不用百分比）：百分比高度与 detents 的解析不一致，面板会比内容盒高、
   * 底部露出 backgroundColor（默认白）；列表内部滚动，密钥再多也放得下
   */
  private get createSheetDirKeyOptions(): SheetOptions {
    return themedSheetOptions(this, 'CreateDirKey', 
      (): SheetOptions => panelSheetOptions(this.colors.surface, 480, (): void => this.resetCreateSheet()),
      this.colors.surface, 480);
  }

  /**
   * 新建底部菜单：鸿蒙原生风格。
   * 菜单态：动作面板（图标 20vp + 标题 16fp Medium，行高 56vp，圆角 16vp 分组卡片）；
   * 表单态：标题 20fp Medium + 输入框/下拉（高 44、圆角 12）+ 取消/确认（次操作/主操作按钮规范）。
   */
  @Builder
  createSheetBuilder() {
    // 根容器撑满面板；表单态把「字段区」与「按钮行」分开：
    // 软键盘弹起会把面板压矮，按钮若随内容流排布就会被裁到屏外点不到，
    // 因此字段区直接排布（不包 Scroll），按钮行由下方 Blank() 占位撑到面板底部。
    Column() {
      if (this.dirKeyMode) {
        // 修改此目录的加密密钥：列出已导入私钥供选择；选定后预扫→确认→重加密
        Column() {
          Text($r('app.string.home_dirkey_panel_title'))
            .fontSize(FontSize.TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors.textPrimary)
            .width('100%')

          Text(this.viewModel.currentDir.length > 0 ? this.viewModel.currentDir : $r('app.string.store_root_dir'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .width('100%')
            .margin({ top: Spacing.XS })

          Text(this.dirKeyCurrent.length > 0
            ? Strings.fmt('home_dirkey_current', this.dirKeyCurrent)
            : Strings.get('home_dirkey_current_inherit'))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textTertiary)
            .width('100%')
            .margin({ top: Spacing.XS, bottom: Spacing.LG })

          if (this.dirKeyCandidates.length === 0) {
            Text($r('app.string.home_dirkey_no_keys'))
              .fontSize(FontSize.CAPTION)
              .fontColor(this.colors.textTertiary)
              .padding({ top: Spacing.MD, bottom: Spacing.MD })
          } else {
            List() {
              ForEach(this.dirKeyCandidates, (key: GpgKeyId) => {
                ListItem() {
                  Row() {
                    Column() {
                      Text(key.name.length > 0 ? key.name : key.userId)
                        .fontSize(FontSize.SUBTITLE)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.colors.textPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(key.email.length > 0 ? key.email : key.fingerprint)
                        .fontSize(FontSize.CAPTION)
                        .fontColor(this.colors.textTertiary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                        .margin({ top: Spacing.XS })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    // 勾选标记：多选必须给出明确的可选状态，否则用户无从知道能否再选
                    if (this.isDirKeyChecked(key.fingerprint)) {
                      SymbolGlyph($r('sys.symbol.checkmark'))
                        .fontSize(IconSize.MD)
                        .fontColor([this.colors.primary])
                    }
                  }
                  .width('100%')
                  .height(ComponentSize.ROW_TWO_LINE)
                  .padding({ left: Spacing.MD, right: Spacing.MD })
                  .borderRadius(Radius.CARD)
                  .alignItems(VerticalAlign.Center)
                  .stateStyles({
                    normal: {
                      .backgroundColor(this.isDirKeyChecked(key.fingerprint)
                        ? this.colors.primarySoft : this.colors.inputBackground),
                    },
                    pressed: { .backgroundColor(this.colors.pressed) },
                  })
                  .onClick(() => {
                    this.toggleDirKey(key.fingerprint);
                  })
                }
                .margin({ bottom: Spacing.SM })
              }, (key: GpgKeyId) => key.fingerprint)
            }
            .layoutWeight(1)
            .width('100%')
          }

          Row({ space: ButtonSpec.ROW_GAP }) {
            Button(this.reencryptBusy ? Strings.get('home_reencrypting') : Strings.get('common_cancel'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.SECONDARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.SECONDARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .fontWeight(ButtonSpec.FONT_WEIGHT)
              .backgroundColor(this.colors.inputBackground)
              .fontColor(this.colors.textSecondary)
              .enabled(!this.reencryptBusy)
              .onClick(() => {
                this.isCreateSheetVisible = false;
              })

            Button($r('app.string.common_apply'))
              .type(ButtonType.Normal)
              .borderRadius(ButtonSpec.PRIMARY_RADIUS)
              .layoutWeight(1)
              .height(ButtonSpec.PRIMARY_HEIGHT)
              .fontSize(ButtonSpec.FONT_SIZE)
              .fontWeight(ButtonSpec.FONT_WEIGHT)
              .backgroundColor(this.colors.primary)
              .fontColor(this.colors.onPrimary)
              .enabled(this.dirKeySelectedFps.length > 0 && !this.reencryptBusy)
              .opacity(this.dirKeySelectedFps.length > 0 ? 1 : 0.4)
              .onClick(() => {
                this.onApplyDirKeys();
              })
          }
          .width('100%')
          .margin({ top: Spacing.MD })
        }
        .width('100%')
        .height('100%')
        // 留白一律由外层容器统一给：此处再给会叠加成双倍（实测横向多缩进 16vp，
        // 同一面板两个形态的按钮左右边界对不齐）
        .alignItems(HorizontalAlign.Center)
      } else if (!this.isCreateDirFormVisible) {
        // 鸿蒙动作面板：圆角 16vp 分组卡片，行高 56，图标+文字左对齐
        Column() {
          // 顺序：最常用的新建密码在最上，其次建目录，最后是密钥维护
          this.createActionItem($r('sys.symbol.plus'), Strings.get('home_create_password'), (): void => {
            this.isCreateSheetVisible = false;
            // 以当前浏览目录为父目录，目录内新建不再落到根目录
            const param: PasswordCreateNavParam = { parentDir: this.viewModel.currentDir, editPath: '' };
            RouteManager.getInstance().pushPath(RouteNames.PASSWORD_CREATE, param);
          })
          this.menuDivider()
          this.createActionItem($r('sys.symbol.folder_badge_plus'), Strings.get('home_create_folder'), (): void => {
            // 切换 options 会触发 sheet 重建关闭：先关闭，动画结束后以表单态重开
            this.isSwitchingToForm = true;
            this.isCreateSheetVisible = false;
            setTimeout(() => {
              this.isCreateDirFormVisible = true;
              // 必须带上当前目录：parentDir 为空会把新目录建到仓库根，
              // 且 loadKeys 读到的也是根目录的 .gpg-id（默认勾选的密钥同样会错）
              this.folderCreateVM.parentDir = this.viewModel.currentDir;
              // loadKeys 会按父目录 .gpg-id 预勾选密钥，无需页面再指定索引
              this.folderCreateVM.loadKeys();
              this.isCreateSheetVisible = true;
            }, 350);
          })
          this.menuDivider()
          this.createActionItem($r('sys.symbol.key'), Strings.get('home_dirkey_menu'), (): void => {
            this.openDirKeyMode();
          })
        }
        .width('100%')
        .borderRadius(Radius.CARD)
        .backgroundColor(this.colors.surface)
      } else {
        // 字段区：**不能包在 Scroll 里**。
        // 键盘弹起时半模态面板被压缩，系统滚动容器会让内容高度失去约束，
        // 实测面板塌陷到约 161px、输入框被完全裁出布局树（连节点都不存在），
        // 按钮行也随之塌陷。表单内容本身很短，直接顺序排布即可。
        // 创建新目录表单（鸿蒙弹窗规范：标题 20fp Medium，输入框 44vp/圆角 12）
        Text($r('app.string.home_create_folder'))
          .fontSize(FontSize.TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: Spacing.LG })

        TextInput({ text: this.folderCreateVM.folderName, placeholder: $r('app.string.home_folder_name_hint') })
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.colors.textPrimary)
          .placeholderColor(this.colors.textTertiary)
          .placeholderFont({ size: FontSize.SUBTITLE })
          .height(ComponentSize.CONTROL)
          .borderRadius(Radius.MD)
          .backgroundColor(this.colors.inputBackground)
          .padding({ left: Spacing.MD, right: Spacing.MD })
          .margin({ bottom: Spacing.MD })
          .onChange((v: string) => {
            this.folderCreateVM.folderName = v;
          })

        // 加密密钥：多选（每勾选一把都会作为接收方写入该目录 .gpg-id，pass 约定每行一把）。
        // 用**固定高度**的 List 而不是让它自适应：键盘弹起时面板被压缩，
        // 高度自适应的列表会把按钮行挤出面板（见 AGENTS.md 的 bindSheet 键盘避让），
        // 固定高度 + 内部滚动则不受密钥数量影响。
        Text($r('app.string.home_dirkey_multiselect_hint'))
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.textSecondary)
          .width('100%')
          .margin({ bottom: Spacing.SM })

        List() {
          ForEach(this.folderCreateVM.keys, (key: GpgKeyId) => {
            ListItem() {
              Row() {
                Column() {
                  Text(key.name.length > 0 ? key.name : key.userId)
                    .fontSize(FontSize.SUBTITLE)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.colors.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(key.email.length > 0 ? key.email : key.fingerprint)
                    .fontSize(FontSize.CAPTION)
                    .fontColor(this.colors.textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.folderCreateVM.isKeySelected(key.fingerprint)) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(IconSize.MD)
                    .fontColor([this.colors.primary])
                }
              }
              .width('100%')
              .height(ComponentSize.ROW_TWO_LINE)
              .padding({ left: Spacing.MD, right: Spacing.MD })
              .borderRadius(Radius.CARD)
              .alignItems(VerticalAlign.Center)
              .stateStyles({
                normal: {
                  .backgroundColor(this.folderCreateVM.isKeySelected(key.fingerprint)
                    ? this.colors.primarySoft : this.colors.inputBackground),
                },
                pressed: { .backgroundColor(this.colors.pressed) },
              })
              .onClick(() => {
                this.folderCreateVM.toggleKey(key.fingerprint);
              })
            }
            .margin({ bottom: Spacing.XS })
          }, (key: GpgKeyId) => key.fingerprint)
        }
        .width('100%')
        // 固定高度（而非自适应）：键盘弹起时面板被压缩，自适应列表会把按钮行挤出面板
        .height(ComponentSize.ROW_TWO_LINE * 3 + Spacing.XS * 3)
        .scrollBar(BarState.Auto)

        // 弹性占位：把按钮行撑到面板底部（与 PGP/SSH 表单一致）
        Blank()
          .layoutWeight(1)

        // 按钮行
        Row({ space: ButtonSpec.ROW_GAP }) {
          // 次操作：中性底 + 强调色文字
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.SECONDARY_RADIUS)
            .layoutWeight(1)
            .height(ButtonSpec.SECONDARY_HEIGHT)
            .backgroundColor(this.colors.inputBackground)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .fontColor(this.colors.primary)
            .onClick(() => {
              this.isCreateSheetVisible = false;
            })

          // 主操作：强调色底 + onPrimary 文字
          Button(this.folderCreateVM.isSaving ? Strings.get('home_creating') : Strings.get('common_confirm'))
            .type(ButtonType.Normal)
            .borderRadius(ButtonSpec.PRIMARY_RADIUS)
            .layoutWeight(1)
            .height(ButtonSpec.PRIMARY_HEIGHT)
            .backgroundColor(this.colors.primary)
            .fontSize(ButtonSpec.FONT_SIZE)
            .fontWeight(ButtonSpec.FONT_WEIGHT)
            .fontColor(this.colors.onPrimary)
            .enabled(this.folderCreateVM.folderName.trim().length > 0 && !this.folderCreateVM.isSaving)
            .opacity(this.folderCreateVM.folderName.trim().length > 0 ? 1 : 0.4)
            .onClick(() => {
              this.confirmCreateDirectory();
            })
        }
        .width('100%')
        .margin({ top: Spacing.MD })

        if (this.folderCreateVM.errorMessage.length > 0) {
          Text(this.folderCreateVM.errorMessage)
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.danger)
            .width('100%')
            .margin({ top: Spacing.SM })
        }
      }
    }
    .width('100%')
    .height('100%')
    // 顶部留出拖拽指示器空间（SHEET_PAD_TOP 含 dragBar 高度）；
    // 底部：表单态给按钮行留出与屏幕下沿的距离，菜单态按动作面板规范紧贴下沿
    .padding({
      top: SHEET_PAD_TOP,
      left: Spacing.LG,
      right: Spacing.LG,
      // 表单态与「修改目录密钥」态都用 SHEET_PAD_BOTTOM：两者的按钮行都在内容流末尾，
      // 底部留白不一致会让同一面板的两个形态按钮高度不同（实测 24vp vs 16vp）
      bottom: (this.isCreateDirFormVisible || this.dirKeyMode) ? SHEET_PAD_BOTTOM : Spacing.LG,
    })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors.surface)
  }

  /** 鸿蒙动作面板行：图标 20vp + 标题 16fp Medium，行高 56vp，按下态反馈 */
  @Builder
  createActionItem(icon: Resource, label: string, onTap: () => void) {
    Row() {
      SymbolGlyph(icon)
        .fontSize(IconSize.ACTION)
        .fontColor([this.colors.primary])

      Text(label)
        .fontSize(FontSize.SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors.textPrimary)
        .margin({ left: Spacing.MD })
    }
    .width('100%')
    .height(ComponentSize.ROW)
    .padding({ left: Spacing.MD, right: Spacing.MD })
    .borderRadius(Radius.CARD)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(this.colors.pressed) },
    })
    .onClick(onTap)
  }

  /** 下拉菜单项 */
  @Builder
  menuItem(label: string, onTap: () => void) {
    Text(label)
      .fontSize(FontSize.SUBTITLE)
      .fontColor(this.colors.textPrimary)
      .width('100%')
      .textAlign(TextAlign.Start)
      .height(ComponentSize.CONTROL + Spacing.SM)
      .padding({ left: Spacing.LG, right: Spacing.LG })
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(onTap)
  }

  /** 下拉菜单分隔线 */
  @Builder
  menuDivider() {
    Divider()
      .color(this.colors.divider)
      .margin({ left: Spacing.LG, right: Spacing.LG })
  }

  /**
   * 确认创建目录：用勾选的密钥（可多把）创建子目录并写入 .gpg-id，
   * 成功后关闭 sheet 并刷新列表
   */
  private confirmCreateDirectory(): void {
    const vm: FolderCreateViewModel = this.folderCreateVM;
    // 勾选状态即 vm.selectedFingerprints（表单里由 toggleKey 维护），直接落盘；
    // createFolder 会为每把密钥写一行 .gpg-id（pass 约定）
    vm.createFolder().then(() => {
      if (vm.errorMessage.length === 0) {
        this.isCreateSheetVisible = false;
        this.isCreateDirFormVisible = false;
        vm.folderName = '';
        this.viewModel.loadEntries();
      }
    });
  }

  /**
   * 收起顶栏搜索框：清空搜索恢复目录列表，回到应用名/目录名标题模式
   */
  collapseSearchBar(): void {
    if (!this.isSearchBarVisible) return;
    this.viewModel.clearSearch();
    this.isSearchBarVisible = false;
  }

  /**
   * 条目解密候选密钥：**密文实际收件人优先**，再退回 .gpg-id 指定的密钥
   *
   * `.gpg-id` 只决定加密时的接收方。改过 `.gpg-id`（换密钥）后，旧条目仍由旧密钥
   * 加密——此时若只看 `.gpg-id` 就会向用户索取**新**密钥的口令，解锁"成功"后却解不开
   * 密文（表现为进详情页再弹一次口令框）。故以密文的收件人 Key ID 为权威依据，
   * 与 `pass` 的 `gpg --decrypt --list-only` 同源。
   */
  private entryDecryptionCandidates(entry: PasswordEntryVM): string[] {
    const gpgIdFps: string[] = PgpKeyManager.getInstance()
      .resolvedKeyFingerprints(PasswordRepository.getInstance().getGpgIdForPath(entry.relativePath));
    const ciphertext: string = PasswordRepository.getInstance().readCiphertext(entry.relativePath);
    return PgpCrypto.getInstance().entryDecryptionCandidates(ciphertext, gpgIdFps);
  }

  /**
   * 进入「修改此目录加密密钥」模式
   *
   * 切换 sheet 的 options 会触发面板重建关闭，故沿用「先关、动画结束后重开」的做法。
   */
  private async openDirKeyMode(): Promise<void> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    const dirPath: string = this.viewModel.currentDir;
    const gpgId: string[] = PasswordRepository.getInstance().getGpgIdForPath(dirPath);
    // 预勾选该目录现有 .gpg-id 指向的密钥（KeyID/小写指纹统一解析为标准指纹），
    // 否则用户一进面板就看到「全未选中」，容易误以为当前没设密钥而重复配置
    const selected: string[] = [];
    const mgr: PgpKeyManager = PgpKeyManager.getInstance();
    for (let i: number = 0; i < gpgId.length; i++) {
      const resolved: GpgKeyId | null = mgr.resolveKeyByIdEntry(gpgId[i]);
      if (resolved !== null) {
        selected.push(resolved.fingerprint);
      }
    }
    // 标签按解析出的标准指纹统一生成：同名密钥会带指纹后缀，避免两把 gmg137 无法区分
    this.dirKeyCurrent = this.keyLabelsFor(selected).join(Strings.get('common_list_sep'));
    this.dirKeySelectedFps = selected;
    this.dirKeyCandidates = keys;
    this.isSwitchingToForm = true;
    this.isCreateSheetVisible = false;
    setTimeout(() => {
      this.dirKeyMode = true;
      this.isCreateSheetVisible = true;
    }, 350);
  }

  /** 该密钥是否已勾选（面板多选态） */
  private isDirKeyChecked(fingerprint: string): boolean {
    return this.dirKeySelectedFps.indexOf(fingerprint) >= 0;
  }

  /**
   * 密钥展示标签列表（同名密钥追加指纹后缀区分）
   *
   * 一个目录可能同时挂同名不同邮箱的两把密钥（如 gmg137@live.com 与 gmg137@163.com），
   * 只显示姓名会让「将用「gmg137、test、gmg137」重新加密」这类文案无法辨认到底选了哪两把。
   */
  private keyLabelsFor(fingerprints: string[]): string[] {
    const mgr: PgpKeyManager = PgpKeyManager.getInstance();
    const labels: string[] = [];
    for (let i: number = 0; i < fingerprints.length; i++) {
      labels.push(mgr.keyLabelFor(fingerprints[i]));
    }
    const out: string[] = [];
    for (let i: number = 0; i < labels.length; i++) {
      let label: string = labels[i];
      for (let j: number = 0; j < labels.length; j++) {
        if (j !== i && labels[j] === label) {
          const fp: string = fingerprints[i];
          label = `${label}（…${fp.substring(Math.max(0, fp.length - 8))}）`;
          break;
        }
      }
      out.push(label);
    }
    return out;
  }

  /** 切换勾选（重新赋值数组以触发 @Local 刷新） */
  private toggleDirKey(fingerprint: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (let i: number = 0; i < this.dirKeySelectedFps.length; i++) {
      if (this.dirKeySelectedFps[i] === fingerprint) {
        removed = true;
      } else {
        next.push(this.dirKeySelectedFps[i]);
      }
    }
    if (!removed) {
      next.push(fingerprint);
    }
    this.dirKeySelectedFps = next;
  }

  /**
   * 应用所选密钥：先预扫（不动文件），把代价摆给用户确认
   *
   * 预扫会算出「要重加密几条 / 因缺私钥跳过几条 / 需要哪把旧密钥的口令」。
   * 多把目标密钥共用一次预扫：plan 的目标是「目标 Key ID 集合」，
   * 与接收方是一把还是多把无关。
   */
  private async onApplyDirKeys(): Promise<void> {
    try {
      await this.onApplyDirKeysInner(this.dirKeySelectedFps.slice());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'onApplyDirKeys failed: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      showToastSafe(this.getUIContext(), Strings.get('home_reencrypt_error_toast'), 2500);
    }
  }

  private async onApplyDirKeysInner(fingerprints: string[]): Promise<void> {
    if (this.reencryptBusy) {
      return;
    }
    if (fingerprints.length === 0) {
      showToastSafe(this.getUIContext(), Strings.get('home_dirkey_need_selection'), 2500);
      return;
    }
    const dirPath: string = this.viewModel.currentDir;
    // 预扫现在跨线程逐条解析收件人（条目多时耗时数秒），必须置忙：
    // 面板的取消/应用按钮会显示忙碌文案并禁用，防重复触发
    this.reencryptBusy = true;
    try {
      const plan: ReencryptPlan = await ReencryptService.getInstance().plan(dirPath, fingerprints);
      if (plan.error.length > 0) {
        showToastSafe(this.getUIContext(), plan.error, 2500);
        return;
      }
      // 预扫是异步的：期间用户可能已手势关闭面板（视为放弃本次变更），
      // 此时丢弃结果——不写 .gpg-id、不弹确认框
      if (!this.isCreateSheetVisible) {
        return;
      }
      if (plan.needsCount === 0) {
        // 该目录下没有需要换的条目：直接写 .gpg-id 即可
        const written = PasswordRepository.getInstance().setGpgIdForDir(dirPath, fingerprints);
        showToastSafe(this.getUIContext(), written.success ? Strings.get('home_dirkey_updated_no_reencrypt') : written.error, 2500);
        if (written.success) {
          RepoChangeNotifier.connect().bump();
          this.isCreateSheetVisible = false;
        }
        return;
      }

      hilog.info(DOMAIN, TAG, 'applyDirKeys: count=%{public}d needs=%{public}d',
        fingerprints.length, plan.needsCount);
      // 先关面板再弹确认框：bindSheet 与 AlertDialog 同处 UIContext 顶层，
      // 面板还在关闭动画中时确认框会被压在下面（实测确认框根本不进布局树）
      this.isCreateSheetVisible = false;
      setTimeout(() => {
        this.showReencryptConfirm(dirPath, fingerprints, plan);
      }, 400);
    } finally {
      this.reencryptBusy = false;
    }
  }

  /** 重加密确认框（面板关闭后再弹，避免被面板遮挡） */
  private showReencryptConfirm(dirPath: string, fingerprints: string[],
    plan: ReencryptPlan): void {
    const label: string = this.keyLabelsFor(fingerprints).join(Strings.get('common_list_sep'));
    let message: string = Strings.fmt('home_reencrypt_confirm_msg', label, plan.needsCount);
    if (plan.missingKeyCount > 0) {
      message += '\n' + Strings.fmt('home_reencrypt_skipped_msg', plan.missingKeyCount);
    }
    if (plan.requiredKeys.length > 0) {
      message += '\n' + Strings.get('home_reencrypt_need_passphrase');
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.home_reencrypt_confirm_title'),
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.common_start'),
        fontColor: this.colors.primary,
        action: (): void => {
          this.proceedReencrypt(dirPath, fingerprints, plan);
        },
      },
    });
  }

  /**
   * 执行前的口令准备：旧密钥未解锁则走既有口令弹窗，解锁后由 onDialogConfirm 继续
   */
  private async proceedReencrypt(dirPath: string, fingerprints: string[],
    plan: ReencryptPlan): Promise<void> {
    this.reencryptBusy = true;
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    let ready: boolean = plan.requiredKeys.length === 0
      || crypto.isUnlockedFor(plan.requiredKeys);
    if (!ready && plan.requiredKeys.length > 0) {
      ready = await crypto.ensureUnlocked(plan.requiredKeys);
    }
    if (!ready) {
      // 需要用户输入旧密钥口令：记下待办，复用既有口令弹窗
      this.pendingReencrypt = { dirPath: dirPath, fingerprints: fingerprints, plan: plan };
      this.dialogPassphrase = '';
      this.dialogError = '';
      // 多接收方条目任一把密钥的口令都能解开，故列出全部候选而不是只写第一把
      this.dialogKeyId = this.keyLabelsFor(plan.requiredKeys).join(Strings.get('common_list_sep'));
      this.isPassphraseDialogVisible = true;
      this.openPassphraseDialog();
      this.reencryptBusy = false;
      return;
    }
    await this.executeReencrypt(dirPath, fingerprints, plan);
  }

  /** 逐条重加密并落盘；进度以全模态遮罩反馈，结果以 Toast 汇总（失败条目保持原样） */
  private async executeReencrypt(dirPath: string, fingerprints: string[],
    plan: ReencryptPlan): Promise<void> {
    this.reencryptBusy = true;
    this.reencryptDone = 0;
    this.reencryptTotal = plan.needsCount;
    this.reencryptRunning = true;
    let outcome: ReencryptOutcome;
    try {
      outcome = await ReencryptService.getInstance().run(
        dirPath, fingerprints, plan,
        (done: number, total: number): void => {
          // TaskPool 逐条下发，每个 await 都让出主线程，这里能即时刷新
          this.reencryptDone = done;
          this.reencryptTotal = total;
        });
    } finally {
      this.reencryptRunning = false;
      this.reencryptBusy = false;
    }

    let message: string;
    if (outcome.success) {
      message = Strings.fmt('home_reencrypted_count', outcome.reencrypted)
        + (outcome.skipped > 0 ? Strings.fmt('home_reencrypt_skipped_suffix', outcome.skipped) : '');
    } else {
      message = Strings.fmt('home_reencrypt_failed', outcome.error);
      if (outcome.failures.length > 0) {
        message += '\n' + Strings.fmt('home_reencrypt_first_failure',
          outcome.failures[0].relativePath, outcome.failures[0].error);
      }
    }
    showToastSafe(this.getUIContext(), message, 3500);
    if (outcome.success) {
      this.isCreateSheetVisible = false;
    }
  }

  /** 兜底：全部已导入私钥指纹（.gpg-id 无可用条目时用） */
  private async allSecretFingerprints(): Promise<string[]> {
    const keys: GpgKeyId[] = await PgpKeyManager.getInstance().listKeys(true);
    const result: string[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      result.push(keys[i].fingerprint);
    }
    return result;
  }

  /**
   * 点击密码条目：该条目的密钥已就绪直接进详情；否则弹原生密码弹窗验证
   */
  private async onPasswordEntryClick(entry: PasswordEntryVM): Promise<void> {
    // 按密文实际收件人判断该用哪把密钥：无密码保护的密钥可免密直接进详情；
    // 也不能因为别的密钥已解锁就放行，否则会用错密钥解密失败
    const candidates: string[] = this.entryDecryptionCandidates(entry);
    const crypto: PgpCrypto = PgpCrypto.getInstance();
    if (candidates.length === 0) {
      // 没有任何已导入密钥能解该条目：明确告知缺哪把密钥，而不是反复索取口令
      // （对齐 agrahn fork 的 no_decryption_keys 提示语义）
      const ciphertext: string = PasswordRepository.getInstance().readCiphertext(entry.relativePath);
      const ids: string[] = crypto.recipientKeyIds(ciphertext);
      const idText: string = ids.length > 0 ? ids.join(Strings.get('common_list_sep')) : Strings.get('home_no_recipient_hint');
      this.getUIContext().showAlertDialog({
        title: $r('app.string.home_missing_decrypt_key_title'),
        message: Strings.fmt('home_missing_key_msg', idText) + '\n' + Strings.get('home_missing_key_action'),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        onWillDismiss: (action: DismissDialogAction): void => {
          action.dismiss();
        },
        confirm: {
          value: $r('app.string.common_got_it'),
          fontColor: this.colors.primary,
          action: (): void => {},
        },
      });
      return;
    }
    let ready: boolean = crypto.isUnlockedFor(candidates);
    if (!ready) {
      ready = await crypto.ensureUnlocked(candidates);
    }
    if (ready) {
      this.navigateToDetail(entry);
      return;
    }
    this.pendingEntry = entry;
    this.dialogPassphrase = '';
    this.dialogError = '';
    this.dialogKeyId = this.resolveEntryKeyId(entry);
    this.isPassphraseDialogVisible = true;
    this.openPassphraseDialog();
  }

  /**
   * 解析待解密条目对应的 PGP 密钥标识（列出**全部**能解该密文的密钥邮箱）
   *
   * 多接收方条目（如目录同时挂了普通密钥与 gpgPqc 密钥）任一把都能解开，
   * 只显示第一把会让用户以为必须输入那一把的口令。
   */
  private resolveEntryKeyId(entry: PasswordEntryVM): string {
    // 标签取**实际能解该密文**的密钥身份（不是 .gpg-id 指向的密钥）
    const candidates: string[] = this.entryDecryptionCandidates(entry);
    const emails: string[] = [];
    for (let i: number = 0; i < candidates.length; i++) {
      const key: GpgKeyId | null = PgpKeyManager.getInstance().findKey(candidates[i]);
      if (key !== null) {
        emails.push(key.email.length > 0 ? key.email : key.userId);
      }
    }
    return emails.length > 0 ? emails.join(Strings.get('common_list_sep')) : '****@***';
  }

  /**
   * 左滑露出的删除按钮
   *
   * 卡片自身带 `margin({ top: Spacing.SM })`（见 PasswordItemView），故外层留同样的
   * 上间距、内层 `height('100%')` 才能与卡片等高对齐（百分比高度按父容器内容盒解析）。
   */
  @Builder
  swipeDeleteAction(entry: PasswordEntryVM) {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(IconSize.MD)
          .fontColor([this.colors.onPrimary])
      }
      .width(ComponentSize.CONTROL)
      .height(ComponentSize.CONTROL)
      // 圆形按钮：半径取边长一半（与 FAB 的 Circle 形态一致）
      .borderRadius(ComponentSize.CONTROL / 2)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors.danger)
      // 按钮只剩图标，读屏需要文字说明
      .accessibilityText(entry.isDirectory
        ? Strings.fmt('home_a11y_delete_dir', entry.name)
        : Strings.fmt('home_a11y_delete_entry', entry.name))
      .onClick(() => {
        // 先收起已展开的滑动项：否则确认框弹出时按钮仍停在展开态，返回后误触
        this.listScroller.closeAllSwipeActions();
        this.confirmSwipeDelete(entry);
      })
    }
    .height('100%')
    // 上间距与卡片自身的 margin({ top: Spacing.SM }) 一致，垂直居中后才与卡片对齐
    .padding({ left: Spacing.MD, top: Spacing.SM })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 左滑删除确认
   *
   * 目录是**递归删除**（`deleteDirectory` 直接删整棵子树），必须把范围写在确认文案里，
   * 不能让用户以为只删了这一个目录名。
   */
  private confirmSwipeDelete(entry: PasswordEntryVM): void {
    const isDir: boolean = entry.isDirectory;
    const message: string = isDir
      ? Strings.fmt('store_delete_dir_confirm', entry.name, entry.childCount)
      : Strings.fmt('store_delete_entry_confirm', entry.name);
    this.getUIContext().showAlertDialog({
      title: isDir ? $r('app.string.home_delete_dir_title') : $r('app.string.home_delete_pw_title'),
      message: message,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      onWillDismiss: (action: DismissDialogAction): void => {
        action.dismiss();
      },
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {},
      },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: this.colors.danger,
        action: (): void => {
          this.executeSwipeDelete(entry);
        },
      },
    });
  }

  /**
   * 执行删除并刷新列表
   *
   * 与详情页删除一致：只落盘 + bump 通知，**不自动提交 git**（提交/推送由用户显式触发）。
   */
  private executeSwipeDelete(entry: PasswordEntryVM): void {
    const repo: PasswordRepository = PasswordRepository.getInstance();
    const result = entry.isDirectory
      ? repo.deleteDirectory(entry.relativePath)
      : repo.deletePassword(entry.relativePath);
    if (!result.success) {
      showToastSafe(this.getUIContext(), result.error.length > 0 ? result.error : Strings.get('home_delete_failed'), 2500);
      return;
    }
    hilog.info(DOMAIN, TAG, 'swipe delete: %{public}s (dir=%{public}s)',
      entry.relativePath, entry.isDirectory ? 'yes' : 'no');
    RepoChangeNotifier.connect().bump();
    this.viewModel.loadEntries();
    showToastSafe(this.getUIContext(), entry.isDirectory ? Strings.get('home_dir_deleted') : Strings.get('home_pw_deleted'), 2000);
  }

  private navigateToDetail(entry: PasswordEntryVM): void {
    const param: PasswordDetailNavParam = { relativePath: entry.relativePath };
    RouteManager.getInstance().pushPath(RouteNames.PASSWORD_DETAIL, param);
  }

  /**
   * 弹出原生自定义弹窗（openCustomDialog，鸿蒙规范方案）
   */
  /**
   * 弹出自定义弹窗（已处理异常）
   *
   * openCustomDialog 声明会抛异常，且返回 Promise 也可能 reject（弹窗创建失败）；
   * 直接调用会触发「Function may throw exceptions」告警，失败时还会留下一个关不掉的
   * 遮罩层，故统一在这里兜住。
   */
  private openDialogSafe(open: () => Promise<number>): void {
    try {
      open().then((dialogId: number) => {
        this.passphraseDialogId = dialogId;
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'openCustomDialog failed: %{public}s', e.message);
        this.isPassphraseDialogVisible = false;
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'openCustomDialog threw: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      this.isPassphraseDialogVisible = false;
    }
  }

  /** 关闭弹窗（同样兜住异常，避免关闭失败时把遮罩留在屏幕上） */
  private closeDialogSafe(dialogId: number): void {
    try {
      this.getUIContext().getPromptAction().closeCustomDialog(dialogId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'closeCustomDialog failed: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    }
  }

  private openPassphraseDialog(): void {
    this.openDialogSafe((): Promise<number> => this.getUIContext().getPromptAction().openCustomDialog({
      builder: (): void => {
        this.passphraseDialogBuilder();
      },
      autoCancel: true,
      alignment: DialogAlignment.Center,
      maskColor: 'rgba(0,0,0,0.4)',
      // 关闭默认背景与模糊层（深色模式下默认模糊层呈黑块，与内容叠出黑色重叠背景），
      // 背景由 builder 内容的 surface 卡片承担
      backgroundColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      isModal: true,
    }));
  }

  private closePassphraseDialog(): void {
    if (this.passphraseDialogId >= 0) {
      this.closeDialogSafe(this.passphraseDialogId);
      this.passphraseDialogId = -1;
    }
    this.isPassphraseDialogVisible = false;
  }

  /**
   * 弹窗内确认：验证密钥密码，成功后解锁会话并跳详情页
   */
  private async onDialogConfirm(): Promise<void> {
    if (this.isUnlocking || this.dialogPassphrase.length === 0) {
      return;
    }
    this.isUnlocking = true;
    this.dialogError = '';

    // 解锁目标：重加密待办优先（需旧密钥口令），否则按条目的密文收件人
    const pending: ReencryptPending | null = this.pendingReencrypt;
    const entry: PasswordEntryVM | null = this.pendingEntry;
    const candidates: string[] = entry !== null
      ? this.entryDecryptionCandidates(entry)
      : [];
    const targets: string[] = pending !== null
      ? pending.plan.requiredKeys
      : (candidates.length > 0 ? candidates : await this.allSecretFingerprints());
    let unlocked: boolean = false;
    // 记录失败原因：只显示「密码错误」会掩盖「导入的是公钥」等可修复问题
    let failReason: string = Strings.get('common_passphrase_wrong');
    for (let i: number = 0; i < targets.length; i++) {
      const res: UnlockResult = await PgpCrypto.getInstance().unlockPassphrase(
        targets[i], this.dialogPassphrase);
      if (res.success) {
        unlocked = true;
        break;
      }
      if (res.error.length > 0) {
        failReason = res.error;
      }
    }

    this.isUnlocking = false;
    if (!unlocked) {
      this.dialogError = failReason;
      return;
    }

    // 重加密待办：口令已验证，继续执行（不跳详情页）
    if (pending !== null) {
      this.pendingReencrypt = null;
      this.closePassphraseDialog();
      await this.executeReencrypt(pending.dirPath, pending.fingerprints, pending.plan);
      return;
    }

    this.closePassphraseDialog();
    this.pendingEntry = null;
    if (entry !== null) {
      this.navigateToDetail(entry);
    }
  }

  /**
   * 解密密码弹窗 UI（原生 openCustomDialog 内容）
   */
  @Builder
  passphraseDialogBuilder() {
    Column() {
      Text($r('app.string.home_passphrase_title'))
        .fontSize(FontSize.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors.textPrimary)

      Text(Strings.fmt('home_pgp_id_label', this.dialogKeyId))
        .fontSize(FontSize.CAPTION)
        .fontColor(this.colors.textTertiary)
        .margin({ top: Spacing.SM })

      TextInput({ text: this.dialogPassphrase, placeholder: $r('app.string.home_passphrase_hint') })
        .type(InputType.Password)
        .fontSize(FontSize.SUBTITLE)
        .width('100%')
        .height(ComponentSize.CONTROL)
        .borderRadius(Radius.MD)
        .backgroundColor(this.colors.inputBackground)
        .fontColor(this.colors.textPrimary)
        .placeholderColor(this.colors.textTertiary)
        .margin({ top: Spacing.LG })
        .enabled(!this.isUnlocking)
        .onChange((v: string) => {
          this.dialogPassphrase = v;
        })
        .onSubmit(() => {
          this.onDialogConfirm();
        })

      if (this.dialogError.length > 0) {
        Text(this.dialogError)
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.danger)
          .margin({ top: Spacing.SM })
      }

      Row({ space: ButtonSpec.ROW_GAP }) {
        Button($r('app.string.common_cancel'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.SECONDARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.isUnlocking)
          .onClick(() => {
            this.closePassphraseDialog();
            this.pendingEntry = null;
          })

        Button(this.isUnlocking ? Strings.get('home_verifying') : Strings.get('common_confirm'))
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.PRIMARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .fontSize(ButtonSpec.FONT_SIZE)
          .fontWeight(ButtonSpec.FONT_WEIGHT)
          .backgroundColor(this.colors.primary)
          .fontColor(this.colors.onPrimary)
          .enabled(!this.isUnlocking && this.dialogPassphrase.length > 0)
          .onClick(() => {
            this.onDialogConfirm();
          })
      }
      .width('100%')
      .margin({ top: Spacing.LG })
    }
    .width('86%')
    .padding(Spacing.XL)
    .borderRadius(Radius.LG)
    .backgroundColor(this.colors.surface)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      // ===== 顶部标题区：返回 + 应用名/搜索框 + 设置按钮 =====
      Row() {
        // 返回按钮：进入目录后始终显示（标题/搜索模式均保留），左右间距一致
        if (this.viewModel.currentDir.length > 0) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(IconSize.BACK)
              .fontColor([this.colors.textPrimary])
          }
          .width(IconSize.BACK_BUTTON)
          .height(IconSize.BACK_BUTTON)
          .backgroundColor(this.colors.inputBackground)
          .margin({ right: Spacing.MD })
          .onClick(() => {
            this.viewModel.navigateUp();
          })
        }

        if (this.isSearchBarVisible) {
          // 搜索模式：顶栏出现搜索框，右侧继续显示设置按钮
          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(IconSize.XS)
              .fontColor([this.colors.textTertiary])
              .margin({ right: Spacing.SM })

            TextInput({ text: this.viewModel.searchKeyword, placeholder: $r('app.string.search_placeholder') })
              .id(SEARCH_INPUT_ID)
              .fontSize(FontSize.BODY)
              .fontColor(this.colors.textPrimary)
              .placeholderColor(this.colors.textTertiary)
              .placeholderFont({ size: FontSize.BODY })
              .backgroundColor(Color.Transparent)
              // 必须把输入框自身的圆角去掉：它的背景是透明的、圆角看不见，但**裁剪仍在**
              // ——光标贴在最左沿时会被左侧圆角弧切掉一半，只剩一条两端渐尖的月牙，
              // 看起来像蓝色的「(」（实测像素：贴边时光标左缘呈弧形，打字后光标右移
              // 到 x=237 即恢复正常竖条）。外层胶囊形由父 Row 的 borderRadius 负责，
              // 这里置 0 不改变任何可见外观。
              .borderRadius(0)
              .padding(0)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.viewModel.updateSearchKeyword(v);
              })

            if (this.viewModel.searchKeyword.length > 0) {
              Text('✕')
                .fontSize(FontSize.BODY)
                .fontColor(this.colors.textTertiary)
                .padding(Spacing.XS)
                .onClick(() => {
                  this.viewModel.clearSearch();
                  this.isSearchBarVisible = false;
                })
            }
          }
          .layoutWeight(1)
          .height(ComponentSize.SEARCH)
          .borderRadius(Radius.FULL)
          .backgroundColor(this.colors.surface)
          .border({ width: DividerSpec.STROKE, color: this.colors.divider })
          .padding({ left: Spacing.MD, right: Spacing.SM })
          .alignItems(VerticalAlign.Center)
        } else {
          // 标题模式：目录名，根目录显示应用名
          // 根目录回退标题为「仓库名」语义（home_root_title），目录名保持字符串变量；
          // Text 内容为 ResourceStr，两分支混用允许
          Text(this.viewModel.currentDir.length > 0 ? this.viewModel.currentDir : $r('app.string.home_root_title'))
            .fontSize(FontSize.DISPLAY_MD)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }

        // 搜索按钮（搜索模式下隐藏）
        if (!this.isSearchBarVisible) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(IconSize.MD)
              .fontColor([this.colors.textPrimary])
          }
          .width(IconSize.BACK_BUTTON)
          .height(IconSize.BACK_BUTTON)
          .backgroundColor(this.colors.inputBackground)
          .onClick(() => {
            this.isSearchBarVisible = true;
            // 焦点必须在**节点创建之后**再请求：搜索框是条件渲染出来的，
            // 同帧调用 requestFocus 会找不到目标（静默失败，表现为点了没反应）。
            // 用 requestFocus(id) 而不是 TextInput 的 defaultFocus——后者只在
            // 页面首次创建时生效，对动态出现的节点无效。
            setTimeout((): void => {
              this.getUIContext().getFocusController().requestFocus(SEARCH_INPUT_ID);
            }, 100);
          })
        }

        // 设置按钮（始终显示）：点击弹出下拉菜单
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
            .fontSize(IconSize.MD)
            .fontColor([this.colors.textPrimary])
        }
        .width(IconSize.BACK_BUTTON)
        .height(IconSize.BACK_BUTTON)
        .backgroundColor(this.colors.inputBackground)
        .margin({ left: Spacing.SM })
        .onClick(() => {
          this.isMenuVisible = !this.isMenuVisible;
        })
      }
      .width('100%')
      // 与 AppTitleBar 保持一致：高度 56vp、水平内边距 PAGE_H、上下各 8
      .height(ComponentSize.TITLE_BAR)
      .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, top: Spacing.SM, bottom: Spacing.SM })
      .alignItems(VerticalAlign.Center)

      // ===== 搜索结果计数（目录导航已上移至顶栏） =====
      if (this.viewModel.searchKeyword.length > 0) {
        Row() {
          Text(Strings.fmt('found_results', this.viewModel.filteredEntries.length))
            .fontSize(FontSize.CAPTION)
            .fontColor(this.colors.textSecondary)
            .layoutWeight(1)
        }
        .width('100%')
        // 与列表卡片的水平留白（XL）对齐，计数文字跟卡片左缘平齐
        .padding({ left: Spacing.XL, right: Spacing.XL, bottom: Spacing.XS })
      }

      // ===== 列表区 =====
      if (this.viewModel.filteredEntries.length === 0) {
        Column() {
          EmptyState({
            icon: $r('sys.symbol.lock'),
            title: this.viewModel.searchKeyword.length > 0
              ? Strings.get('home_search_no_match') : Strings.get('home_store_empty'),
            hint: this.viewModel.searchKeyword.length > 0
              ? Strings.get('home_search_try_other') : Strings.get('home_create_first_hint'),
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.collapseSearchBar())
      } else {
        List({ scroller: this.listScroller, space: Spacing.CARD_GAP }) {
          ForEach(this.viewModel.filteredEntries, (entry: PasswordEntryVM) => {
            ListItem() {
              PasswordItemView({ entry: entry, onItemClicked: (e: PasswordEntryVM): void => {
                if (e.isDirectory) {
                  this.viewModel.onEntryClicked(e);
                } else {
                  this.onPasswordEntryClick(e);
                }
              } })
            }
            // 左滑露出删除按钮（参照 TKeShi 的 swipeAction end 形态）
            .swipeAction({
              end: (): void => {
                this.swipeDeleteAction(entry);
              },
              edgeEffect: SwipeEdgeEffect.Spring,
            })
          }, (entry: PasswordEntryVM) => entry.relativePath)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .width('100%')
        // 水平留白用 PAGE_H
        // 底部只避让系统手势条
        .padding({ left: Spacing.PAGE_H, right: Spacing.PAGE_H, top: Spacing.XS,
          bottom: SystemInsets.bottomVp() })
        .onClick(() => this.collapseSearchBar())
      }

      // ===== 浮动按钮区 =====
      // 浮动添加按钮（点击弹出"创建新目录/创建新密码"底部菜单）
      AppFab({
        onTap: (): void => {
          this.isCreateDirFormVisible = false;
          this.isCreateSheetVisible = true;
        },
      })
      // 右缘锚定：FAB 右缘 = 父容器右缘 - (FAB 宽 + 卡片右距)，与列表卡片右缘
      // 平齐（右距同为 Spacing.PAGE_H）。原先 x:'82%' 是左缘按屏宽的百分比、随屏宽
      // 漂移，右侧与屏幕的间距锁不住（实测比卡片右缘多凸出约 15vp）。
      .position({ x: '100%', y: '88%' })
      .markAnchor({ x: IconSize.FAB + Spacing.PAGE_H, y: 0 })
      // 同步面板挂在此节点：同一节点只能挂一个 bindSheet（后挂的会覆盖先挂的），
      // 与根节点的 create sheet 分开挂载，否则「同步存储库」永远打不开
      .bindSheet(this.isSyncSheetVisible, this.syncSheetBuilder(), this.syncSheetOptions)

      // ===== 设置下拉菜单（外层 Column 末尾：绘制在列表之上） =====
      if (this.isMenuVisible) {
        // 全屏透明遮罩：点击任意处关闭菜单
        Column()
          .width('100%')
          .height('100%')
          .position({ x: 0, y: 0 })
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.isMenuVisible = false;
          })

        Column() {
          this.menuItem(Strings.get('home_sync_all'), (): void => {
            this.isMenuVisible = false;
            this.runSyncOperation('sync');
          })
          this.menuItem(Strings.get('home_sync_repo_menu'), (): void => {
            this.isMenuVisible = false;
            this.openSyncSheet();
          })
          this.menuItem(Strings.get('home_refresh_list'), (): void => {
            this.isMenuVisible = false;
            this.viewModel.loadEntries();
          })
          this.menuDivider()
          this.menuItem(Strings.get('settings'), (): void => {
            this.isMenuVisible = false;
            RouteManager.getInstance().pushPath(RouteNames.SETTINGS);
          })
        }
        .width(ComponentSize.MENU_WIDTH)
        .borderRadius(Radius.CARD)
        .backgroundColor(this.colors.surface)
        .shadow({ radius: Radius.CARD, color: 'rgba(0,0,0,0.2)', offsetY: 4 })
        .padding({ top: Spacing.XS, bottom: Spacing.XS })
        .position({ x: '58%', y: 56 })
        .zIndex(101)
      }

      // ===== 重加密进度遮罩（须为根 Column 最后一个子节点才能盖住全部内容） =====
      // position 移出文档流（同上方设置菜单遮罩的写法），否则会被排在后面的兄弟
      // 节点压住；触摸拦截由 LoadingOverlay 自带的 hitTestBehavior(Block) 负责，
      // 返回键由 aboutToAppear 里 BackHandler 的 busy 分支消费
      if (this.reencryptRunning) {
        LoadingOverlay({
          text: Strings.get('home_reencrypting'),
          percent: this.reencryptTotal > 0
            ? this.reencryptDone * 100 / this.reencryptTotal
            : -1,
        })
          .position({ x: 0, y: 0 })
          .zIndex(200)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors.background)
    .bindSheet(this.isCreateSheetVisible, this.createSheetBuilder(),
      this.dirKeyMode
        ? this.createSheetDirKeyOptions
        : (this.isCreateDirFormVisible ? this.createSheetFormOptions : this.createSheetMenuOptions))
  }
}
