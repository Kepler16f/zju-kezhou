// generate_jieshao.js — 课舟 ClassArk 作品介绍 docx（竞赛骨架）
// 封面用 design-system.md 的 R4 (Top Color Block) + GO-1 色板原样实现。
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  Header, Footer, PageNumber, AlignmentType, HeadingLevel, WidthType,
  BorderStyle, VerticalAlign,
} = require("docx");
const fs = require("fs");

// ── 从 design-system.md 原样复制的共享件 ──
const P = {
  bg: "1A2330", primary: "FFFFFF", accent: "D4875A",
  cover: { titleColor: "FFFFFF", subtitleColor: "B0B8C0", metaColor: "90989F", footerColor: "687078" },
  table: { headerBg: "D4875A", headerText: "FFFFFF", accentLine: "D4875A", innerLine: "DDD0C8", surface: "F8F0EB" },
};
const c = (hex) => hex.replace("#", "");
const NB = { style: BorderStyle.NONE, size: 0, color: "FFFFFF" };
const noBorders = { top: NB, bottom: NB, left: NB, right: NB };
const allNoBorders = { top: NB, bottom: NB, left: NB, right: NB, insideHorizontal: NB, insideVertical: NB };
const emptyPara = () => new Paragraph({ children: [] });

function splitTitleLines(title, charsPerLine) {
  if (title.length <= charsPerLine) return [title];
  const breakAfter = new Set([
    ...'，。、；：！？',
    ...'的与和及之在于为',
    ...'-_—–·/',
    ...' \t',
  ]);
  const chars = [...title];
  let best = -1, bestPenalty = Infinity;
  const lo = Math.floor(charsPerLine * 0.6), hi = Math.ceil(charsPerLine * 1.3);
  for (let i = 0; i < chars.length; i++) {
    if (i < lo || i > hi) continue;
    if (breakAfter.has(chars[i])) {
      const penalty = Math.abs((i + 1) - charsPerLine);
      if (penalty < bestPenalty) { bestPenalty = penalty; best = i; }
    }
  }
  if (best === -1) best = Math.min(charsPerLine, chars.length) - 1;
  const first = chars.slice(0, best + 1).join("");
  return [first, ...splitTitleLines(chars.slice(best + 1).join(""), charsPerLine)];
}
function calcTitleLayout(title, maxWidthTwips, preferredPt = 40, minPt = 24) {
  const charWidth = (pt) => pt * 20;
  const charsPerLine = (pt) => Math.floor(maxWidthTwips / charWidth(pt));
  let titlePt = preferredPt, lines;
  while (titlePt >= minPt) {
    const cpl = charsPerLine(titlePt);
    if (cpl < 2) { titlePt -= 2; continue; }
    lines = splitTitleLines(title, cpl);
    if (lines.length <= 3) break;
    titlePt -= 2;
  }
  if (!lines || lines.length > 3) { lines = splitTitleLines(title, charsPerLine(minPt)); titlePt = minPt; }
  return { titlePt, titleLines: lines };
}

