const header = document.querySelector("[data-header]");
const menuToggle = document.querySelector("[data-menu-toggle]");
const menu = document.querySelector("[data-menu]");
const lightbox = document.querySelector("[data-lightbox-dialog]");
const lightboxImage = document.querySelector("[data-lightbox-image]");
const lightboxClose = document.querySelector("[data-lightbox-close]");

const chineseText = new Map([
  ["Skip to content", "跳到正文"],
  ["Open navigation", "打开导航"],
  ["Mirror", "镜像"],
  ["Wireless", "无线"],
  ["AI harness", "AI 自动化"],
  ["Use cases", "使用场景"],
  ["Download latest", "下载最新版"],
  ["Put your iPhone on your Mac.", "把 iPhone 接上 Mac。"],
  ["Leave the rest to", "剩下的交给"],
  ["StupidMirror.", "StupidMirror。"],
  ["Mirror a real iPhone over USB or Wi-Fi. Then let local OCR, Accessibility, and MCP make it operable by you and your AI agent.", "USB 或无线，把真实 iPhone 放到 Mac 上。再通过本地 OCR、访问树与 MCP，把它交给你和 AI 一起操作。"],
  ["Download for macOS", "下载 macOS 版"],
  ["Buy activation code", "购买激活码"],
  ["View source", "GitHub 源码"],
  ["It is a mirror,", "它是一面镜子，"],
  ["and a device operations console.", "也是一套设备操作台。"],
  ["Mirroring, control, and automation no longer live in separate tools. Discovery, live video, independent windows, and AI actions all happen in one native Mac app.", "镜像、控制和自动化不再是三套割裂的工具。设备发现、实时画面、独立窗口与 AI 操作，都在一个原生 macOS 应用里完成。"],
  ["Open the camera. The mirror stays live.", "开启相机，镜像仍然保持。"],
  ["A mirror built to stay live", "真正稳定的镜像体验"],
  ["No lock screen.", "不用锁屏。"],
  ["No context switching.", "不用来回切换。"],
  ["StupidMirror uses the iPhone screen source exposed directly by macOS. Even while the iPhone camera is active, the dashboard and standalone mirror keep rendering.", "StupidMirror 直接使用 macOS 暴露的 iPhone 屏幕源。即使 iPhone 正在使用摄像头，Mac 上的主窗口与独立镜像窗口也能继续显示。"],
  ["Plug in over USB", "USB 即连即用"],
  ["Connect, trust the Mac, and the device appears.", "连接并信任 Mac，设备自动发现。"],
  ["Standalone mirror", "独立镜像窗口"],
  ["True device proportions for debugging, capture, and demos.", "按真实设备比例展示，适合调试、录屏与演示。"],
  ["Multiple iPhones", "多台 iPhone"],
  ["Sign in with Google, GitHub, or email, buy an SM- code on 链动小铺, then redeem it onto your account.", "用 Google、GitHub 或邮箱登录，在链动小铺购买 SM- 激活码，再兑换到该账号。"],
  ["Native speed", "原生速度"],
  ["Swift, AVFoundation, and CoreMediaIO — without a heavyweight browser shell.", "Swift + AVFoundation / CoreMediaIO，不套一层笨重的浏览器壳。"],
  ["Wireless freedom", "无线自由"],
  ["Prepare once over USB, then discover and mirror on the same local network.", "一次 USB 准备，之后在同一局域网内主动发现并镜像。"],
  ["Local recognition", "本地识别"],
  ["macOS Vision OCR and iOS Accessibility replace visual guesswork with real targets.", "macOS Vision OCR 与 iOS 访问树协同，减少视觉模型盲猜。"],
  ["MCP control", "MCP 控制"],
  ["Tap, swipe, long-press, type, and clear on iPhone or Android 11+ from an agent workflow.", "在 iPhone 或 Android 11+ 上执行点击、滑动、长按、输入与清空，直接进入 Agent 工作流。"],
  ["ALSO ON ANDROID", "同时支持 ANDROID"],
  ["Android 11+ is supported, too.", "也支持 Android 11+。"],
  ["Connect with USB debugging and use the same StupidMirror workspace for live mirroring, device audio, direct control, and MCP automation.", "开启 USB 调试后，即可在同一个 StupidMirror 工作台中使用实时镜像、设备音频、直接控制和 MCP 自动化。"],
  ["discovery", "设备发现"],
  ["+ audio", "+ 音频"],
  ["control", "控制"],
  ["tools", "工具"],
  ["Start with one cable.", "一根线起步，"],
  ["Keep going wirelessly.", "之后无线继续。"],
  ["The built-in guide checks the device, your Apple development account, and the screen agent. After one USB setup, disconnect the cable and keep a full-resolution H.264 mirror over your LAN.", "内置向导会检查设备、Apple 开发账号与画面代理。完成一次准备后，断开 USB，仍可通过局域网获得全分辨率 H.264 镜像。"],
  ["Prepare once over USB", "首次通过 USB 准备一次"],
  ["Same-network mirror", "同网发现与镜像"],
  ["Complete access units", "完整访问单元传输"],
  ["VideoToolbox codec", "VideoToolbox 编解码"],
  ["Mirroring and control stay separate. Viewing a screen never installs or starts the control path behind your back.", "镜像与控制保持独立：只想查看画面时，不会擅自安装或启动控制流程。"],
  ["MCP configuration included", "MCP 配置已内置"],
  ["AI is not a spectator.", "AI 不是旁观者。"],
  ["It can operate the iPhone.", "它真的可以操作 iPhone。"],
  ["StupidMirror includes an MCP server bound to localhost. It embeds no model and asks for no model API key — it hands the real device to the Codex or Claude Code setup you already use.", "StupidMirror 内置只监听本机的 MCP Server。不内置模型，不要求额外填写模型 API Key，把真机能力直接交给你已在使用的 Codex 或 Claude Code。"],
  ["Understand, then act", "先看懂，再操作"],
  ["The latest frame, local Vision OCR, and iOS Accessibility converge on the real target.", "最新镜像帧、本地 Vision OCR 与 iOS 访问树共同定位真实目标。"],
  ["Every action is visible", "每一步都可见"],
  ["Targets, taps, and swipe paths appear only on the Mac, ready for review or takeover.", "目标框、点击位置和滑动轨迹只显示在 Mac 侧，方便随时确认与接管。"],
  ["Built for real interfaces", "复杂界面也能找"],
  ["System Settings, the App Store, dense feeds, and custom canvases all yield semantic targets.", "系统设置、App Store、内容流与自定义业务页面都能获得语义化目标。"],
  ["Not a demo page.", "不是 Demo 页，"],
  ["Real-world apps.", "是真实世界的 App。"],
  ["Drag through the captures. Open any screen to inspect the recognized targets.", "拖动浏览截图，点击任意画面可放大查看识别细节。"],
  ["Local services / dense information", "本地生活 / 密集信息"],
  ["System Settings / native controls", "系统设置 / 原生控件"],
  ["App Store / layered cards", "App Store / 多层卡片"],
  ["Business apps / custom canvas", "业务应用 / 自定义画布"],
  ["Recognition stays local.", "识别在本地。"],
  ["Control stays with you.", "控制权也在你手里。"],
  ["OCR runs on demand on your Mac. Action overlays never go back to the iPhone or into the video stream. StupidMirror embeds no model, needs no model API key, and never uploads the screen to a model service on its own.", "OCR 在 Mac 本地按需运行。操作标记不写回 iPhone，也不烧录进视频流。StupidMirror 自身不内置模型、不要求模型 API Key，更不会主动把屏幕上传给模型服务。"],
  ["One Mac.", "一台 Mac，"],
  ["Three new ways to work.", "三种新工作方式。"],
  ["Development & testing", "开发与测试"],
  ["Debug real hardware, reproduce issues, and rerun flows without bouncing between iPhone and Mac.", "真机调试、问题复现、流程回归，不再在 iPhone 与 Mac 之间反复切换。"],
  ["Live device video", "真实设备画面"],
  ["Visible action trails", "可见操作轨迹"],
  ["Fast WDA reconnects", "快速重连 WDA"],
  ["AI automation", "AI 自动化"],
  ["Hand a real device to Codex or Claude Code through MCP for observable, verifiable workflows.", "通过 MCP 把真机交给 Codex 或 Claude Code，执行可观察、可验证的操作链路。"],
  ["Semantic targeting", "语义化定位"],
  ["Local OCR", "本地 OCR"],
  ["Taps and text input", "点击与文本输入"],
  ["Demos & multiple devices", "演示与多设备"],
  ["Standalone mirrors fit recording, streaming, and demos; an account-bound SM- license unlocks parallel iPhone workflows.", "独立镜像窗口适合录屏、直播与演示；绑定到账号的 SM- 许可可并行管理多台 iPhone。"],
  ["Device-ratio windows", "设备比例窗口"],
  ["Parallel devices", "多设备并行"],
  ["English and Chinese UI", "中英文界面"],
  ["Now put a real iPhone", "现在，把真实 iPhone"],
  ["into your workflow.", "接入你的工作流。"],
  ["macOS 15+ · Free for personal and noncommercial use · Commercial license required", "macOS 15+ · 个人及非商业用途免费 · 商业使用需另行授权"],
  ["Download latest release", "下载最新公开版"],
  ["View on GitHub", "在 GitHub 查看"],
  ["Native iPhone mirroring & automation harness for macOS.", "原生 macOS iPhone 镜像与自动化工具。"],
]);

