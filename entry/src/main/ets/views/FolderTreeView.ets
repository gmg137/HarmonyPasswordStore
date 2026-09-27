import { FileUtils } from '../utils/FileUtils';
import { ThemeColors, Palette, Radius, Spacing, FontSize, IconSize, ComponentSize } from '../common/ThemeColors';

/** .gpg-id 等隐藏文件不入树 */
const GPG_ID_FILE: string = '.gpg-id';

/**
 * 目录树节点
 */
export interface FolderTreeNode {
  /** 目录名（显示用） */
  name: string;
  /** 相对路径（'' 为根） */
  relativePath: string;
  /** 层级深度（根为 0） */
  depth: number;
  /** 是否含子目录 */
  hasChildren: boolean;
}

/**
 * 目录树选择器
 *
 * 展开式目录树：从仓库根开始，点击目录展开子目录并选中。
 * 用于密码条目移动/文件夹操作的目标位置选择。
 * 根节点表示仓库根目录，始终可选。
 */
@ComponentV2
export struct FolderTreeView {
  /** 当前选中的相对路径（'' 为根目录） */
  @Param selectedPath: string = '';
  /** 选中变化回调 */
  @Param onSelected: (path: string) => void = (path: string) => {};
  /** 仓库根绝对路径 */
  @Param storePath: string = '';

  @Local expandedPaths: Set<string> = new Set<string>(['']);
  @Local rootChildren: FolderTreeNode[] = [];
  @Local childMap: Map<string, FolderTreeNode[]> = new Map<string, FolderTreeNode[]>();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.loadChildren('');
  }

  /**
   * 加载某目录的直接子目录
   */
  private loadChildren(relativePath: string): void {
    const absPath: string = relativePath.length > 0
      ? `${this.storePath}/${relativePath}` : this.storePath;
    const names: string[] = FileUtils.listDir(absPath);
    const nodes: FolderTreeNode[] = [];
    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i];
      if (name.startsWith('.') || name === '.git') {
        continue;
      }
      const childAbs: string = `${absPath}/${name}`;
      if (!this.isDirectory(childAbs)) {
        continue;
      }
      const childRel: string = relativePath.length > 0 ? `${relativePath}/${name}` : name;
      const subDirs: string[] = FileUtils.listDir(childAbs)
        .filter((n: string) => !n.startsWith('.') && n !== '.git'
          && this.isDirectory(`${childAbs}/${n}`));
      const node: FolderTreeNode = {
        name: name,
        relativePath: childRel,
        depth: relativePath.length === 0 ? 1 : relativePath.split('/').length + 1,
        hasChildren: subDirs.length > 0,
      };
      nodes.push(node);
    }
    nodes.sort((a: FolderTreeNode, b: FolderTreeNode) => a.name.localeCompare(b.name));

    if (relativePath.length === 0) {
      this.rootChildren = nodes;
    } else {
      const newMap: Map<string, FolderTreeNode[]> = new Map<string, FolderTreeNode[]>(this.childMap);
      newMap.set(relativePath, nodes);
      this.childMap = newMap;
    }
  }

  /**
   * 判断是否为**目录**（委托 FileUtils.isDirectory：statSync + isDirectory）
   *
   * 曾用 `FileUtils.exists()` 冒充——它对文件同样返回 true，于是条目文件
   * （aaaaaa.gpg 等）也被当成目录列进树并可选中，选中后移动必然失败
   */
  private isDirectory(absPath: string): boolean {
    return FileUtils.isDirectory(absPath);
  }

  /**
   * 切换展开/选中
   */
  toggleExpand(node: FolderTreeNode): void {
    const newSet: Set<string> = new Set<string>(this.expandedPaths);
    if (newSet.has(node.relativePath)) {
      newSet.delete(node.relativePath);
    } else {
      newSet.add(node.relativePath);
      if (!this.childMap.has(node.relativePath)) {
        this.loadChildren(node.relativePath);
      }
    }
    this.expandedPaths = newSet;
    this.onSelected(node.relativePath);
  }

  /**
   * 选择根目录
   */
  selectRoot(): void {
    this.onSelected('');
  }

  @Builder
  nodeItem(node: FolderTreeNode) {
    Column() {
      Row() {
        Blank().width(node.depth * Spacing.CARD)

        SymbolGlyph(this.expandedPaths.has(node.relativePath)
          ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(IconSize.CHEVRON)
          .fontColor([this.colors.textTertiary])
          .width(IconSize.CHEVRON)

        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(IconSize.MD)
          .fontColor([this.colors.textSecondary])
          .margin({ right: Spacing.SM })

        Text(node.name)
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.selectedPath === node.relativePath ? this.colors.primary : this.colors.textPrimary)
          .fontWeight(this.selectedPath === node.relativePath ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(ComponentSize.CONTROL)
      .padding({ left: Spacing.SM, right: Spacing.SM })
      .borderRadius(Radius.SM)
      .alignItems(VerticalAlign.Center)
      // 选中态用强调色淡底；未选中时给按压反馈（透明底 → 按压底色）
      .stateStyles({
        normal: {
          .backgroundColor(this.selectedPath === node.relativePath
            ? this.colors.primarySoft : Color.Transparent),
        },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(() => {
        this.toggleExpand(node);
      })

      // 展开的子目录
      if (this.expandedPaths.has(node.relativePath) && this.childMap.has(node.relativePath)) {
        ForEach(this.childMap.get(node.relativePath)!, (child: FolderTreeNode) => {
          this.nodeItem(child)
        }, (child: FolderTreeNode) => child.relativePath)
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      // 根节点（仓库根目录）
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(IconSize.CHEVRON)
          .fontColor([this.colors.textTertiary])
          .width(IconSize.CHEVRON)

        SymbolGlyph($r('sys.symbol.doc_filled_on_doc'))
          .fontSize(IconSize.MD)
          .fontColor([this.colors.textSecondary])
          .margin({ right: Spacing.SM })

        Text($r('app.string.store_root_dir'))
          .fontSize(FontSize.SUBTITLE)
          .fontColor(this.selectedPath.length === 0 ? this.colors.primary : this.colors.textPrimary)
          .fontWeight(this.selectedPath.length === 0 ? FontWeight.Medium : FontWeight.Normal)
      }
      .width('100%')
      .height(ComponentSize.CONTROL)
      .padding({ left: Spacing.SM, right: Spacing.SM })
      .borderRadius(Radius.SM)
      .alignItems(VerticalAlign.Center)
      .stateStyles({
        normal: {
          .backgroundColor(this.selectedPath.length === 0
            ? this.colors.primarySoft : Color.Transparent),
        },
        pressed: { .backgroundColor(this.colors.pressed) },
      })
      .onClick(() => {
        this.selectRoot();
      })

      // 第一层子目录
      ForEach(this.rootChildren, (node: FolderTreeNode) => {
        this.nodeItem(node)
      }, (node: FolderTreeNode) => node.relativePath)
    }
    .width('100%')
    .padding(Spacing.SM)
    .backgroundColor(this.colors.inputBackground)
    .borderRadius(Radius.CARD)
  }
}
