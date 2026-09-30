#!/usr/bin/env node
/**
 * 调色板对比度校验（AGC 上架审核：图标/标题 >3:1、正文 >4.5:1）
 *
 * 直接解析 `entry/src/main/ets/common/ThemeColors.ets` 里的两套调色板
 * （不另存一份色值——那必然会与源码漂移），对「前景 token × 背景 token」
 * 全矩阵计算 WCAG 2.x 对比度，任一组合低于阈值即以非零码退出。
 *
 * 用法：`node scripts/check-contrast.mjs`
 *
 * ## 为什么需要它
 *
 * 首轮 AGC 审核因「两处对比度不足」被打回，根因是 `textTertiary = #9AA0A9`
 * （2.09~2.63:1）同时低于正文与图标两条线，而它既做说明文字又做行尾箭头。
 * 这类问题**肉眼看不出来**（浅灰在浅底上「看着还行」），只能靠数值拦住，
 * 所以把它固化成脚本、挂进 CI/提交前检查。
 */

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SOURCE = resolve(HERE, '../entry/src/main/ets/common/ThemeColors.ets');

/** 正文文字下限（WCAG AA 常规字号） */
const BODY_MIN = 4.5;
/** 图标 / 标题文字下限 */
const ICON_MIN = 3.0;

/** 会被当作**背景**的 token（页面底、卡片、输入框、中性按钮） */
const BACKGROUND_TOKENS = ['surface', 'background', 'inputBackground', 'neutralButton'];
/** 会被当作**前景**（文字或图标）的 token */
const FOREGROUND_TOKENS = [
  'textPrimary', 'textSecondary', 'textTertiary',
  'primary', 'success', 'warning', 'danger',
];
/**
 * 各前景 token 实际会落在哪些背景上（未列出的 token = 全部四个背景）
 *
 * 只对**强调色**收窄：它作前景时只出现在卡片 / 页面底 / 输入框底（分段控件的选中项、
 * 链接式文字、行首图标），从不出现在中性按钮上。而深色下「强调色文字落在
 * `neutralButton`(#2E2E2E) 上 >4.5:1」与「白字落在强调色上 >3:1（按钮/FAB 图标）」
 * 两个约束的可行亮度区间几乎不重叠（需要 L 落在 0.298~0.30 之间，零余量），
 * 强行同时满足会让任一取值在浮点误差下随时破线。故按真实用法校验。
 * 新增「强调色文字落在中性按钮上」的写法时，必须把 `neutralButton` 加回本列表。
 */
const FOREGROUND_BACKGROUNDS = {
  primary: ['surface', 'background', 'inputBackground'],
};
/**
 * 仅作图标/大色块使用的前景 token
 *
 * `onPrimary`（按钮/FAB 上的白字白图标）只对强调色底要求 3:1——
 * 它按定义不会落在页面底/卡片上，不参与四背景矩阵。
 */
const ICON_ONLY_ON_PRIMARY = 'onPrimary';

function srgbToLinear(channel) {
  const c = channel / 255;
  return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/** #RRGGBB 或 #AARRGGBB → 相对亮度（8 位写法按 ArkUI 约定 alpha 在前，此处忽略 alpha） */
function relativeLuminance(hex) {
  let h = hex.replace('#', '');
  if (h.length === 8) h = h.slice(2);
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b);
}

function contrast(a, b) {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const [hi, lo] = la > lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}

/** 从 ThemeColors.ets 里抽出 `const LIGHT_PALETTE: Palette = { ... };` 的键值 */
function parsePalette(source, constName) {
  const start = source.indexOf(`const ${constName}`);
  if (start < 0) throw new Error(`未找到 ${constName}（源码结构变了？请同步本脚本）`);
  const open = source.indexOf('{', start);
  const close = source.indexOf('};', open);
  const body = source.slice(open + 1, close);
  const palette = {};
  const re = /^\s*([A-Za-z][A-Za-z0-9]*)\s*:\s*'(#[0-9A-Fa-f]{6,8})'/gm;
  let m;
  while ((m = re.exec(body)) !== null) palette[m[1]] = m[2];
  return palette;
}

const source = readFileSync(SOURCE, 'utf8');
const palettes = [
  { name: 'LIGHT', values: parsePalette(source, 'LIGHT_PALETTE') },
  { name: 'DARK', values: parsePalette(source, 'DARK_PALETTE') },
];

let failures = 0;
let checks = 0;

for (const { name, values } of palettes) {
  console.log(`\n=== ${name} ===`);
  for (const fg of FOREGROUND_TOKENS) {
    if (!values[fg]) {
      console.log(`  [MISS] 前景 token 缺失：${fg}`);
      failures++;
      continue;
    }
    let worst = { ratio: Infinity, bg: '' };
    const backgrounds = FOREGROUND_BACKGROUNDS[fg] ?? BACKGROUND_TOKENS;
    for (const bg of backgrounds) {
      if (!values[bg]) {
        console.log(`  [MISS] 背景 token 缺失：${bg}`);
        failures++;
        continue;
      }
      const ratio = contrast(values[fg], values[bg]);
      if (ratio < worst.ratio) worst = { ratio, bg };
    }
    checks++;
    const ok = worst.ratio >= BODY_MIN;
    if (!ok) failures++;
    console.log(
      `  ${ok ? '[ OK ]' : '[FAIL]'} ${fg.padEnd(14)} ${values[fg]}  ` +
      `最低 ${worst.ratio.toFixed(2)}:1 (需 ${BODY_MIN}:1) @ ${worst.bg}`,
    );
  }

  // 白字/白图标落在强调色上（按钮、FAB）
  const onPrimary = values[ICON_ONLY_ON_PRIMARY] ?? '#FFFFFF';
  const onPrimaryRatio = contrast(onPrimary, values.primary);
  checks++;
  const onPrimaryOk = onPrimaryRatio >= ICON_MIN;
  if (!onPrimaryOk) failures++;
  console.log(
    `  ${onPrimaryOk ? '[ OK ]' : '[FAIL]'} ${ICON_ONLY_ON_PRIMARY} on primary ` +
    `${onPrimary} / ${values.primary}  ${onPrimaryRatio.toFixed(2)}:1 (需 ${ICON_MIN}:1)`,
  );
}

console.log(
  `\n共校验 ${checks} 项，${failures === 0 ? '全部通过' : `${failures} 项未达标`}。`,
);
if (failures > 0) {
  console.error(
    '\n未达标项必须调整取值（不要放宽阈值）：阈值来自 AGC 上架审核的硬性要求，\n' +
    '且语义色在本应用里同时作正文与图标，需按正文口径取值。详见 ThemeColors.ets 文件头。',
  );
  process.exit(1);
}