const chineseAttributes = new Map([
  ["StupidMirror home", "StupidMirror 首页"],
  ["Primary navigation", "主导航"],
  ["Product information", "产品信息"],
  ["Enlarge the StupidMirror dashboard", "放大查看 StupidMirror 主界面"],
  ["The StupidMirror dashboard mirroring an iPhone", "StupidMirror 主界面正在镜像一台 iPhone"],
  ["Enlarge the camera mirroring screenshot", "放大查看相机镜像截图"],
  ["StupidMirror keeps both mirror windows live while the iPhone camera is open", "iPhone 打开相机时，StupidMirror 主窗口与独立镜像窗口仍在同步显示"],
  ["Enlarge the wireless mirroring setup guide", "放大查看无线镜像设置向导"],
  ["The four-step StupidMirror wireless mirroring guide", "StupidMirror 无线镜像四步设置向导"],
  ["Enlarge the MCP configuration screen", "放大查看 MCP 配置界面"],
  ["The built-in StupidMirror MCP server configuration", "StupidMirror 内置 MCP Server 配置界面"],
  ["Supported automation actions", "支持的自动化动作"],
  ["Android compatibility", "Android 兼容性"],
  ["Android capabilities", "Android 支持能力"],
  ["Enlarge Home Screen element recognition", "放大查看主屏幕元素识别效果"],
  ["Numbered clickable regions on the iPhone Home Screen", "iPhone 主屏幕中的可点击区域被编号标注"],
  ["Enlarge feed element recognition", "放大查看信息流元素识别效果"],
  ["Recognized clickable regions in a dense content feed", "复杂信息流页面中的可点击区域被识别"],
  ["Enlarge short-video screen recognition", "放大查看短视频页面识别效果"],
  ["Numbered buttons and labels on a short-video screen", "短视频页面中的按钮和标签被编号标注"],
  ["Recognition captures from real apps", "真实应用识别截图"],
  ["Element recognition on a Meituan screen", "美团页面元素识别"],
  ["Element recognition in iOS Settings", "iOS 设置页面元素识别"],
  ["Element recognition in the App Store", "App Store 页面元素识别"],
  ["Element recognition in an education app", "教育应用页面元素识别"],
  ["Screenshot preview", "截图预览"],
  ["Close preview", "关闭预览"],
  ["Enlarged product screenshot", "放大的产品截图"],
]);

