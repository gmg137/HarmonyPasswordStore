# HarmonyPasswordStore 鸿蒙原生设计规范审查报告

> 审查日期：2026-09-16  
> 审查范围：`entry/src/main/ets/` 下全部 20+ 页面与 3 个视图组件  
> 对标规范：HarmonyOS Design（references/styles/huawei-harmonyos.md）  
> 审查维度：色彩体系 · 字体排版 · 间距网格 · 圆角体系 · 组件规范 · 深色模式 · 动效 · 无障碍 · 性能  
> 还原度评分：**62 / 100**

---

## 目录

1. [审查总览](#1-审查总览)
2. [P0 严重偏差（必须修复）](#2-p0-严重偏差必须修复)
3. [P1 明显偏差（强烈建议修复）](#3-p1-明显偏差强烈建议修复)
4. [P2 优化建议](#4-p2-优化建议)
5. [逐页面审查清单](#5-逐页面审查清单)
6. [优化方案](#6-优化方案)
7. [还原度评分明细](#7-还原度评分明细)

---

## 1. 审查总览

### 总体评价

项目已建立了基础的 Design Token 体系（`ThemeColors.ets`），在间距、圆角、字号阶梯方面有较好的骨架，大部分页面使用了语义化色值令牌（`colors.primary`、`colors.surface` 等），深色模式在核心页面有基础支持。

但存在以下系统性问题：

| 问题类别 | 严重度 | 影响范围 | 根因 |
|----------|--------|---------|------|
| 强调色值不符合鸿蒙规范 | P0 | 全局 | `#0A59F7` ≠ 鸿蒙蓝 `#007DFF` |
| 大量硬编码色值 | P0 | 6 个页面 | 未使用 Palette 令牌 |
| 深色模式完全缺失 | P0 | 3 个组件 | SyncSheet/GitLogView/PinSetupPage |
| 按钮圆角与高度不统一 | P0 | 全局 | 统一 8vp 圆角，未遵循鸿蒙按钮规范 |
| 卡片内边距偏差 | P1 | 全局 | Spacing.CARD=12vp ≠ 规范 16vp |
| List 未用 LazyForEach | P1 | 列表页 | 性能隐患 |
| 缺少底部 TabBar | P1 | 主页 | 不符合鸿蒙导航范式 |
| 无障碍标签缺失 | P1 | 全局 | 无 accessibilityText |

### 各页面合规度

| 页面/组件 | 色彩 | 深色模式 | 组件规范 | 间距网格 | 综合 |
|-----------|------|---------|---------|---------|------|
| ThemeColors.ets | ❌ 色值偏差 | ⚠️ 部分偏差 | — | ✅ | 60% |
| Index.ets | ✅ | ✅ | ✅ | ✅ | 90% |
| PasswordListPage | ✅ | ✅ | ⚠️ 无TabBar | ⚠️ | 75% |
| PasswordItemView | ✅ | ✅ | ⚠️ 间距 | ⚠️ | 80% |
| PasswordCreatePage | ⚠️ | ✅ | ❌ 按钮圆角 | ⚠️ | 65% |
| PasswordDetailPage | ⚠️ | ✅ | ❌ 按钮圆角 | ⚠️ | 65% |
| SettingsPage | ✅ | ✅ | ⚠️ | ✅ | 80% |
| AboutPage | ✅ | ✅ | ✅ | ✅ | 85% |
| PinSetupPage | ❌ 硬编码 | ❌ 缺失 | ❌ | ⚠️ | 35% |
| PassgenPage | ⚠️ | ✅ | ❌ 按钮圆角 | ⚠️ | 60% |
| OnboardingPage | ❌ 硬编码 | ⚠️ 部分 | ❌ 按钮圆角 | ⚠️ | 45% |
| GitClonePage | ❌ 硬编码 | ⚠️ 部分 | ❌ 按钮圆角 | ⚠️ | 45% |
| GitConfigPage | ❌ 硬编码 | ⚠️ 部分 | ❌ 按钮圆角 | ⚠️ | 40% |
| PgpKeyManagerPage | ✅ | ✅ | ⚠️ | ✅ | 80% |
| SshKeyManagerPage | ✅ | ✅ | ⚠️ | ✅ | 80% |
| PasskeyListPage | ✅ | ✅ | ⚠️ | ✅ | 80% |
| LockPage | ✅ | ✅ | ✅ | ✅ | 85% |
| MoveEntryPage | ✅ | ✅ | ✅ | ✅ | 85% |
| FolderCreatePage | ✅ | ✅ | ✅ | ✅ | 85% |
| AutofillFillPage | ✅ | ✅ | ⚠️ | ⚠️ | 75% |
| AutofillSettingsPage | ✅ | ✅ | ✅ | ✅ | 85% |
| PrivacyPolicyPage | ✅ | ✅ | ✅ | ✅ | 85% |
| **SyncSheet** | ❌ 全硬编码 | ❌ 完全缺失 | ❌ | ⚠️ | **20%** |
| **GitLogView** | ❌ 全硬编码 | ❌ 完全缺失 | ❌ | ⚠️ | **20%** |
| FolderTreeView | ✅ | ✅ | ✅ | ✅ | 85% |

---

## 2. P0 严重偏差（必须修复）

### P0-1 强调色值不符合鸿蒙品牌色规范

**规范要求**：鸿蒙蓝浅色模式 `#007DFF`，深色模式 `#4DA0FF`

**现状**：
```typescript
// ThemeColors.ets
export const EMPHASIZE_COLOR: string = '#0A59F7';  // ❌ 非鸿蒙蓝
const DARK_PALETTE: Palette = {
  primary: '#4D8CFF',  // ❌ 应为 #4DA0FF
  ...
};
```

**影响**：全局所有使用 `colors.primary` 的组件颜色均偏差，包括按钮、链接、选中态、开关等。

**修复方案**：
```typescript
// ThemeColors.ets — 对齐鸿蒙品牌色
export const EMPHASIZE_COLOR: string = '#007DFF';

const LIGHT_PALETTE: Palette = {
  // ...
  primary: '#007DFF',        // 鸿蒙蓝
  primarySoft: '#0A59F71A',  // 保持（淡背景仍可用）
  onPrimary: '#FFFFFF',
  // ...
};

const DARK_PALETTE: Palette = {
  // ...
  primary: '#4DA0FF',        // 鸿蒙蓝（深色模式）
  primarySoft: '#4DA0FF1A',  // 深色模式淡背景同步调整
  onPrimary: '#FFFFFF',
  // ...
};
```

---

### P0-2 深色模式背景色使用纯黑

**规范要求**：深色主背景 `#1A1A2E`（深蓝黑），次级背景 `#22223B`，三级背景 `#2D2D44`

**现状**：
```typescript
const DARK_PALETTE: Palette = {
  background: '#000000',  // ❌ 纯黑，鸿蒙规范明确"不建议深色模式使用纯黑"
  surface: '#1E1E1E',     // ❌ 应为 #22223B
  divider: '#2E2E2E',    // ❌ 应为 #3A3A52
  inputBackground: '#2A2A2A', // ❌ 应为 #45455E
  // ...
};
```

**修复方案**：
```typescript
const DARK_PALETTE: Palette = {
  background: '#1A1A2E',   // 鸿蒙深色主背景
  surface: '#22223B',       // 鸿蒙深色卡片背景
  divider: '#3A3A52',       // 鸿蒙深色分隔线
  inputBackground: '#45455E', // 鸿蒙深色输入框背景
  textPrimary: '#E8E8F0',   // 鸿蒙深色主文字
  textSecondary: '#A0A0B8', // 鸿蒙深色次级文字
  textTertiary: '#707088',  // 鸿蒙深色占位文字
  // ...
};
```

---

### P0-3 大量硬编码色值（违反鸿蒙设计禁忌第7条）

**规范要求**：禁止使用固定色值代替语义色，必须使用系统语义化颜色。

**涉及文件与硬编码色值清单**：

| 文件 | 硬编码色值 | 应替换为 |
|------|-----------|---------|
| PinSetupPage.ets | `'#D1D5DB'` | `colors.divider` |
| PinSetupPage.ets | `'#FEF2F2'` | `colors.dangerSoft` |
| PinSetupPage.ets | `'#44AA44'` | `colors.success` |
| PinSetupPage.ets | `'#3B82F6'` | `colors.primary` |
| PinSetupPage.ets | `'#FFFFFF'` | `colors.onPrimary` |
| OnboardingPage.ets | `'#F9FAFB'` | `colors.inputBackground` |
| OnboardingPage.ets | `'#44AA44'` | `colors.success` |
| OnboardingPage.ets | `'#999999'` | `colors.textTertiary` |
| GitClonePage.ets | `'#44AA44'` | `colors.success` |
| GitConfigPage.ets | `'#6B7280'` | `colors.textSecondary` |
| GitConfigPage.ets | `'#FF8800'` | `colors.warning` |
| SettingsPage.ets | `'#F97272'` | `colors.danger` |
| SyncSheet.ets | `'#999999'` | `colors.textTertiary` |
| SyncSheet.ets | `'#FF4444'` | `colors.danger` |
| SyncSheet.ets | `'#666666'` | `colors.textSecondary` |
| SyncSheet.ets | `'#44AA44'` | `colors.success` |
| SyncSheet.ets | `'#F3F4F6'` | `colors.inputBackground` |
| SyncSheet.ets | `'#333333'` | `colors.textPrimary` |
| SyncSheet.ets | `'#3B82F6'` | `colors.primary` |
| SyncSheet.ets | `'#FFFFFF'` | `colors.surface` / `colors.onPrimary` |
| GitLogView.ets | `'#999999'` | `colors.textTertiary` |
| GitLogView.ets | `'#3B82F6'` | `colors.primary` |
| GitLogView.ets | `'#333333'` | `colors.textPrimary` |

**修复方案**：逐文件将硬编码色值替换为 `this.colors.xxx` 令牌引用。SyncSheet 和 GitLogView 需先引入 ThemeColors + Palette 并添加 `private get colors()` getter。

---

### P0-4 按钮圆角与高度不统一，不符合鸿蒙按钮规范

**规范要求**：

| 按钮类型 | 高度 | 圆角 | 当前状态 |
|---------|------|------|---------|
| 主操作按钮 | 44vp | 22vp（胶囊形） | ❌ 48vp + 8vp |
| 次操作按钮 | 44vp | 12vp | ❌ 44vp + 8vp |
| 小型按钮 | 32vp | 16vp | ❌ 40vp + 8vp |
| 危险按钮 | 44vp | 22vp | ❌ 44vp + 8vp |

**现状**：项目中所有按钮统一使用 `borderRadius(8)`，高度在 40-48vp 之间不一致。

**修复方案**：在 ThemeColors.ets 中新增按钮令牌：

```typescript
export class ButtonSpec {
  /** 主操作按钮高度 */
  static readonly PRIMARY_HEIGHT: number = 44;
  /** 主操作按钮圆角（胶囊形） */
  static readonly PRIMARY_RADIUS: number = 22;
  /** 次操作按钮圆角 */
  static readonly SECONDARY_RADIUS: number = 12;
  /** 小型按钮高度 */
  static readonly SMALL_HEIGHT: number = 32;
  /** 小型按钮圆角 */
  static readonly SMALL_RADIUS: number = 16;
  /** 按钮字号 */
  static readonly FONT_SIZE: number = 16;
  /** 按钮字重 */
  static readonly FONT_WEIGHT: number = FontWeight.Medium;
}
```

页面修改示例（PasswordCreatePage 保存按钮）：
```typescript
// 修改前
Button('保存')
  .borderRadius(8)
  .height(48)

// 修改后
Button('保存')
  .borderRadius(ButtonSpec.PRIMARY_RADIUS)  // 22vp 胶囊形
  .height(ButtonSpec.PRIMARY_HEIGHT)        // 44vp
```

---

### P0-5 SyncSheet 和 GitLogView 完全不支持深色模式

**现状**：
- `SyncSheet.ets`：背景硬编码 `#FFFFFF`，所有文字色/按钮色均为硬编码，深色模式下白底黑字
- `GitLogView.ets`：无 ThemeColors 引用，全部使用 `#333333`/`#999999`/`#3B82F6` 硬编码

**修复方案**：为两个组件引入 ThemeColors + Palette，添加 colors getter，替换所有硬编码色值。详见第 6 节优化方案。

---

### P0-6 PinSetupPage 深色模式完全缺失

**现状**：PinSetupPage 是密码管理器的安全关键页面，但深色模式下：
- PIN 圆点未选中色 `#D1D5DB`（浅灰色，深色模式下不可见）
- 键盘背景 `colors.inputBackground` 但文字色硬编码
- 成功/按钮色硬编码，不适配深色

**修复方案**：
```typescript
// pinDot 修改
Circle()
  .fill(this.viewModel.enteredPin.length > index 
    ? this.colors.primary 
    : this.colors.divider)  // 替换 #D1D5DB

// pinKey 修改
Text(label)
  .fontColor(this.colors.textPrimary)
  .backgroundColor(this.colors.inputBackground)

// 主按钮修改
Button(...)
  .backgroundColor(this.viewModel.isDone 
    ? this.colors.success 
    : this.colors.primary)  // 替换硬编码
  .fontColor(this.colors.onPrimary)  // 替换 #FFFFFF
```

---

## 3. P1 明显偏差（强烈建议修复）

### P1-1 卡片内边距偏差

**规范要求**：卡片内边距 16vp

**现状**：`Spacing.CARD = 12`（偏差 4vp）

**修复方案**：
```typescript
export class Spacing {
  // ...
  static readonly CARD: number = 16;  // 12 → 16，对齐鸿蒙规范
}
```

注意：此修改会影响所有使用 `Spacing.CARD` 的卡片布局，需验证视觉一致性。

---

### P1-2 浅色模式文字色偏差

**规范要求**：
| 语义 | 规范值 | 当前值 |
|------|--------|--------|
| primaryText | `#191919` | `#182431` |
| textSecondary | `#6C7280` | `#5E5E5E` |
| textTertiary | `#9AA0A9` | `#99182431`（带透明度，非法） |

**修复方案**：
```typescript
const LIGHT_PALETTE: Palette = {
  textPrimary: '#191919',    // 对齐鸿蒙纯黑
  textSecondary: '#6C7280', // 对齐鸿蒙灰6
  textTertiary: '#9AA0A9',  // 对齐鸿蒙灰4（实色，不用透明度）
  // ...
};
```

---

### P1-3 warning 色值偏差且大小写不规范

**现状**：`warning: '#ED8f46'`（小写 f 不规范）

**规范要求**：浅色 `#E8A739`，深色 `#FFB84D`

**修复方案**：
```typescript
const LIGHT_PALETTE: Palette = {
  warning: '#E8A739',  // 对齐鸿蒙警告橙
  // ...
};
const DARK_PALETTE: Palette = {
  warning: '#FFB84D',  // 对齐鸿蒙深色警告
  // ...
};
```

---

### P1-4 List 未使用 LazyForEach（性能隐患）

**规范要求**：长列表阈值 50 条以上必须使用 LazyForEach

**现状**：PasswordListPage 使用 `ForEach`：
```typescript
List() {
  ForEach(this.viewModel.filteredEntries, (entry: PasswordEntryVM) => {
    ListItem() { ... }
  }, (entry: PasswordEntryVM) => entry.relativePath)
}
```

**修复方案**：
```typescript
List() {
  LazyForEach(this.viewModel.getEntryDataSource(), (entry: PasswordEntryVM) => {
    ListItem() {
      PasswordItemView({ entry: entry, onItemClicked: ... })
    }
  }, (entry: PasswordEntryVM) => entry.relativePath)
}
```

需在 PasswordListViewModel 中实现 `LazyForEach` 所需的 `IDataSource` 适配器。

---

### P1-5 缺少底部 TabBar 导航

**规范要求**：鸿蒙底部标签栏高度 56vp，最多 5 个 Tab，选中态鸿蒙蓝

**现状**：PasswordListPage 顶部用自定义 Row 的文字按钮切换"同步"/"设置"，无底部 TabBar。

**分析**：密码管理器的主要功能入口包括：密码列表、密码生成器、设置、密钥管理。当前全部依赖顶部文字按钮或 Navigation push，操作层级深。

**建议方案**（可选，视产品定位决定）：
```
底部 TabBar:
├─ 密码（PasswordListPage）  — 鸿蒙蓝选中
├─ 生成（PassgenPage）       — 鸿蒙蓝选中
├─ 密钥（PgpKeyManagerPage） — 鸿蒙蓝选中
└─ 设置（SettingsPage）      — 鸿蒙蓝选中
```

或保持当前单入口设计但将"同步"/"设置"改为标准导航栏操作按钮（图标按钮，24vp 图标，间距 8vp）。

---

### P1-6 顶部导航栏不规范

**规范要求**：标准导航栏高度 56vp，标题 20fp Medium；大标题导航栏高度 104vp，大标题 28fp Bold

**现状**：PasswordListPage 顶部自定义 Row：
```typescript
Text('密码仓库')
  .fontSize(FontSize.TITLE + 4)  // = 24，硬编码加4，不规范
  .fontWeight(FontWeight.Bold)
```

**修复方案**：
```typescript
// 方案一：大标题样式
Text('密码仓库')
  .fontSize(28)                    // 鸿蒙大标题 28fp
  .fontWeight(FontWeight.Bold)
  .fontColor(this.colors.textPrimary)

// 方案二：标准标题样式
Text('密码仓库')
  .fontSize(20)                    // 鸿蒙标准标题 20fp
  .fontWeight(FontWeight.Medium)
  .fontColor(this.colors.textPrimary)
```

将 `FontSize.TITLE + 4` 的硬编码运算改为 `FontSize.DISPLAY_LG`（值改为 28）。

---

### P1-7 输入框规范偏差

**规范要求**：
| 参数 | 规范值 | 当前值 |
|------|--------|--------|
| 文本输入框高度 | 44vp | 48vp（PasswordCreatePage） |
| 输入框圆角 | 12vp | 未设置 |
| 输入框默认描边 | 1vp #CDD1D6 | 未设置 |
| 输入框聚焦描边 | 2vp #007DFF | 未设置 |

**修复方案**：PasswordCreatePage 输入框添加圆角与边框：
```typescript
TextInput(...)
  .height(44)                                          // 44vp
  .borderRadius(Radius.MD)                             // 12vp
  .border({ width: 1, color: this.colors.divider })   // 1vp 默认边框
  .backgroundColor(this.colors.surface)                // 白色填充
```

---

### P1-8 列表项间距不符合卡片间距规范

**规范要求**：卡片间距 12vp

**现状**：PasswordItemView `margin({ top: Spacing.SM / 2 })` = 4vp

**修复方案**：
```typescript
.margin({ top: Spacing.MD })  // 12vp 卡片间距
```

---

### P1-9 无障碍标签缺失

**规范要求**：所有交互元素必须提供无障碍标签，触控区域不小于 44x44vp

**现状**：全局无 `.accessibilityText()` / `.accessibilityDescription()` 调用。

**修复方案示例**：
```typescript
// PasswordListPage 同步按钮
Text('同步')
  .fontSize(FontSize.SUBTITLE)
  .fontColor(this.colors.primary)
  .accessibilityText('同步密码仓库')
  .accessibilityDescription('点击打开 Git 同步面板')
  .accessibilityRole(AccessibilityRole.Button)
  // 确保触控区域 ≥ 44vp
  .padding({ left: Spacing.LG, right: Spacing.LG, top: Spacing.LG, bottom: Spacing.LG })
```

---

### P1-10 FAB 按钮位置不规范

**规范要求**：FAB 距右边缘 16vp，距底部 16vp + 安全区

**现状**：使用百分比绝对定位：
```typescript
.position({ x: '82%', y: '88%' })  // 不同屏幕宽度下位置不一致
```

**修复方案**：
```typescript
// 使用固定 vp 值 + 安全区适配
.position({ 
  right: Spacing.PAGE_H,  // 16vp 距右边缘
  bottom: Spacing.PAGE_H + 48  // 16vp + 手势导航栏 48vp
})
```

或使用 `markAnchor` + `position` 组合实现锚定。

---

## 4. P2 优化建议

### P2-1 字号阶梯微调

| 令牌 | 当前值 | 规范对应 | 建议 |
|------|--------|---------|------|
| DISPLAY_LG | 28 | 无直接对应（最近 Headline 1 = 36） | 改为 36 或新建 `HEADLINE = 36` |
| DISPLAY_MD | 24 | Headline 3 = 24 ✓ | 保持 |
| TITLE | 20 | Title 2 = 20 ✓ | 保持 |
| SUBTITLE | 16 | Subtitle 1 = 16 ✓ | 保持 |
| BODY | 14 | Body 2 = 14 ✓ | 保持 |
| CAPTION | 12 | Caption 1 = 12 ✓ | 保持 |
| OVERLINE | 11 | Caption 2 = 10 | 改为 10 |

### P2-2 弹窗规范偏差

PasswordDetailPage 删除确认面板使用 `bindSheet`，但鸿蒙规范弹窗应使用 `CustomDialog` 或 `AlertDialog`，圆角 24vp。当前 `bindSheet` 是半模态面板，也可接受，但需添加：
- 顶部拖拽指示器（40x4vp 横条）
- 面板圆角 24vp（顶部）

### P2-3 页面转场动画

建议为 NavDestination 添加鸿蒙弹性转场动画：
```typescript
.customNavContentTransition((from: NavContentInfo, to: NavContentInfo) => {
  // 鸿蒙标准弹性转场：300ms + 阻尼0.75
})
```

### P2-4 触觉反馈

在关键交互处添加触觉反馈：
```typescript
import { vibrator } from '@kit.SensorServiceKit';

// 按钮点击
vibrator.startVibration({ type: 'light', duration: 10 }, 
  { id: 0, usage: 'alarm' });
```

### P2-5 搜索框边框

鸿蒙规范搜索框无边框，仅背景填充。当前 PasswordListPage 搜索框有 `border({ width: 1, color: this.colors.divider })`，建议移除。

### P2-6 字体族声明

虽然系统默认字体就是 HarmonyOS Sans，但建议在全局样式或 EntryAbility 中显式声明：
```typescript
// 在全局 Text 样式中
.fontFamily('HarmonyOS Sans')
```

---

## 5. 逐页面审查清单

### ThemeColors.ets

| 检查项 | 规范值 | 当前值 | 状态 |
|--------|--------|--------|------|
| 强调色（浅色） | #007DFF | #0A59F7 | ❌ |
| 强调色（深色） | #4DA0FF | #4D8CFF | ❌ |
| 深色背景 | #1A1A2E | #000000 | ❌ |
| 深色卡片背景 | #22223B | #1E1E1E | ❌ |
| 深色分隔线 | #3A3A52 | #2E2E2E | ❌ |
| 深色输入框背景 | #45455E | #2A2A2A | ❌ |
| 深色主文字 | #E8E8F0 | #E5E5E5 | ❌ |
| 深色次级文字 | #A0A0B8 | #A6A6A6 | ❌ |
| 深色占位文字 | #707088 | #99FFFFFF | ❌ |
| 浅色主文字 | #191919 | #182431 | ❌ |
| 浅色次级文字 | #6C7280 | #5E5E5E | ❌ |
| 浅色三级文字 | #9AA0A9 | #99182431 | ❌ |
| 警告色（浅色） | #E8A739 | #ED8f46 | ❌ |
| 警告色（深色） | #FFB84D | #F0A05A | ❌ |
| 圆角阶梯 | 8/12/16/24 | 8/12/16/24 | ✅ |
| 间距阶梯 | 4/8/12/16/24 | 4/8/12/16/24 | ✅ |
| 卡片内边距 | 16 | 12 | ❌ |
| 字号阶梯 | 基本对齐 | 基本对齐 | ⚠️ |

### PasswordListPage.ets

| 检查项 | 规范 | 当前 | 状态 |
|--------|------|------|------|
| 标题字号 | 28fp Bold（大标题） | 24fp Bold | ⚠️ |
| 搜索框高度 | 40vp | 40vp | ✅ |
| 搜索框圆角 | 20vp（全圆角） | 999（全圆角） | ✅ |
| 搜索框边框 | 无边框 | 有1vp边框 | ⚠️ |
| FAB 尺寸 | 56x56vp | 56x56vp | ✅ |
| FAB 圆角 | 胶囊形 | Circle | ✅ |
| FAB 位置 | 固定距右16vp | 百分比定位 | ❌ |
| 列表虚拟滚动 | LazyForEach | ForEach | ❌ |
| 空状态图标 | 48vp | 56vp | ⚠️ |
| 顶部操作按钮触控区 | ≥44vp | 可能不足 | ⚠️ |

### PasswordDetailPage.ets

| 检查项 | 规范 | 当前 | 状态 |
|--------|------|------|------|
| 信息行高度 | 48vp | 64vp | ⚠️ 偏高 |
| 信息行圆角 | 12vp | 12vp | ✅ |
| 按钮高度 | 44vp | 44vp | ✅ |
| 按钮圆角 | 22vp（主）/12vp（次） | 8vp | ❌ |
| 删除确认弹窗圆角 | 24vp | bindSheet 默认 | ⚠️ |
| 复制图标尺寸 | 24vp | 22vp | ⚠️ |
| 信息行间距 | 8vp | 8vp | ✅ |

### PinSetupPage.ets

| 检查项 | 规范 | 当前 | 状态 |
|--------|------|------|------|
| 深色模式支持 | 必须 | 完全缺失 | ❌ |
| 硬编码色值 | 禁止 | 5处 | ❌ |
| 按钮圆角 | 22vp | 8vp | ❌ |
| 键盘按键圆角 | 16vp | 16vp | ✅ |
| 键盘按键尺寸 | 72x64vp | 72x64vp | ⚠️ 宽度偏大 |

### SyncSheet.ets

| 检查项 | 规范 | 当前 | 状态 |
|--------|------|------|------|
| 深色模式支持 | 必须 | 完全缺失 | ❌ |
| 硬编码色值 | 禁止 | 10+处 | ❌ |
| 面板圆角 | 24vp（顶部） | 16vp | ❌ |
| 按钮圆角 | 22vp/12vp | 8vp | ❌ |
| 状态色值 | 语义化 | 全硬编码 | ❌ |
| ThemeColors 引用 | 必须 | 未引入 | ❌ |

### GitLogView.ets

| 检查项 | 规范 | 当前 | 状态 |
|--------|------|------|------|
| 深色模式支持 | 必须 | 完全缺失 | ❌ |
| 硬编码色值 | 禁止 | 6+处 | ❌ |
| ThemeColors 引用 | 必须 | 未引入 | ❌ |
| 列表行高 | 48vp | 自适应 | ⚠️ |
| 哈希字号 | 12fp | 12fp | ✅ |

---

## 6. 优化方案

### 6.1 ThemeColors.ets 完整修复

```typescript
/** HarmonyOS Design 强调色（鸿蒙蓝） */
export const EMPHASIZE_COLOR: string = '#007DFF';

/** 浅色调色板（对齐 HarmonyOS 浅色语义） */
const LIGHT_PALETTE: Palette = {
  background: '#F1F3F5',     // 灰白主背景 ✅
  surface: '#FFFFFF',         // 卡片背景 ✅
  textPrimary: '#191919',    // 纯黑主文字 ← 修正
  textSecondary: '#6C7280', // 灰6次级文字 ← 修正
  textTertiary: '#9AA0A9',  // 灰4三级文字（实色） ← 修正
  divider: '#E5E8EA',       // 分隔线 ✅（微调）
  primary: '#007DFF',       // 鸿蒙蓝 ← 修正
  primarySoft: '#007DFF1A', // 鸿蒙蓝淡背景 ← 修正
  onPrimary: '#FFFFFF',     // ✅
  success: '#64BB5C',       // 成功绿 ✅
  warning: '#E8A739',       // 警告橙 ← 修正
  danger: '#E84026',       // 错误红 ✅
  dangerSoft: '#FEF2F2',   // ✅
  inputBackground: '#F1F3F5', // ✅
};

/** 深色调色板（对齐 HarmonyOS 深色语义） */
const DARK_PALETTE: Palette = {
  background: '#1A1A2E',    // 深蓝黑主背景 ← 修正
  surface: '#22223B',       // 深色卡片背景 ← 修正
  textPrimary: '#E8E8F0',  // 深色主文字 ← 修正
  textSecondary: '#A0A0B8',// 深色次级文字 ← 修正
  textTertiary: '#707088', // 深色占位文字 ← 修正
  divider: '#3A3A52',      // 深色分隔线 ← 修正
  primary: '#4DA0FF',      // 鸿蒙蓝（深色） ← 修正
  primarySoft: '#4DA0FF1A',// 深色淡背景 ← 修正
  onPrimary: '#FFFFFF',     // ✅
  success: '#7ED680',       // 深色成功绿 ← 修正
  warning: '#FFB84D',       // 深色警告橙 ← 修正
  danger: '#FF6B5E',        // 深色错误红 ← 修正
  dangerSoft: '#2A1A18',   // 深色错误淡背景 ← 修正
  inputBackground: '#45455E',// 深色输入框背景 ← 修正
};
```

### 6.2 Spacing 与 FontSize 修正

```typescript
export class Spacing {
  static readonly XS: number = 4;
  static readonly SM: number = 8;
  static readonly MD: number = 12;
  static readonly LG: number = 16;
  static readonly XL: number = 24;
  static readonly PAGE_H: number = 16;
  static readonly CARD: number = 16;  // 12 → 16 ← 修正
}

export class FontSize {
  static readonly HEADLINE: number = 36;    // 新增鸿蒙 Headline 1
  static readonly DISPLAY_LG: number = 28;  // 大标题（非鸿蒙标准阶梯，保留用于页面标题）
  static readonly DISPLAY_MD: number = 24;  // Headline 3 ✅
  static readonly TITLE: number = 20;       // Title 2 ✅
  static readonly SUBTITLE: number = 16;    // Subtitle 1 ✅
  static readonly BODY: number = 14;        // Body 2 ✅
  static readonly CAPTION: number = 12;     // Caption 1 ✅
  static readonly OVERLINE: number = 10;    // 11 → 10 ← 修正（Caption 2）
}
```

### 6.3 新增按钮规范令牌

```typescript
export class ButtonSpec {
  static readonly PRIMARY_HEIGHT: number = 44;
  static readonly PRIMARY_RADIUS: number = 22;
  static readonly SECONDARY_HEIGHT: number = 44;
  static readonly SECONDARY_RADIUS: number = 12;
  static readonly SMALL_HEIGHT: number = 32;
  static readonly SMALL_RADIUS: number = 16;
  static readonly DANGER_HEIGHT: number = 44;
  static readonly DANGER_RADIUS: number = 22;
  static readonly FONT_SIZE: number = 16;
  static readonly FONT_WEIGHT: number = FontWeight.Medium;
}
```

### 6.4 SyncSheet 完整重构方案

```typescript
import { SyncViewModel } from '../viewmodel/SyncViewModel';
import { GitLogView } from './GitLogView';
import { ThemeColors, Palette, ButtonSpec, Spacing, FontSize } from '../common/ThemeColors';

@ComponentV2
export struct SyncSheet {
  @Param viewModel: SyncViewModel = new SyncViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.refreshStatus();
  }

  build() {
    Column() {
      // 拖拽指示器（鸿蒙半模态面板规范）
      Divider()
        .width(40)
        .height(4)
        .borderRadius(2)
        .color(this.colors.divider)
        .margin({ top: Spacing.SM, bottom: Spacing.SM })

      // 标题
      Row() {
        Text('Git 同步')
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .layoutWeight(1)

        Text(this.viewModel.getStatusSummary())
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.textTertiary)
      }
      .width('100%')
      .padding({ left: Spacing.LG, right: Spacing.LG, bottom: Spacing.SM })

      // 冲突提示
      if (this.viewModel.conflictMessage.length > 0) {
        Text(this.viewModel.conflictMessage)
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.danger)
          .padding({ left: Spacing.LG, right: Spacing.LG, bottom: Spacing.SM })
      }

      // 操作中提示
      if (this.viewModel.isSyncing) {
        Row() {
          LoadingProgress()
            .width(20)
            .height(20)
            .margin({ right: Spacing.SM })
          Text(this.viewModel.operationText)
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.textSecondary)
        }
        .width('100%')
        .padding({ left: Spacing.LG, right: Spacing.LG, bottom: Spacing.SM })
      }

      // 操作结果提示
      if (this.viewModel.resultToast.length > 0) {
        Text(this.viewModel.resultToast)
          .fontSize(FontSize.BODY)
          .fontColor(this.viewModel.lastOperationSuccess 
            ? this.colors.success 
            : this.colors.danger)
          .padding({ left: Spacing.LG, right: Spacing.LG, bottom: Spacing.SM })
      }

      // 操作按钮
      Row() {
        Button('拉取')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .margin({ right: Spacing.SM })
          .onClick(() => { this.viewModel.pull(); })

        Button('提交')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .margin({ right: Spacing.SM })
          .onClick(() => { this.viewModel.commit(''); })

        Button('推送')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.SECONDARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .backgroundColor(this.colors.inputBackground)
          .fontColor(this.colors.textPrimary)
          .enabled(!this.viewModel.isSyncing)
          .margin({ right: Spacing.SM })
          .onClick(() => { this.viewModel.push(); })

        Button('一键同步')
          .type(ButtonType.Normal)
          .borderRadius(ButtonSpec.PRIMARY_RADIUS)
          .layoutWeight(1)
          .height(ButtonSpec.PRIMARY_HEIGHT)
          .backgroundColor(this.colors.primary)
          .fontColor(this.colors.onPrimary)
          .enabled(!this.viewModel.isSyncing)
          .onClick(() => { this.viewModel.syncAll(); })
      }
      .width('100%')
      .padding({ left: Spacing.LG, right: Spacing.LG, top: Spacing.SM })

      // 提交历史
      Column() {
        Scroll() {
          GitLogView()
        }
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: Spacing.XS, bottom: Spacing.SM })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors.background)
    .borderRadius({ topLeft: 24, topRight: 24 })  // 鸿蒙半模态面板圆角 24vp
  }
}
```

### 6.5 GitLogView 完整重构方案

```typescript
import { GitLogViewModel } from '../viewmodel/GitLogViewModel';
import { GitCommitInfo } from '../utils/GitClient';
import { ThemeColors, Palette, Spacing, FontSize, Radius } from '../common/ThemeColors';

@ComponentV2
export struct GitLogView {
  @Local viewModel: GitLogViewModel = new GitLogViewModel();

  private get colors(): Palette {
    return ThemeColors.getInstance().palette();
  }

  aboutToAppear(): void {
    this.viewModel.loadLog();
  }

  build() {
    Column() {
      Row() {
        Text('提交历史')
          .fontSize(FontSize.SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors.textPrimary)
          .layoutWeight(1)

        Text('刷新')
          .fontSize(FontSize.CAPTION)
          .fontColor(this.colors.primary)
          .onClick(() => { this.viewModel.loadLog(); })
      }
      .width('100%')
      .padding({ left: Spacing.LG, right: Spacing.LG, top: Spacing.MD, bottom: Spacing.SM })

      if (this.viewModel.isLoading) {
        Row() {
          LoadingProgress().width(24).height(24)
          Text('加载中...')
            .fontSize(FontSize.BODY)
            .fontColor(this.colors.textTertiary)
            .margin({ left: Spacing.SM })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding(Spacing.XL)
      } else if (this.viewModel.errorMessage.length > 0) {
        Text(this.viewModel.errorMessage)
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Spacing.XL)
      } else if (this.viewModel.commits.length === 0) {
        Text('暂无提交记录')
          .fontSize(FontSize.BODY)
          .fontColor(this.colors.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Spacing.XL)
      } else {
        List() {
          LazyForEach(this.viewModel.getCommitDataSource(), (commit: GitCommitInfo) => {
            ListItem() {
              Row() {
                Column() {
                  Text(commit.summary)
                    .fontSize(FontSize.BODY)
                    .fontColor(this.colors.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Row() {
                    Text(this.viewModel.shortHash(commit.hash))
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.primary)
                      .fontFamily('monospace')
                    Text(commit.authorName)
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.textTertiary)
                      .margin({ left: Spacing.SM })
                    Blank()
                    Text(this.viewModel.formatTime(commit.timestamp))
                      .fontSize(FontSize.CAPTION)
                      .fontColor(this.colors.textTertiary)
                  }
                  .width('100%')
                  .margin({ top: Spacing.XS })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ 
                left: Spacing.LG, right: Spacing.LG, 
                top: Spacing.SM + 2, bottom: Spacing.SM + 2 
              })
            }
          }, (commit: GitCommitInfo) => commit.hash)
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .constraintSize({ minHeight: 120 })
      }
    }
    .width('100%')
  }
}
```

### 6.6 PinSetupPage 修复方案

```typescript
@Builder
pinDot(index: number) {
  Circle()
    .width(14)
    .height(14)
    .fill(this.viewModel.enteredPin.length > index 
      ? this.colors.primary 
      : this.colors.divider)  // ← 替换 #D1D5DB
    .margin({ left: Spacing.SM, right: Spacing.SM })
}

// 底部按钮
Button(this.viewModel.isDone ? '完成' : (...))
  .borderRadius(ButtonSpec.PRIMARY_RADIUS)  // 22vp 胶囊形
  .layoutWeight(1)
  .height(ButtonSpec.PRIMARY_HEIGHT)
  .backgroundColor(this.viewModel.isDone 
    ? this.colors.success 
    : this.colors.primary)  // ← 替换硬编码
  .fontColor(this.colors.onPrimary)  // ← 替换 #FFFFFF

// 清除按钮
Button('清除 PIN')
  .borderRadius(ButtonSpec.PRIMARY_RADIUS)
  .width(110)
  .height(ButtonSpec.PRIMARY_HEIGHT)
  .backgroundColor(this.colors.dangerSoft)  // ← 替换 #FEF2F2
  .fontColor(this.colors.danger)
```

### 6.7 全局按钮修复清单

需将以下页面中所有 `borderRadius(8)` 按钮改为鸿蒙规范圆角：

| 页面 | 按钮位置 | 当前 | 改为 |
|------|---------|------|------|
| PasswordCreatePage | 保存按钮 | 8vp, 48vp | 22vp, 44vp |
| PasswordCreatePage | 生成密码按钮 | 8vp, 40vp | 16vp, 32vp |
| PasswordDetailPage | 编辑按钮 | 8vp, 44vp | 22vp, 44vp |
| PasswordDetailPage | 移动按钮 | 8vp, 44vp | 12vp, 44vp |
| PasswordDetailPage | 删除按钮 | 8vp, 44vp | 22vp, 44vp |
| PasswordDetailPage | 复制按钮 | 8vp, 40vp | 12vp, 44vp |
| PasswordDetailPage | 删除确认/取消 | 8vp, 42vp | 12vp, 44vp |
| PassgenPage | 生成/复制按钮 | 8vp, 44vp | 22vp, 44vp |
| OnboardingPage | 所有按钮 | 8vp, 44vp | 22vp, 44vp |
| GitClonePage | 克隆/取消按钮 | 8vp, 48/44vp | 22vp, 44vp |
| GitClonePage | 粘贴按钮 | 8vp, 32vp | 16vp, 32vp |
| GitConfigPage | 所有按钮 | 8vp, 40/44vp | 22/12vp, 44vp |
| MoveEntryPage | 保存按钮 | Capsule, 48vp | 保持✅ |
| FolderCreatePage | 创建按钮 | Capsule, 48vp | 保持✅ |
| PgpKeyManagerPage | 导入/生成按钮 | 8vp, 42vp | 16vp, 32vp |
| SshKeyManagerPage | 导入/生成按钮 | 8vp, 42vp | 16vp, 32vp |
| LockPage | 生物识别按钮 | FULL, 40vp | 保持✅ |

---

## 7. 还原度评分明细

| 维度 | 满分 | 得分 | 说明 |
|------|------|------|------|
| 色彩体系 | 15 | 8 | 强调色偏差+硬编码色值扣分 |
| 深色模式 | 15 | 7 | 3个组件完全缺失深色支持 |
| 字体排版 | 10 | 8 | 阶梯基本对齐，个别偏差 |
| 间距网格 | 10 | 7 | 卡片内边距偏差+非8倍数间距 |
| 圆角体系 | 10 | 7 | 阶梯正确但按钮圆角全错 |
| 组件规范 | 15 | 8 | 按钮高度/圆角/输入框偏差 |
| 交互范式 | 10 | 7 | 缺少TabBar+FAB位置不规范 |
| 无障碍 | 5 | 2 | 无障碍标签全面缺失 |
| 性能优化 | 5 | 3 | List未用LazyForEach |
| 动效 | 5 | 2 | 未自定义转场/触觉反馈 |
| **总计** | **100** | **62** | |

---

## 优化优先级建议

| 优先级 | 任务 | 影响范围 | 工作量 |
|--------|------|---------|--------|
| **P0-1** | 修复 ThemeColors 色值 | 全局 | 小（改1个文件） |
| **P0-2** | 消除硬编码色值 | 6个页面 | 中（逐文件替换） |
| **P0-3** | 重构 SyncSheet + GitLogView | 2个组件 | 中（引入ThemeColors） |
| **P0-4** | 统一按钮圆角/高度 | 全局 | 中（逐页面修改） |
| **P0-5** | 修复 PinSetupPage 深色模式 | 1个页面 | 小 |
| **P1-1** | 修复卡片内边距 | 全局 | 小（改1个常量） |
| **P1-2** | List 改用 LazyForEach | 2个列表 | 中 |
| **P1-3** | 修复 FAB 位置 | 1个页面 | 小 |
| **P1-4** | 添加无障碍标签 | 全局 | 大 |
| **P2** | 动效/触觉反馈/搜索框边框 | 全局 | 中 |

---

> **结论**：项目在架构骨架（Design Token 分层、V2 状态管理、深浅色切换机制）方面做得较好，但在鸿蒙品牌色值准确度、硬编码色值治理、按钮/输入框组件规范、深色模式覆盖率四个维度存在系统性偏差。建议按上述 P0 → P1 → P2 顺序逐步修复，预计可将还原度从 62 提升至 90+。
