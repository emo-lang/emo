# EmoUI

用 Emo 写的组件式 UI 框架:一棵声明式树渲染到终端、服务端页面、macOS/AppKit 窗口与 GTK 4 窗口——浏览器 DOM 随后按自己的运行时路径接入。Emo 的语法就是为它塑形的,原则是**没有模板语言——UI 就是普通的 Emo 代码**,与配置同一哲学。

组件树是带块的嵌套调用:

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }
}

list(users) -> (user User) {
  card(user) {
    text(user.name)
    text(user.bio)
  }
}
```

## 状态

**这个目录里还没有任何实现。** 设计已定,各包落在这里;第一个任务是 T48.1,可移植的 `ui` 核心。设计与证据:

- [`docs/zh-CN/emo-ui.md`](../../docs/zh-CN/emo-ui.md) —— 评估与设计方向。
- [`docs/zh-CN/emo-ui-composition.md`](../../docs/zh-CN/emo-ui-composition.md) —— 一棵树怎么写出来:组件为什么返回子节点而不是发射。
- [`plan/step-48-emo-ui.md`](../../plan/step-48-emo-ui.md) —— 执行计划,T48.1–T48.13。
- [`spike/emo-ui-spelling/`](../../spike/emo-ui-spelling/) —— 定下写法的两屏度量,以及 `ui.emo`,核心的原型。
- [`spike/emo-ui-probe/`](../../spike/emo-ui-probe/)、[`spike/components/`](../../spike/components/)、[`spike/macos-gui/`](../../spike/macos-gui/)、[`spike/gtk/`](../../spike/gtk/) —— 语言特性与原生工具包两方面的证据。

## 这个目录的位置

EmoUI 是一个**独立项目**,不是标准库包:标准库以生成数据的形式内嵌在编译器二进制里,而一个带着每平台原生 shim 的 UI 框架不该放在那儿。它活在编译器仓库的 `projects/emo-ui/` 下,以它将来可以拆分出去的仓库命名,好让 `git subtree split -P projects/emo-ui` 之后能带着历史得到那个独立仓库(`CHECK.md`,in-tree 项目布局)。

这个目录由它自己的 `package.emo` 生根,和任何其他 Emo 项目一样——仓库根没有 manifest,所以这个包的模块按它自己的程序来检查,编译器的构建也不会把它们扫进来。
