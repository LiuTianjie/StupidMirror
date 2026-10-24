#!/usr/bin/env node
// Builds the Codex plugin guide pages (docs/codex/ and docs/zh/codex/) from the
// copy below, which follows docs/codex-plugin.md. Both languages come from one
// source so their structure, hreflang and structured data stay in step.
//
//   node scripts/build-site-guides.mjs           write the pages
//   node scripts/build-site-guides.mjs --check   fail if they are out of date
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const base = "https://stupidmirror.itool.tech/";
const download = "https://github.com/LiuTianjie/StupidMirror/releases/latest";
const guideSource = "https://github.com/LiuTianjie/StupidMirror/blob/main/docs/codex-plugin.md";
const redirect =
  '<script>if(location.hostname.endsWith("github.io"))location.replace("https://stupidmirror.itool.tech"+location.pathname.replace(/^\\/StupidMirror/i,"")+location.search+location.hash)</script>';

const pages = {
  en: {
    lang: "en",
    locale: "en_US",
    path: "codex/",
    up: "../",
    home: "",
    title: "Control an iPhone or Android inside Codex | StupidMirror",
    description:
      "Use the StupidMirror Codex plugin to watch a real iPhone or Android screen inside Codex, let the agent tap and type through MCP, and send annotated screenshots.",
    eyebrow: "CODEX PLUGIN",
    h1: "A real phone, inside your Codex chat.",
    lead: "StupidMirror bundles a Codex plugin. Your agent sees the live screen of a real iPhone or Android device, operates it through MCP, and you point at exactly what you mean with annotations.",
    homeLabel: "StupidMirror",
    guideLabel: "Codex plugin",
    download: "Download StupidMirror",
    connectTitle: "Connect in four steps",
    connectIntro: "No repository clone, Python or Node.js install, or token copying is needed for the installed app.",
    steps: [
      ["Install and connect the phone", "Move StupidMirror to Applications and open it. Connect and unlock the phone. USB video needs trust and Camera permission; Android needs authorized ADB."],
      ["Run iPhone setup once", "For iPhone control or wireless video, complete Set Up This iPhone over USB."],
      ["Click Connect Codex", "In Settings → MCP Automation, click Connect Codex. The app enables local MCP and installs its bundled plugin through the Codex desktop app's CLI."],
      ["Ask Codex", "Open a new Codex chat, select StupidMirror and ask: “Show my phone inside Codex without tapping anything.” The panel opens through show_screen."],
    ],
    useTitle: "View, operate, annotate",
    uses: [
      ["View", "Choose a device; pause and resume, refresh, return Home or copy a screenshot. Video plays in the chat without a separate mirror window."],
      ["Operate", "Explicitly enable control, then click to tap or drag to swipe. Nothing is sent to the phone until you turn it on."],
      ["Annotate", "Freeze the frame and draw up to eight numbered boxes, then send the marked image and your note with Command-Enter. Drawing never taps the phone."],
      ["Let the agent act", "The agent works in an observe → act → observe loop with local OCR, element IDs and targeted taps, and checks the result on the device."],
    ],
    privacyTitle: "Video stays on this Mac",
    privacy:
      "Hardware H.264 travels over encrypted local WebRTC, with no cloud relay or STUN/TURN service. Screenshots your agent requests and annotations you send go to your AI client and follow its data settings. Never paste the MCP connection file into a chat.",
    faqTitle: "Troubleshooting",
    faq: [
      ["Codex shows no StupidMirror tools", "Reconnect the plugin and select it in a new Codex chat. After updating the app, click Connect Codex (Update or reinstall plugin) again."],
      ["Initialization fails with -32603", "Older builds reject experimental client capabilities. Update to StupidMirror 0.3.1 or later and reconnect the plugin; restarting Codex does not fix it."],
      ["No device or no video", "Unlock the phone, check the cable and trust prompt or ADB authorization, and refresh. USB iPhone video needs Camera permission; wireless video needs the iPhone setup guide."],
      ["Taps do nothing", "Wait for control setup, check Developer Mode and the signed runner on the iPhone, then enable Operate again. Viewing and control are ready independently."],
      ["Annotations cannot be sent", "The host has to support image messages. If the panel reports an unavailable composer, open the chat, ask Codex to call show_screen again and continue in the new panel. Your draft is kept."],
    ],
    more: "Full guide on GitHub",
  },
  zh: {
    lang: "zh-CN",
    locale: "zh_CN",
    path: "zh/codex/",
    up: "../../",
    home: "zh/",
    title: "在 Codex 里查看并操作 iPhone / Android｜StupidMirror",
    description:
      "用 StupidMirror 的 Codex 插件，在 Codex 聊天里看到真实 iPhone 或 Android 的实时画面，让 Agent 通过 MCP 点击和输入，并发送带标注的截图。",
    eyebrow: "CODEX 插件",
    h1: "把真实手机放进 Codex 聊天里。",
    lead: "StupidMirror 内置 Codex 插件。Agent 能看到真实 iPhone 或 Android 的实时画面，通过 MCP 操作它；你可以用标注直接指出想说的位置。",
    homeLabel: "StupidMirror",
    guideLabel: "Codex 插件",
    download: "下载 StupidMirror",
    connectTitle: "四步连接",
    connectIntro: "使用已安装的应用时，不需要克隆仓库、安装 Python / Node.js 或复制令牌。",
    steps: [
      ["安装应用并连接手机", "将 StupidMirror 放入「应用程序」并打开，连接并解锁手机。USB 画面需要信任这台 Mac 并授予摄像头权限；Android 需要授权 ADB。"],
      ["完成一次 iPhone 设置", "首次控制 iPhone 或使用无线画面前，先用 USB 完成「设置这台 iPhone」。"],
      ["点击「连接 Codex」", "在「设置 → MCP 自动化」点击「连接 Codex」。应用会开启本机 MCP，并通过 Codex 桌面应用的 CLI 安装内置插件。"],
      ["向 Codex 提问", "新建 Codex 聊天，选中 StupidMirror，发送：「在 Codex 里显示我的手机，先不要点击。」面板会通过 show_screen 打开。"],
    ],
    useTitle: "查看、操作、标注",
    uses: [
      ["查看", "选择设备，暂停或继续、刷新、回到主屏幕、复制截图。画面直接显示在聊天里，不会另开镜像窗口。"],
      ["操作", "手动开启「操作」后，单击即点击、拖动即滑动。开启之前不会向手机发送任何操作。"],
      ["标注", "冻结当前画面，最多画八个编号框，用 ⌘＋回车把标注截图和说明一起发送。画框不会误触手机。"],
      ["让 Agent 动手", "Agent 按「观察 → 操作 → 观察」的循环工作，用本地 OCR、元素 ID 和定点点击完成任务，并在真机上确认结果。"],
    ],
    privacyTitle: "画面只在这台 Mac 上传输",
    privacy:
      "硬件 H.264 画面通过加密的本地 WebRTC 传输，没有云端中转，也不使用 STUN/TURN。Agent 请求的截图和你主动发送的标注会交给 AI 客户端，受该客户端的数据设置约束。不要把 MCP 连接凭据文件发到聊天里。",
    faqTitle: "常见问题排查",
    faq: [
      ["Codex 里没有 StupidMirror 的工具", "重新连接插件，并在新的 Codex 聊天中选中它。更新应用后，需要再点一次「连接 Codex」（更新或重新安装插件）。"],
      ["初始化报错 -32603", "旧版本不兼容实验性的客户端能力。升级到 StupidMirror 0.3.1 或更新版本后重新连接插件；重启 Codex 解决不了这个问题。"],
      ["找不到设备或没有画面", "解锁手机，检查数据线和信任提示或 ADB 授权，然后刷新。USB 连接的 iPhone 需要摄像头权限；无线画面需要先完成 iPhone 设置向导。"],
      ["点击没有反应", "等待控制连接完成，确认 iPhone 已开启开发者模式并安装了签名的运行组件，然后重新开启「操作」。查看和控制是分别就绪的。"],
      ["标注发不出去", "宿主需要支持图片消息。如果面板提示输入框不可用，打开对应聊天，让 Codex 再调用一次 show_screen，在新面板中继续。草稿会保留。"],
    ],
    more: "在 GitHub 查看完整指南",
  },
};

