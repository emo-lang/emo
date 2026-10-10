# emo-ui 决策检查单

状态:**决策待定**(记录于 2026-10-10)。本文档是把 GUI spike 变成真正的 Emo UI 包的关口清单:哪些已经定了、那一个阻塞决策是什么、以及它之后还剩什么。证据都在三个 spike(`spike/macos-gui`、`spike/gtk`、`spike/components`)和它们驱动的编译器修复里。

## Spike 已经定下的事

1. **可达性。** 带可用回调的原生窗口今天就能做到:macOS 经词汇表 shim 驱动 AppKit(`spike/macos-gui`),Linux 上 GTK 4 基本靠直呼 `foreign def`(`spike/gtk`——它的 shim 只有三分之一厚,因为 C 工具包根本不需要词汇表)。
2. **组件模型。** `spike/components` 跑通了一个 React/Elm 风格的应用——def 即组件、update/view 回路在 Emo、样式是每节点 Map 且子覆盖父、布局在 Emo 里算——经九动词 `ui_*` shim 契约在 AppKit 和 GTK 4 上逐字节一致。
3. **Spike 驱动的编译器修复**(均在 `develop`,2026-10-10):c 目标的 `Void` foreign 返回、`.emo-build/emo_defs.h` shim 声明、内容寻址构建缓存,以及 c 目标的本地跨模块**调用**(入口模块的别名绑定曾把值一侧降成垃圾 C)。

## 阻塞决策:跨模块类型

组件模型想成为两个模块——UI 库(`ui.emo`:VNode、层叠、布局、paint)和应用(`app.emo`:组件、update、view)。上面的修复之后,调用这条腿通了;类型这条腿不通。拆分真实试过,死在检查期:

- 应用模块里的 `def view(count Int64) VNode` → **E4005("unknown type `VNode`")**:checker 的类/接口/枚举表按模块构建(`check_module_typed`,emo_check.ml),没有任何机制预注册其他模块的类型声明。
- 去掉注解也无路可退:无注解的 def 推断为 Void,返回值的 def 随即报 **E4016**。两个错误互相锁死;拆分已回退。

今天唯一的带类型面在单个模块内部。注册表包(`xml`)遵循同一条规则:消费方把包类型当作渐进(不检查)的值持有。

### 方案 A —— 程序级类型预注册

在任何模块检查之前,收集所有模块的类/接口/枚举;名字保持不带限定。

- 成本:每模块检查前的收集 pass,外加一条"程序内类型名唯一"规则(两个模块都声明 `Widget` 必须响亮报错——静默解析会背叛 strictness)。
- 解锁:处处干净的注解(`def view(count Int64) VNode`)、跨模块的 `is()` 收窄、对库作者和消费方都最小的表面积。

### 方案 B —— 模块限定类型名

注解写出模块路径(`def view(count Int64) ui.VNode`),经由调用已在用的别名机制解析。

- 成本:parser 与类型名解析器的工作,且限定名必须规约到模块 mangle 后的类名——贯穿 IR、`is()` vtable 和两个发射器——比 A 更多层。
- 解锁:无碰撞的组合(两个包都可以定义 `Widget`)、每个使用点显式可 grep 的类型。

### 建议(提案——未定)

先做方案 A,带上响亮的碰撞报错。它改动更小,符合 strictness-first 的姿态,并且在"类型名唯一"的生态现状下就能解锁 emo-ui 包。等真实碰撞出现再叠方案 B。无论选哪个,规则应在 emo-ui 包启动前落入 CHECK.md。

## 决策之后:emo-ui 包的检查单

按依赖顺序,每道关口带证据:

1. **跨模块类型**——即上面的决策。解锁:ui/app 拆分、共享组件库、包本身。
2. **内存回收**——c 目标的 bump 分配器从不释放(`emo_c_runtime.c` 自述);几分钟的 demo 量不出跑一天的 app。回收决策已在 CHECK.md 记为待定;GUI 是让它变成必答题的消费者。
3. **一等回调**——今天 C 回调经固定 extern 名重入 Emo、状态走签名穿线(spike 的模式)。block 跨 FFI(E4200)加上现成的 `emo_closure_fn` 约定,就能让组件把处理器当值携带。
4. **渲染深度**——每事件全量重绘在 demo 尺度没问题;协调(reconciliation)、样式键校验(今天的样式表是字符串键 Float64 值的 Map)、以及工具包原生布局所需的 struct 编组,是包存在之后的成长路径。

## 刻意不谈的

不谈打包/应用商店,不谈 UI 线程的并发故事,也不承诺第一个包瞄准哪个工具包——九动词契约从构造上就是工具包无关的,本文档只假设这么多。