function buildCoverR4(config) {
  const padL = 1200, padR = 800;
  const availableWidth = 11906 - padL - padR;
  const { titlePt, titleLines } = calcTitleLayout(config.title, availableWidth, 40, 26);
  const titleSize = titlePt * 2;
  const titleBlockHeight = titleLines.length * (titlePt * 23 + 200);
  const englishLabelH = config.englishLabel ? (9 * 23 + 500) : 0;
  const subtitleH = config.subtitle ? (12 * 23 + 200) : 0;
  const upperContentH = englishLabelH + titleBlockHeight + subtitleH;
  const UPPER_MIN = 7500;
  const UPPER_H = Math.max(UPPER_MIN, upperContentH + 1500 + 800);
  const DIVIDER_H = 60;
  const contentEstimate =
    (config.englishLabel ? (9 * 23 + 500) : 0) +
    titleLines.length * (titlePt * 23 + 200) +
    (config.subtitle ? (12 * 23 + 200) : 0);
  const spacerIntrinsic = 280;
  const topSpacing = Math.max(UPPER_H - contentEstimate - spacerIntrinsic - 800, 400);

  const upperBlock = new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    layout: "fixed",
    borders: allNoBorders,
    rows: [new TableRow({
      height: { value: UPPER_H, rule: "exact" },
      children: [new TableCell({
        borders: noBorders, shading: { fill: P.bg }, verticalAlign: VerticalAlign.BOTTOM,
        children: [
          new Paragraph({ spacing: { before: topSpacing } }),
          config.englishLabel ? new Paragraph({
            indent: { left: padL }, spacing: { after: 300 },
            children: [new TextRun({ text: config.englishLabel, size: 18, color: P.accent, font: { ascii: "Calibri" }, characterSpacing: 60 })],
          }) : null,
          ...titleLines.map((line, i) => new Paragraph({
            indent: { left: padL, right: padR },
            spacing: { after: i < titleLines.length - 1 ? 100 : 200 },
            children: [new TextRun({ text: line, size: titleSize, bold: true, color: P.cover.titleColor, font: { eastAsia: "SimHei", ascii: "Arial" } })],
          })),
          config.subtitle ? new Paragraph({
            indent: { left: padL, right: padR }, spacing: { after: 100 },
            children: [new TextRun({ text: config.subtitle, size: 24, color: P.cover.subtitleColor, font: { eastAsia: "Microsoft YaHei", ascii: "Arial" } })],
          }) : null,
        ].filter(Boolean),
      })],
    })],
  });

  const divider = new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    borders: allNoBorders,
    rows: [new TableRow({
      height: { value: DIVIDER_H, rule: "exact" },
      children: [new TableCell({ borders: noBorders, shading: { fill: P.accent }, children: [emptyPara()] })],
    })],
  });

  const lowerContent = [
    new Paragraph({ spacing: { before: 800 } }),
    ...(config.metaLines || []).map(line => new Paragraph({
      indent: { left: padL }, spacing: { after: 100 },
      children: [new TextRun({ text: line, size: 28, color: P.cover.metaColor, font: { eastAsia: "Microsoft YaHei", ascii: "Arial" } })],
    })),
    new Paragraph({ spacing: { before: 2000 } }),
    new Paragraph({
      indent: { left: padL },
      children: [
        new TextRun({ text: config.footerLeft || "", size: 22, color: "909090" }),
        new TextRun({ text: "          " }),
        new TextRun({ text: config.footerRight || "", size: 22, color: "909090" }),
      ],
    }),
  ];

  return [new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    layout: "fixed",
    borders: allNoBorders,
    rows: [new TableRow({
      height: { value: 16838, rule: "exact" },
      children: [new TableCell({
        shading: { fill: "FFFFFF" }, borders: noBorders, verticalAlign: "top",
        children: [upperBlock, divider, ...lowerContent],
      })],
    })],
  })];
}

// ── 正文辅助 ──
function heading(text, level = HeadingLevel.HEADING_1) {
  return new Paragraph({
    heading: level,
    spacing: { before: level === HeadingLevel.HEADING_1 ? 360 : 240, after: 120 },
    children: [new TextRun({ text, bold: true, color: c(P.table.accentLine), font: { ascii: "Calibri", eastAsia: "SimHei" } })],
  });
}
function body(text) {
  return new Paragraph({
    alignment: AlignmentType.JUSTIFIED,
    indent: { firstLine: 480 },
    spacing: { line: 312 },
    children: [new TextRun({ text, size: 24, color: "333333" })],
  });
}
function placeholder(text) {
  return new Paragraph({
    alignment: AlignmentType.JUSTIFIED,
    indent: { firstLine: 480 },
    spacing: { line: 312 },
    children: [new TextRun({ text: "〔待填〕" + text, size: 24, italics: true, color: "888888" })],
  });
}
function bullet(text) {
  return new Paragraph({
    bullet: { level: 0 }, spacing: { line: 312 },
    children: [new TextRun({ text, size: 24, color: "333333" })],
  });
}
function tableOf(rows) {
  const mk = (cells, header) => new TableRow({
    children: cells.map((t, i) => new TableCell({
      borders: { top: { style: BorderStyle.SINGLE, size: 4, color: header ? P.table.accentLine : P.table.innerLine },
                 bottom: { style: BorderStyle.SINGLE, size: 4, color: header ? P.table.accentLine : P.table.innerLine },
                 left: { style: BorderStyle.SINGLE, size: 4, color: header ? P.table.accentLine : P.table.innerLine },
                 right: { style: BorderStyle.SINGLE, size: 4, color: header ? P.table.accentLine : P.table.innerLine } },
      shading: header ? { fill: P.table.headerBg } : (undefined),
      verticalAlign: VerticalAlign.CENTER,
      children: [new Paragraph({
        spacing: { before: 60, after: 60 },
        children: [new TextRun({ text: t, size: 21, bold: header, color: header ? "FFFFFF" : "333333" })],
      })],
    })),
  });
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    rows: [mk(rows[0], true), ...rows.slice(1).map(r => mk(r, false))],
  });
}

