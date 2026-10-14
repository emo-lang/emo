# 以「区域」为粒度的 arena 回收

这是 step 48(EmoUI)派生出的一个 spike,在动手做 `ui-macos`(T48.8)和
`ui-gtk`(T48.9)之前回答一个问题:

> UI 每来一个事件就重跑一次 `view()`。`c` 目标能不能回收一次渲染所
> 分配的内存——以某种「区域」为粒度?如果可以,安全规则是什么,代价
> 又是什么?

**结论:不能——它无法作为独立机制成立,也不该成为 T48.8 的前置条
件。** 区域本身很容易做,而且说到做到:在 UI 能安全指认的那个边界
上,它回收了 100% 的 arena。但它没有回收那个真正拖垮进程的泄漏,而
且这个机制的形态使得那部分泄漏变得**永久无法恢复**。正确的答案是给
值语义家族加上引用计数,而那是另一个独立的里程碑。在那之前,`c` 目
标的 UI 故事只到 demo 规模,诚实的做法是把这条限制写进文档,而不是先
把一个区域交出去。

推理见[结论](#结论)一节;它依据的数字在下面。

## 出发点

T23.5 于 2026-10-11 落地了 `c` 目标的回收模型(`CHECK.md:18`):对
**带身份的**单元格——实例、闭包、`Box`——做引用计数,外加一个帧作用
域的 autorelease pool。所有值语义的种类(字符串、元组、数组、Map、
List、Bytes、枚举、装箱标量)都住在 bump arena 里,只在进程退出时释
放(`src/emo_codegen/c/emo_c_runtime.c:96`)。做这个 spike 的时候,
`CHECK.md:37`(cross-target invariants 那条,第 2 项)把这一点记为未决;
下面那条已定的条目就是它的答案。

UI 是第一个把这件事从「整洁问题」变成「产品问题」的工作负载,问题也
因此在这里被提出来。

## 探针是怎么构建的

`src/` 下一行都不改。每个探针都链接到一个这样的运行时:编译器**自己**
产出的 `emo_c_runtime.{c,h}`,后面追加 `runtime/probe_arena.{c,h}`:

```sh
cat .emo-build/emo_c_runtime.c runtime/probe_arena.c > build/<probe>/emo_c_runtime.c
```

追加的这块只**增加**函数——`arena_bytes`、`arena_chunks`、`arena_mark`、
`arena_reset`——所以与出厂运行时的 diff 中「删除或修改的行」是 0,探
针量到的是出厂运行时的数字,而不是某个变体的数字。(编译器内嵌运行时
时会在首尾各加一个空行;这是 `.emo-build/emo_c_runtime.c` 与
`src/emo_codegen/c/emo_c_runtime.c` 唯一的差别。)

有三件事让这套做法跑得通,每一件不预先知道都要花时间:

- **必须允许 `emo build` 失败。** 它先把 `.emo-build/main.c` 写出来,
  然后才调 `cc`;探针调用 `emo_arena_*`,而出厂运行时没有这些符号,所
  以链接会在**写完之后**失败。`build.sh` 用 `|| true` 跑它,把日志留
  成 `stock-pass.log`,并在 `main.c` 缺失或比探针源码还旧时直接报错拒
  续——缓存短路就是这个样子。
- **带引号的 include 会优先按包含它的文件所在目录解析。**
  `.emo-build/main.c` 里写着 `#include "emo_c_runtime.h"`,它会先找到
  `.emo-build` 里那份出厂头文件,任何 `-I` 路径都排在后面。所以
  `build.sh` 把 `main.c` 复制到 `build/` 里、与追加后的运行时放在一
  起,而不是去覆盖 `.emo-build` 里的任何东西。
- **编译参数必须一致。** 追加后的运行时用的就是 `emo build` 那一套
  (`-O2 -ffp-contract=off -std=c11 -Wall -Wno-deprecated-declarations …
  -lm`),这样产出的二进制与出厂二进制的差别就只有那几个新增探针。

## 数字

### P1 —— 一次渲染的代价

`probe1_render_churn.emo` 按 `spike/components/app.emo` 的形状渲染一
棵树——`view()` 全量重建、children 数组用反复 `.append` 长出、每个节
点带一个 style `Map`、layout 深度优先遍历并在第二个 append 数组里累
积 `Draw` 命令——每一档把节点数翻倍。每档渲染 100 次。

**不用区域**(一个事件 = 一次 `view()` + 一次 `paint()` + 丢弃):

| nodes | bytes/render | ×上一档 | bytes/node | ids/render | 泄漏的 ids |
| ----: | -----------: | ------: | ---------: | ---------: | ---------: |
|    25 |       20,104 |       — |        804 |         41 |      4,100 |
|    50 |       42,728 |   2.12× |        855 |         82 |      8,200 |
|   100 |      129,848 |   3.03× |      1,298 |        205 |     20,500 |
|   200 |      339,208 |   2.61× |      1,696 |        410 |     41,000 |
|   400 |      998,528 |   2.94× |      2,496 |        820 |     82,000 |

这里有两件事要分开看。

**arena 的代价是超线性的。** `bytes/node` 这一列就是直接证据:25 个节
点时每节点 804 字节,400 个节点时 2,496 字节——每多一个节点都比上一
个更贵。`×上一档` 这一列从另一面说同一件事:翻一倍要付 2.1–3.0 倍,
介于线性与二次之间,这正是「二次项搭在一个很大的线性项上」的样子。
(这个 spike 事先登记预期是「每翻倍大致 4 倍」;实测是 2.1–3.0 倍,而
`bytes/node` 那一列是同一事实的更好证据。)

二次项来自 layout 遍历。`layout_step` 为每个叶子往一个不断增长的数组
上 append 一个 `Draw`,而 `emo_array_append` 每次都分配一个
`8·(len+2)` 字节的单元格,于是 n 次 append 的代价是 Σ 8(j+2) ≈
**4n²**——在 n = 400 时对应实测 998 KB 中的约 645 KB。构建 children 的
那两条链只贡献线性项,因为每个 panel 固定是 20 个叶子(约 92n 字节);
剩下的来自逐节点分配:每个 `label()` 都要建一个 style `Map`,而一个
`Map` 是若干 arena 单元格。探针没有把最后这两项拆开,结论也不取决于
这个拆分。

在 400 个节点上,这就是**每次渲染约 1 MB**。60 fps 下约 60 MB/s,而且
永不停止。

**身份的泄漏是线性的、永久的。** 400 个节点时每次渲染泄漏 820 个身
份——每节点两个,一个 `VLeaf` 一个 `Draw`。60 fps 下约每秒 49,000 个
对象,每一个都是 `calloc` 出来的、永远无法释放的单元格。这才是让进程
走向终止的泄漏:它是 `malloc` 内存,引用计数永远不会归零,因为持有该
引用的那个 arena 数组本身也永远不会被释放。

### P2 —— 区域到底回收了什么

`probe2_region_clean.emo` 在一个区域内把 4,000 个 `Leaf` 实例建进
arena 数组,读一遍,只返回一个 `Int64`:

```console
outside the region  bytes=0 chunks=0 ids=0
inside  the region  bytes=563200 chunks=9 ids=4000
reset reclaimed     bytes=563200
outside the region  bytes=0 chunks=0 ids=4000
arena  : 563200 bytes in, 0 left  -> reclaimed
rent   : 4000 identities in, 4000 left  -> leaked
```

arena 被完全恢复到起点,连 chunk 都一样。而每一个身份都留了下来。这个
反差就是这个 spike 的核心结果,而且两端都不是舍入误差:100% 回收,
0% 回收。

### P3 —— UI 第一个会想到的那个边界

`probe3_region_escape.emo` 把区域关在组件库天然会提议的位置上——包住
`view()`。这是不安全的,而探针把失败演示出来,而不是论证出来:

```console
region open : children=60 (read inside the region)
region closed: reclaimed 18200 bytes; the arena now holds 104
the root instance is malloc'd, so it survived the reset...
the native Float64 480.0 survived too - it is a C double, not a cell
...but the array the instance holds was arena memory. Reading it now:
runtime error: only strings, Bytes, tuples, arrays, and Lists have a length
exit=70
```

实例单元格是 `malloc` 出来的,所以 reset 碰不到它;它持有的
`Array[VNode]` 是 arena 内存,所以 reset 碰到了。树的形状活了下来,内
容没有——那个悬空指针现在读到的是一格被投毒的单元格。
`emo_arena_reset` 在归还被回收的字节之前先填 `0xAA`,这不是合法的
cell kind,所以悬空值第一次解引用就会报出「单元格已损坏」,而不是读到
分配器碰巧留下的东西。读已释放内存无论如何都是未定义行为;投毒只是
让它每次都以同样的方式失败。

(reset 之后 arena 里还有 104 字节,不是 0:在顶层取 mark 之前,已经有
东西分配过。mark 在那里,但那里不是时间的起点。)

### P1 的第二组阶梯 —— 一个**确实**安全的边界上的区域

然后把区域挪到它能正确的位置上:包住整个事件,在取出 model 之后、丢
弃这一帧之前。穿过这个边界的只有一个 `Int64` model 和一个原生
`Float64` 光标。

| nodes | bytes/render | chunks | ids/render | 泄漏的 ids |
| ----: | -----------: | -----: | ---------: | ---------: |
|    25 |            0 |      0 |         41 |      4,100 |
|    50 |            0 |      0 |         82 |      8,200 |
|   100 |            0 |      0 |        205 |     20,500 |
|   200 |            0 |      0 |        410 |     41,000 |
|   400 |            0 |      0 |        820 |     82,000 |

arena 那一列平在 0 —— 区域把自己的活儿干得完美。身份那一列则**与不用
区域的那组阶梯逐档完全一致**。区域回收了字节,一个对象也没回收。

## 结论

这个 spike 在测量之前给自己定了三条判据。

**V1 —— 代价真实存在且在上升。通过。** 两列都单调上升;`bytes/node`
从 804 爬到 2,496。

**V2 —— 在现实节点数下代价足够大,且能看到超线性项。通过。** 400 个
节点时每次渲染约 1 MB,而 `bytes/node` 那一列就是这个超线性项本身。

**V3 —— 存在某个区域边界,能回收所述比例的这一帧字节,同时在 reset
之后不读取任何在区域内创建的东西。通过。** 事件级区域回收了 100%,且
没有读取任何被它释放的内容。

三條全过,按事先的说法就该是「动手实现」。让它走向反面的,是第四条事
实——判据没有预见到它,因为它与区域的边界无关,而与区域是由什么构成
的有关。

**arena 不是整个堆,而每个区域都横跨这条边界。** 身份——实例、闭包、
`Box`——是逐个 `malloc` 出来的,在 arena 之外,这是设计使然
(`emo_idcell_new`,`emo_c_runtime.c:121`)。而 arena 里的聚合体会
retain 它们存放的身份(`:390`、`:402`、`:407`、`:911`)。于是在 UI
里,区域内的每一个 children 数组都持有指向区域**之外**的引用,指向
reset 一无所知的 `malloc` 内存。一次生硬的区域 reset 可以释放字节,却
无法执行 release:它既不知道被回收范围内哪些字是指针,更不知道哪些是
身份。

两个后果都在上面的数字里看得见:

- reset 回收了 arena 字节,却回收了 0% 的对象泄漏——对象在边界的另一
  侧。
- 它丢掉了那些引用却没有 release,这让那些引用计数**永久无法恢复**。
  没有区域时,数组钉住它的身份,将来某个修复可以把两者一起释放;有了
  区域,数组的字节没了,身份被搁浅在一个谁也减不到零的计数上。

最显然的补救是把 arena 做过的 retain 记进日志、reset 时倒序回放。这份
日志的规模等于它要解决的问题:`emo_array_append` 在**每一次** append
时都会把**每一个**元素重新 retain 一遍(`emo_c_runtime.c:407-419`),
所以用 k 次 append 建一个 k 元素数组会做约 k²/2 次 retain。UI 建的
children 数组正好是这个形状,于是日志每次渲染都是二次的——和它要回收
的数据一样大。(这一条是读运行时源码得出的,不是测量得出的;探针接口
报的是单元格数量,不是引用计数的量值。)

**所以:不要为 T48.8 实现区域回收。** 它能在 400 个节点上买回约
60 MB/s 的 arena 增长,同时留下每秒约 49,000 个永远分配着的对象,而且
让这半边泄漏在以后更难修。把限制写进文档,把真正的修复排进计划。

## 这排除了什么,又剩下了什么

**排除:按 fiber 划分 arena。** 它诱人,因为一个跑完的 fiber 的 arena
可以完全不做分析就整块释放。但 `send` 传递的是指向共享 arena 的指针
并 retain 它们(`emo_c_runtime.c:1988`),`spawn` 的参数同理(`:1924`),
所以按 fiber 划分 arena 就要求对所有值语义家族做 copy-on-send——把逃逸
分析搬到并发模型的热路径上,是同一笔交易换了个更糟的位置。没有做原型。

**排除:让身份重新住回 arena**,这样区域就装得下它所持有的一切。那会
让生硬的 reset 变得安全,同时也会拿掉这个目标唯一的回收手段——T23.5
刚落地的那套引用计数。区域于是成为**唯一**的机制,而这会直接撞回 P3:
UI 能指认的边界并不总是「无物逃逸」的边界。

**剩下的:把引用计数扩展到值语义家族**——也就是这份代码库自己在
`CHECK.md:18` 里引用的 Swift 模型。支持它的理由比预期更充分。emitter
本来就是照着它写的:无论什么 kind,每个动态绑定都会 retain
(`emo_c.ml:1851`)、每个动态绑定在作用域退出时都会 release(`:423`);
而运行时的 `emo_retain`/`emo_release` 之所以对值语义家族是 no-op,唯一
原因就是 `emo_identity_kind` 的白名单只列了三种 kind(`:143`)。翻转这
份白名单就是运行时改动的大头;绑定层面不需要动 emitter。值语义家族不
可变、自底向上构建,因此没有环。

反对的理由在于代价落在哪里。pool 的契约是**语句**级的,而 arena 语义
让表达式内部的临时值——嵌套的 `emo_str_concat`、链式的 `.append`——
白白泄漏。要回收这些,就得把 `may_own` 扩展到所有动态类型并逐个审计
每个构造器:等于在子表达式粒度上,把 pool 存在的意义就是为了抹掉的
那套所有权分析重新引进来(`emo_c_runtime.c:1753`)。**那是一个里程
碑,不是一个前置条件。** 它应该按自己的节奏排期,而 T48.8、T48.9 应
当在 demo 规模上推进,并把这条限制写下来。

### 一条给 EmoUI 的附带发现

`Array` 没有 O(1) 的 append。`emo_array_append` 会复制并重新 retain
整个数组,旁边也没有别的 builder,所以**任何**动态尺寸的数组都是
O(k²) 的——而 `List`(O(1) 的双端队列)没有转回可索引 `Array` 的通道,
用它建 children 只是把二次的那一步挪到最后。EmoUI 已定的设计是
children 用一个显式的 `Array[Node]`(`docs/emo-ui.md` 决策 3)、每次
渲染重建,正好撞上这一点。在 T48.1 开始写可移植核心之前值得知道:要么
核心需要换一种 children 表示,要么这门语言需要一个廉价的数组 builder。

## 落地后的 `CHECK.md` 条目

这一节原本是拟议;该条目已于 **2026-10-14 落地**,以展开形式紧跟在
cross-target-invariants 那条之后——它就是那条第二项里已定的那一半:

> - `c` target long-running memory: **settled (2026-10-14, the
>   arena-scope spike) — region reclamation is not viable as a standalone
>   mechanism; the value families need refcounting, and that is its own
>   milestone.** …

于是判定里的「把真正的修复排期」有了名字:**M16 — 值语义家族的回收
(step 49)**,规格在 `plan/step-49-value-reclamation.md`。T48.8 与 T48.9
停在 demo 尺度并把限制写进文档,而不是被它闸住;而 `Array` 缺少 O(1)
append——下面那条附带发现——就是那一步的 T49.3。

`CHECK.md:37` 的另一半——`c` 目标的 `raise` 结束的是整个程序而不是当前
进程——是一个 GUI 同样会暴露出来的、与之相邻的问题,仍然未决。

## 复现

```sh
./build.sh && ./run.sh
```

`build.sh` 编译三个探针(预期并记录第一次链接的失败);`run.sh` 把每个
探针的输出与退出码和 `expected/` 做 diff。输出逐次运行都是确定的——
不打印任何地址——所以出现 diff 就意味着运行时变了,这正是把输出签入
仓库的用途。用 `EMO=/path/to/emo` 可以换编译器。

`build/` 是生成物、被忽略;`expected/` 是签入的。
