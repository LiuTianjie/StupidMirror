# StupidMirror 宣发页

这是一个无构建依赖的静态宣发网站，也是 GitHub Pages 的发布目录。产品截图来自现有飞书宣发稿，并已转为 WebP。

## 本地预览

在仓库根目录执行：

```bash
python3 -m http.server 4173 --directory docs
```

然后访问 <http://127.0.0.1:4173>。

## GitHub Pages

当前站点由 `main/docs` 自动发布。发布准备只推送到独立分支并创建 PR；用户亲自合并后站点才会上线。不要为验证预览而直接推送 `main`。

仓库的 **Settings → Pages** 配置：

- Source：`Deploy from a branch`
- Branch：`main`
- Folder：`/docs`

默认访问地址为 <https://stupidmirror.itool.tech/>。

英文页是 `index.html`，中文页是静态生成的 `zh/index.html`（旧的 `?lang=zh` 链接会跳转过去）。改动英文页或中文文案（`scripts/site-zh.json`）后运行 `node scripts/build-site-zh.mjs`，CI 用 `--check` 校验两页是否同步。不要手改 `zh/index.html`。

官网部署在 `https://stupidmirror.itool.tech/`：本地 `~/seos/stupidmirror/sync.sh` 从本目录复制站点（不含 `updates/`），`~/seos/deploy.sh stupidmirror` 用 Luma 部署到 cn 的 manager 节点。GitHub Pages 仍然发布本目录，保留 Sparkle 更新源 `updates/appcast.xml`；页面在 `github.io` 上打开时会跳转到新域名。SEO 相关文件：`sitemap.xml`、`robots.txt`、`llms.txt`、`404.html`（`noindex`）、`assets/og-image.jpg`（1200×630 分享图）。首页「常见问题」同时写入 FAQPage 结构化数据，两处要保持一致。改版后同步更新 `sitemap.xml` 的 `lastmod` 和 JSON-LD 中的 `softwareVersion`。

`mvp-architecture.md`、`research.md`、`codex-plugin.md` 是项目文档，不列入 sitemap。

StupidMirror 采用 PolyForm Noncommercial 1.0.0：个人及其他非商业用途可免费使用，商业用途需要项目所有者另行书面授权。

官网的下载按钮统一指向最新公开 Release，避免指向旧版本或未发布的草稿。Codex 使用说明维护在 `codex-plugin.md`，新文案同步维护 `index.html` 与 `scripts/site-zh.json` 的中文映射。现有手机截图是原生镜像示例，不代表 Codex 面板截图。