const esc = (value) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function render(key) {
  const p = pages[key];
  const url = base + p.path;
  const homeURL = base + p.home;
  const data = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "TechArticle",
        "@id": `${url}#article`,
        headline: p.h1,
        description: p.description,
        inLanguage: p.lang,
        url,
        image: `${base}assets/og-image.jpg`,
        about: { "@id": `${base}#software` },
        isPartOf: { "@id": `${base}#website` },
        publisher: { "@id": `${base}#organization` },
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: [
          { "@type": "ListItem", position: 1, name: p.homeLabel, item: homeURL },
          { "@type": "ListItem", position: 2, name: p.guideLabel, item: url },
        ],
      },
      {
        "@type": "FAQPage",
        "@id": `${url}#faq`,
        inLanguage: p.lang,
        mainEntity: p.faq.map(([q, a]) => ({ "@type": "Question", name: q, acceptedAnswer: { "@type": "Answer", text: a } })),
      },
    ],
  };
  const json = JSON.stringify(data, null, 2).replace(/</g, "\\u003c").replace(/\n/g, "\n      ");
  const card = ([title, body], i) =>
    `          <article class="card step"><span class="step-number">${String(i + 1).padStart(2, "0")}</span><h3>${esc(title)}</h3><p>${esc(body)}</p></article>`;
  const faq = p.faq
    .map(([q, a]) => `          <details class="faq-item">\n            <summary><h3>${esc(q)}</h3></summary>\n            <p>${esc(a)}</p>\n          </details>`)
    .join("\n");
  return `<!doctype html>
<html lang="${p.lang}">
  <head>
    <meta charset="UTF-8" />
    ${redirect}
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${esc(p.title)}</title>
    <meta name="description" content="${esc(p.description)}" />
    <meta name="robots" content="index, follow, max-image-preview:large" />
    <meta name="theme-color" content="#08090a" />
    <meta name="color-scheme" content="dark" />
    <link rel="canonical" href="${url}" />
    <link rel="alternate" hreflang="en" href="${base}${pages.en.path}" />
    <link rel="alternate" hreflang="zh-CN" href="${base}${pages.zh.path}" />
    <link rel="alternate" hreflang="x-default" href="${base}${pages.en.path}" />
    <meta property="og:type" content="article" />
    <meta property="og:site_name" content="StupidMirror" />
    <meta property="og:url" content="${url}" />
    <meta property="og:title" content="${esc(p.title)}" />
    <meta property="og:description" content="${esc(p.description)}" />
    <meta property="og:image" content="${base}assets/og-image.jpg" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:locale" content="${p.locale}" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${esc(p.title)}" />
    <meta name="twitter:description" content="${esc(p.description)}" />
    <meta name="twitter:image" content="${base}assets/og-image.jpg" />
    <link rel="icon" type="image/png" sizes="128x128" href="${p.up}assets/favicon.png" />
    <link rel="apple-touch-icon" sizes="180x180" href="${p.up}assets/apple-touch-icon.png" />
    <link rel="stylesheet" href="${p.up}styles.css?v=20261024-guide" />
    <script type="application/ld+json">
      ${json}
    </script>
  </head>
  <body>
    <header class="site-header">
      <nav class="nav-shell" aria-label="${key === "zh" ? "主导航" : "Primary navigation"}">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="28" height="28" /><span>StupidMirror</span></a>
        <div class="nav-actions">
          <a class="nav-link" href="${p.up}${key === "zh" ? pages.en.path : pages.zh.path}" hreflang="${key === "zh" ? "en" : "zh-CN"}" lang="${key === "zh" ? "en" : "zh-CN"}">${key === "zh" ? "English" : "中文"}</a>
          <a class="button button-primary button-small" href="${download}" target="_blank" rel="noreferrer">${esc(p.download)}</a>
        </div>
      </nav>
    </header>
    <main>
      <section class="section-shell guide-hero">
        <nav class="guide-breadcrumb" aria-label="Breadcrumb"><a href="${p.up}${p.home}">${esc(p.homeLabel)}</a><span aria-hidden="true">/</span><span aria-current="page">${esc(p.guideLabel)}</span></nav>
        <p class="section-index">${esc(p.eyebrow)}</p>
        <h1>${esc(p.h1)}</h1>
        <p class="guide-lead">${esc(p.lead)}</p>
        <figure class="guide-shot"><img src="${p.up}assets/site-mcp.webp" alt="${esc(p.guideLabel)}" width="1441" height="1321" loading="lazy" decoding="async" /></figure>
      </section>
      <section class="section-shell guide-section">
        <h2>${esc(p.connectTitle)}</h2>
        <p class="guide-note">${esc(p.connectIntro)}</p>
        <div class="step-grid guide-grid">
${p.steps.map(card).join("\n")}
        </div>
      </section>
      <section class="section-shell guide-section">
        <h2>${esc(p.useTitle)}</h2>
        <div class="step-grid guide-grid">
${p.uses.map(card).join("\n")}
        </div>
      </section>
      <section class="section-shell guide-section">
        <h2>${esc(p.privacyTitle)}</h2>
        <p class="guide-note">${esc(p.privacy)}</p>
      </section>
      <section class="section-shell guide-section" id="faq">
        <h2>${esc(p.faqTitle)}</h2>
        <div class="faq-list">
${faq}
        </div>
        <p class="guide-note"><a class="text-link" href="${guideSource}">${esc(p.more)}</a></p>
      </section>
    </main>
    <footer class="site-footer">
      <div class="section-shell footer-inner">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="22" height="22" loading="lazy" /><span>StupidMirror</span></a>
        <span>© 2026 StupidMirror</span>
      </div>
    </footer>
  </body>
</html>
`;
}

let stale = false;
for (const key of Object.keys(pages)) {
  const out = join(root, "docs", pages[key].path, "index.html");
  const html = render(key);
  if (process.argv.includes("--check")) {
    let current = "";
    try {
      current = readFileSync(out, "utf8");
    } catch {}
    if (current !== html) {
      console.error(`${out} is out of date: run node scripts/build-site-guides.mjs`);
      stale = true;
    }
  } else {
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, html);
    console.log(`wrote ${out}`);
  }
}
if (stale) process.exit(1);
