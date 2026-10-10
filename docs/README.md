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

默认访问地址为 <https://liutianjie.github.io/StupidMirror/>。

页面默认使用英文，可通过顶部语言入口切换完整中文文案；不依赖后端或打包流程。`mvp-architecture.md` 和 `research.md` 是原有项目文档，不影响站点入口。

StupidMirror 采用 PolyForm Noncommercial 1.0.0：个人及其他非商业用途可免费使用，商业用途需要项目所有者另行书面授权。

官网的下载按钮统一指向最新公开 Release，避免指向旧版本或未发布的草稿。Codex 使用说明维护在 `codex-plugin.md`，新文案同步维护 `index.html` 与 `script.js` 的中文映射。现有手机截图是原生镜像示例，不代表 Codex 面板截图。