// ── 组装 ──
const cover = buildCoverR4({
  englishLabel: "CLASSARK  ·  AIHUB 作品申报",
  title: "课舟 ClassArk 作品介绍",
  subtitle: "本科培养方案结构化与选课风险审计智能体",
  metaLines: [
    "参赛赛道：AI 应用创新（本科生队）",
    "作品形态：全平台应用 + 开源仓库",
    "仓库链接：https://github.com/Kepler16f/zju-kezhou",
  ],
  footerLeft: "版本 0.12.1",
  footerRight: "2026 年 10 月",
});

const intro = "课舟 ClassArk——面向浙大学子的学业规划助手，一套代码覆盖 Windows/macOS/Linux/Android/iOS/鸿蒙，交付即安装包。用学生本人账号只读对接教务系统，实时拉取成绩、课表、培养方案与选课信息：自动结构化几十页方案，逐条审计学分缺口、先修断链、时间冲突并溯源到方案页码；内置 GPA 看板、学期走势、GPA 模拟器与选课跨轮汇总。AI 只做「读和说」：把确定性引擎算好的结果翻译成沟通材料，公益端点开箱即用，发送范围经确认且不含姓名、学号与凭证。另有导师审阅模式：学生自愿导出脱敏分享包，教师端零登录零抓取。数据只读、凭证仅存本机沙箱、结论可溯源，实用且合规。";