const normalizeText = (value) => value.replace(/\s+/g, " ").trim();

const localeMetadata = {
  en: {
    lang: "en",
    title: "StupidMirror | Native iPhone mirroring and automation for macOS",
    description:
      "StupidMirror is a native macOS iPhone mirroring and automation harness with USB and wireless video, local OCR, MCP control, and optional Android 11+ support.",
    ogTitle: "StupidMirror | Make a real iPhone observable and operable",
    ogDescription: "Bring a real iPhone to your Mac — and into Codex or Claude Code.",
    ogLocale: "en_US",
  },
  zh: {
    lang: "zh-CN",
    title: "StupidMirror｜让 iPhone 镜像可操作、可自动化",
    description:
      "StupidMirror 是一款原生 macOS iPhone 镜像与自动化工具，支持 USB / 无线镜像、本地 OCR、MCP 控制，并兼容 Android 11+。",
    ogTitle: "StupidMirror｜让 iPhone 镜像可操作、可自动化",
    ogDescription: "把真实 iPhone 接入 Mac，也接入 Codex 与 Claude Code。",
    ogLocale: "zh_CN",
  },
};

const localizableTextNodes = [];
const textWalker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
while (textWalker.nextNode()) {
  const node = textWalker.currentNode;
  const english = node.nodeValue || "";
  const translation = chineseText.get(normalizeText(english));
  if (!translation) continue;
  const leading = english.match(/^\s*/)?.[0] || "";
  const trailing = english.match(/\s*$/)?.[0] || "";
  localizableTextNodes.push({
    node,
    english,
    chinese: `${leading}${translation}${trailing}`,
  });
}

