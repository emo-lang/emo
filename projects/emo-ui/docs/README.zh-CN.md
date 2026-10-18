# EmoUI 各包参考

`projects/emo-ui/` 里每个公开包一页。每份参考写明该包的清单(名字、目标、原生字段)、源码中声明的入口,以及调用方可以依赖的行为;`golden/` 是共享的测量装置而不是公开包,它的关口在顶层 README 里描述。各包参考目前以英文撰写,中文翻译尚未补齐。

| 包 | 是什么 |
|---|---|
| [`ui`](ui.md) | 可移植核心:节点、样式、Elm 循环、后端接口 |
| [`debug`](debug.md) | 无头后端与稳定文本形式(`ui` 的一个模块) |
| [`ui_tui`](ui_tui.md) | 终端后端及其字符格盒模型 |
| [`ui_ssr`](ui_ssr.md) | 服务端渲染的 HTML/CSS 后端 |
| [`ui_macos`](ui_macos.md) | macOS/AppKit 后端 |
| [`ui_gtk`](ui_gtk.md) | GTK 4 后端 |
| [`ui_browser`](ui_browser.md) | DOM 后端 |
| [`ui_corpus`](ui_corpus.md) | 每个后端都运行的共享应用 |

一个应用依赖 `emo/ui` 加一个后端包,并调用 `ui.run(view, update, model, backend)`。这些包实现的设计写在仓库的 `README.md` 里;证据与开放问题见 [`docs/emo-ui.md`](../../../docs/zh-CN/emo-ui.md)。
