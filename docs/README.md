# StupidMirror 宣发页

这是一个无构建依赖的静态宣发网站，也是 GitHub Pages 的发布目录。产品截图来自现有飞书宣发稿，并已转为 WebP。

## 本地预览

在仓库根目录执行：

```bash
python3 -m http.server 4173 --directory docs
```

然后访问 <http://127.0.0.1:4173>。

## GitHub Pages

仓库公开并将本目录提交到 `main` 后，在仓库的 **Settings → Pages** 中设置：

- Source：`Deploy from a branch`
- Branch：`main`
- Folder：`/docs`

默认访问地址为 <https://liutianjie.github.io/StupidMirror/>。

页面不依赖后端或打包流程。`mvp-architecture.md` 和 `research.md` 是原有项目文档，不影响站点入口。

StupidMirror 采用 PolyForm Noncommercial 1.0.0：个人及其他非商业用途可免费使用，商业用途需要项目所有者另行书面授权。
