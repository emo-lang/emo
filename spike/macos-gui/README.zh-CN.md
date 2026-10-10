# macOS GUI spike(可行性验证)

一次可行性验证:一个原生 AppKit 窗口,所有可见行为都是 Emo 代码,通过一个固定的 C 词汇表 shim 驱动——**零编译器改动**。它存在的目的是把 FFI 分析变成实证:检验当前 `foreign def` + C 目标到底能承载什么、不能承载什么。

## 运行

```sh
./build.sh                        # 两遍构建(见下)
./gui-spike                       # 演示:点击按钮
EMO_GUI_AUTOTEST=1 ./gui-spike    # 自驱测试:合成一次点击、打印
                                  # label 文本、自动退出(exit 0)
```

需要 macOS 和 Xcode 命令行工具。解释器拒绝 foreign def(E3009),所以本验证从构造上就只能编译运行。

## 文件构成

- **`main.emo`** — 全部 UI 逻辑:窗口/按钮/label 的组装(每个布局数字都在这里)、点击行为(计数、消息排版、更新 label),以及词汇表的 foreign 声明。
- **`shim.m`** — 整个桥,约 200 行:三个复合创建器(AppKit 里 Emo 无法命名的仪式:结构体参数、方法链、target 接线)、五个通用 `objc_msgSend` 形状(选择器用字符串命名)、一个把点击转发进 Emo 的 delegate,以及自驱测试模式。
- **`build.sh`** — 第一遍跑 `emo build`,明知它会在链接时失败:目的是让它写出 `.emo-build/emo_c_runtime.h`(shim 编译所依赖的头文件);第二遍用 `--cclib` 把 shim 目标文件链进去。

## 发现(2026-10-10)

演示端到端跑通:Emo 组装 UI,AppKit 投递事件,delegate 调用 `main__on_click`,Emo 通过 foreign 调用更新 label,自驱测试从真实窗口读回结果。回路每一条边都被实测。

过程中发现并实证的缺口:

1. **foreign def 不能返回 Void**(E4200)——词汇表里所有"只管发不管回"的调用都带一个假的 `Int64` 返回。*2026-10-10 已解决:c 目标放行 Void 返回,词汇表里"只管发不管回"的调用现在是真正的 Void。*
2. **C 目标没有 def 可达的全局存储。** def 内引用顶层 `const` 会被降级成 `Type_ref`(拒绝);顶层 `var` 降级成 `Global_var` 表达式(拒绝)。Emo 里没有任何地方可以放跨回调的状态,所以状态只能走回调签名:当前计数传入、新计数传出,槽位由 shim 持有。
3. **入口模块的 def 以模块限定名发射**——是 `main__on_click`,不是裸的 `on_click`。
4. **`--cclib` 透传规则**:只有以 `-` 或 `/` 开头的值原样透传(shim 目标文件必须写成 `--cclib="$PWD/shim.o"`,裸的 `shim.o` 会变成 `-lshim.o`);以 `-` 开头的值要用等号形式传给 cmdliner(`--cclib="-framework AppKit"`)。*另有 2026-10-10:指向真实文件的 cclib 按内容进入构建缓存键——编辑 shim 即可让缓存失效,而不是静默链接旧二进制。*
5. **AppKit 头文件是 Objective-C**——shim 必须以 `.m` 编译(还是同一个 clang,无需额外工具链,但"纯 C 桥"死在头文件上,不是死在 runtime API 上)。ARC 还要求 Int64 句柄约定走 `__bridge` 跳板。

这次 spike 直接催生了两个编译器改动(2026-10-10):c 目标的 `Void` foreign 返回,以及 `.emo-build/emo_defs.h`——程序的全部外部可达声明,由 `emo build` 写出,shim 现在 include 编译器自己的声明、不再手写 extern。故意破坏 shim 签名会在 cc 时以 `conflicting types` 报错——已实测。

产品级 GUI 仍然挡着的硬伤(spike 前的评估已列出,本次未变):bump 分配器从不回收(跑几分钟没事,跑一天致命);回调不是一等公民(FFI 不跨函数指针,状态和处理器只能走固定签名);没有 struct 和变参 marshaling;同一个 C 符号不能按两个签名声明(五个通用形状装不下的 selector,每个都得单独写 shim 函数)。

## 状态

仅为 spike——不属于工具链,未提交。`emo` 二进制路径默认 `../../_build/default/src/emo_cli/emo.exe`,可用 `EMO=...` 覆盖。
