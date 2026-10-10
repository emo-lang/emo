# 组件化 spike:一份 Emo 源码,两个 GUI 平台

第三个 GUI spike。第一个证明了够得着 macOS 窗口;第二个量化了 C 工具包需要多厚的绑定层;这一个直接搭架构:**React/Elm 风格的组件模型,Emo 写一次,macOS 走 AppKit、Linux 走 GTK 4。**它以零编译器改动落地,而它的多模块后续反过来驱动了两个编译器修复(C 目标的本地跨模块调用,以及 ocaml 发射器的零参函数)。

## 运行

```sh
./build-mac.sh                      # macOS,底下是 AppKit
./build-gtk.sh                      # Linux 容器(Docker),底下是 GTK 4
EMO_GUI_AUTOTEST=1 ./ui-app         # 自驱:+1、-1、+1、报告、退出——
                                    # 两端输出逐字一致
```

## 架构

- **组件就是一个 def。** `counter_label(count)`、`action_panel()`、`view(count)`——返回 VNode 的普通函数,函数嵌套即层级。语言侧没有为此新增任何 construct。
- **Elm 回路整个活在 Emo 里。** `update(tag, model)` 和 `view(model)` 是纯函数;shim 只负责保管模型标量、点击时调 `app__on_event(tag, model)`、把返回值留给下一次事件。其余一切——更新、重渲染、重绘——都发生在 Emo。
- **样式是每节点一个 Map。** `Map.new(("gap", 28.0), ("padding", 24.0))`——Map 没有元素顺序,所以两条样式声明之间**永不互相依赖**(与 SwiftUI 的链式修饰针锋相对:`.bold().red()` 和 `.red().bold()` 在那边是可能分叉的)。优先级只来自层级:节点的生效样式 = 父 Map 被子 Map 覆盖——嵌套面板的 `gap: 8` 覆盖根的 `gap: 28`,其余全部向下流动——这就是 CSS 的层叠。demo 把两种间距同时画在屏幕上。
- **布局在 Emo 里算。** 垂直列遍历把 VNode 树变成带位置的 Draw 指令(padding、gap、按 kind 的默认高度、可被 `width`/`height` 键覆盖);shim 只负责摆像素。一份布局引擎,两端像素一致。
- **平台差异收缩为约 100 行的画笔。** 两个 shim 实现同一个九动词 `ui_*` 契约(`window_make`、`label_make`、`button_make`、`place`、`clear`、`connect`、`root`、`run`、`autotest_arm`)。重绘是全量重建——`clear` 加重新摆放——因为 `view` 是纯函数;差量协调(reconciliation)是后续里程碑。

## 顺带的语言发现

1. **本地跨模块调用曾在 c 目标被拒绝——现已修复。** 顺手 innocen 的架构——共享模块加薄入口——死在 codegen:经模块别名的 `ui.show(n)` 降级成类型级方法("the c target does not support the type-level method ... yet")。两个根因,均已修复(2026-10-10):入口模块的别名绑定(`const ui = internal.vnode`)把值一侧降成了垃圾 C——别名绑定现在在入口不降任何语句、在 def 体内降为无害的 Int 局部;另外缓存 key 从不包含编译器自身内容,陈旧的缓存二进制在编译器修复后依然存活——三个目标臂现在都把运行中可执行文件的摘要混入键值。多模块拆分随后真的试了一次,并暴露出**下一个缺口:跨模块类型注解仍然被拒**(E4005——checker 的类型表按模块隔离),`def view(count Int64) VNode` 无法跨模块书写,spike 保持单文件。拆分实验留在 git 历史里;通用的 Emo UI 包从跨模块类型起步。
2. **递归类型必须用 xml 包的形状。** 类不能在自己的 `init` 里提名(E4005),接口不能在签名里自指。可行形状:接口 `VNode`(统一访问器)+ `VControl`/`VColumn` 两个具体类,`children Array[VNode]` 放在容器上,遍历时 `is()` 收窄。
3. **递归是唯一的循环。** 没有 `while`/`for`——布局遍历用递归;累积结果靠 `Array[Draw]` 随返回值穿线(`Laid` 结果类捆住指令和游标),因为 def 只返回一个值,而 `Box.new([])` 装的是动态数组、其 `.append` 在动态世界没有接线(运行时 "message not understood: append/1")。
4. **`Map.new` 收变长 pairs**,空表用 `Map.new()`——元组数组在检查期被拒(E4009)。
5. ARC 的 `__bridge` 跳板、Linux 的 `int64_t`=`long`、两遍构建的舞步,全部从前两轮 spike 延续;中性词汇还顺带化解了 defs 头与库头文件的 TU 冲突——defs 头不再点名任何 GTK/AppKit 符号。

## 文件

- `app.emo` — Emo 的一切:词汇表声明、VNode、组件、层叠、布局、paint、update/view/on_event。
- `shim_mac.m` / `shim_gtk.c` — 两支画笔,同一契约。
- `build-mac.sh` / `build-gtk.sh` — 两遍构建(第一遍写出 `.emo-build/emo_defs.h`,两个 shim 都对着它编译)。
- `ui-gtk.png` / `ui-mac.png` — 同一个界面在两个平台上。
