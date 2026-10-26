#!/usr/bin/env node
// Builds the guide pages (docs/codex/, docs/mcp/ and their docs/zh/ copies) from
// the copy below, which follows docs/codex-plugin.md and the README. Both languages come from one
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

const codex = {
  en: {
    lang: "en",
    locale: "en_US",
    path: "codex/",
    image: { src: "site-dashboard.webp", width: 2200, height: 1400, alt: "The StupidMirror dashboard mirroring an iPhone" },
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
      ["Install and connect the phone", "Move StupidMirror to Applications and open it. Connect, unlock and trust the phone; Android needs authorized ADB."],
      ["Run iPhone setup once", "Both USB and Wi-Fi iPhone video need the signed screen agent prepared through Set Up This iPhone over USB. Video needs no Camera permission. System touch on iOS 27+ needs Xcode, trust and Developer Mode."],
      ["Click Connect Codex", "In Settings → MCP Automation, click Connect Codex. The app enables local MCP and installs its bundled plugin through the Codex desktop app's CLI."],
      ["Ask Codex", "Open a new Codex chat, select StupidMirror and ask: “Show my phone inside Codex without tapping anything.” The panel opens through show_screen."],
    ],
    useTitle: "View, operate, annotate",
    uses: [
      ["View", "Choose a device; pause and resume, refresh, return Home or copy a screenshot. Video plays in the chat without a separate mirror window."],
      ["Operate", "Enable Operate to send single-finger presses, holds and drags through the same backend as the native mirror. Hold the left mouse button for a long press; right-click does not send one. Compatibility control remains available."],
      ["Trackpad input", "Native mirror scrolling, pinch and rotation stream through the system gesture service when available, with phases and scroll momentum. The browser panel can only forward fallback scroll increments from DOM wheel events. On iOS, programmatic pinch or rotate requests keep their specified center through WDA."],
      ["USB audio", "Choose Phone to keep sound on the iPhone, or Mac to play it here. Mac audio needs Camera and Microphone permissions for the USB audio source; video itself needs neither."],
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
      ["No device or no video", "Unlock the phone, check the cable and trust prompt or ADB authorization, and refresh. Both USB and Wi-Fi iPhone video need the signed screen agent prepared by the setup guide; video needs no Camera permission."],
      ["Taps do nothing", "Wait for control setup. Check Xcode, trust and Developer Mode for system touch, or the signed runner for compatibility control, then enable Operate again. Viewing and control are ready independently."],
      ["Annotations cannot be sent", "The host has to support image messages. If the panel reports an unavailable composer, open the chat, ask Codex to call show_screen again and continue in the new panel. Your draft is kept."],
    ],
    more: "Full guide on GitHub",
  },
  zh: {
    lang: "zh-CN",
    locale: "zh_CN",
    path: "zh/codex/",
    image: { src: "site-dashboard.webp", width: 2200, height: 1400, alt: "StupidMirror 主界面正在镜像一台 iPhone" },
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
      ["安装应用并连接手机", "将 StupidMirror 放入「应用程序」并打开，连接、解锁手机并信任这台 Mac；Android 需要授权 ADB。"],
      ["完成一次 iPhone 设置", "USB 和 Wi-Fi 的 iPhone 画面都需要先通过 USB「设置这台 iPhone」准备签名的屏幕组件，视频不需要摄像头权限。iOS 27 及以上版本的系统触控需要 Xcode、信任配对和开发者模式。"],
      ["点击「连接 Codex」", "在「设置 → MCP 自动化」点击「连接 Codex」。应用会开启本机 MCP，并通过 Codex 桌面应用的 CLI 安装内置插件。"],
      ["向 Codex 提问", "新建 Codex 聊天，选中 StupidMirror，发送：「在 Codex 里显示我的手机，先不要点击。」面板会通过 show_screen 打开。"],
    ],
    useTitle: "查看、操作、标注",
    uses: [
      ["查看", "选择设备，暂停或继续、刷新、回到主屏幕、复制截图。画面直接显示在聊天里，不会另开镜像窗口。"],
      ["操作", "开启「操作」后，单指按下、长按与拖动会使用原生镜像的同一触控后端。长按需按住鼠标左键，右键不再映射为长按；兼容控制仍然保留。"],
      ["触控板输入", "系统手势服务可用时，原生镜像的滚动、缩放和旋转会逐事件发送，并保留手势相位与滚动惯性。浏览器面板只能从 DOM 滚轮事件发送降级滚动增量；iOS 上程序化指定中心点的缩放与旋转仍通过 WDA 保留目标位置。"],
      ["USB 声音", "选择「手机」让声音留在 iPhone 上，或选择「Mac」在电脑播放。Mac 声音需要摄像头和麦克风权限来访问 USB 音频源，视频本身不需要这两项权限。"],
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
      ["找不到设备或没有画面", "解锁手机，检查数据线和信任提示或 ADB 授权，然后刷新。USB 和 Wi-Fi 的 iPhone 画面都需要通过设置向导准备签名的屏幕组件；视频不需要摄像头权限。"],
      ["点击没有反应", "等待控制连接完成。系统触控需检查 Xcode、信任配对和开发者模式；兼容控制需检查签名的运行组件，然后重新开启「操作」。查看和控制是分别就绪的。"],
      ["标注发不出去", "宿主需要支持图片消息。如果面板提示输入框不可用，打开对应聊天，让 Codex 再调用一次 show_screen，在新面板中继续。草稿会保留。"],
    ],
    more: "在 GitHub 查看完整指南",
  },
};