const localizableAttributes = [];
document.querySelectorAll("[aria-label], [alt]").forEach((element) => {
  ["aria-label", "alt"].forEach((attribute) => {
    const english = element.getAttribute(attribute);
    const chinese = english ? chineseAttributes.get(english) : null;
    if (english && chinese) localizableAttributes.push({ element, attribute, english, chinese });
  });
});

const languageSwitch = document.querySelector("[data-lang-switch]");
let currentLocale = "en";

const applyLocale = (locale, { updateHistory = false } = {}) => {
  const nextLocale = locale === "zh" ? "zh" : "en";
  const metadata = localeMetadata[nextLocale];
  const isChinese = nextLocale === "zh";

  document.documentElement.lang = metadata.lang;
  document.title = metadata.title;
  document
    .querySelector('meta[name="description"]')
    ?.setAttribute("content", metadata.description);
  document.querySelector('meta[property="og:title"]')?.setAttribute("content", metadata.ogTitle);
  document
    .querySelector('meta[property="og:description"]')
    ?.setAttribute("content", metadata.ogDescription);
  document.querySelector('meta[property="og:locale"]')?.setAttribute("content", metadata.ogLocale);

  localizableTextNodes.forEach(({ node, english, chinese }) => {
    node.nodeValue = isChinese ? chinese : english;
  });
  localizableAttributes.forEach(({ element, attribute, english, chinese }) => {
    element.setAttribute(attribute, isChinese ? chinese : english);
  });

  if (languageSwitch) {
    languageSwitch.textContent = isChinese ? "English" : "中文";
    languageSwitch.setAttribute("href", isChinese ? "./" : "?lang=zh");
  }

  currentLocale = nextLocale;
  if (updateHistory) {
    const url = new URL(window.location.href);
    if (isChinese) url.searchParams.set("lang", "zh");
    else url.searchParams.delete("lang");
    window.history.pushState({ locale: nextLocale }, "", url);
  }
  document.documentElement.classList.remove("locale-pending");
};

const requestedLocale = new URLSearchParams(window.location.search).get("lang");
applyLocale(requestedLocale === "zh" ? "zh" : "en");

languageSwitch?.addEventListener("click", (event) => {
  event.preventDefault();
  applyLocale(currentLocale === "zh" ? "en" : "zh", { updateHistory: true });
});

window.addEventListener("popstate", () => {
  const locale = new URLSearchParams(window.location.search).get("lang") === "zh" ? "zh" : "en";
  applyLocale(locale);
});

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const updateHeader = () => {
  header?.classList.toggle("scrolled", window.scrollY > 24);
};

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

menuToggle?.addEventListener("click", () => {
  const nextState = menuToggle.getAttribute("aria-expanded") !== "true";
  menuToggle.setAttribute("aria-expanded", String(nextState));
  menu?.classList.toggle("open", nextState);
  document.body.classList.toggle("menu-open", nextState);
});

menu?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    menuToggle?.setAttribute("aria-expanded", "false");
    menu.classList.remove("open");
    document.body.classList.remove("menu-open");
  });
});

const openLightbox = (source) => {
  if (!lightbox || !lightboxImage) return;
  lightboxImage.src = source;
  if (typeof lightbox.showModal === "function") {
    lightbox.showModal();
  }
};

document.querySelectorAll("[data-lightbox]").forEach((button) => {
  button.addEventListener("click", () => openLightbox(button.dataset.lightbox));
});

lightboxClose?.addEventListener("click", () => lightbox?.close());

lightbox?.addEventListener("click", (event) => {
  if (event.target === lightbox) lightbox.close();
});

lightbox?.addEventListener("close", () => {
  if (lightboxImage) lightboxImage.src = "";
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menu?.classList.contains("open")) {
    menuToggle?.setAttribute("aria-expanded", "false");
    menu.classList.remove("open");
    document.body.classList.remove("menu-open");
  }
});
