#!/usr/bin/env node
// Builds docs/zh/index.html from docs/index.html and scripts/site-zh.json.
// The Chinese page used to be the English page translated in the browser
// (?lang=zh), which search engines index as English. A static copy gives it
// its own URL, lang, title and description.
//
//   node scripts/build-site-zh.mjs           write docs/zh/index.html
//   node scripts/build-site-zh.mjs --check   fail if it is out of date
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = join(root, "docs/index.html");
const outputPath = join(root, "docs/zh/index.html");
const base = "https://stupidmirror.itool.tech/";
const zhURL = `${base}zh/`;

const meta = {
  title: "StupidMirror｜Mac 上的 iPhone 镜像与 AI 自动化工具",
  description:
    "在 Mac 上通过 USB 或 Wi-Fi 镜像并控制真实 iPhone 与 Android。本地 OCR、只监听本机的 MCP Server 与 Codex 插件，让 AI Agent 直接操作真机。",
  ogTitle: "StupidMirror｜让 iPhone 镜像可操作、可自动化",
  ogDescription: "把真实 iPhone 接入 Mac，也接入 Codex 与 Claude Code。",
  imageAlt: "StupidMirror macOS 主界面正在镜像一台已连接的 iPhone",
};

const maps = JSON.parse(readFileSync(join(root, "scripts/site-zh.json"), "utf8"));
const text = new Map(maps.text);
const attributes = new Map(maps.attributes);

const decode = (value) =>
  value.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
const encode = (value) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const normalize = (value) => value.replace(/\s+/g, " ").trim();

const replaceOnce = (html, pattern, replacement) => {
  let hits = 0;
  const result = html.replace(pattern, (...args) => {
    hits += 1;
    return typeof replacement === "function" ? replacement(...args) : replacement;
  });
  if (hits !== 1) throw new Error(`expected one match for ${pattern}, found ${hits}`);
  return result;
};

let html = readFileSync(sourcePath, "utf8");

// <head>
html = replaceOnce(html, /<html lang="en">/, '<html lang="zh-CN">');
html = replaceOnce(html, /<title>[^<]*<\/title>/, `<title>${encode(meta.title)}</title>`);
html = replaceOnce(html, /(name="description"\s+content=")[^"]*"/, (_, head) => `${head}${encode(meta.description)}"`);
html = replaceOnce(html, /<link rel="canonical" href="[^"]*" \/>/, `<link rel="canonical" href="${zhURL}" />`);
html = replaceOnce(html, /(property="og:url" content=")[^"]*"/, (_, head) => `${head}${zhURL}"`);
for (const name of ['property="og:title"', 'name="twitter:title"']) {
  html = replaceOnce(html, new RegExp(`(${name} content=")[^"]*"`), (_, head) => `${head}${encode(meta.ogTitle)}"`);
}
for (const name of ['property="og:description"', 'name="twitter:description"']) {
  html = replaceOnce(html, new RegExp(`(${name} content=")[^"]*"`), (_, head) => `${head}${encode(meta.ogDescription)}"`);
}
for (const name of ['property="og:image:alt"', 'name="twitter:image:alt"']) {
  html = replaceOnce(html, new RegExp(`(${name} content=")[^"]*"`), (_, head) => `${head}${encode(meta.imageAlt)}"`);
}
html = replaceOnce(html, /<meta property="og:locale" content="en_US" \/>/, '<meta property="og:locale" content="zh_CN" />');
html = replaceOnce(html, /<meta property="og:locale:alternate" content="zh_CN" \/>/, '<meta property="og:locale:alternate" content="en_US" />');
// The English page forwards old ?lang=zh links here; this page has nothing to forward.
html = replaceOnce(html, /\n\s*\/\/ Old links used \?lang=zh[^\n]*\n[^\n]*window\.location\.replace\([^\n]*\n/, "\n");

html = replaceOnce(html, /(<script type="application\/ld\+json">)([\s\S]*?)(<\/script>)/, (_, open, json, close) => {
  const data = JSON.parse(json);
  const page = data["@graph"].find((node) => node["@type"] === "WebPage");
  Object.assign(page, {
    "@id": `${zhURL}#webpage`,
    url: zhURL,
    name: meta.title,
    description: meta.description,
    inLanguage: "zh-CN",
  });
  // Structured FAQ must match the visible questions, which this page shows in Chinese.
  const faq = data["@graph"].find((node) => node["@type"] === "FAQPage");
  if (faq) {
    const zh = (english) => {
      const translation = text.get(normalize(english));
      if (!translation) throw new Error(`no Chinese text for FAQ entry: ${english}`);
      return translation;
    };
    faq["@id"] = `${zhURL}#faq`;
    faq.inLanguage = "zh-CN";
    for (const question of faq.mainEntity) {
      question.name = zh(question.name);
      question.acceptedAnswer.text = zh(question.acceptedAnswer.text);
    }
  }
  const body = JSON.stringify(data, null, 2).replace(/\n/g, "\n      ");
  return `${open}\n      ${body}\n    ${close}`;
});

// The page lives one directory down.
html = html.replace(/(\s(?:src|href|data-lightbox)=")((?:assets\/|styles\.css|script\.js)[^"]*")/g, "$1../$2");

// <body>
const bodyStart = html.indexOf("<body");
let head = html.slice(0, bodyStart);
let body = html.slice(bodyStart);

body = replaceOnce(body, /<a href="zh\/" hreflang="zh-CN" lang="zh-CN">中文<\/a>/, '<a href="../" hreflang="en" lang="en">English</a>');

body = body.replace(/>([^<]+)</g, (match, raw) => {
  const translation = text.get(normalize(decode(raw)));
  if (!translation) return match;
  const leading = raw.match(/^\s*/)[0];
  const trailing = raw.match(/\s*$/)[0];
  return `>${leading}${encode(translation)}${trailing}<`;
});

body = body.replace(/\s(aria-label|alt)="([^"]+)"/g, (match, name, raw) => {
  const english = decode(raw);
  const translation = attributes.get(english) ?? text.get(english);
  return translation ? ` ${name}="${encode(translation)}"` : match;
});

const output = head + body;

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(outputPath, "utf8");
  } catch {}
  if (current !== output) {
    console.error("docs/zh/index.html is out of date: run node scripts/build-site-zh.mjs");
    process.exit(1);
  }
} else {
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, output);
  console.log(`wrote ${outputPath}`);
}