const mcp = {
  en: {
    lang: "en",
    locale: "en_US",
    path: "mcp/",
    up: "../",
    home: "",
    image: { src: "site-mcp.webp", width: 1441, height: 1321, alt: "The built-in StupidMirror MCP server settings" },
    title: "iPhone & Android MCP server for Claude Code | StupidMirror",
    description:
      "StupidMirror runs a localhost MCP server on your Mac, so Claude Code, Codex or any MCP client can observe, tap, type and verify on a real iPhone or Android device.",
    eyebrow: "MCP SERVER",
    h1: "Give Claude Code a real iPhone or Android.",
    lead: "StupidMirror exposes connected devices through an authenticated MCP server on this Mac. It embeds no model and needs no model API key: it hands the device to the agent you already use.",
    homeLabel: "StupidMirror",
    guideLabel: "MCP setup",
    download: "Download StupidMirror",
    connectTitle: "Connect an MCP client",
    connectIntro: "In Settings → MCP Automation, Connect Codex and Connect Claude Code each install their plugin and MCP tools in one click; parts already in place are skipped. Other MCP clients use the generated configuration.",
    steps: [
      ["Turn on the MCP server", "Open Settings → MCP and enable the local MCP server. It listens only on http://127.0.0.1:<port>/mcp."],
      ["Pick your client", "Click Connect Claude Code (or Connect Codex) for one-click setup. For another MCP client, open Advanced connection settings · Other AI clients."],
      ["Start a new session", "Open a new Claude Code session in the terminal or the Claude desktop app's Code tab. Ask for the live viewer to watch the phone: open_viewer returns a local link that opens in the desktop Browser pane. Manual clients instead copy the generated configuration, which includes the endpoint, bearer authentication and a 240-second tool timeout."],
      ["Ask the agent", "Keep StupidMirror open and try: “List my connected devices, start mirroring my iPhone, and highlight the visible clickable elements without tapping them.”"],
    ],
    useTitle: "Observe, act, verify",
    uses: [
      ["Connect", "list_devices, show_screen and connect_control discover the target and prepare the sessions it needs."],
      ["Observe", "observe_screen and find_any_element read a live frame with local OCR, and request accessibility only when needed."],
      ["Act", "tap_text, tap_element, replace_text and swipe target observed content or an explicit gesture."],
      ["Verify", "wait_for, assert_screen and observe_screen check the resulting state on the device."],
      ["Guide without touching", "highlight_clickable_elements and highlight_elements draw targets on the Mac mirror without sending input."],
      ["Apps and recordings", "install_app installs an .app, .ipa or .apk build; open_url opens deep links; start_recording saves the mirror as an .mp4 of up to 10 minutes."],
    ],
    privacyTitle: "Local server, your AI client's rules",
    privacy:
      "Capture, playback and OCR run on this Mac, and StupidMirror does not upload mirrored content to a model provider on its own. An AI client connected over MCP receives the screenshots and tool results it asks for, and its own data settings apply. Rotating the bearer token invalidates the previous credential.",
    faqTitle: "Questions from agent authors",
    faq: [
      ["Does StupidMirror need a model API key?", "No. It embeds no model. Your MCP client brings the model; StupidMirror provides the device tools."],
      ["Which clients work?", "Codex and Claude Code through one-click setup that installs their plugin and MCP tools, and other MCP clients through the generated configuration with bearer authentication."],
      ["Why is the first action slow?", "First-time control setup can take a while, so the generated configuration sets a 240-second tool timeout."],
      ["How do I target one of several devices?", "Pass device_id. Call list_devices first to see the identifiers."],
      ["How should an agent edit iOS text fields?", "After focusing a field, use replace_text or clear_text directly, and type_text to append. Accessibility snapshots can disturb a focused field, and replacement verifies the resulting value."],
      ["Which languages does OCR read?", "Apple Vision OCR defaults to Chinese and English, offers fast and accurate modes, and runs on demand outside the capture path."],
    ],
    more: "Tool reference on GitHub",
    source: "https://github.com/LiuTianjie/StupidMirror#observe--act--verify",
  },
  zh: {
    lang: "zh-CN",
    locale: "zh_CN",
    path: "zh/mcp/",
    up: "../../",
    home: "zh/",
    image: { src: "site-mcp.webp", width: 1441, height: 1321, alt: "StupidMirror 内置 MCP Server 设置界面" },
    title: "让 Claude Code 操作 iPhone / 安卓真机的 MCP｜StupidMirror",
    description:
      "StupidMirror 在 Mac 上提供只监听本机的 MCP Server，Claude Code、Codex 等 MCP 客户端可以直接观察、点击、输入并验证真实 iPhone 或安卓手机。",
    eyebrow: "MCP SERVER",
    h1: "把真实 iPhone / 安卓交给 Claude Code。",
    lead: "StupidMirror 通过一个带认证、只监听本机的 MCP Server 提供已连接的设备。它不内置模型，也不需要模型 API Key，只是把真机交给你正在用的 Agent。",
    homeLabel: "StupidMirror",
    guideLabel: "MCP 配置",
    download: "下载 StupidMirror",
    connectTitle: "接入 MCP 客户端",
    connectIntro: "在「设置 → MCP 自动化」中，「接入 Codex」和「接入 Claude Code」都会一键安装插件和 MCP 工具，已装好的部分会跳过。其他 MCP 客户端使用自动生成的配置。",
    steps: [
      ["开启 MCP Server", "打开「设置 → MCP」，开启本机 MCP Server。它只监听 http://127.0.0.1:<port>/mcp。"],
      ["选择客户端", "点击「接入 Claude Code」（或「接入 Codex」）一键接入。其他 MCP 客户端请展开「高级连接设置 · 其他 AI 客户端」。"],
      ["新开会话", "在终端或 Claude 桌面版的 Code 标签里新开一个 Claude Code 会话。想看手机画面时让它打开实时画面：open_viewer 会返回一个本机链接，可在桌面版的浏览器面板中打开。手动接入的客户端则复制生成的配置，其中包含地址、Bearer 认证和 240 秒的工具超时。"],
      ["向 Agent 提问", "保持 StupidMirror 打开，试试：「列出已连接的设备，开始镜像我的 iPhone，并标出可点击元素，先不要点击。」"],
    ],
    useTitle: "观察、操作、验证",
    uses: [
      ["连接", "list_devices、show_screen、connect_control 负责找到目标设备并准备所需的会话。"],
      ["观察", "observe_screen、find_any_element 读取实时画面并做本地 OCR，只在需要时才获取无障碍信息。"],
      ["操作", "tap_text、tap_element、replace_text、swipe 针对已观察到的内容或明确的手势执行操作。"],
      ["验证", "wait_for、assert_screen、observe_screen 在真机上检查操作结果。"],
      ["只标注不点击", "highlight_clickable_elements、highlight_elements 在 Mac 镜像上画出目标，不向手机发送任何操作。"],
      ["应用与录屏", "install_app 安装 .app、.ipa 或 .apk；open_url 打开深链；start_recording 把镜像录成最长 10 分钟的 .mp4。"],
    ],
    privacyTitle: "本机服务，数据规则由 AI 客户端决定",
    privacy:
      "采集、播放和 OCR 都在这台 Mac 上完成，StupidMirror 不会自行把镜像内容上传给模型服务商。通过 MCP 接入的 AI 客户端会收到它请求的截图和工具结果，之后如何处理取决于该客户端的数据设置。轮换 Bearer 令牌会让旧凭据失效。",
    faqTitle: "Agent 开发者常见问题",
    faq: [
      ["需要模型 API Key 吗？", "不需要。StupidMirror 不内置模型，模型由你的 MCP 客户端提供，StupidMirror 只提供设备工具。"],
      ["支持哪些客户端？", "Codex 和 Claude Code 一键接入，同时安装插件和 MCP 工具；其他 MCP 客户端通过生成的配置（含 Bearer 认证）接入。"],
      ["为什么第一次操作比较慢？", "首次建立控制连接需要一些时间，所以生成的配置把工具超时设为 240 秒。"],
      ["连了多台设备怎么指定？", "传入 device_id。先调用 list_devices 查看设备标识。"],
      ["Agent 怎么修改 iOS 输入框？", "聚焦输入框后，直接用 replace_text 或 clear_text，追加内容用 type_text。获取无障碍快照可能打断已聚焦的输入框，替换操作会校验最终的值。"],
      ["OCR 支持哪些语言？", "Apple Vision OCR 默认识别中文和英文，提供快速与精确两种模式，按需运行，不占用采集链路。"],
    ],
    more: "在 GitHub 查看工具说明",
    source: "https://github.com/LiuTianjie/StupidMirror/blob/main/README.zh-CN.md",
  },
};

