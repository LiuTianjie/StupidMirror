#!/usr/bin/env node
// CHANGELOG.md is the only release-history source. Both pages are fully static.
// Run after editing VERSION or CHANGELOG.md; --check is used by CI and releases.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const base = "https://stupidmirror.itool.tech/";
const repository = "https://github.com/LiuTianjie/StupidMirror";
const source = readFileSync(join(root, "CHANGELOG.md"), "utf8");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
const headings = [...source.matchAll(/^## (\d+\.\d+\.\d+)(?: - (\d{4}-\d{2}-\d{2}))?\s*$/gm)];
const entries = headings.map((heading, i) => ({
  version: heading[1], date: heading[2],
  body: source.slice(heading.index + heading[0].length, headings[i + 1]?.index ?? source.length).trim(),
}));
if (!/^\d+\.\d+\.\d+$/.test(version) || entries[0]?.version !== version) {
  throw new Error(`CHANGELOG.md must begin with an entry for VERSION ${version}. Add it before generating the website.`);
}
if (new Set(entries.map((entry) => entry.version)).size !== entries.length) {
  throw new Error("CHANGELOG.md contains duplicate versions.");
}
if ((source.match(/^## /gm) ?? []).length !== entries.length) {
  throw new Error("Use release headings in the form: ## x.y.z - YYYY-MM-DD.");
}
for (const entry of entries) {
  if (!entry.body || (entry.date && new Date(`${entry.date}T00:00:00Z`).toISOString().slice(0, 10) !== entry.date)) {
    throw new Error(`Release ${entry.version} has empty notes or an invalid date.`);
  }
}
if (!entries[0].date) throw new Error(`The current release ${version} needs a date.`);
const digest = createHash("sha256").update(source).digest("hex");
const esc = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// The changelog uses paragraphs, lists, headings and fenced code. Escape HTML
// and keep the small inline Markdown subset used by the source readable.
function inline(text) {
  let html = "", cursor = 0;
  const tokens = /`([^`]+)`|\*\*([^*]+)\*\*|\[([^\]]+)\]\(([^\s)]+)\)/g;
  for (const token of text.matchAll(tokens)) {
    html += esc(text.slice(cursor, token.index));
    if (token[1]) html += `<code>${esc(token[1])}</code>`;
    else if (token[2]) html += `<strong>${inline(token[2])}</strong>`;
    else {
      const target = token[4];
      const href = /^(https?:\/\/|#)/.test(target) ? target
        : !/^[a-z][a-z\d+.-]*:/i.test(target) ? new URL(target, `${repository}/blob/main/`).href : null;
      html += href ? `<a href="${esc(href)}">${esc(token[3])}</a>` : esc(token[3]);
    }
    cursor = token.index + token[0].length;
  }
  return html + esc(text.slice(cursor));
}

function blocks(lines) {
  const html = [];
  let i = 0;
  while (i < lines.length) {
    if (!lines[i].trim()) { i += 1; continue; }
    if (/^\s*```/.test(lines[i])) {
      const code = [];
      i += 1;
      while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
      i += 1;
      html.push(`<pre><code>${esc(code.join("\n"))}</code></pre>`);
      continue;
    }
    const heading = lines[i].match(/^\s*#{3,6}\s+(.+)$/);
    if (heading) { html.push(`<h3>${inline(heading[1])}</h3>`); i += 1; continue; }
    const first = lines[i].match(/^(\s*)(?:[-*+]\s+|\d+\.\s+)(.*)$/);
    if (first) {
      const indent = first[1].length;
      const tag = /^\s*\d+\./.test(lines[i]) ? "ol" : "ul";
      const items = [];
      while (i < lines.length) {
        const item = lines[i].match(/^(\s*)(?:[-*+]\s+|\d+\.\s+)(.*)$/);
        if (!item || item[1].length !== indent) break;
        const content = [item[2]];
        i += 1;
        while (i < lines.length) {
          if (!lines[i].trim()) { content.push(""); i += 1; continue; }
          const spaces = lines[i].match(/^\s*/)[0].length;
          if (spaces <= indent) break;
          content.push(lines[i].slice(Math.min(spaces, indent + 2)));
          i += 1;
        }
        items.push(`<li>${blocks(content)}</li>`);
      }
      html.push(`<${tag}>${items.join("")}</${tag}>`);
      continue;
    }
    const paragraph = [lines[i++].trim()];
    while (i < lines.length && lines[i].trim() && !/^\s*(?:[-*+]\s|\d+\.\s|#{3,6}\s|```)/.test(lines[i])) {
      paragraph.push(lines[i++].trim());
    }
    html.push(`<p>${inline(paragraph.join(" "))}</p>`);
  }
  return html.join("\n");
}

const locales = {
  en: {
    lang: "en", path: "changelog/", up: "../", home: "", other: "zh/changelog/",
    title: "Changelog | StupidMirror", label: "Changelog", language: "中文", otherLang: "zh-CN",
    intro: "New features, improvements and fixes, release by release.",
    note: "The complete project history. Older entries describe the behavior of that version.",
    latest: "Latest", download: "Download latest", jump: "Jump to a version", versions: "versions",
    source: "Source on GitHub", releases: "GitHub releases", early: "Early development", top: "Back to top",
    nav: "Primary navigation", skip: "Skip to release history", codex: "Codex plugin", mcp: "MCP setup",
  },
  zh: {
    lang: "zh-CN", path: "zh/changelog/", up: "../../", home: "zh/", other: "changelog/",
    title: "更新日志｜StupidMirror", label: "更新日志", language: "English", otherLang: "en",
    intro: "新功能、体验改进与问题修复，按版本记录。",
    note: "完整保留项目历史。版本正文沿用英文原始记录；旧条目描述的是对应版本的行为。",
    latest: "最新版本", download: "下载最新版", jump: "跳转到版本", versions: "个版本",
    source: "在 GitHub 查看源文件", releases: "GitHub 发布记录", early: "早期开发", top: "回到顶部",
    nav: "主导航", skip: "跳转到版本历史", codex: "Codex 插件", mcp: "MCP 配置",
  },
};

function render(p) {
  const url = base + p.path;
  const structured = {
    "@context": "https://schema.org", "@type": "CollectionPage", name: p.title,
    url, inLanguage: p.lang, description: p.intro, dateModified: entries[0].date,
    mainEntity: { "@type": "ItemList", numberOfItems: entries.length,
      itemListElement: entries.map((entry, i) => ({ "@type": "ListItem", position: i + 1,
        name: `StupidMirror ${entry.version}`, url: `${url}#v${entry.version}` })) },
  };
  const articles = entries.map((entry, i) => `        <article class="release-entry" id="v${entry.version}" aria-labelledby="title-${entry.version}">
          <header class="release-heading">
            <div><h2 id="title-${entry.version}"><a href="#v${entry.version}">v${entry.version}</a></h2>${i === 0 ? `<span class="release-badge">${p.latest}</span>` : ""}</div>
            ${entry.date ? `<time datetime="${entry.date}">${entry.date}</time>` : `<span class="release-date">${p.early}</span>`}
          </header>
          <div class="release-body" lang="en">${blocks(entry.body.split(/\r?\n/))}</div>
        </article>`).join("\n");
  return `<!doctype html>
<!-- Generated from CHANGELOG.md; sha256 ${digest}. Do not edit this page directly. -->
<html lang="${p.lang}">
  <head>
    <meta charset="UTF-8" />
    <script>if(location.hostname.endsWith("github.io"))location.replace("https://stupidmirror.itool.tech"+location.pathname.replace(/^\\/StupidMirror/i,"")+location.search+location.hash)</script>
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>${p.title}</title>
    <meta name="description" content="${p.intro}" />
    <meta name="robots" content="index, follow" />
    <meta name="theme-color" content="#08090a" />
    <meta name="color-scheme" content="dark" />
    <link rel="canonical" href="${url}" />
    <link rel="alternate" hreflang="en" href="${base}changelog/" />
    <link rel="alternate" hreflang="zh-CN" href="${base}zh/changelog/" />
    <link rel="alternate" hreflang="x-default" href="${base}changelog/" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="StupidMirror" />
    <meta property="og:url" content="${url}" />
    <meta property="og:title" content="${p.title}" />
    <meta property="og:description" content="${p.intro}" />
    <meta property="og:image" content="${base}assets/og-image.jpg" />
    <link rel="icon" type="image/png" sizes="128x128" href="${p.up}assets/favicon.png" />
    <link rel="apple-touch-icon" sizes="180x180" href="${p.up}assets/apple-touch-icon.png" />
    <link rel="stylesheet" href="${p.up}styles.css?v=20261026-changelog" />
    <script type="application/ld+json">${JSON.stringify(structured).replace(/</g, "\\u003c")}</script>
  </head>
  <body id="top">
    <a class="skip-link" href="#history">${p.skip}</a>
    <header class="site-header scrolled">
      <nav class="nav-shell" aria-label="${p.nav}">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="28" height="28" /><span>StupidMirror</span></a>
        <div class="changelog-nav-actions">
          <a class="nav-link" href="${p.up}${p.other}" hreflang="${p.otherLang}" lang="${p.otherLang}">${p.language}</a>
          <a class="button button-primary button-small" href="${repository}/releases/latest">${p.download}</a>
        </div>
      </nav>
    </header>
    <main>
      <section class="section-shell guide-hero changelog-hero">
        <nav class="guide-breadcrumb" aria-label="${p.nav}"><a href="${p.up}${p.home}">StupidMirror</a><span aria-hidden="true">/</span><span aria-current="page">${p.label}</span></nav>
        <p class="section-index">RELEASE NOTES</p>
        <h1>${p.label}</h1>
        <p class="guide-lead">${p.intro}</p>
        <div class="changelog-meta"><a href="#v${version}">${p.latest} · v${version}</a><span>${entries.length} ${p.versions}</span><a href="${repository}/releases">${p.releases} ↗</a></div>
        <p class="changelog-note">${p.note}</p>
      </section>
      <div class="section-shell changelog-layout">
        <aside class="changelog-index"><nav aria-label="${p.jump}"><h2>${p.jump}</h2><div>${entries.map((entry) => `<a href="#v${entry.version}">v${entry.version}</a>`).join("")}</div></nav></aside>
        <section class="release-history" id="history" aria-label="${p.label}">
${articles}
        </section>
      </div>
    </main>
    <footer class="site-footer">
      <div class="section-shell footer-inner">
        <a class="brand" href="${p.up}${p.home}"><img src="${p.up}assets/app-icon.webp" alt="" width="22" height="22" /><span>StupidMirror</span></a>
        <nav class="guide-footer-nav" aria-label="${p.nav}"><a href="${p.up}${p.home}codex/">${p.codex}</a><a href="${p.up}${p.home}mcp/">${p.mcp}</a><a href="${repository}/blob/main/CHANGELOG.md">${p.source}</a><a href="#top">${p.top} ↑</a></nav>
      </div>
    </footer>
  </body>
</html>
`;
}

const outputs = Object.values(locales).map((p) => [join(root, "docs", p.path, "index.html"), render(p)]);
const sitemapPath = join(root, "docs/sitemap.xml");
const sitemap = readFileSync(sitemapPath, "utf8");
const sitemapBlock = `  <!-- changelog: generated start -->\n${Object.values(locales).map((p) => `  <url>
    <loc>${base}${p.path}</loc>
    <lastmod>${entries[0].date}</lastmod>
    <xhtml:link rel="alternate" hreflang="en" href="${base}changelog/" />
    <xhtml:link rel="alternate" hreflang="zh-CN" href="${base}zh/changelog/" />
    <xhtml:link rel="alternate" hreflang="x-default" href="${base}changelog/" />
  </url>`).join("\n")}\n  <!-- changelog: generated end -->\n`;
const marker = /  <!-- changelog: generated start -->[\s\S]*?  <!-- changelog: generated end -->\n/;
if (!sitemap.includes("</urlset>")) throw new Error("Invalid docs/sitemap.xml: missing urlset.");
outputs.push([sitemapPath, marker.test(sitemap) ? sitemap.replace(marker, sitemapBlock) : sitemap.replace("</urlset>", sitemapBlock + "</urlset>")]);
let stale = false;
for (const [path, html] of outputs) {
  if (process.argv.includes("--check")) {
    let current = "";
    try { current = readFileSync(path, "utf8"); } catch {}
    if (current !== html) { console.error(`${path} is out of date: run node scripts/build-site-changelog.mjs`); stale = true; }
  } else {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, html);
    console.log(`wrote ${path}`);
  }
}
if (stale) process.exitCode = 1;