const bodyChildren = [
  heading("1  作品简介"),
  body(intro),
  new Paragraph({ spacing: { before: 120 }, indent: { firstLine: 480 },
    children: [new TextRun({ text: "（上段即提交表单用的 ≤300 字简介，共 295 字。）", size: 21, color: "888888" })] }),

  heading("2  解决的问题"),
  body("培养方案是几十页 PDF，选课依赖口口相传的经验：差多少学分、哪门课必须排在哪学期、教学班容量与轮次如何取舍——这些判断分散、滞后、易错。课舟把方案结构化、把经验规则化，让学生随时拿到一份能溯源的学业审计报告。"),
  bullet("〔待补〕一句话用户故事 + 〔待补〕真实使用反馈（建议 2–3 条，可匿名）"),

  heading("3  为什么用 AI · 怎么用 AI（创新）"),
  body("分工原则：LLM 负责「读和说」，代码负责「对不对」。学分核算、先修链、时间冲突、选课匹配全部由确定性规则引擎计算，AI 不碰数字。"),
  bullet("M1 抽取工作流：LLM 把方案 PDF 结构化为 JSON，代码校验 + 人工订正，终稿冻结进金标集（准确率评测脚本出数）。"),
  bullet("M2 叙事包装：审计报告 JSON → 三色 Markdown，LLM 只做表述；固定声明由引擎硬编码，LLM 无权删改。"),
  bullet("M4 政策问答：知识库检索 + 代码拒答门，超纲问题固定拒答。"),
  bullet("App 内 AI 助手：公益端点开箱即用；白名单发送范围、首次确认、不含凭证/学号/姓名；Windows 本地 OCR 支持「回答屏幕上的问题」，屏幕内容不外传。"),
  bullet("〔待补〕AI 环节截图或调用链示意 1–2 张"),

  heading("4  实用性"),
  body("不是 demo 而是日常工具：登录自己的教务账号即可用，覆盖从成绩看板、方案审计、选课查询到导师分享的完整链路；无网络时仍可用样例数据与粘贴数据完成审计。"),
  tableOf([
    ["功能", "要点"],
    ["学业看板", "五分制/4.3 制 GPA、加权百分制、学分构成、素拓（第二/三/四课堂）"],
    ["培养方案", "登录后自动匹配方案并结构化；有歧义列候选不盲猜；官方 PDF 应用内看"],
    ["学业审计", "三色报告：缺口/先修断链/同学期排错/时间冲突/停开风险，逐条溯源"],
    ["GPA 工具", "学期走势折线、GPA 模拟器、目标反推（剩余学分需达绩点闭式解）"],
    ["选课查询", "跨轮汇总同教学班快照、与方案/课表匹配的建议卡；只读绝不提交"],
    ["导师模式", "学生自愿导出脱敏分享包；教师端零登录零抓取"],
  ]),

  heading("5  完整性 / 工程质量"),
  bullet("全平台安装包：Windows(arm64/x64) Setup.exe、Android APK(arm64/armv7/x64)、iOS ipa、macOS zip、Linux tar.gz、鸿蒙 HAP。"),
  bullet("CI 金标门：GitHub Actions 双引擎对照（Python↔Dart 逐字段一致）、24+ 单测、只读红线扫描；push tag 即全平台出包。"),
  bullet("可靠性：崩溃自动恢复、单实例、托盘、断网退避、内置中文字体保证一致渲染。"),
  bullet("〔待补〕路线图/已知限制（如 iOS 未签名需自签、鸿蒙未签名需挂载调试）"),

  heading("6  合规与安全"),
  bullet("只读通道：无任何教务写接口，check_readonly.py 在 CI 机械拦截。"),
  bullet("凭证仅存本机沙箱（混淆落盘、可一键清除），Cookie 仅驻内存。"),
  bullet("AI 发送白名单见第 3 节；分享包默认脱敏；报告固定「以教务系统为准」声明。"),
  bullet("〔待补〕如涉及真实账号演示的授权说明（书面/截图）"),

  heading("7  演示"),
  bullet("〔待填〕在线演示入口/视频链接（视频不计入初赛，仅作辅助）"),
  bullet("〔待填〕3 分钟演示脚本要点：登录 → 方案匹配 → 三色报告 → GPA 模拟 → AI 解读"),

  heading("8  团队"),
  tableOf([
    ["成员", "角色", "分工"],
    ["〔待填〕", "〔队长〕", "〔架构与引擎〕"],
    ["〔待填〕", "", "〔App 与 CI〕"],
    ["〔待填〕", "", "〔方案数据与评测〕"],
  ]),

  new Paragraph({ spacing: { before: 240 }, children: [
    new TextRun({ text: "附录：仓库 README、开发方案（docs/开发方案.md）、各接入说明文档可另附。", size: 21, color: "888888" })] }),
];

const doc = new Document({
  styles: { default: { document: {
    run: { font: { ascii: "Calibri", eastAsia: "Microsoft YaHei" }, size: 24, color: "333333" },
    paragraph: { spacing: { line: 312 } },
  }}},
  features: { enableFootnoteAndEndnotes: false },
  sections: [
    { properties: { page: { margin: { top: 0, bottom: 0, left: 0, right: 0 } } }, children: cover },
    {
      properties: { page: { margin: { top: 1440, bottom: 1440, left: 1701, right: 1417 } } },
      footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
        children: [new TextRun({ children: [PageNumber.CURRENT], size: 18 })] })] }) },
      children: bodyChildren,
    },
  ],
});

Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync("docs/作品介绍.docx", buf);
  console.log("OK", buf.length, "bytes -> docs/作品介绍.docx");
});