const guides = [codex, mcp];

const esc = (value) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function render(pages, key) {
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
    <link rel="icon" href="/favicon.ico" sizes="48x48" />
    <link rel="manifest" href="/site.webmanifest" />
    <link rel="stylesheet" href="${p.up}styles.css?v=20261026-changelog" />
    <script type="application/ld+json">
      ${json}
    </script>
  </head>
  <body>
    <header class="site-header">
      <nav class="nav-shell" aria-label="${key === "zh" ? "主导航" : "Primary navigation"}">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="28" height="28" /><span>StupidMirror</span></a>
        <div class="nav-actions">
          <a class="nav-link" href="${p.up}${p.home}changelog/">${key === "zh" ? "更新日志" : "Changelog"}</a>
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
        <figure class="guide-shot"><img src="${p.up}assets/${p.image.src}" alt="${esc(p.image.alt)}" width="${p.image.width}" height="${p.image.height}" loading="lazy" decoding="async" /></figure>
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
        <p class="guide-note"><a class="text-link" href="${p.source ?? guideSource}">${esc(p.more)}</a></p>
      </section>
    </main>
    <footer class="site-footer">
      <div class="section-shell footer-inner">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="22" height="22" loading="lazy" /><span>StupidMirror</span></a>
        <nav class="guide-footer-nav" aria-label="${key === "zh" ? "指南" : "Guides"}">${guides.map((g) => `<a href="${p.up}${g[key].path}">${esc(g[key].guideLabel)}</a>`).join("")}<a href="${p.up}${p.home}changelog/">${key === "zh" ? "更新日志" : "Changelog"}</a></nav>
        <span>© 2026 StupidMirror</span>
      </div>
    </footer>
  </body>
</html>
`;
}

let stale = false;
for (const pages of guides) for (const key of Object.keys(pages)) {
  const out = join(root, "docs", pages[key].path, "index.html");
  const html = render(pages, key);
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
