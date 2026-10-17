# 开发任务清单

> 中文版,与英文版 [docs/TASKS.md](../TASKS.md) 内容一一对应;更新英文版时请同步更新本文件。

从 `plan/step-01-project-scaffold.md` 起汇总而成的编号任务清单。plan 文件仍是规格说明——下面每个任务所属的步骤文件里有完整的目标、范围与验收标准。本文件是进度追踪表。

## 使用说明

- **编号规则:** `T<步骤>.<序号>` —— 步骤号对应 `plan/step-NN-*.md`。
- **利用闲余时间推进:** 步骤内的任务按顺序排列;完成任意前缀任务后,代码树都处于一致状态。步骤边界是检查点,此时仓库必须能构建且 `dune test` 全绿。
- **基本规则**(来自 `plan/README.md`):
  - 构建不红才开下一步,绝不在红构建上开始下一个步骤。
  - 根目录 `README.md` 是设计的唯一权威来源。下文标注了临时决定;依赖它的任务开工前,先在 `CHECK.md` / `README.md` 里落定。
  - 严格优先:尽早拒绝并给出清晰的诊断。不做自动修复、不做隐式补充、不做静默回退。
- **进度追踪:** 完成一个任务就在此勾选;步骤完成时同步更新 `plan/README.md` 的状态表。

## 里程碑

| 里程碑 | 步骤 | 完成标准 |
| --- | --- | --- |
| M1 — MVP 解释器 | 01–08 | 单文件 Emo 程序(函数、类、枚举、异常)可通过 `emo run` / `emo repl` 运行,错误信息可读。 |
| M2 — 编译期体验 | 09–11 | 渐进类型检查器、结构化模块系统、基于 MVS 的包解析;多包项目可构建、可运行。 |
| M3 — 并发与网络 | 12–13 | 基于效果(effect)调度器的进程与消息传递;直风格(direct style)网络 API。 |
| M4 — 编译目标 | 14–19 | 通过 `emo build` 生成原生代码;随后是 wasm / TypeScript / BEAM / riscv64。 |
| M5 — Wasm 运行时 | 20–22 | 用 Emo 编写的 WebAssembly 运行时:共享系统层,随后是二进制解码器/验证器,再是解释器与 spec 套件金测。 |
| M6 — 自包含托管后端 | 23 | `emo build --target c` 发射 C、自带运行时、直接 C ABI——hosted-native-FFI 评估已排期;解锁自包含工具分发(CHECK.md)。 |
| M7 — 工具链 | 24 | 工具链发布:GitHub Releases 上的按平台签名 `emo` 二进制(brew/opam 作为源码构建渠道);仅有二进制的机器即可运行并构建 Emo 程序;`emo new` / `emo deps` / `emo doctor` 补齐命令集。 |
| M8 — Target 独立 | 25 | 每个 target 的运行时都活在 target 自己的生态里——以内嵌生成数据(c、ocaml、typescript)或编译进发射模块(wasm、beam)的形态存在——绝不在二进制旁、也绝不在宿主构建树里;宿主只贡献发射器。 |
| M9 — For / While 循环 | 26–27 | 已定案的循环面在解释器与全部六个 target 上逐字节运行:`for`(三子句,头部 `var` 作用域限定在循环)与 `while`,搭配裸 `break`/`continue`;循环在任何栈上都不增长;尾调用保证不变。 |
| M10 — 错误处理 | 28–30 | Erlang 式分界落地:预期内的失败返回 `(R.ok, value)` / `(R.error, reason)`,用 `case` 匹配或用绑定模式断言绑定;违例抛出唯一的 `Exception` 类;stdlib 的 raise 点逐包迁移到新约定——所有 target 逐字节一致,`R` 一并抵达 freestanding 层。 |
| M11 — 标准库 | 31–38 | 随编译器交付的 stdlib 各包——`json`、`yaml`、`xml`、`os`、`base64`、`slog`、`bufio`,以及首个原生绑定包 `sqlite3`——逐一按 manifest 的 `targets` 解析,在它声明的每个 target 上逐字节一致,并各自附完整 API 参考与可运行金测。 |
| M12 — 可视化(`plot`) | 39–45 | `plot` 包补齐其 T0 表面(连续轴;line / scatter / area / histogram mark;对数标度、域、图例、网格、主题、调色板、分面)与 T1 数据集图表,随后加入终端与 PNG 渲染器——SVG 输出在全部五个宿主 target 上逐字节一致。 |
| M13 — 单元测试 | 46 | `emo test` 发现项目的 `test/` 目录并逐个运行其中的顶层 `def test_*`,带逐测试隔离、报告与退出码族;`expect_*` 断言内建失败时抛出唯一的 `Exception` 类(解释器内;编译 target 诚实地拒绝);脚手架、示例、测试与文档一同落地。 |
| M14 — CSV 读写 | 47 | 随编译器交付的 `csv` 包——RFC 4180 记录,只认 UTF-8——像其他 stdlib 包一样解析,在全部五个 target 上逐字节一致,并附 API 参考与可运行金测。 |
| M15 — EmoUI | 48 | 一套声明式 EmoUI 树渲染到终端、服务端页面、macOS/AppKit 窗口与 GTK 4 窗口(浏览器 DOM 随后按其运行时路径接入),各自只落在一个薄薄的每平台入口后面;共享 app 模块是可移植的 Emo,组合语法处处一致,各平台组件库共享收敛命名。EmoUI 各包活在本仓库的 `projects/emo-ui/` 下,编译器侧关口与终端输入包也落在本仓库(`CHECK.md`,in-tree 项目布局)。 |
| M16 — 值语义家族的回收 | 49 | `c` 目标回收值语义的那些种类,而不只是身份格:长跑程序每次渲染的 arena 字节与身份存活数保持平坦,而不是随事件上涨;数组增长是线性而非二次;每个 target 上既有的金测逐字节不变(`spike/arena-scope`、`CHECK.md`)。 |
| M17 — 跨 target 一致性 | 50 | 兑现已经做出的承诺,而不是新设计:`c` 目标里子进程 raise 只结束子进程、`send` 送的是快照,`foreign def` 在 `wasm` 与 `beam` 上按名拒绝;每个 target 上既有的金测逐字节不变(`CHECK.md`)。 |
| M18 — `c` 目标上的 TLS | 51 | 既有三个 `net` TLS 内建在默认 target 上运行:C 运行时以手写原型与按 IR 判定的条件链接落在系统 OpenSSL/LibreSSL 上(不用 TLS 的构建绝不链接 OpenSSL),ocaml 调度器的语义与 reason 约定保持一致,`http` 的 `https://` 在 `c` 上端到端可用(`CHECK.md`)。 |

## 设计闸门

`CHECK.md` 中记录、并阻塞下述任务的未落定决策。开始被闸门挡住的工作之前,先落定它们:

| 决策 | 阻塞的任务 | 落定前的临时方案 |
| --- | --- | --- |
| CLI 命令名 | T01.3、T08.1–T08.2 | 已在 M1 落定——`run` / `repl` / `check` / `version` 已随 M1 交付 |
| 字符串转义规则 | T02.3、T02.4 | 最小集合 `\n \t \\ \' \"` |
| 进程获取自身 pid 的机制 | T12.1 | 已落定——`self_pid()` 内置、`Pid` 类型渲染为 `<pid N>`、`halt()`;核心不提供用户态 kill/wait |
| 错误处理模型(原:异常捕获语法) | T13.5、M10 | 已定案 2026-10-11——无 catch;`(R.ok, value)` / `(R.error, reason)` 元组 + 唯一的 `Exception` 类(`CHECK.md`);步骤 28–29 落地 |
| 清单/锁文件文件名、scope 前缀格式、版本区间、deps CLI 命令名 | T11.2、T11.5–T11.6、T11.8–T11.9 | `package.emo`、`package.lock`、`owner/name`、仅精确版本、`emo deps *`;deps 的键是字符串字面量(T11.9) |
| C FFI 绑定表面语法 | T14.6 | 已落定——`foreign def name(params) Ret = "c_symbol"`,仅 `Float`/`String`/`Bool`,经生成的 C 包装器编组 |
| 动态世界的回收模型(无追踪 GC) | T23.5 | 已落定——身份对象用引用计数、值语义数据走 arena(`CHECK.md`,T23.5 落定) |
| `emo build` 默认 target | T24.1 | 由 `ocaml` 翻转为 `c`:分发的二进制不携带 OCaml 工具链;`ocaml` target 保留给源码构建安装 |
| 标准库:内嵌 vs 旁挂目录 | T24.2 | 内嵌为编译器内的生成数据(C 运行时的同一机制);`EMO_REGISTRY` 覆盖保留 |
| `emo install` 语义 | T24.4 | 已落定后被取代(2026-10-17)——该命令已移除;resolve/fetch/lock 由 `emo deps` 与构建路径承担,全局可执行文件安装仍不进 1.0 范围 |
| 运行时独立原则 | T25.1 | target 的运行时用 target 的语言写,以生成数据随编译器内嵌;宿主只贡献发射器 |
| ocaml 运行时的依赖策略 | T25.4 | 核心用 OCaml 标准库加 `unix`;`ssl` 是唯一的 opam 依赖,缺失时以清晰消息拒绝;不用 eio |
| EmoUI 原生 UI 打包(per-package 编译 flags / `pkg_config`) | T48.7–T48.9 | 方向已定(2026-10-14)——manifest 长出 per-package 原生字段,原生后端不再以应用级构建脚本发布(`CHECK.md`、`docs/emo-ui.md`)。字段面(`pkg_config`、编译/链接 flags、`.m` 是否收集)仍属 T48.7 自己的范围 |
| `c` 目标的长跑内存(值语义家族的回收) | T48.8–T48.9(demo 尺度)、step 49 | 已定(2026-10-14)——region 回收不可行;值语义家族需要引用计数,作为 step 49 排期(`CHECK.md`、`spike/arena-scope/`)。在它落地之前,原生 UI 后端停在 demo 尺度并把限制写进文档,而不是被它闸住 |
| EmoUI 浏览器运行时路径 | T48.10–T48.11 | 已定(2026-10-15)——走拆分路线:把 TypeScript 运行时拆出浏览器安全子集、加 `dom_*` 家族,再配一个打包步骤,而不是新增 wasm 宿主 import(`CHECK.md`、`docs/emo-ui.md`)。打包步骤在工具链里的落点仍属 T48.10 自己的范围 |
| 跨 target 一致性(`c` 的 raise、`c` 的 send、`foreign def` 在 `wasm`/`beam` 上) | step 50 | 已定(2026-10-15)——这是对已经做出的承诺的一致性修复,不是新设计:子进程 raise 只结束子进程、`send` 送快照、两个 emitter 按名拒绝 `foreign def`(`CHECK.md`)。`typescript` 目标 send 仍共享这一项保持开放 |
| 数组增长(O(1) 的 append 还是一个 builder) | T48.1、T49.4 | 已定(2026-10-15,T49.3)——走 builder,并且是语言层的新类型 `ArrayBuilder`,而不是 `Array` 的表示层改动(`CHECK.md`、`docs/intro/syntax.md`);从 `List` 转回 `Array` 那一半刻意不做 |
| in-tree 项目布局(`projects/`) | M15 全部 | 已定(2026-10-15)——仓库根的 `projects/<仓库名>/` 存放每个具名 Emo 项目(EmoUI、EmoOS、EmoShell),以它将来可拆分出去的仓库命名;EmoUI 仍不是标准库包(`CHECK.md`) |
| 终端输入的位置(T48.5) | T48.5 | 已定(2026-10-15)——raw mode 是一个标准库包,形状同 `sqlite3`(包自带 `.c`/`.h`,经 `foreign def` 调用,由 `targets` 把关),不是 UI 框架侧或编译器侧的产物(`CHECK.md`、`docs/emo-ui.md`) |
| `c` 目标上的 TLS(链接判定、原型、Windows) | step 51 | 已定(2026-10-17)——既有三个 `net` TLS 内建落在 C 运行时、链系统 OpenSSL/LibreSSL:`c` emitter 的 IR 走查闸住 `EMO_HAS_TLS` + `-lssl -lcrypto`,原型全部手写(不依赖任何 OpenSSL 头文件),下限是 API 子集(OpenSSL ≥ 1.1.1 / LibreSSL ≥ 3.5.0),Windows 保持拒绝(`CHECK.md`、`plan/step-51-tls-c-target.md`) |

---

## M1 — MVP 解释器

### 步骤 01 — 项目脚手架与 CLI 骨架 · `plan/step-01-project-scaffold.md`

**前置:** 无。
**完成标准:** 干净检出后 `dune build` 和 `dune test` 通过;`emo version` 输出 `emo 0.0.1`;占位子命令以非零码退出;CI 在 Linux 和 macOS 上全绿。

- [x] **T01.1** — 创建 `dune-project` 和 `src/` 各库骨架(`emo_support`、`emo_lexer`、`emo_parser`、`emo_ast`、`emo_eval`、`emo_check`、`emo_cli`),用能编译的占位模块填充。
- [x] **T01.2** — 实现 `emo_support`:span、severity、diagnostic、渲染器;为渲染器写单元测试。
- [x] **T01.3** — 用 cmdliner 实现 `emo_cli`;把四个子命令接到占位动作上。
- [x] **T01.4** — 为每个库添加 alcotest 冒烟测试和 CI 工作流(setup-ocaml、`dune build`、`dune test`,Linux + macOS)。
- [x] **T01.5** — 添加 `.ocamlformat`(conventional profile);整体格式化一次(`dune build @fmt` 通过)。

### 步骤 02 — 词法分析器 · `plan/step-02-lexer.md`

**前置:** 步骤 01。
**完成标准:** 测试覆盖所有 token 类别、插值嵌套(`"a ${ "b ${x}" } c"`)、多行输入的位置精度,以及每个错误用例;`dune test` 全绿。

- [x] **T02.1** — `emo_lexer` 中的 token 类型与带位置的 token 流。
- [x] **T02.2** — 两类标识符(`LOWER_IDENT` / `UPPER_IDENT`)、关键字、运算符。
- [x] **T02.3** — 数字与字符字面量,含转义处理。
- [x] **T02.4** — 插值字符串的 token 方案,带嵌套测试。
- [x] **T02.5** — 保留换行信息的流式 API。
- [x] **T02.6** — 错误用例:每个都经 `emo_support` 以正确的行列号拒绝。

### 步骤 03 — 解析器:表达式 · `plan/step-03-parser-expressions.md`

**前置:** 步骤 02。
**完成标准:** README 中的每个表达式片段都解析为预期 AST(金测/golden 测试);优先级被固定(`1 + 2 * 3`、`a && b || !c`、`x.foo(1)[i].bar?()`);`dune test` 全绿。

- [x] **T03.1** — `emo_ast` 的表达式/语句类型,每个节点都带 span。
- [x] **T03.2** — 按优先级表实现的 Pratt 式表达式解析器。
- [x] **T03.3** — 调用解析:位置参数 + 具名参数、尾随块语法糖。
- [x] **T03.4** — 箭头块;`if` / `else`(单一形态,无链式)。
- [x] **T03.5** — 带深度追踪的换行终止规则。
- [x] **T03.6** — 从词法部分重组插值字符串。
- [x] **T03.7** — 解析器测试:优先级表、行尾悬空运算符的续行、非法输入报错。

范围说明:按内容规则解析的元组字面量、元组模式、`case` / `receive` / `do` / 发送语法都在本步骤内完成解析(语义在步骤 05 / 11 之前保持"尚未实现"错误)。

### 步骤 04 — 解析器:声明 · `plan/step-04-parser-declarations.md`

**前置:** 步骤 03。
**完成标准:** README 中的 `User`、`Greeter` / `English`、`welcome`、`Color` 片段解析为金测 AST;反向测试(camelCase `def`、`UPPER` 变量、枚举载荷、重复 `init`、给 `init` 标返回类型)以正确的消息和 span 拒绝;`dune test` 全绿。

- [x] **T04.1** — 声明 AST 节点;顶层项序列。
- [x] **T04.2** — `def` 解析,含 `init` 豁免与 `?` 命名规则。
- [x] **T04.3** — `class`(单一 `init` 规则,从 `self.x =` 收集字段)。
- [x] **T04.4** — `interface` 仅签名的类体。
- [x] **T04.5** — `enum` 成员列表。
- [x] **T04.6** — `raise` 语句。
- [x] **T04.7** — 带 span 的命名规范检查;多错误恢复。
- [x] **T04.8** — 金测:README 示例干净解析;违反命名规范产生预期错误。

### 步骤 05 — 解释器:核心值与求值 · `plan/step-05-interpreter-core.md`

**前置:** 步骤 04。
**完成标准:** 验收程序可运行(`fib(20)` → 6765、插值问候语、`count_down(1000000)` 且栈保持平坦);`dune test` 全绿,含深递归用例。

- [x] **T05.1** — 值 ADT + 相等性;环境链。
- [x] **T05.2** — 带 tag 检查运算符的表达式求值。
- [x] **T05.3** — 插值;`print` 内建;`.to_string()`。
- [x] **T05.4** — 闭包捕获(词法作用域,按引用指向环境)。
- [x] **T05.5** — 求值器中的尾调用循环;深递归测试。
- [x] **T05.6** — `if` / `return` 语义;带 span 的运行时类型错误。
- [x] **T05.7** — 端到端运行真实程序的 alcotest 测试(断言捕获到的 stdout)。

范围说明:数组、元组和 `Box`(三个操作构成的完整操作集)都属于本步骤的值模型。`print` 是临时名字——I/O 表面设计落定后提升进 README。

### 步骤 06 — 解释器:类、枚举、接口 · `plan/step-06-interpreter-objects.md`

**前置:** 步骤 05。
**完成标准:** README 的对象示例原样可跑(值语义的 `User`、`Color`、鸭子类型的 `welcome`、结构化的 `is()`);反向测试(在 `init` 之外 `self.x =`、调用缺失方法、未捕获 raise)按规格报错;`dune test` 全绿。

- [x] **T06.1** — `ClassDef` / `Instance` 值;`init` 窗口标记;字段冻结。
- [x] **T06.2** — 方法分派 + `self`;`NoMethodError`。
- [x] **T06.3** — 实例的深 `==`;共享结构的不可变性测试。
- [x] **T06.4** — 枚举单例;`TypeValue`;带结构化接口检查的 `is()`。
- [x] **T06.5** — `raise`;内建 `Exception`;未捕获异常终止。
- [x] **T06.6** — 实例、枚举、异常的 `.to_string()`。

### Step 07 — 函数组(`emo` 关键字)· `plan/step-07-function-group.md`

**前置:** Steps 01–06。
**完成标准:** `emo Foo { def ... const ... }` 声明函数组,`Foo.hello()` / `Config.version` 在解释器与四个后端上解析并运行(金测进 CI),README 记录该语法。

- [x] **T07.1** — 解析器(`emo` 关键字 + 组成员)、检查器(组符号、命名与参数规则)、IR 降级为带前缀的函数;`examples/function_group/` 金测走 `emo run`。
- [x] **T07.2** — 该示例的 TypeScript、wasm、beam 金测;README(英文 + 中文)记录该语法。

收尾:两个任务随同一提交(`bd2f4c7`)落地:组成员降级为带前缀的函数,符号双键注册(组限定键 `Foo.hello` 与组内裸引用键),四个后端无需任何组相关代码。展示用例(`examples/showcase/`,连带其拉出的 TypeScript 进程支持)在四个目标上演练跨文件组调用。它还暴露并修复了 `emo_project` 的一个缺陷:以相对路径启动的 manifest 项目注册的是相对文件串,绝对路径的入口查找落空,入口被降级两次——一次作为根模块,一次以自身模块名。决策见 `plan/step-07-function-group.md`(Close-out)。**Step 07 验收达成。**

### 步骤 08 — CLI 与诊断 · `plan/step-08-cli-diagnostics.md`

**前置:** 步骤 01–07。
**完成标准:** 每个 `examples/*.emo` 在 CI 中以预期输出运行;含三个解析错误的文件一次报告全部三个、行列号正确、`--no-color` 下稳定;REPL 可交互运行步骤 06 的验收块。**达成 M1 完成标准。**

- [x] **T08.1** — `run` 命令,含阶段流水线与退出码(词法/解析 65,求值 70,未捕获异常 1)。
- [x] **T08.2** — REPL:多行读取、持久环境、值回显。
- [x] **T08.3** — 诊断渲染器完善(源码摘录、错误码、提示、颜色、错误上限);基于金测渲染的单元测试。
- [x] **T08.4** — 求值器中的未捕获异常追踪管道。
- [x] **T08.5** — `examples/` 金测接入 CI。
- [x] **T08.6** — 人工过一遍:运行每个示例,交互使用 REPL。

收尾说明:把 M1 验证过的临时决定(`print`、尾随块语法糖)提升进 README。

---

## M2 — 编译期体验

### 步骤 09 — 渐进类型检查器 · `plan/step-09-type-checker.md`

**前置:** 步骤 01–08。
**完成标准:** 每个 README 示例类型检查干净;带类型声明的错误语料(错误返回类型、非法具名参数、`var` 逃逸、收窄误用)以正确 span 拒绝;零误报纸料通过且无任何诊断;`emo check` 可用,且 `emo run` 先跑同一检查。

- [x] **T09.1** — 类型表示 + 类型声明收集 pass。
- [x] **T09.2** — 在 `Unknown` 纪律下的语句/表达式检查。
- [x] **T09.3** — 签名检查;箭头块推断。
- [x] **T09.4** — 基于 `is()` 收窄的流敏感环境。
- [x] **T09.5** — 结构化接口一致性。
- [x] **T09.6** — `var` 逃逸检测。
- [x] **T09.7** — 调用点检查;具名参数校验。
- [x] **T09.8** — `case` 检查:模式类型化、`when` 守卫须为 `Bool`、可判定枚举的穷尽性,以及可判定 `(Enum, ...)` 元组的首元素穷尽性(带守卫的分支不计入覆盖)。
- [x] **T09.9** — `emo check` 命令;接入 `emo run`。
- [x] **T09.10** — 测试类别:严格类型声明拒绝、推断成功、零误报纸料。

后续:选定的 `var` 逃逸分析近似方案已记于 `docs/var-escape.md`。

### 步骤 10 — 结构化模块系统 · `plan/step-10-modules.md`

**前置:** 步骤 01–09。
**完成标准:** README 的 `shop/` 目录树原样可跑(路径即模块、`const` 别名);从 `shop` 之外引用 `shop.internal.discounts` 报错并同时点名两个模块;两模块循环被拒绝并给出完整链路;多文件测试全绿。

- [x] **T10.1** — 模块路径解析(文件 ↔ 模块名;冲突即错误)。
- [x] **T10.2** — 惰性 `Module` 值接入求值器的成员访问。
- [x] **T10.3** — 加载顺序编排;仅加载一次语义。
- [x] **T10.4** — 检查期间提取引用图。
- [x] **T10.5** — `internal/` 子树私有检查。
- [x] **T10.6** — 带链路报告的循环检测。
- [x] **T10.7** — 按内容哈希的进程内缓存。
- [x] **T10.8** — `examples/` 下镜像 README `shop/` 树的多文件测试项目。

注意:已在步骤 11 解决——项目以工作目录为根,该目录必须放着 `package.emo`(T11.10);它之上的目录永不查找。

### 步骤 11 — 包与版本解析 · `plan/step-11-packages.md`

**前置:** 步骤 01–10。
**完成标准:** README 的 `require "acme/json_tools"` 场景对固定注册表(fixture registry)可跑通;从 `deps` 移除依赖但 `require` 仍在是编译错误;冲突的精确版本解析为最高版本且第二次运行校验锁文件校验和;`targets` 不含当前目标的依赖在解析期报错。**达成 M2 完成标准。**

- [x] **T11.1** — `require` 解析 + 作用域规则。
- [x] **T11.2** — 清单阶段 A:严格 schema 解析器,带 span 报错。
- [x] **T11.3** — 严格的 require/deps 配对检查。
- [x] **T11.4** — 带目标兼容性闸门的 MVS 解析器;针对版本格(unit lattice)的单元测试。
- [x] **T11.5** — 锁文件读/写/校验;不匹配报错。
- [x] **T11.6** — 注册表客户端 + 内容寻址缓存 + 供测试的目录注册表。
- [x] **T11.7** — 清单阶段 B:带步数预算的受限 profile 求值。
- [x] **T11.8** — 端到端 fixture:两个本地包,其一依赖另一,解析、锁定、构建、运行。
- [x] **T11.9** — `deps` 的键是字符串字面量:deps 块唯一的写法,于是包名不再是词法层面必须接受的东西。**2026-10-15 落地**,横跨解析器、清单求值器与 `emo_pkg`。清单现在有自己的解析 profile(`parse_program_in ~manifest:true`,唯一调用方是 `Emo_pkg.parse_manifest`):在这个 profile 里,以字符串为赋值目标的就是依赖名,以标识符为目标的仍是包字段;把带 scope 的名字折成 `Ident` 的那个 `a / b` 折叠被删掉,它喂养的那条已不可达的 `E4015` 带 scope 包名检查一并删除。以字符串为键的字段是 `E5102`,所以打错的字段不会再被静默丢弃;依赖名为空是 `E5102`;`deps` 里出现的杂散语句是 `E5104`。理由是:`emo` 是保留字,于是本仓库自己的包没法把 scope 写成 `emo/ui` ——而名字在其它地方本来就是数据(`name` 字段、`require`、锁文件、注册表),键是它唯一一处伪装成代码的地方。29 份清单完成迁移(`examples/**`、`benchmarks/http_echo`、五个标准库包、emo-ui 的 golden),所有已提交的锁文件重新解析,`projects/emo-ui/` 的包名现在是 `emo/ui`。同一天,`emo check <FILE>` 补上了编辑器早已采用的规则:`package.emo` 按清单读取而不是按模块读取,两者对清单的说法因此一致(规则只有一处,在 `Emo_pkg.is_manifest_file`),T11.7 取代掉的 token 级 phase-A 清单辅助代码也一并清除。`emo run` 与 `emo build` 把清单当入口时直接拒绝(退出码 66),不再把它当程序读——清单在任何读取方那里都是数据,需要程序的命令会告诉你该写哪个模块。

- [x] **T11.10** — 根就是你站的地方:项目就是工作目录,而它必须放着 `package.emo`。**2026-10-16 落地。** 沿入口文件向上找最近清单的那套查找已删除——当天定下的规则只看 cwd,于是缺 `./package.emo` 是 **E5010**(``run `emo new <name>` to scaffold a project here``,span 落在该目录上),不属于那里所扎根的包的入口是 **E5011**(span 落在入口上),两者都经 `Static_errors` → 65。理由是:旧查找让无清单的目录树悄悄变成一个以 cwd 为根的项目——在仓库根跑 `emo check examples/alias_demo/main.emo` 会检查整个仓库并报出别的示例的错误——也让同一个文件随命令敲在哪里而指不同的事。每个缺清单的可运行目录树各补了一份(16 个 `examples/`、7 个 `benchmarks/`、6 个 `spike/`,以及发布 workflow 的 smoke 项目),每个测试调用现在都站在它所扎根的目录里。LSP 同样收紧:只有当交给它的根放着 `package.emo` 时才索引该项目,每个 workspace 只说一次,并且 `scan` 像编译器 `walk` 那样跳过嵌套的包。同时这里:foreign 参数的约束现在按限定名解析,于是 `c` 目标上指向入口模块内声明的类型的 `foreign def` 能解析了——这是被旧的独立入口构建掩盖住的一个潜在 bug。

同时:把步骤 10 的过渡性根规则换成基于清单的根规则——已完成;根就是工作目录,而它必须放着 `package.emo`。

---

## M3 — 并发与网络

### 步骤 12 — 进程与消息传递 · `plan/step-12-concurrency.md`

**前置:** 步骤 01–11。
**完成标准:** 乒乓(100 万条消息)与扇出/扇入(1000 个 worker)在 Eio 版和自研 effects 调度器下都正确;消息处理中途 raise 的进程独自死亡、父进程继续;发送 `Box` 送达快照;递归数百万次的 receive 循环保持原生栈平坦;确定性调度器下 `dune test` 全绿。

- [x] **T12.1** — 设计 pass:在 `CHECK.md` / README 中落定自 pid 机制(`do`、`<-`、`receive { ... }` 与 `Box` 操作集均已决定)。本步骤其余任务的前置闸门。
- [x] **T12.2** — 基于 Eio 的进程/邮箱抽象;spawn/send/receive。
- [x] **T12.3** — 崩溃隔离;供未来监督者使用的进程退出信号。
- [x] **T12.4** — 快照随发送语义的 `Box`。
- [x] **T12.5** — 供测试用的确定性调度器日志。
- [x] **T12.6** — 阶段 B:同一接口之下的自研 effects 调度器。
- [x] **T12.7** — 压力测试:乒乓、扇出/扇入、深 receive 循环递归。

### 步骤 13 — 网络库 · `plan/step-13-networking.md`

**前置:** 步骤 01–12。
**完成标准:** 一个 Emo HTTP 服务器 + 客户端在 localhost 上于单个 `emo run` 程序内完成往返,全程直风格;超时与连接被拒各自以精确消息抛出 Emo 异常;对测试证书的 TLS 握手在校验失败时拒绝连接。**达成 M3 完成标准。**

- [x] **T13.1** — 调度器之上的 TCP socket 表面;优雅关闭语义。
- [x] **T13.2** — UDP + Unix 域套接字。
- [x] **T13.3** — 走同一挂起路径的 DNS 解析。
- [x] **T13.4** — OpenSSL TLS 绑定;证书校验错误以 Emo 异常呈现。
- [x] **T13.5** — HTTP 客户端;带每连接一进程辅助器的 HTTP 服务器。
- [x] **T13.6** — 带目标元数据的标准库打包;fixture 式集成测试(回环监听、顺序确定)。

收尾说明:`net.*` / `http.*` 的确切名称已写入 README(Networking 一节);标准库以 `stdlib/registry` 下的目录注册表包形式发布,当时为 `targets = ["native"]`(现为 `["ocaml", "c"]`);验收示例为 `examples/http_roundtrip`。步骤决策见 `plan/step-13-networking.md`(Close-out)。**M3 退出标准已达成。**

后续:本步骤落定后,把标准库的准确模块/方法名(`net.*`、`http.*`)写进 README。

---

## M4 — 编译目标

### 步骤 14 — 原生后端 · `plan/step-14-native-backend.md`

**前置:** 步骤 01–13。
**完成标准:** 每个 `examples/*.emo` 都编译为输出与 `emo run` 完全一致的原生二进制(CI 中金测对比);特化后的数值代码在基准测试中显著优于未特化构建;`emo build` 构建的每连接一进程 HTTP 服务器通过负载测试;基准结果被记录。

- [x] **T14.1** — IR 定义 + 已检查 AST 的 lowering。
- [x] **T14.2** — 阶段 A:OCaml 发射、运行时链接、单二进制输出。
- [x] **T14.3** — 带增量缓存的 `emo build`。
- [x] **T14.4** — 接入 CI 的基准集(记录数字,而非只记通过/失败)。
- [x] **T14.5** — 阶段 B:以步骤 09 完整性检查为前置的类型驱动特化 pass(去装箱、直接分派)。
- [x] **T14.6** — C FFI 链接路径,待绑定表面语法落定后进行(被阻塞——先在 `CHECK.md` 落定)。
- [x] **T14.7** — 引导测试:`examples/` 全套编译出的二进制与解释器输出逐字节一致。

收尾:阶段 A 发射 OCaml 源码(权衡记录在 `docs/zh-CN/ocaml-backend.md`);IR 位于 `src/emo_ir`,含阶段 B 的 `specialize` 不动点,T14.5 的特化随 T14.1/T14.2 提交交付。`foreign def` 按上表落定,经生成的 C 包装器编组(`emo build` 用 `cc` 编译它们);`Float`/`String`/`Bool` 可跨边界,其余类型以 E4200 拒绝。基准:`benchmarks/results.md` 记录 fib(30) 未特化 345ms 对特化 212ms(约 1.6 倍)、ping-pong、JSON 扫描,以及 HTTP echo 负载测试 112 req/s。引导:全部五个示例构建的二进制与 `emo run` 逐字节一致(`test/emo_project` 的 `bootstrap` 套件)。决策见 `plan/step-14-native-backend.md`(收尾)。**步骤 14 验收达成。**

### 步骤 15 — 其余目标:wasm、TypeScript、BEAM、riscv64 裸机 · `plan/step-15-other-targets.md`

**前置:** 步骤 01–14(按目标)。这些是路线条目,不是可直接执行的计划——每个目标排期时独立成步骤文件。推荐顺序:Wasm → TypeScript → BEAM → riscv64。

- [x] **T15.1** — 某目标排期时,把它拆成完整标准格式(目标 / 范围 / 任务 / 验收)的 `step-NN-<target>.md`,并更新 `plan/README.md` 的状态表;其任务延续编号(`T17.*`,……)。
- [ ] **T15.2** — 记录每个目标落定了哪些关键决策、落定在哪(README / `CHECK.md` / docs)——保留轨迹。

各目标需落定的关键决策:Wasm —— WasmGC vs 自定义 GC(两者都先做原型);TypeScript —— 直风格到事件循环的映射、进程映射;BEAM —— 类的值语义 vs Erlang maps;riscv64 —— 可插拔运行时、链接脚本(风险最高;`core` 库分层应提前)。

晋升轨迹:**TypeScript → `plan/step-17-typescript.md`**(2026-10-02,首个目标;其关键决策——IR 降级、统一 async、协作式任务——已在那个文件落定)。**Wasm → `plan/step-16-wasm.md`**(2026-10-02,第二个目标;GC 问题已落定——WasmGC,结构体与数组 + RTT 分派,无自定义堆)。推荐顺序中下一个是 BEAM。

### 步骤 16 — Wasm 目标(WasmGC)· `plan/step-16-wasm.md`

**前置:** 步骤 01–15。
**完成标准:** `emo build --target wasm` 产出可运行于 Node WasmGC 的 `.wasm`(附带 `.wat` 可读形式),核心子集(hello_world、fib、objects、language_tour、shop)输出与 `emo run` 逐字节一致(CI 金测),且依赖缺少该 target 的包在发射前就被解析门拒绝。

- [x] **T16.1** — 后端骨架:`--target wasm` 管线(解析门读取 target);WAT 中间形式;二进制编码器;装箱结构体值模型 + RTT 分派。金测:hello_world、fib、objects。
- [x] **T16.2** — 完整核心语义:模式与守卫、元组、数组、Box、插值、内容相等、接口窄化、跨文件模块引用。金测:language_tour、shop。
- [x] **T16.3** — 引导:CI 中的 wasm 子集金测,以及缺 `"wasm"` 包的解析门拒绝测试。
- [x] **T16.4** — 并发:模块内协作式驱动实现 `do` / `<-` / `receive`,宿主定时器抢占点。金测:pipeline。(以 T16.2 为前置。)
- [ ] **T16.5** — WASI 与 IO 审计:标准库 `"wasm"` 元数据,以及宿主支持范围内的 io 金测。

### 步骤 17 — TypeScript 目标 · `plan/step-17-typescript.md`

**前置:** 步骤 01–16。
**完成标准:** `emo build --target typescript` 发射的 TypeScript 在 Node 上运行,示例子集(hello_world、fib、objects、language_tour、shop、pipeline、tcp_echo、http_roundtrip)的输出与 `emo run` 逐字节一致(CI 金测),且依赖缺少该 target 的包在发射前就被解析门拒绝。

- [x] **T17.1** — 目标管线与核心发射器:`--target` 贯穿 CLI、项目与解析门;IR → TypeScript 核心子集发射器;带标签值的运行时。金测:hello_world、fib、objects。
- [x] **T17.2** — 完整核心语义:模式与守卫、元组、数组、Box、插值、内容相等、跨文件模块引用。金测:language_tour、shop。(2026-10-17 完成:两个示例加入 `ts_golden_tests`,其 manifest 声明 `"typescript"`。emitter 本身已覆盖这些语义,缺的是金测钉住,因此没有后端改动。)
- [x] **T17.3** — 并发:协作式任务、邮箱、选择性 receive、`self_pid`、`halt`。金测:pipeline。
- [x] **T17.4** — 直风格 IO:socket 与 HTTP 经 Node API 包装为 await 的 promise;标准库 target 元数据加 `"typescript"`。金测:tcp_echo、http_roundtrip。(2026-10-12 完成:`net` 的全部能力经 `E.builtin` 搭在 `node:net`/`node:dgram`/`node:tls`/`node:dns` 上,每连接一个常驻 reader。root 进程结束时释放存活的 handle,让事件循环自然排空,与原生规则一致。`net`、`http` 声明 `"typescript"`;tcp_echo 与 http_roundtrip 进入该目标的金测。`c` 目标仍只覆盖 TCP;`http` 服务端块重复关闭连接的问题——原生调度器掩盖、TypeScript 目标暴露——已修复。)
- [x] **T17.5** — 引导:CI 中的按 target 金测套件,以及缺 target 包的解析门测试。(2026-10-17 完成:`pipeline` 加入 `ts_golden` 组,补全上述子集;解析门补齐拒绝与接受两个测试,与 `wasm` 的那一对同形。)

收尾:按 target 的金测组(`ts_golden`)钉住了上述子集——共 25 个示例——解析门的拒绝与接受两种情况都有测试。决策见 `plan/step-17-typescript.md`(决策轨迹)。**Step 17 验收达成。**

### Step 18 — BEAM 目标(Core Erlang)· `plan/step-18-beam.md`

**前置:** Steps 01–17。
**完成标准:** `emo build --target beam` 发射 Core Erlang 文本并由 `erlc` 汇编为 `.beam`,核心子集(hello_world、fib、objects、language_tour、shop、pipeline)与 `emo run` 输出逐字节一致(CI 金测),解析门读取 `"beam"`。

- [x] **T18.1** — 后端骨架:`--target beam` 管线;Core Erlang 发射器(模块、定义、字面量、call/apply、序列化),对照已探明的 OTP 29 文法。金测:hello_world。
- [x] **T18.2** — 值模型与算术:掩码 i64 回绕 Int64、binary 字符串与插值、元组、数组、枚举、深内容相等。金测:fib。
- [x] **T18.3** — 类/实例(带标签 map)、Box 持有进程、闭包即 fun、case 模式与守卫。金测:objects、language_tour。
- [x] **T18.4** — 进程(`do` / `<-` / `receive` 走编译器同款 receive primop)、shop 多模块、pipeline 金测;CI `beam_examples` 组与 `"beam"` 解析门测试。

### Step 19 — RISC-V 目标(裸机 RV64)· `plan/step-19-riscv64.md`

**前置:** 步骤 01–14(特化 pass);step-15 的 RISC-V 参考笔记是设计记录。
**完成标准:** `emo build --target riscv64` 产出可在 `qemu-system-riscv64 -machine virt` 下引导的裸机 ELF;核心子集中每个示例的输出与 `emo run` 完全一致(CI 金测);`spawn`/`send`/`receive` 与 `foreign def` 以清晰诊断拒绝;缺 `"riscv64"` 的包在解析门被拒;`dune test` 全绿。

- [x] **T19.1** — 后端骨架:`--target riscv64` 管线(发射器模块;CLI 分支写出 `main.s`、调 `as`/`ld` 并附生成的链接脚本;`emo run` 在 QEMU 下引导该 ELF);入口桩、BSS 清零、SBI 控制台。金测:hello_world(串口输出与 `emo run` 逐字节一致)。
- [x] **T19.2** — 值模型与算术:带标签字的动态表示(`Int64`/`Float64` 装箱单元,Bool/Char 立即数)与 bump 分配器;回绕算术、比较、`if`、整数格式化(`INT64_MIN` 正确);有保证的尾调用编译为 `tail`。金测:fib。
- [x] **T19.3** — 动态世界数据结构:元组、数组、Box、枚举、实例 + vtable 分派、闭包与一等函数;带守卫的模式;按 `%g` 浮点规则的插值。金测:objects、language_tour。
- [x] **T19.4** — 引导:CI `riscv64_examples` 组(运行器装 QEMU + cross-binutils)、缺 `"riscv64"` 包的解析门拒绝测试、发射期拒绝诊断、收尾。

**Step 19 验收达成。** freestanding RV64 后端交付——hello_world、fib、objects、language_tour 在 QEMU 下以逐字节一致的 golden 引导,拒绝响亮,解析门约束包。`%g` 浮点 to_string 作为独立后续落地(plan/step-19 收尾)。

## M5 — Wasm 运行时

该层是用 Emo 编写的 WebAssembly 解码器、验证器与解释器。它在统一闸门下一次设计成型——原语只有在能点名一个具体的近期需求时才准入;`plan/step-20-wasm-runtime.md` 记录项目决策、机制矩阵与阶梯。

### Step 20 — 系统层(wasm 运行时)· `plan/step-20-wasm-runtime.md`

**前置:** Steps 01–19。
**完成标准:** `& | ^ << >> ~` 在整数类型上于解释器与四个后端工作;带小端访问器的 `Bytes` 核心类型可用;`file.read` 在调度器下从磁盘读入文件;`Int64` 与 `Byte` 算术在各目标上回绕(金测进 CI);`runtime/wasm/` 成为真实存在的包。

- [x] **T20.1** — 整数类型上的位运算符(`& | ^ << >> ~`):词法、语法、检查器、解释器与四个后端;`examples/bit_ops/` 金测走 `emo run` 与各目标 CI 组。
- [x] **T20.2** — `Bytes` 核心类型:构造、越界检查的 get/set、小端访问器、String 互转;四个后端;金测示例。(u64 访问器已随 T20.4 的 Int64 落地;wasm 上打印裸 `Bytes` 值输出的是缓冲区字节而非 `Bytes[n]` 标签——已知缺口。)
- [x] **T20.3** — `file.read` 标准库包(native,调度器直风格);从磁盘读文件的金测示例。附带 `file.write`(示例自行写入数据文件,金测与工作目录无关);写句柄在恢复进程前关闭,保证读己之写;测试经 EMO_REGISTRY 解析注册表。
- [x] **T20.4** — `Int64` 与 `Byte`:字面量、回绕算术、比较、显式转换;四个后端;金测示例。`runtime/wasm/` 包骨架在此任务创建。

小结:`Int64` 与 `Byte` 直接复用各目标已有的整数表示——OCaml 的 `int64`/`int`、Erlang 按 64 位有符号掩码的整数、wasm 的 `$vint`、TS 的 `BigInt`/`number`——没有哪个后端新增第二套值模型;各自补的是回绕规则(Byte 在 add、sub、mul、shl、bnot 之后掩到 256)与显式转换,`examples/fixed_width/` 在四个目标上全部跑通。T20.2 缓办的 `Bytes` u64 访问器在本任务落地,因为它等的载体正是 `Int64`,金测在每个目标上都覆盖了它们。两条后端备注:OTP 29 的 `erlc` 无法编译浮点位串模式,`Float.from_bits` 只能走 ETF 浮点头的 `binary_to_term`;Emo 按 OCaml 的 `%g` 规则打印浮点,Erlang 与 JavaScript 的原生格式化都不匹配,BEAM 运行时与 wasm 宿主各自实现了这条规则。wasm 金测还冲出两个此前示例够不到的运行时缺陷:`bytes_from_mem` 在线性内存里读的是 `i` 而不是 `ptr + i`,`int_str` 用有符号除法取位,把 `INT64_MIN` 弄花了。决策记录在 `plan/step-20-wasm-runtime.md`(Close-out)。**步骤 20 验收达成。**

### Step 21 — wasm 运行时:解码器与验证器 · `plan/step-21-wasm-decoder.md`

**前置:** 步骤 20。
**完成标准:** `runtime/wasm/` 能解码并验证 vendored spec 套件的二进制形式用例——每个合法模块被接受,每个 `assert_malformed` 用例在解码阶段被拒,每个 `assert_invalid` 用例在验证阶段被拒;默认 `dune test` 用 Emo 写的运行时跑一个冒烟子集,`wasm_spec` alias 跑全量清单且无 pending。

- [x] **T21.1** — 冒烟规则:`runtime/wasm/main.emo`、其金测文件,以及一条在沙箱里跑 `emo run main.emo` 的 `runtest` 规则。包不再空转;无需注册表也无需 native 工具链(deps 为 `{}`)。
- [x] **T21.2** — 用例清单格式与其十六进制编解码、语料运行器、`main.emo` / `spec.emo` 两个驱动,以及 `wasm_spec` alias。两个清单起始为空;汇总行报 `pending 0`。
- [x] **T21.3** — `devtools/vendor-wasm-spec`(把固定版本的 wasm spec 检出过一遍 `wast2json --no-check`)与首批语料:`binary.wast` 的二进制形式用例,以 `pending` 入库。与后续所有解码任务相互独立。
- [x] **T21.4** — 带诊断的失败值与 `Bytes` 读取器,每次访问前先做边界检查;截断读取类用例。
- [x] **T21.5** — LEB128(`u32`/`u64`/`s32`/`s64`)与 spec 的长度上限;`binary-leb128.wast` 加手写边界向量。
- [x] **T21.6** — 文件头与 section 遍历:magic、version、section id 与长度、顺序、自定义 section、未知 id、尾部多余字节。
- [x] **T21.7** — 类型 section,以及模块模型其余部分照抄的标签元组 / cons 链形状。
- [x] **T21.8** — 声明类 section:function、table、memory、global、import、export。
- [x] **T21.9** — element、data 与常量表达式。
- [x] **T21.10** — 操作码表与数值指令。
- [x] **T21.11** — 参数指令、变量指令与内存指令。
- [x] **T21.12** — 结构化指令:block/loop/if/else/end、br/br_if/br_table,以及 `end` 配对记账。
- [x] **T21.13** — 包表面的 `decode(bytes)`,以及合法模块语料。
- [x] **T21.14** — 验证上下文、各索引空间与函数签名检查。
- [x] **T21.15** — 普通指令的操作数类型栈。
- [x] **T21.16** — 控制帧:标签深度、分支操作数类型,以及分支之后的多态栈。
- [x] **T21.17** — 跨 section 规则:start 函数、element/data 偏移、limits、全局初始化器。
- [x] **T21.18** — 全量语料跑通且无 pending、冒烟子集、`runtime/wasm/README.md`、收尾。

小结:清仓收官——`wasm_spec` 报 3456 认领、0 pending、0 失败,冒烟子集(四十例,覆盖每个解码器与验证器族)随默认 `dune test` 运行。过程中冲出的缺陷比验证器本身更老:br_table 的立即数从未消费过 default 索引(T21.12 起就存在——漏出的字节被当作指令,整段函数体错位),0xfc 批量内存/表操作的编号也换成了最终规范版(而非合并前的提案编号)。验证器的帧栈改为带逻辑栈顶(逐弹重建在深层嵌套下是指数级),压栈前先截断到活跃前缀;块参数按 push_ctrl 语义活在帧内;unreachable 帧内压栈仍是具体类型,`type-num-vs-num` 一族照旧被拒。解释器的一条限制塑造了代码形状:对递归结果调用方法(`f(n-1).append(x)`)在约 25 层嵌套后会卡死,所有返回数组的递归都改成了尾累加——已记为语言压力。datacount 规则按相位拆分:有 data 段时,缺 datacount 的 bulk-memory 使用是 malformed;没有 data 段时,验证器的未知段检查使其为 invalid——两种都被语料钉住。声明引用集(全局、导出、elem 段——不含 start 函数)为 `ref.func` 定型。**步骤 21 验收达成。**


防止"仓内运行时"演变成"仓内语言"的三条边界——包边界、spec 数据不占默认测试路径、运行时离开本仓的条件——记录在计划文件中,连同运行时撞上的语言表面压力,以及让这份清单能在零散时间推进的任务粒度。

### Step 22 — wasm 运行时:解释器内核与 spec 套件金测 · `plan/step-22-wasm-interpreter.md`

**前置:** 步骤 21。
**完成标准:** `runtime/wasm/` 执行一个通过验证的模块——实例化(导入经注册命名空间与 `spectest` 宿主模块解析、各段按规范的越界即陷阱规则布局、运行 start 函数),调用导出函数,报告结果值或首个陷阱。`wasm_runs` alias 运行 vendored 运行语料(每条 `assert_return` 按位精确匹配、含 NaN 载荷类别;每条 `assert_trap` 与实例化失败都落在规范指定处)且无 pending;默认 `dune test` 跑双语料冒烟切片。

- [x] **T22.1** — 运行清单格式与其编解码(带类型标签的位模式字、NaN 记号、判定前缀)、步骤 21 旁的运行运行器、`runs.emo` 驱动、`wasm_runs` dune 规则,以及 `vendor-wasm-spec runs` 把命令语料整表落为 `pending`。独立于所有执行类任务。
- [x] **T22.2** — 实例模型:通过验证的模块固化为冻结记录——函数为签名加函数体字节区间、各索引空间、各段、导入、导出、start、声明引用集——包表面提供 `wasm.load(bytes)` 返回"模块或判定"。
- [x] **T22.3** — 值模型:i32/i64 为掩码位模式,f32/f64 为位模式、仅在运算点转换到 `Float64`,引用为带标签的对;NaN 载荷纪律与比较编解码。夹具先行——尚无执行。
- [x] **T22.4** — 整数族(纯函数):回绕算术、移位与旋转、clz/ctz/popcnt、带陷阱的除法与余数、符号扩展、饱和截断、wrap 与 extend。取自规范边界案例的夹具。
- [x] **T22.5** — 浮点族:经桥接的算术与比较;含截断陷阱的类型转换、promote/demote 用位手术实现正确舍入(语言无 `Float32`)、reinterpret 视为位模式搬运。类型转换边界夹具,含 NaN 类别。
- [x] **T22.6** — 存储:`Bytes` 上的线性内存(按页增长、访问前查界、小端各宽度),带 grow/size/fill/copy/init 的表,可变全局;陷阱皆为值。OOB 边缘夹具。
- [x] **T22.7** — 帧机器:u64 槽的操作数竞技场、局部与变量指令、以递归实现结构化控制且分支为解栈信号、带陷阱的 `call`/`call_indirect`、`return`、`unreachable`。`fac` 夹具证明尾调用链。
- [x] **T22.8** — 实例化与链接:经注册命名空间与宿主解析导入、全局初始化器、按越界即陷阱布局各段(`assert_uninstantiable` 在此失败,存储丢弃)、start 函数、`register`。缺失或失配的导入为链接失败。
- [x] **T22.9** — `spectest` 宿主模块:print 函数族、带类型的全局、表与内存,躲在同一个导入接口后面。
- [x] **T22.10** — 清仓 I:按序认领运行语料各族——整数、浮点、类型转换、控制流、调用——每族一次独立提交,残余保持 pending。
- [x] **T22.11** — 清仓 II:寻址与端序、内存与表操作、段初始化、经注册命名空间的链接、经 spectest 的导入、陷阱案例与收尾残余——运行清单终态零 pending 零失败。
- [x] **T22.12** — 收官:运行清单冒烟切片随 `dune test`,`runtime/wasm/README.md` 补执行表面,验收记录于此与 `docs/TASKS.md`(双语)。

收官:全量运行语料以 **25135 claimed、0 pending、0 failed** 收尾——每条 `assert_return` 按位精确匹配(NaN 载荷类别按记号),每条 `assert_trap` 与实例化失败都落在规范指定处,`register` 与链接行为正确——默认 `dune test` 跑双语料冒烟切片。统一闸门产出一项语言新增:浮点原语 `Float64.sqrt`/`floor`/`ceil`/`trunc`、`Float64.to_int64`、`Int64.to_float64`(`CHECK.md`)。运行驱动改为编译执行:求值器正确但无法把循环密集的内存测试带过自身递归上限,而原生编译需要装箱 `Int64` 路线与模块级 `var` 支持,二者均在此落地。**步骤 22 验收达成。**

步骤 21 记录的三条边界原样生效(包边界、spec 数据不进默认测试路径、拆分条件),清仓中发现并立为成规的"不得对递归结果调用方法"在计划中正式化。压力记录(`Int32`/`Float32` 掩码、可增长缓冲的竞技场、递归上限、argv)是统一闸门的原始素材,不是任务。

## M6 — 自包含托管后端

自包含故事的托管半边:Emo 自己的运行时、以 C ABI 作为 FFI 表面、产物二进制不依赖 OCaml 工具链——本里程碑交付后,构建 Emo 程序也不再需要 OCaml 工具链(CHECK.md,工具分发)。hosted-native-FFI 评估(`plan/hosted-native-ffi.md`)是本里程碑的设计记录——它是评估而非承载任务的步骤,因此本文件没有对应段落。Step 19 的研究共享标签字值模型。

### Step 23 — C 目标(发射 C 代码)· `plan/step-23-c-target.md`

**前置:** 步骤 01–14(IR);设计记录为 `plan/hosted-native-ffi.md`,本步骤将其排期。
**完成标准:** `emo build --target c` 发射 C 代码、经系统 `cc` 编译链接为不依赖 OCaml 运行时的独立二进制;金测子集(hello_world、fib、objects、language_tour、shop、pipeline、function_group、bit_ops、bytes、fixed_width、file_read)的输出与 `emo run` 逐字节一致(CI 金测);`foreign def` 经直接 C ABI 跨界;缺 `"c"` 的包在解析门被拒;`dune test` 全绿。

- [x] **T23.1** — 设计闸门关闭(CHECK.md:路线确认发射 C、蹦床方案落定、arena 临时化)与后端骨架:`src/emo_codegen` 中的发射器模块 + 调 `cc` 的 `--target c` CLI 分支;入口桩、托管启动、`println`;`"c"` 进入 `known_targets`,附缺 target 解析门拒绝测试。金测:hello_world。
- [x] **T23.2** — 尾调用与整数核心:蹦床(自/互尾调用,`return` 编译为跳往 epilogue 的分支——顺带修复现有后端循环基准慢约 4 倍的缺陷);`uint64_t` 上的回绕 `Int64`;比较、`if`、`INT64_MIN` 格式化正确。金测:fib;100 万层 `count_down` 在 C 栈上保持平坦;`loops_tail` 数字记入 `benchmarks/results.md`(4 ms——OCaml 后端特化构建为 1910 ms)。examples/fib 的完整金测等闭包落地(T23.5,其 `greeting` 依赖闭包);`c_integer` 夹具覆盖 fib、count_down、互尾簇与回绕,在 1MB C 栈下运行。同时修复 checker 的 span 类型表(原先仅按起始偏移做键,后检查的嵌套表达式类型覆盖先检查的)以及该修复暴露出的 wasm/beam 后端 ClassType 分派缺陷。
- [x] **T23.3** — 标量运行时:长度前缀字符串(仅在 FFI 边界 NUL 结尾)、`%g` 浮点规则、`Bool`/`Char`、插值、标量内容相等。金测:numerics、if_expr。(2026-10-06 完成:if_expr 是首个完整例子金测;numerics 本身等 `foreign def`(T23.8)与元组(T23.4)——`c_scalar` 夹具改为与解释器自身的渲染交叉对拍打印规则。字符串布局与运行时用 C 写两项决策已记入 CHECK.md。)
- [x] **T23.4** — 动态值模型:Step 19 的标签字(8 字节对齐堆块、3 个低位标签位;`Int64`/`Float64` 装箱双字单元;不做 NaN-boxing);bump/arena 分配器(临时画像);元组、值语义数组、`Box`。金测:objects。(2026-10-06 完成:标签字已落地——一个 `emo_value` 字,低位 000/001/011 区分指针/Bool/Char,堆块种类记在头字——bump 分配、malloc 泄漏按 CHECK.md 临时画像记录。regime 转换(`emo_box_*`/`emo_unbox_*`)在每个调用、绑定、返回与运算符处桥接本地与动态代码;动态 `+`/比较/相等按解释器规则在运行时分派;`to_string` 渲染元组 `(a, b)`、数组 `[a, b]`、Box 为 `<box>`。objects 金测等 classes(T23.5)——`c_dynamic` 夹具改为与解释器自身的渲染交叉对拍动态世界。)
- [x] **T23.5** — 类、枚举、接口、闭包:编译期 vtable 的实例、枚举单例、结构化 `is()`、带守卫的模式;合并前回收模型决策须已落在 CHECK.md。金测:language_tour。(2026-10-06 完成:language_tour 与 objects 双双成为完整例子金测,逐字节一致。vtable 携带方法签名与动态约定 thunk——类类型接收者直接分派,接口/Unknown 接收者经 `emo_send`;`is()` 按 vtable 身份(类)或形状(接口)比较;闭包采用规范动态约定 `[header][fn][captured...]`,创建点做捕获分析,直接动态返回;`case` 降为顺序的测试/绑定/守卫块,以 goto 链落空下落。回收模型决策已在 CHECK.md 落定:身份对象用引用计数、值语义数据走 arena——retain/release 发射工作在 T23.9 让长驻程序成真之前落地。)
- [x] **T23.6** — 模块与异常:跨文件模块引用、`raise`、未捕获异常退出码(`begin`/`catch`/`ensure` 仍未排期——不在范围内)。金测:shop、function_group(经 IR 降级免费获得——认领金测)。(2026-10-06 完成:两个金测逐字节认领。跨文件引用需要两处调用点修复——funsigs 现在携带被调方的声明结果,checker 定型为 Unknown 的跨模块调用仍能转换;IR 不再把模块别名 const 绑定降为 thunk(它们绑定的是路径而非值);组常量 thunk 返回 Unknown 而非 Void。`raise` 在根进程向 stderr 渲染解释器的 E3010 消息并以 1 退出——`begin`/`catch` 落地前无展开器;派生的进程 raise 只结束它自己,见 step 50。)
- [x] **T23.7** — 系统层表面:带小端访问器的 `Bytes`、位运算符、`Byte`、`Int64`/`Float64` 位转换。金测:bit_ops、bytes、fixed_width。(2026-10-06 完成:三个完整例子金测逐字节通过。`&`/`|`/`^` 在 int64_t 上精确二补码;`<<`/`>>` 在运行时守卫计数(负数报错、≥64 得 0/符号填充);Byte 是 uint8_t,截断回绕,复用 Int64 的除法/移位守卫;动态世界中的 Byte 物化为存 0-255 的 Int64 单元。Bytes 是新的堆块种类,存储在单元内,`to_bytes`/`to_string` 互操作,运行时 `to_string` 方法分派(Bytes 出内容、其他值出渲染)——对应解释器的运行时分派。checker 现把 `Unknown + Unknown` 定型为 Unknown(运行时按值分派 `+`——两个结果都不可证明);Emo 定义名撞 C 保留字时加 `_c` 后缀。)
- [x] **T23.8** — 直接 C ABI 上的 C FFI 第 1–3 级(不再需要包装器生成器):标量、随语言落地的宽度类型、不透明句柄 + 拷贝缓冲区;能力表中 `c` 翻转为支持 `foreign def`。金测:libm `sqrt` fixture 与一个小型 C 不透明句柄 fixture。(2026-10-06 完成:c 后端发射 `extern` 声明并直调符号——无包装。字符串跨界带 NUL 终止(出经 `emo_str_cstr`、入经 `emo_str_from_cstr`,按 CHECK.md 的布局决策);Int64 以 `int64_t` 直过——能力表在 checker 中目标感知(`c` 接纳 Int64,OCaml 后端保持 Float64/String/Bool);不透明句柄以指针尺寸的 Int64 承载,在 `c_foreign` 测试组中与 libm 夹具并列,配一个外部所有的计数器库、显式关闭。)
- [x] **T23.9** — 进程与协作式调度器:`do` / `<-` / `receive`、邮箱、选择性 receive、`self_pid`、`halt`;单线程协作循环;执行轨迹与 `emo_sched_det` 做 diff。金测:pipeline、showcase。(2026-10-06 完成:两个完整例子金测逐字节通过。每个 Emo 进程是一个 ucontext 纤维,拥有独立栈;调度器沿用 emo_sched_det 的策略——FIFO 运行队列,spawn 入队子进程而不挂起父进程,send 投递 + 唤醒 + 把发送者重新排在队尾,receive 在生成代码中扫描邮箱取第一条被某分支接受的消息(守卫失败的消息留在队中),无匹配时停靠纤维;运行队列空而有纤维停靠即报告死锁。Pid 是 EMO_PID 单元(渲染 `<pid N>`);`EMO_TRACE=1` 打印 spawn/send/park/dispatch/exit/reap 事件供 diff。顺带修复:入口文件被双发现(根副本 + 树副本,键上带 `/.` 路径)导致每个符号按两种 mangling 降级——walk 现规范化文件路径,IR 按 parsed items 的物理同一性去重模块副本。)
- [x] **T23.10** — 托管 IO 与标准库元数据:`file.read`/`file.write`、TCP/UDP socket、HTTP 客户端/服务器;标准库 `targets` 加 `"c"`。金测:file_read、tcp_echo、http_roundtrip。(2026-10-06 完成:三个完整例子金测逐字节通过,包括 stdlib 的 http/net 包在 c 目标上编译。socket 是非阻塞 fd,would-block 读取停靠纤维——运行队列空时调度器轮询停靠的描述符;根进程结束即程序结束。跨模块 Unknown 接收者按方法/字段名分派(全局运行时独有的名称,运行时助手;实例字段按 vtable 名)。Unix socket、TLS、DNS 解析、UDP 编译为诚实的运行时拒绝。stdlib 的 file/net/http 包与三个示例已声明 `"c"`,lockfile 重新生成。)
- [x] **T23.11** — 引导、基准、收尾:CI `c_examples` 组;特化(去装箱、直接分派),热循环加 `restrict`;`benchmarks/results.md` 增加 `c` 列;`native` → `ocaml` 改名在此或紧随其后的独立步骤落地;收尾记录决策。(2026-10-06 完成:六个基准的 c 目标数字全部落档——fib 7 ms、tail loop 4 ms(比 OCaml 后端的特化构建快 470 倍,距 C 基线 1.3 倍)、ffi 46 ms、bytes 43 ms、json 3 ms、http 83 req/s。特化在本目标上是结构性的:双 regime 发射器已对已知类型去装箱并直接分派;`restrict` 等待指针参数的热循环(缓冲区 rung)。改名作为紧随其后的独立步骤。)

## M7 — 工具链

自包含故事的最后一公里,也是工具链发布——正式的 1.0 随后。M6 把 OCaml 工具链从*程序*里移除了;M7 把安装负担从*工具*身上移除——`CHECK.md` 中"发布工具链本身未排期"的部分就此排期,按已定的方向(`docs/toolchain-distribution.md` 是设计记录):GitHub Releases 上的按平台预编译二进制为主渠道,`opam` 与 Homebrew formula 作为源码构建渠道,并补齐产品所需的命令集——`emo new`、`emo deps`、`emo doctor` 加入 `run`/`repl`/`check`/`build`/`publish`——让一台只有二进制的机器就能运行、检查、构建(经 `c` target)、钉住并解析依赖、发布包。

边界,明说:公共 registry *服务*是另一个里程碑——工具随包发布时只讲文件系统 registry 加内置标准库(`publish` 已经讲 HTTP;HTTP 拉取与它对话的服务一起落地);原生 Windows 不在本次发布内——WSL2 是受支持的 Windows 路径,C 运行时的 ucontext/socket 移植是记录在案的阻塞点(Microsoft Trusted Signing 仍是它落地时的既定签名路线);c 后端的记录在案的后续工作(retain/release 发射、零拷贝缓冲区 rung、跨模块类型传播)属于后端线,不随本里程碑。

### Step 24 — 工具链分发与发布 · `plan/step-24-toolchain.md`

**前置:** 步骤 23(`c` target;`native` → `ocaml` 改名已随其落地)。
**完成标准:** 发布工作流在版本 tag 上运行,产出经签名的按平台归档(Linux x86_64/aarch64、macOS x86_64/arm64),其制品在每个平台都通过端到端验收;一台只有安装好的二进制的机器——无 OCaml、无 opam、无仓库——就能经 `c` target 运行、检查、构建 Emo 程序,用 `emo new` 脚手架、`emo deps add` 钉住依赖、`emo doctor` 诊断环境;`dune test` 全绿。

- [x] **T24.1** — 设计闸门关闭与默认 target:四项落定记入 `CHECK.md`——构建默认由 `ocaml` 翻转为 `c`;标准库内嵌为生成数据(C 运行时的机制),不做旁挂目录;`emo install` 是项目依赖前端(全局可执行文件安装不进 1.0);依赖缓存离开临时目录,换持久的用户缓存。翻转在此落地,解析门测试与 CI 组随之改指——c 金测已覆盖该 target,移动的只是默认值。 (2026-10-07 完成:四项全部落定 CHECK.md;翻转把每条默认路径移到 c,并暴露出内容哈希缓存原本只在 ocaml 分支实现——c 分支补齐;ocaml 后端测试夹具与基准脚本钉住 --target ocaml;树级 @fmt 漂移一并晋升。2026-10-17 修订:`emo install` 命令已移除;resolve/fetch/lock 由 `emo deps` 与构建路径承担。)
- [x] **T24.2** — 自包含二进制:内置标准库作为编译器内的生成数据;registry endpoint 成为文件系统目录或内嵌标准库二者之一;`EMO_REGISTRY` 仍可覆盖。验证:一个孤零零的 `emo` 拷进空目录,即可运行、检查、构建带标准库导入的程序——`publish` 的内嵌上传器也能从它工作。 (2026-10-07 完成:经 devtools/gen-stdlib-data.sh 生成数据;macOS 沙箱把 source_tree 依赖物化为符号链接——生成器以 -type f -o -type l 遍历,靠探针发现而非猜测;endpoint 为 Fs_dir 或 Embedded;孤二进制验证通过(run/check/build/publish);内嵌与文件系统的校验和对拍由测试钉住。)
- [x] **T24.3** — `emo new <name>`:脚手架——`package.emo`(名称、版本、targets)与 hello-world `main.emo`,外加 `.gitignore`。严格性保持:目录已存在或文件冲突一律以清晰错误拒绝,不设 `--force`。脚手架生成的瞬间就是绿的——CI 创建、检查、运行并构建一个。 (2026-10-07 完成:CI 脚手架、检查、构建并运行一个;owner/name 在相对单斜杠参数下按原样采用;拒绝以 65 退出。)
- [x] **T24.4** — `emo install`:读 manifest,对 registry 解析,取入用户缓存,写 `package.lock`;重复执行幂等不变;每种失败形态——未配置 registry、无法满足的 pin、依赖缺所请求的 target——各有清晰报错。`emo deps` 保留 resolve/update/list 作为显式路径。 (2026-10-07 完成:幂等;lockfile 仅在会变化时写入;缓存默认迁往 ~/.cache/emo(尊重 XDG,EMO_CACHE_DIR 覆盖)。2026-10-17 修订:`emo install` 命令已移除,它承载的 resolve/fetch/lock 现由 `emo deps resolve` 与构建路径自身的解析承担。)
- [x] **T24.5** — `emo doctor`:target 感知的环境检查,取代 `CHECK.md` 中过渡期的仅 ocaml 形态。按 target:`c`——cc 编译并运行的冒烟;`ocaml`——运行时 `.cmxa` 在 switch 中找到,或诚实的"预编译安装:ocaml target 需要源码构建安装(`opam install emo`)";`typescript`——node;`beam`——erlc;`wasm`——无需任何。外加安装形态(预编译 vs 源码)、标准库在位、版本号。只在真正损坏处才以非零退出。 (2026-10-07 完成:源码 vs 预编译以二进制旁的运行时 .cmxa 集探测;c 冒烟决定退出码;ocaml 不可用时报告 opam 安装修复。)
- [x] **T24.6** — 发布打包与 CI:现有 CI 旁的 tag 触发工作流——按平台矩阵构建(Linux x86_64/aarch64、macOS x86_64/arm64),经 dune 产出发布二进制,T24.1 落定的归档布局、`SHA256SUMS`、GitHub Release 草稿。Linux 二进制可移植——静态或最旧的可用 glibc——在干净容器中验证,而非构建机上。 (2026-10-07 完成:package-release.sh 本机端到端验证;矩阵 = linux x86_64/aarch64(ubuntu-22.04,glibc 2.35)+ macOS x86_64/arm64,打包前先跑测试套件,Linux 在干净 ubuntu:22.04 容器中验证。)
- [x] **T24.7** — 签名与平台闸门:macOS codesign(hardened runtime)→ notarytool → staple,凭据在 CI secrets——`CHECK.md` 中"已解决、非阻塞"的一项就此排期。Windows:WSL2 记录为受支持路径,原生预编译记录为推迟,ucontext/socket 移植点名为阻塞;`docs/toolchain-distribution.md` 同步更新(双语)。 (2026-10-07 完成:四个密钥把 codesign → notarytool → staple 设为条件路径;密钥缺席以未签名发布并出 notice;分发文档双语更新。)
- [x] **T24.8** — 供给渠道与安装文档:Homebrew formula(先自有 tap;项目够格后进 core)与 opam 包——带来 `ocaml` target 的源码渠道。README 安装章节双语更新:预编译归档优先,其后 brew、opam、WSL2。 (2026-10-07 完成:公式在 devtools/homebrew/emo.rb 供自有 tap 使用,校验和发布时填写;dune-project 生成 emo.opam(stanza 无 dev_repo 字段——弃之);README 安装章节双语落地。)
- [x] **T24.9** — 发布验收与剪出:对每个已发布制品端到端——下载、解包、`emo doctor`、`emo new`、`emo run`、依赖解析、`emo build`(`c` target)——包括一个带标准库导入的程序与从安装后的二进制执行的金测子集。发布 commit 携带发布的 VERSION;annotated tag、发布说明、收尾。 (2026-10-07 完成:验收对着打包并解压的归档执行——doctor 以预编译形态全绿;new → run → build 全通,`emo install` 经内嵌标准库解析(该命令已于 2026-10-17 移除,这一步现由 `emo deps resolve` 与构建路径承担);金测 14/14 出自安装后的二进制(13 个经 emo run 逐字节,numerics 走其设计的编译路径——它跨 foreign def,emo run 按设计拒绝;http_roundtrip/tcp_echo 依托树内套件)。)

收尾:2026-10-07 记于 `plan/step-24-toolchain.md`——验收对着打包制品而非构建树执行;默认 target 翻转把每条默认路径移到 `c`(并暴露出内容哈希缓存原本只在 ocaml 分支实现),内嵌的 dune 规则需要 `-type f -o -type l`(macOS 沙箱把 source_tree 依赖物化为符号链接),归档不带安装脚本发布。**步骤 24 验收达成。** M7 完成:工具链发布随正式的 1.0 一起。

## M8 — Target 独立

让宿主/目标的区分真正落地。宿主语言(emo 是怎么造出来的——今天是 OCaml)回答一个问题;target(emo 把你的程序变成什么)回答另一个。完整兑现这个区分,意味着宿主只贡献发射器:每个 target 的运行时都活在 target 自己的生态里,绝不在二进制旁、也绝不在宿主构建树里——将来宿主重写(Go 或别的宿主语言)只动发射器。

审计发现五个 target 已有三个达标——**c**(独立 C 运行时,以内嵌生成数据分发,待推广的模式)、**wasm**(运行时编译进模块;那 3 个导入是对 wasm 引擎的 ABI,与编译器宿主分属两个轴)、**beam**(单个自包含 Core Erlang 模块,站在 OTP 上)。两个没有:**typescript** 的运行时前奏是旁挂文件,因此在每个安装好的二进制上都是坏的(发布布局只带 `bin/emo`);**ocaml** 链接宿主自己的八个库、从宿主构建树里找,这就是它只在树内可用的原因——也是 `opam install emo` 带不来它的原因(已验证:opam 安装集为七个文件,零个 `.cmxa`)。

### Step 25 — Target 独立 · `plan/step-25-target-independence.md`

**前置:** 步骤 24(本步骤要修正其表述的工具链)。
**完成标准:** 没有任何 target 从二进制旁或宿主构建树读取运行时——c、ocaml、typescript 的运行时以生成数据随编译器内嵌,wasm 与 beam 的在发射模块内;`emo build --target ocaml` 在任何 OCaml 工具链在 PATH 上的安装形态下可用,无 `.cmxa` 查找、无安装形态条件分支;typescript target 在发布布局下可用;全部金测逐字节;`dune test` 全绿。

- [x] **T25.1** — 原则与 ts 内嵌:运行时独立原则记入 `CHECK.md`;ts 前奏以内嵌生成数据(C runtime 的 dune 规则模式)分发,typescript 分支停止读文件系统。验证:孤零零的发布布局二进制能编译 typescript 程序;ts 金测逐字节。 (2026-10-07 完成:前奏作为生成数据随 `emo_codegen/ts` 内嵌,CLI 不再为它触碰文件系统;孤立二进制能编译并运行 typescript 程序;七个 ts 金测全绿。)
- [x] **T25.2** — 发射代码清单与独立骨架:经 ocaml 发射器发射金测子集,机械收集发射代码引用的每个宿主符号,把清单记为独立运行时的契约;骨架以纯 `ocamlopt` 编译——零 `emo_*` 依赖——由仅从构建目录出发的 fixture 证明。 (2026-10-07 完成:两个模块、七十余个符号作为契约记入 plan,由 `devtools/ocaml-runtime-inventory.sh` 在十六个示例的金测语料上机械收集,并带游离模块告警;骨架随 ADT、信号与 effects 定型落地。)
- [x] **T25.3** — 值与标量核心:值 ADT、字符串、print/插值渲染、算术/比较分派,以及清单点名的 case/错误路径,全部独立化。每片由仅对独立运行时编译的 fixture 覆盖。 (2026-10-07 完成:五个按发射器调用形状编写的 fixture 程序,以 `ocamlopt -open Emo_ocaml_runtime` 仅对抽出的运行时编译。)
- [x] **T25.4** — 调度器与 IO:基于 effects 的调度器、文件 IO 与网络面,按依赖策略执行(核心用 OCaml 标准库加 `unix`;`ssl` 为唯一 opam 依赖;不用 eio)。Fixture:进程程序与 HTTP 往返,均仅对独立运行时编译。 (2026-10-07 完成:det 调度器整体移植——spawn/send/receive、fd 与定时器停靠、TLS、UDP、文件 IO;eio 退出,策略落定为 unix 加 ssl;另有四个 fixture 骑在调度器上。)
- [x] **T25.5** — 切换:ocaml 发射器的引用翻转到独立运行时;分支发射运行时 + `main.ml` 并调用 `ocamlopt`(ocamlfind 只为运行时自己的包);`.cmxa` 机制、库扫描与二进制旁查找删除;拒绝与 doctor 措辞改为与安装形态无关。全部 ocaml 金测与测试逐字节;带 OCaml 工具链的安装二进制构建金测子集。 (2026-10-07 完成:该分支写出运行时 + `main.ml`,并用目标自己的 ocamlopt 编译;cmxa 机制、库扫描与二进制旁查找全部删除;十六个金测逐字节一致,发射的 `main.ml` 不变;孤立的发布布局二进制能构建金测子集。)
- [x] **T25.6** — 独立性审计与收尾:wasm 与 beam 记录为验证独立(无任务——证据在案);文档修正(`docs/toolchain.md`、`docs/toolchain-distribution.md`——用真实的 ocaml target 故事取代"源码安装带来 ocaml target");`benchmarks/results.md` 的 ocaml 列对独立运行时复测;收尾。 (2026-10-07 完成:wasm 与 beam 的证据记入 plan;两份工具链文档双语更正,doctor 删除 installation 行;基准套件在独立运行时上复测,ocaml 行落在机器观测噪声带内;plan 状态记为 done。)

步骤 25 完成(2026-10-07,T25.1–T25.6 于 `feat/target-independence`):没有任何 target 从二进制旁或宿主构建树读取运行时;ocaml target 在 OCaml 工具链在 PATH 上的任何安装形态下、用孤立的发布布局二进制即可工作;typescript target 亦然;全部金测逐字节,`dune test` 全绿。

## M9 — For / While 循环

`CHECK.md` 已定案的循环面(2026-10-06):保证的尾调用保留,`for` / `while` 加入其中。`for var i = 0; i < n; i = i + 1 { ... }` 无括号、恰好三个子句、头部的 `var` 作用域限定在头部与循环体;`while cond { ... }` 仅条件;`break` 与 `continue` 是绑定最近循环的裸语句;不加 `do`/`while`,不加 `+=`/`++`。动机:循环是向量化与 OpenMP 并行循环 rung(HPC 闸门)的原生形状,免去循环代码的尾位置证明负担,并与 `var` 自然搭配——而 var 逃逸规则(E4012)已挡住 Go 的循环捕获陷阱。设计记录在 `CHECK.md` 与 README;每个步骤的 plan 文件在步骤启动时编写。

### Step 26 — 循环表面:lexer、parser、checker、解释器

**前置:** Step 25。
**完成标准:** README 的循环示例经 `emo run` 逐字运行;CHECK.md 的演示范例(`for var i = 0; i < 100; i = i + 50`)先打印 `i = 0` 再打印 `i = 50`;千万次迭代的 `while` 栈保持平坦;每种拒绝——保留字用作标识符、缺子句、`;` 出现在 `for` 头之外、循环外的 `break`/`continue`——各有自己的诊断;`dune test` 全绿。

- [x] **T26.1** — 关键字:lexer 保留 `for`、`while`、`break`、`continue`;LSP 补全列表与 VS Code grammar 同步翻转;把这四个词用作标识符的代码得到清晰的保留字诊断。(2026-10-11 完成。)
- [x] **T26.2** — Parser:`while cond { }` 与三子句 `for`——不许省略,post 子句是赋值,`;` 是仅在 `for` 头内合法的记号,`while` 条件与 `for` 三个子句都设 `suppress_block_sugar`,使随后的 `{` 打开循环体而非粘成尾随块;四个语句的 AST 节点。(2026-10-11 完成。)
- [x] **T26.3** — Checker:头部 `var` 在现有深度模型下作用域限定于头部+循环体;`break`/`continue` 绑定最近的循环,循环外一律拒绝;`definitely_returns` 把循环纳入,使 `return` 可达性保持可靠;箭头块捕获头部 `var` 仍是 E4012。(2026-10-11 完成。)
- [x] **T26.4** — 解释器:四个语句进入 `eval_stmt`;迭代跑宿主循环、绝不递归——千万次迭代栈平坦;`continue` 先执行 `for` 的 post 子句;步数预算按每次迭代计一步。(2026-10-11 完成。)
- [x] **T26.5** — 示例与拒绝语料:`examples/loops`——演示范例、`while` 计数、`break`/`continue`、嵌套循环——经 `emo run` 金测;parser 与 checker 的拒绝语料钉住每一种拒绝。(2026-10-11 完成。)
- [x] **T26.6** — README 对齐:README(英文 + 中文)已按定案写好循环语法——对照实现核对,漂移处一并修正。(2026-10-11 完成。)

Step 26 收尾(2026-10-11,`feat/loops` 分支):循环面在 lexer、parser、checker、解释器全链路落地,每个任务一个提交。`;` 成为正式 token,唯一合法位置是 `for` 头部(E2025);头部形状是解析期法则——init 必须是 `var`、post 必须是赋值、三个子句缺一不可(E2026),所有子句解析时关闭块语法糖。checker 把循环拆成两层作用域——header 一层,body 是它的子层——因此头部 `var` 比 body 中任何箭头块浅一层,捕获它就是普通的 var 逃逸错误(E4012);`break`/`continue` 经 `loop_depth` 字段绑定最近的循环,箭头块把该字段清零(循环外为 E4022),且任何循环形状都不算返回点。解释器每轮迭代是一个 OCaml 尾循环、body 每轮全新帧——千万次迭代实测栈平坦;`continue` 仍先执行 `for` 的 post 子句;步数预算计入每一次迭代——循环出现之后,受限配置档的终止性正靠它保证。`examples/loops` 经解释器金测;六个后端对循环语句响亮拒绝,留待 Step 27 下降。

### Step 27 — 循环上全部 target:IR 与六个后端

**前置:** Step 26。
**完成标准:** `examples/loops` 在 c、ocaml、typescript、wasm、beam、riscv64 上编译,每个 target 逐字节打印 `emo run` 的输出(金测入 CI);千万次迭代的循环在每个 target 上栈保持平坦;尾调用保证不被触动(`loops_tail` 不变);`dune test` 全绿。

- [x] **T27.1** — IR:循环语句进入 `emo_ir` 的 `stmt` 与 Ast→IR 降低——头部 `var` 降为循环作用域的可变绑定;一套节点,每个后端一个分支。(2026-10-11 完成;赋值降低改为最内层优先,头部 `var` 正确遮蔽同名模块级 `var`。)
- [x] **T27.2** — c:发射出的 C 自带的 `while`/`for` 与原生 `break`/`continue`;循环内的 `return` 走既有的分支到收尾路径。(2026-10-11 完成;`for` 用 `while(1)` 加 continue 标签使 post 先行;顺带修复动态重绑先释放后求值的未定义行为。)
- [x] **T27.3** — ocaml:原生 `while`/`for` 配既有的 `ref` 纪律表达头部 `var`;`break`/`continue` 经 plan 文件记录的唯一机制降低(done 标记或本地异常——落定,绝不静默回退)。(2026-10-11 完成;机制落定为每循环一对局部异常 `Break_N`/`Continue_N`。)
- [x] **T27.4** — typescript:发射体内原生 `while`/`for`;`break`/`continue` 用目标语言自己的。(2026-10-11 完成。顺带修复循环金测暴露的预存后端 bug:`stmts` 在链头之前发射链的其余部分——sprintf 参数从右往左求值——导致 `var` 的 ref 注册落在需要它的语句之后;现在链头先行发射。自尾调用的 driver 循环获得 `__emo_driver` 标签,使循环内的尾调用续接 driver,而不是 Emo 循环。)
- [x] **T27.5** — wasm:结构化控制流——`Loop` 加条件上的 `Br_if`;`break` 分支出循环块,`continue` 到循环头,post 子句先行执行。(2026-10-11 完成。`for` 降为 `block $exit { init; loop $head { test; br_if $exit; block $post { body } post; br $head } }`,因此 `continue` 落在 post 上、`break` 越过它离开;语句级 if 与 case 分派都会跟踪帧深度,使嵌套控制流内部的分支深度保持相对正确。)
- [x] **T27.6** — beam:循环降为尾递归的局部函数——条件守卫、循环体、带重绑变量的递归调用;`break` 穿线一个 done 标记。(2026-10-11 完成。每个循环是一个隐藏的模块函数,除头部 `var` 外还接收循环体读取或赋值的全部外层绑定,并在线程化的递归调用间传递;done 标志标记 `break`,`continue` 先执行 post。循环体发射为尾链——if 把其余部分编进自己的分支,跳转截断其后的死代码——因此每次跳转都是真正的尾调用;Core Erlang 的 `do` 只对其最后一个操作数做尾调用。)(另修复:单语句 `Assign_var` 路径在求值之前就注册了遮蔽绑定,导致 `n = n + 1` 读到它正在定义的那个变量。)
- [x] **T27.7** — riscv64:标号与条件分支——循环头是标号,`break`/`continue` 是跳转。(2026-10-11 完成。`while` 是 `head: test; beqz exit; body; j head`;`for` 在 body 与回跳之间放一个 post 标签,因此 `continue` 落在 post 上、`break` 越过它离开。头部 `var` 是一个帧槽,沿用既有纪律。值堆那套无回收 arena——与循环之前的尾递归惯用法共用——仍为长跑程序划界;本任务未改动它。)
- [x] **T27.8** — 金测与基准:`examples/loops` 上全部六个 target 金测列表;`benchmarks/results.md` 在 `loops_tail` 旁新增纯循环一行;CI 各组;收尾。(2026-10-11 完成。riscv64 target 补齐 `/` 与 `%`——`div`/`rem` 加零除中止——使示例能在该处启动;纯循环基准在 c target 与解释器之侧记录了 ocaml target 按构造即为动态的数字。)

步骤 27 收尾(2026-10-11,`feat/loops` 分支):循环语句在全部六个 target 上完成降低,每任务一次提交。IR 承载 While/For/Break/Continue,头部 `var` 是循环作用域的可变绑定;赋值降低按最内层优先解析,使头部 `var` 在同名模块级 `var` 之下仍更新自身。c 发射自己的 `while` 与一个 `while(1)` 形式,其 continue 标签执行 post;ocaml 采用 ref 纪律,每循环一对局部异常;typescript 用目标原生的 `for`,并为尾调用加一个带标签的 driver 循环;wasm 降为 block/loop/br_if 加一个 post 块;beam 把每个自由变量经一个隐藏的递归函数线程化,配 done 标志;riscv64 用标签与跳转——并补齐 `/` 与 `%` 使示例可启动。`examples/loops` 在全部六个 target 加解释器上金测通过,纯循环基准行在 c target 之侧记录了 ocaml target 按构造即为动态的数字。

## M10 — 错误处理

`CHECK.md` 已定案的错误模型(2026-10-11):预期内的失败是值——来自内置 `R` 枚举的 `(R.ok, value)` / `(R.error, reason)`——用 `case` 匹配,或用绑定模式断言绑定(`const (R.ok, body) = f()`);违例抛出唯一的 `Exception` 类,抛出即结束进程——任何 target 都没有 catch 构造。`R` 位于规格层(`CHECK.md`,类型分层),包括 riscv64 在内的每个 target 都获得它;stdlib 迁移把 ~220 处 raise 逐包挪到新约定。设计记录在 `CHECK.md` 与 README(双语);每个步骤的 plan 文件在步骤启动时编写。

### Step 28 — 错误处理表面:R、绑定模式、raise 纪律

**前置:** Step 27。
**完成标准:** README 的异常示例经 `emo run` 逐字运行;错误元组流入 `const (R.ok, body)` 时进程以 case 无匹配的运行时错误结束;`raise "str"` 与 `raise user` 各有自己的诊断;内置名 `R` 与 `Exception` 拒绝用户重复声明;未捕获报告打印非空 `data`;`dune test` 全绿。

- [x] **T28.1** — 内置 `R { ok, error }`:绑定在 checker 根环境与解释器全局帧(走 `Exception` 的先例);`R.ok` / `R.error` 在枚举成员已通行的每一处构造与模式匹配;`enum R` / `class R` 报保留名诊断。
- [x] **T28.2** — Parser:`const`/`var` 接受完整模式代替名字(`Ast.Binding` 携带它);`const (` 不再是硬错,不破坏任何文法。
- [x] **T28.3** — IR:模式绑定脱糖为单臂 `case` 包住块的剩余部分——没有新 IR 节点,六个后端只见既有节点。
- [x] **T28.4** — Checker:模式绑定经 `check_pattern` 对初始化式的类型检查;`raise` 的操作数必须是 `Exception` 实例(其余各有自己的 E-code);未捕获诊断附加非空 `data`。
- [x] **T28.5** — 解释器:模式绑定求值,不匹配走 case 无匹配的运行时错误;raise 操作数纪律的运行时面;未捕获格式变化的既有金测重录。
- [x] **T28.6** — 示例与拒绝语料:`examples/errors`——README 示例逐字(ok/error 匹配、断言绑定、违例抛出)——经 `emo run` 金测;匹配示例在全部六个 target 逐字节金测(riscv64 跑匹配的一半;其 raise 拒绝不变);拒绝语料钉住每一种新诊断。
- [x] **T28.7** — README 对齐:README(英文 + 中文)已按定案写好——对照实现核对,漂移处一并修正。

### Step 29 — stdlib 迁移:元组替换 raise,逐包进行

**前置:** Step 28。
**完成标准:** 每个标准库包的数据性失败返回 `(R.error, reason)`,只有契约违例抛出;每个包在其声明的 target 上金测全绿;`dune test` 全绿。

- [x] **T29.1** — `file` + `os`:open/read/write 与权限缺失、路径不存在返回元组;原生 raise 点(os 运行时,interp + ocaml + c)改为返回;waitpid 解码不动。
- [x] **T29.2** — `json` + `yaml`(+ `internal/float`):解析与访问器失败返回元组——最大的两处,约 150 个点。
- [x] **T29.3** — `xml` + `base64` + `bufio` + `slog` + `http` + `sync`:同样的分界;`http` 的连接被拒/解析失败/超期按 README 网络节改为元组。(`xml`/`base64` 的解码失败与 `net` 全表面返回元组;`bufio`/`slog`/`sync` 保留 raise——每一处都是调用方失误。)
- [x] **T29.4** — 金测:每个被触及包的错误路径 fixture 重录为匹配 `(R.error, why)`;包金测在全部声明 target 上全绿。
- [x] **T29.5** — 文档:`docs/stdlib/` 各包页面(及中文镜像)措辞 raise → 返回;错误消息表更新。

### Step 30 — 检查器严格化:Box 类型化与跨模块值签名

`feat/checker` 上的检查器专项(2026-10-11):循环专项记下的两处分歧,以及揭开失察后暴露的问题。定案见 CHECK.md。

- [x] **T30.1** — `Box.new` 类型化为 `Box[T]`:在 `List.new`/`Map.new` 之侧补上构造器特判,`read`/`replace` 按单元类型受查,其余成员——包括裸成员访问——在检查期拒绝(裸 `x.v` 分歧;此前 stdlib 的 Box 状态完全失察)。接收者一旦带上类型,两处 c 侧预存偏差随即现形:`emo_box_replace` 返回 box 本身,而其余所有 target 都返回新值(已对齐);发射器的 `to_string` 分派臂劫持了静态类型的实例接收者,打印调试 repr 而不调用类自己的方法(实例先按类分派,无同名方法时才走内建转换)。
- [x] **T30.2** — 跨模块值签名:def 与 foreign 按声明的 `FuncType`、const/var 按初始化表达式的类型、`emo` 组进程序级注册表——全部在类型表之侧预注册。限定调用经 `check_apply` 受查;裸成员读取要么解析出类型、要么静态报 E5004;组成员获得类型(此前连同模块的裸 `Math.tau` 都是 Unknown);局部名遮蔽同名模块,与运行时规则一致。顺带落地两个预存 bug:`longest_module_prefix` 走的是路径的后缀而非前缀;空点路径被当成模块前缀——任何非简单接收者上的裸成员访问(`foo(1).field`)恒为 Unknown。
- [x] **T30.3** — 项目检查下,解析不到任何类型、组或模块的大驼峰值名在书写处报 E4003(运行时携带值的内建名保持合法);单文件视图保持旧的沉默,与它看不见的所有跨文件缺口一致。json/yaml 接口声明 `get`(自引用签名;json 补齐四个标量类的 raise 型变体,与类已有的回答一致)。checker 与 project 测试;CHECK.md 条目;全部 target 金测绿。

## M11 — 标准库

随编译器交付的 stdlib 自成里程碑:每个步骤一个包,各自带上 API 参考与可运行金测。步骤从 `json`(31)排到 `bufio`(37),其后是原生绑定包 `sqlite3`(38)与 SQL parser `sql`。

### Step 31 — 标准库:`json` · `plan/step-31-stdlib-json.md`

**前置:** Step 11(包)+ Step 25(target 独立)。
**完成标准:** `require "json"` 在编译器交付的每个 target 上解码与编码 JSON 且逐字节一致——严格、携带偏移的错误,数字精确往返,值树是普通 Emo 数据、跑在共享运行时上,除 typescript UTF-8 bytes 修复外零按 target 的运行时工作;六条路径全部金测;`dune test` 全绿。

- [x] **T31.1** — 规格与骨架:包 `stdlib/registry/json/0.1.0`(覆盖五个已测 target 的 `package.emo`;`json.emo` 带值模型——`JsonKind`、`Json` 接口、七个载荷类、各工厂;`internal/float.emo` 承载数值机制),重新构建时内嵌。验证:工厂构造的值可编码,解释执行。(2026-10-09 完成。)
- [x] **T31.2** — typescript bytes 修复:ts 前奏里 `to_bytes` 按 UTF-8 编码、`Bytes.to_string` 按 UTF-8 解码;全部既有 ts 金测逐字节。(2026-10-09 完成:解释器、c、typescript 就非 ASCII 往返达成一致。)
- [x] **T31.3** — 解码器:逐字节的扫描器加递归下降解析器,按 RFC 8259 文法——转义含代理对、精确的 `Int64`/`Float64` 数字、深度上限、带偏移的错误。(2026-10-09 完成:decode 对小数只舍入一次,就近取整、平局取偶——`strtod` 的答案——经 `internal/float.emo` 里的精确长除法实现。)
- [x] **T31.4** — 编码器:紧凑与 pretty 两种形态;字符串转义;整数走 `Int64.to_string`;最短往返浮点格式化器。(2026-10-09 完成:π 打印 `3.141592653589793`,最小非规格化数打印 `5.0e-324`,最大值打印 `1.7976931348623157e+308`;浮点数永远看得出是浮点数。)
- [x] **T31.5** — 金测示例:`examples/json_demo` 接入解释器 bootstrap 与 typescript 金测列表(共用一份 `expected.txt`);c、wasm、beam 等下方的跨模块后续。(2026-10-09 完成。)
- [x] **T31.6** — 边界 fixture:`examples/json_edge`——转义矩阵、代理对、512 数组上限的往返、重复键、数字边界、往返、pretty 形态——接入解释器 bootstrap 列表。(2026-10-09 完成;揪出紧凑编码器缺失的空容器守卫。)
- [x] **T31.7** — 文档与收尾:`docs/stdlib/json.md` 及 zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 31 收尾(2026-10-09,`feat/stdlib` 分支):`require "json"` 在解释器、ocaml target、typescript target 上解码与编码逐字节一致——金测 `json_demo`(bootstrap + ts)与 `json_edge`(bootstrap)全绿,`dune build @fmt` 与 `dune test` 端到端全绿。这个包是普通的纯 Emo;c、wasm、beam 仍被一个检查器步骤挡住——跨模块类型名("cross-module types stay unchecked this step",步骤 10)——最小复现与本步骤已落地的后端修复记录在 `plan/step-31-stdlib-json.md`。随本步骤落地的编译器修复:按文件键控的 span 类型表(多模块类型互窜)、typescript 尾调用重写的实参临时变量 + 字符串转义 + 接口分隔符、c 的 `emo_send` 实参数组 + 未知接收者的 vtable 回退 + 互尾调用簇的入口分派、wasm 接口分派的 `Ref_cast` + 字段显示名解析。

### Step 32 — 标准库:`yaml` · `plan/step-32-stdlib-yaml.md`

**前置:** Step 31(json 包——本包沿用的树设计与浮点机制)。**完成标准:** `require "yaml"` 在检查器支持的 target 上解码与编码 YAML 1.2(core schema)且逐字节一致——块/流样式、带引号标量配 YAML 转义集、块标量配 chomping、重复键后者胜、数字打满边界;解释器/ocaml/typescript 金测全绿;c、wasm、beam 等与 Step 31 共享的跨模块类型后续。

- [x] **T32.1** — 包与解析器:`stdlib/registry/yaml/0.1.0` 重新构建时内嵌;值模型、块/流解析器。(2026-10-09 完成。)
- [x] **T32.2** — 编码器:块样式;无歧义时用 plain 字符串;空容器的流形态。(2026-10-09 完成。)
- [x] **T32.3** — 金测:`examples/yaml_demo`(bootstrap + typescript)与 `examples/yaml_edge`(bootstrap)。(2026-10-09 完成。)
- [x] **T32.4** — 文档:`docs/stdlib/yaml.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 32 收尾(2026-10-09,`feat/stdlib` 分支):yaml 包沿用 json 包的树设计,在解释器、ocaml、typescript 上金测全绿;c、wasm、beam 仍被与 Step 31 共享的跨模块类型检查器步骤挡住。本包还揪出 typescript 运行时的字段遮蔽方法分派 bug(已在 `ts_runtime.ts` 修复:自有属性不是函数时,E.method 现在会落到原型的方法上)。

### Step 33 — 标准库:`xml` · `plan/step-33-stdlib-xml.md`

**前置:** Step 31(json 包——本包沿用的树设计与字节扫描器模式)。**完成标准:** `require "xml"` 在已验证 target 上解码与编码良构 XML 且逐字节一致——带引号属性的元素、自闭合形式、五个实体加字符引用、CDATA 作原始文本、注释 / PI / 声明 / DOCTYPE 跳过、混合内容、带偏移的错误;解释器/ocaml/typescript/c 金测全绿;wasm 与 beam 等与步骤 31–32 共享的跨模块类型后续。

- [x] **T33.1** — 包、值模型与解码器。(2026-10-09 完成。)
- [x] **T33.2** — 编码器。(2026-10-09 完成。)
- [x] **T33.3** — 金测:`examples/xml_demo`(bootstrap + c + typescript)与 `examples/xml_edge`(bootstrap)。(2026-10-09 完成。)
- [x] **T33.4** — 文档:`docs/stdlib/xml.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 33 收尾(2026-10-09,`feat/stdlib` 分支):xml 包——三个格式包里最轻的(XML 全是文本,没有浮点机制)——在解释器、ocaml、typescript 以及 c 上金测全绿(xml_demo 挂上 c_goldens 列表)。本包还揪出三个格式包共有的 exact-buffer `to_string().substring(byte_count)` 越界模式(修复:恰好填满的缓冲直接返回 `to_string()`)。wasm 与 beam 仍被跨模块类型检查器步骤挡住。

### Step 34 — 标准库:`os` · `plan/step-34-stdlib-os.md`

**前置:** Step 23(c target)与 Step 25(target 独立——独立 ocaml 运行时同样需要这套分派)。**完成标准:** `require "os"` 给程序进程身份、fork / execv / waitpid / _exit、管道、裸的无缓冲 fd 文件 IO 与目录面;每个失败的调用抛异常并点名系统调用;waitpid 以纯 Emo 解码器应答内核的原始 16 位状态;list_dir 以字节序排序返回名字,不带 `.` 与 `..`;解释器/ocaml/c 金测全绿;ts/wasm/beam 按 targets 声明拒绝该包。

- [x] **T34.1** — checker 签名、`os_` 运行时实现前缀、解释器的 Unix 后端分派。(2026-10-09 完成。)
- [x] **T34.2** — c 运行时的 `emo_os_*` POSIX 实现与 c 发射器的分派。(2026-10-09 完成。)
- [x] **T34.3** — 独立 ocaml 运行时的分派。(2026-10-09 完成。)
- [x] **T34.4** — 包本体:薄封装、wait 状态解码器、fork/pipe 纪律。(2026-10-09 完成。)
- [x] **T34.5** — 金测:`examples/os_demo` 挂上 bootstrap 与 c_goldens 列表。(2026-10-09 完成。)
- [x] **T34.6** — 文档:`docs/stdlib/os.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 34 收尾(2026-10-09,`feat/stdlib` 分支):os 包——net 之后第二个运行时后端的包,也是第一个伸进进程机制的——在解释器、ocaml、c 上验证;os_demo 金测演练 fork+pipe+waitpid(子进程经 _exit 以 7 退出,父进程解码原始状态)以及裸 IO 与目录面。与格式包不同,os 跨模块只用原生类型,所以 c target 无需跨模块类型检查器步骤即可带走它;ts/wasm/beam 由包的 targets 声明拒绝。

### Step 35 — 标准库:`base64` · `plan/step-35-stdlib-base64.md`

**前置:** Step 31(json 包——字节扫描器纪律)。**完成标准:** `require "base64"` 以标准字母表加 `=` 填充编码,解码严格——只收字母表、填充只出现在末尾分组、零填充位规范——每次拒绝都给出违规字节偏移;金测挂全部五个列表(bootstrap、c、typescript、wasm、beam),处处逐字节一致。

- [x] **T35.1** — 包本体:双向的算术字母表、严格解码器、带偏移的错误。(2026-10-09 完成。)
- [x] **T35.2** — wasm 修复:`&&`/`||` 左操作数补 cast 与零长度字节拷贝守卫。(2026-10-09 完成。)
- [x] **T35.3** — beam 修复:逻辑运算符、元组索引与 `Make_exception`。(2026-10-09 完成。)
- [x] **T35.4** — 金测:`examples/base64_demo` 挂全部五个列表。(2026-10-09 完成。)
- [x] **T35.5** — 文档:`docs/stdlib/base64.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 35 收尾(2026-10-09,`feat/stdlib` 分支):base64 是第一个挂满五个金测的标准库包——本步骤还揪出四个从未被已发布示例触及的潜在后端 bug:wasm 的 `&&`/`||` 左操作数漏了 `ref.cast`(这正是把 json/yaml/xml 挡在 wasm 金测之外的墙)、wasm 的零长度字节拷贝是会在 `"".to_bytes()` 上陷阱的 do-while、beam 的逻辑运算符对两个布尔调用 `emo_add`、beam 的元组索引对 Erlang 元组用 `lists:nth`;beam 还补上 `Make_exception`(异常对象即其消息)。json/yaml/xml 的 wasm 闸门应对照这些修复重验——`&&` 之墙已倒,但它们的跨模块类类型可能仍被 step-31 后续挡着。

格式包后端后续(2026-10-14,`develop` 分支):重验完成——`json_demo`、`yaml_demo`、`xml_demo` 现已挂上 wasm、beam、c 三个金测列表。`String.substring` 在 wasm 与 beam 上都没有运行时;wasm 补了边界内的字节拷贝,beam 补了在解释器范围检查之后的 `binary:part/3`。其后浮出两个 wasm 类 bug:class-pad 公式 `ordinal * (max_fields + 1) + field_count` 让(序号 0, 1 个字段)与(序号 1, 0 个字段)得到同一个两字段结构,于是 WasmGC 合并了两者的 RTT,`ref.test` 无法区分 `YamlNull` 与 `YamlBool`(解码出的 null 答成了 `YamlBool`,看起来像分派 bug);现在每个类的字段总数固定为 `(ordinal + 1) * (max_fields + 1) + 2`,按类唯一,且避开两个全 anyref 的运行时形状。此外 运行时里的 `get` 方法在两个 target 上都遮蔽了每个类的 `get` 方法(`doc.get("k")` 被降为 Bytes 索引);两个后端现在都在运行时判定 Bytes/实例,回退到 Bytes 访问器。

### Step 36 — 标准库:`slog` · `plan/step-36-stdlib-slog.md`

**前置:** Step 35(base64——纯原生类型的表面形状)。**完成标准:** `require "slog"` 每条记录打一行,logfmt 或 JSON,按最低级别过滤;logger 是普通的值——一个携带名称、级别、格式的不透明句柄——attrs 是键严格限于单一字母表的 `Map[String, String]`,金测挂 bootstrap、c、typescript 列表且逐字节一致;wasm 与 beam 在其运行时实现 `Map` 之前拒绝该包。

- [x] **T36.1** — 包本体:有序级别与两种格式、句柄打包/解析、logfmt 与 JSON 渲染器、严格键与精确错误。(2026-10-09 完成。)
- [x] **T36.2** — 金测:`examples/slog_demo`——两种格式、过滤、子 logger、引号与转义、UTF-8、`enabled`——挂 bootstrap、c、typescript 列表。(2026-10-09 完成。)
- [x] **T36.3** — 文档:`docs/stdlib/slog.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 36 收尾(2026-10-09,`feat/slog` 分支):slog 是第一个金测零编译器改动的标准库包——step-35 的 wasm/beam 修复顶住了,interp/ocaml/c/typescript 上的 `Map` 扛起整个表面。设计回答的是"没有框架的 logger":句柄把 `name/level/format` 摆在明处,包自身不持任何状态;记录不带时间戳(无时钟——输出确定,有时间的调用方把它作为属性传入);属性键严格限于与句柄百分号转义共享的同一字母表。manifest 声明今天可用的三个 target,wasm/beam 的 `Map` 缺口补上后加宽。

### Step 37 — 标准库:`bufio` · `plan/step-37-stdlib-bufio.md`

**前置:** Step 36(slog——金测零编译器改动的形状)。**完成标准:** `require "bufio"` 经固定大小缓冲、架在两个单方法结构接口上读写——`Reader` 有行、分隔符、peek、discard 与一级 unread;`Writer` 有合并写、显式 flush、绝不静默丢弃——fd 与内存适配器覆盖具体流,金测挂 bootstrap 与 c 列表且逐字节一致,c 后端的跨模块分派可靠(实例经自己的 vtable 应答、且只求值一次,Void 方法语句保住其调用)。

- [x] **T37.1** — 包本体:两个接口、四个适配器、`Reader` 与 `Writer` 表面、严格尺寸与精确错误。(2026-10-09 完成。)
- [x] **T37.2** — 金测:`examples/bufio_demo`——内存流、真正 flush 的 8 字节缓冲文件写、经两个叠层 reader 读回——挂 bootstrap 与 c 列表。(2026-10-09 完成。)
- [x] **T37.3** — c 后端修复:无类型接收者的运行时分派(`emo_dynamic_builtin` + 运行时方法表)、接收者表达式只求值一次、Void 语句方法的发射。(2026-10-09 完成。)
- [x] **T37.4** — 文档:`docs/stdlib/bufio.md` + zh-CN 镜像;`dune build @fmt` 与 `dune test` 全绿。(2026-10-09 完成。)

步骤 37 收尾(2026-10-09,`feat/bufio` 分支):bufio 是第一个状态以 Box 住在普通类里的标准库包——缓冲、游标、数据源、上次读到的字节都活在 `Box` 中,类在其周围保持不可变。本步骤揪出 c 后端跨模块方法调用路径的三个潜在 bug:把用户类上的 `read_line` 劫持到 socket 实现的名字劫持、接收者表达式被分派求值多达三次、Void 方法语句被编译成空。三处都已在运行时分派(`emo_dynamic_builtin`)修复——它只求值接收者一次,并在任何运行时方法之前把实例交给其 vtable。本包骑在 `os` 上,manifest 声明 ocaml 与 c target,待那些表面到达其他运行时再加宽。

### Step 38 — 标准库:`sqlite3` · `plan/step-38-stdlib-sqlite3.md`

**前置:** Step 23(c target 的直接 C ABI)+ Step 24(内嵌 stdlib)。
**完成标准:** c target 上 `require "sqlite3"` 打开数据库、执行 DDL、准备语句、绑定 int / float / text / null 参数并读取带类型列——消费方无需 `--cclib`、无需手工编译 shim;manifest 的 `link` 字段与随包携带的 `.c`/`.h` 源码随之落地;其他 target 一律拒绝(解析期 `targets` 闸门,或非 c 构建期的 E5007),解释器运行时拒绝(E3009);`dune test` 全绿。

- [x] **T38.1** — manifest 的 `link` 字段:解析(严格、可选、仅裸库名)与测试。
- [x] **T38.2** — 包可携带 `.c`/`.h`:`Registry.collect_files` 与 `gen-stdlib-data.sh` 收集并内嵌它们;publish 与 checksum 流程不变。
- [x] **T38.3** — 构建接线:`load_deps`/`compile_inputs` 收集每个依赖的 C 源码与链接库;c target 的 cc 调用与缓存键纳入它们;非 c 闸门(E5007)。
- [x] **T38.4** — `sqlite3` 包:manifest、`internal/ffi.emo`、`emo_sqlite3_shim.c`、`Database`/`Statement` 公开表面。
- [x] **T38.5** — c target 上的 `examples/sqlite3_demo` 金测(以 sqlite3 探针为门,与 `cc_available` 并列),外加 `test/emo_project` 里的原生依赖测试。
- [x] **T38.6** — 文档:CHECK.md 条目、README(+ zh-CN)、`docs/c-backend.md`(+ zh-CN)、`docs/stdlib/sqlite3.md`(+ zh-CN)、stdlib 巡览。

Step 38 收尾(2026-10-12,`feat/sqlite3` 分支):包系统学会携带原生代码——manifest 新增可选 `link` 字段(仅裸库名;旗标或路径形状的条目报 E5103),`.c`/`.h` 源码随包树进入收集、校验和、内嵌与发布——于是 c target 自行编译并链接依赖的原生输入,消费方零旗标。`sqlite3` 是首个消费者:以 `foreign def` 绑定随包携带的精确 ABI shim(`emo_sqlite3_shim.c`,每个签名只有 `int64_t`/`double`/`bool`/`const char *`),仅 c target,按 `os` 约定 raise,直到错误处理迁移落地。

---

## M12 — 可视化(`plot`)

T0 已落地:`plot` 把柱状图渲染成 SVG,在全部五个宿主 target 上逐字节一致,构建在内部 `Buffer`、标度/刻度、带 `SvgRenderer` 的 `Renderer` 接口,以及声明式的 `figure`/`axes`/`mark` 值之上。数值底座与 `math` 包(sequencing A)已完成。本 milestone 完成设计的 sequencing B–E:T0 表面的其余部分、`Table` 与通道(channels)、T1 数据集图表,最后是终端与 PNG 渲染器。设计与定案记录在 `docs/visualization.md`;包当前表面在 `docs/stdlib/plot.md`;本工作触及的语言使能项在 `docs/temp-visual-check.md`。范围之外(decision 9):交互/GUI 图表、EmoUI 画布、3D、动画。每个步骤的 plan 文件在步骤启动时编写。

### Step 39 — 绘图所需的编译器与语言使能项

与绘图各步骤相互独立;每一项要么解除下面工作的阻塞,要么降低其风险。
**完成标准:** 使能项自身的测试通过,且受影响的绘图代码用上它。

- [ ] **T39.1** — 精确类型化 `self.field`(`docs/temp-visual-check.md` 的 R2)并同步发射器,使 mark 的样式字段不必再扁平存储。今天在动态接收者上读取原生类型字段仍会被装箱,而发射器只按表达式的静态类型来决定原生/动态路径。
- [ ] **T39.2** — 与运行时方法同名的类方法不被遮蔽(R3)。`to_string` 已修;`length` 未修。
- [ ] **T39.3** — `math` 的可选原生快路径:在 `c`/`ocaml` 上分设 `*_native` 的 `foreign def` 函数(`math.exp` 纯净且逐字节一致,`math.exp_native` 为钉定的快路径;decision 15),并记明其 target 钉定。
- [ ] **T39.4** — 归档并修复绘图 spike 撞上的 `ocaml` 特化缺陷(`non-native expression in specialized body`、`Type_ref`),使特化后的原生体与解释器下降结果一致。

### Step 40 — T0 收尾:连续轴与其余 mark

**前置:** Step 39 可选(T39.1 让样式类更好写)。
**完成标准:** `examples/plot_demo` 增加 line/scatter/area/histogram 面板,并在全部五个 target 上逐字节一致;`dune test` 全绿。

- [ ] **T40.1** — 把 `Mark` 接口从分类式的 `y_max`/`bands`/`x_labels` 扩展出去(连续的 x 与 y 范围、`y_min`、`DrawContext` 所需的点/线图元),并让 `Bar` 保持首个实现。
- [ ] **T40.2** — `plot.mark.line` 与 `LineStyle`。
- [ ] **T40.3** — `plot.mark.scatter` 与 `ScatterStyle`。
- [ ] **T40.4** — `plot.mark.area` 与 `AreaStyle`。
- [ ] **T40.5** — `plot.mark.hist`(分箱计数)与 `HistStyle`。
- [ ] **T40.6** — `Axes` 绘制:连续 x 标度、从每个 mark 的范围推断出的 y 域,以及逐 mark 分派(取代今天只支持柱的 `first_labels`/`bands` 路径)。
- [ ] **T40.7** — 示例与金测:每个新 mark 一张图,全部五个 target 逐字节。

### Step 41 — 图形保真:标度、域、图例、网格、主题、颜色

**前置:** Step 39–40。
**完成标准:** T0 值已声明的每个字段都被渲染出来——对数标度、域、网格、图例、主题——且 `DrawContext` 按 `Renderer` 接口类型化,而非 `SvgRenderer`。

- [ ] **T41.1** — `Scale.log`:对数轴,刻度位置与格式正确。
- [ ] **T41.2** — `Domain.auto` / `Domain.fixed`:`Axes` 上的域字段,以及从 mark 推断(decision 19)。
- [ ] **T41.3** — `with_legend` 的图例渲染(decision 20 的绘制顺序规则;分面(faceting)下共用一份图例,T41.7)。
- [ ] **T41.4** — 从 `Figure.grid` 渲染网格,由主题的网格样式驱动。
- [ ] **T41.5** — `Theme` 作为 `Figure` 上的值(背景与前景,网格/轴/标题/标签样式,调色板、colormap、间距、默认尺寸;decision 24),配 `with_theme`。
- [ ] **T41.6** — 调色板与 colormap(decision 21/24):在 `Float64` 中插值,`color` 通道按列的类型分派,`plot.rgb` 校验 0–255 范围。
- [ ] **T41.7** — 分面(faceting,decision 23):排序后的水平、行 × 列、默认 `Share.all`、一份图例、逐面板标签、水平不匹配处留空格。
- [ ] **T41.8** — 把 `DrawContext` 与具体 `SvgRenderer` 解耦:按 `internal` 的 `Renderer` 接口类型化,好让终端或栅格渲染器接入(Steps 44–45 的前置)。

### Step 42 — Table 与通道

**前置:** Step 40。
**完成标准:** `plot.table` / `plot.table_missing` 构建出经校验的 `Table`,图表层通过词表解析通道。

- [ ] **T42.1** — `enum Presence { present, absent }` 与用于缺失数字的并行 `Map[String, Array[Presence]]`,统计跳过 `absent` 项(decision 25)。
- [ ] **T42.2** — `plot.table(numbers, labels)` 与 `plot.table_missing(numbers, presence, labels)`:列式 `Table`,形状违例抛出(decision 4/10)。
- [ ] **T42.3** — 通道 `Map[String, String]`(decision 16):词表 `x`/`y`/`color`/`size`/`marker`/`dash`/`facet_row`/`facet_col`,未知通道报错,每族只读它支持的通道。

### Step 43 — T1 数据集图表

**前置:** Step 41–42。
**完成标准:** decision 17 里的每个 `plot.*` 图表都在 T0 mark 上实现,fixture 在全部五个 target 上逐字节一致。

- [ ] **T43.1** — 统计:描述统计、分箱、KDE、ECDF、箱线统计,以及带置信带的 OLS;`normal_quantile` 与 `normal_cdf` 作为 `plot` 内部(decision 13)。
- [ ] **T43.2** — 关系型:`plot.scatter`、`plot.line`、`plot.reg`。
- [ ] **T43.3** — 分布型:`plot.hist`、`plot.kde`、`plot.ecdf`、`plot.box`、`plot.violin`。
- [ ] **T43.4** — 分类型:`plot.bar`、`plot.count`、`plot.strip`、`plot.point`。
- [ ] **T43.5** — 矩阵型:`plot.heatmap`、`plot.clustermap`。
- [ ] **T43.6** — 在图表层应用分面、调色板与主题;示例与逐字节金测。

### Step 44 — 终端渲染器

**前置:** Step 41(T41.8 的 `Renderer` 解耦)。
**完成标准:** 同一张图经同一份 Layer 0 值图渲染到终端,证明契约与格式无关。

- [ ] **T44.1** — 一个 Unicode `Renderer` 实现(mark 用方块或盲文、文本标签),位于 `internal` 的 `Renderer` 接口之后。
- [ ] **T44.2** — 经 CLI/示例路径接入,并测试同一张图既能经 SVG 也能经终端渲染。

### Step 45 — PNG 渲染器

**前置:** Step 44。
**完成标准:** `plot.png(fig)` 在全部五个 target 上从同一份值图产出合法 PNG,不依赖宿主图像库。

- [ ] **T45.1** — 纯 Emo 的 DEFLATE,stored blocks。
- [ ] **T45.2** — Fixed-Huffman DEFLATE、CRC32 与 Adler-32。
- [ ] **T45.3** — 带超采样的扫描线多边形/线段光栅化器。
- [ ] **T45.4** — 经 Hershey 笔画字体的文本。
- [ ] **T45.5** — `plot.png(fig)`、其示例与金测。

---

## M13 — 单元测试

`feat/unit-test` 上定案的测试面(2026-10-12):项目根部的 `test/` 目录——其中每个 `.emo` 文件都是测试文件,每个顶层 `def test_*` 都是一个测试——断言做成内建(`expect_equal` / `expect_true` / `expect_false` / `expect_fail`),失败时抛出唯一的 `Exception` 类,由 OCaml 运行器逐个测试捕获(Emo 没有 catch,运行器是唯一能截获 raise 的地方)。不新增任何语法构造。本分支上工作已经开始:T46.1–T46.5 与 T46.7 的部分实现留在树中尚未评审——各自按下面的任务定义补齐完成,而不是按现状直接并入。

### Step 46 — 单元测试框架:`emo test` 与 `expect_*` 内建

**前置:** 无(基于 develop)。
**完成标准:** 在带 `test/` 目录的项目里 `emo test` 运行每个 `def test_*`,逐测试报告 pass/fail/error 与捕获的输出,按退出码族退出 0/1/65;`expect_*` 内建在解释器中抛出真正的 `Exception`,在编译 target 上诚实地拒绝;`emo new` 脚手架带一个通过的测试;`dune test` 全绿。

- [x] **T46.1** — 解释器中的 `expect_*` 内建:在 `global_env` 注册、`apply_builtin` 分派,经 `expect_raise` 辅助函数抛出(沿用 `net_raise` 先例——真正的 `Exception` 实例;消息点名断言本身,`expect_equal` 渲染双方值);元数错误 E3007 / 类型错误 E3001 沿用现有内建风格。eval 测试:通过与失败路径、消息渲染、错误码。
- [x] **T46.2** — checker + IR 表面:checker 的 `empty_env` 补 `expect_*` 签名(Unknown 值参数、Void 返回——`println` 模式),`is_builtin` 的裸名列表加入四个 `expect_*` 名字,使编译程序引用这些名字时得到各后端的标配诚实拒绝(riscv 对所有内建统一拒绝;c / ocaml / ts / wasm / beam 在内建分派穷尽处补拒绝臂)。checker 测试覆盖签名。
- [x] **T46.3** — 求值器加 `reset_output`:默认输出槽具名化,`set_output` 重定向后可恢复(运行器的逐测试输出捕获)。
- [x] **T46.4** — `emo_project` 的运行器核心:`prepare_root`(在工作目录发现、从那里找 manifest)、`test_outcome` / `test_result` 类型,以及 `run_tests`——先全树检查(静态错误经 `Static_errors` 抛出),按首段 `test/` 选出测试模块,从模块 env 收集 `def test_*`(仅 `ArrowBlock`;带参数的 `test_*` 是收集错误,绝不调用),每个测试在独立的 `Emo_sched_det.run` 中运行,输出捕获后恢复;`Emo_raise` 判 failed,`Emo_eval.Error` 判 errored。project 测试:混合结果、收集错误、无 `test/` 目录、测试模块中的静态错误。
- [x] **T46.5** — `emo test` 子命令:报告(每测试一行,失败时附渲染的诊断与捕获的输出,末尾汇总行)、退出码 0/1/65、注册进根命令组、帮助文本写明约定。CLI 测试:一个全通过项目与一个失败项目,端到端。
- [x] **T46.6** — `emo new` 脚手架补 `test/greet.emo`(一个通过的 `test_greet`,内建无需 manifest 依赖),提示语提到 `emo test`;脚手架金测同步更新。
- [x] **T46.7** — `examples/test_demo/`:一个小模块、`test/` 下全通过的测试、供金测 harness 使用的 `expected.txt`;协调逐 target 金测构建(它们会降级树中每个模块——在 `expect_*` 于编译 target 拒绝期间,示例的测试模块不能把编译金测弄红)。
- [x] **T46.8** — 文档:README 增加 Testing 一节(约定、命令、内建、raise 只失败当前一个测试),并同步 `docs/zh-CN/README.zh-CN.md` 镜像。

## M14 — CSV 读写

`csv` 包像其他格式包一样从随编译器交付的 registry 读取和写出 RFC 4180 记录(只认 UTF-8)。它不需要任何按 target 的运行时工作:字节与数组就撑起整个表面,所以 golden 骑上全部五张 target 名单。

### Step 47 — 标准库:`csv`

**前置:** Step 35(base64——字节扫描纪律与“五张名单”的形态)与 step 31(json——格式包的约定)。
**完成判定:** `require "csv"` 把 RFC 4180 文本解码为 `Array[Array[String]]` 并写回,在全部五个 target 上逐字节一致——严格的引号规则、CRLF/LF/CR 记录、忽略开头 BOM、逐字节校验 UTF-8、带字节偏移的错误,以及用于 TSV 的单字节分隔符这对函数;五条金测路径全绿;`dune test` 全绿。

- [x] **T47.1** — 包:`stdlib/registry/csv/0.1.0`(manifest 声明全部五个 target,`csv.emo` 含记录模型、严格解码器、规范编码器、UTF-8 校验、分隔符那对函数)。
- [x] **T47.2** — 金测:`examples/csv_demo` 上 bootstrap、c、typescript、wasm、beam 名单;`examples/csv_edge` 上 bootstrap 名单——覆盖每种记录形态、格式错误矩阵、UTF-8 边界、BOM,以及编码器的引号规则。
- [x] **T47.3** — TypeScript 的 UTF-8 修复:运行时的解码器把三字节首字节 E8–EF 判为非法(`b < 0xe8`),导致 U+8000–U+FFFF 被解成 U+FFFD;`csv_demo` 暴露了它。
- [x] **T47.4** — wasm 的 `!` 修复:一元 `!` 直接读 `$vbool` 字段而漏了 `&&`/`||` 已经发出的 `ref.cast`,于是任何用到 `!` 的模块都无法通过 WebAssembly 验证;`bad_utf8` 里的 `!continuation(…)` 暴露了它。
- [x] **T47.5** — 文档:`docs/stdlib/csv.md` 及其 zh-CN 镜像;stdlib 导览与 README 的包清单。

## M15 — EmoUI

EmoUI 是语言语法为之塑形的声明式 UI 框架:UI 是组件的树,从显式状态渲染,没有模板语言——UI 就是普通 Emo。一个共享的应用模块(组件、`update`、`view`,对着可移植的 `ui` 核心写)渲染到终端、服务端页面、macOS/AppKit 窗口与 GTK 4 窗口;浏览器 DOM 随后按自己的运行时路径接入。每个平台可以有各自的组件库,但组件的调用与组合方式完全一致。设计与证据是 `docs/emo-ui.md`、`docs/emo-ui-check.md`、`spike/components` 与 `spike/emo-ui-probe`;EmoUI 各包活在本仓库的 `projects/emo-ui/` 下(`CHECK.md`,in-tree 项目布局),而设计发现的那几道编译器侧关口(原生打包机制、浏览器运行时路径)与终端输入包也落在本仓库。`c` 目标的长跑内存是 UI 逼出来的第四条,也是它拿不到白送的一条:2026-10-14 的 arena-scope spike 落定「廉价的解法不存在」,所以它被单独排期(**M16**,step 49),在它落地之前原生后端停在 demo 尺度——限制写进文档,而不是糊过去。

### Step 48 — EmoUI

**前置:** Step 23(`c` 目标与 `foreign def`)与 step 25(target 独立);跨模块类型名(2026-10-14)与 C→Emo 回调契约(2026-10-11)已在 `develop` 上。
**完成判定:** 共享的可移植 app 模块在 debug 与 SSR 后端上对全部五个托管 target 逐字节一致,并经薄薄的每平台入口驱动 TUI、macOS、GTK 4 与浏览器后端;组合语法在每个后端上完全相同;原生打包机制已落定,于是原生 UI 后端是一个 `require`,而不是手抄的 shim 构建;不需要任何语言改动。

**已落定决策(2026-10-14;全文在 `docs/emo-ui.md`):**

1. EmoUI 是**独立项目**,不是标准库包;稳定之后把可移植核心与纯 Emo 后端搬进标准库是可能的后续分拆,不是 v1。*(2026-10-15 由决策 11 修订:托管在本仓库的 `projects/emo-ui/` 下,而不是一开始就另建独立仓库。它仍不是 stdlib 包。)*
2. 树类型是**多模块的 `ui.Node`**(接口树脊加带类型 props 的具体类),不是字符串化的单类,也不是每平台一套节点类、没有核心。
3. **子节点是显式的 `Array[Node]`**;尾随 block 用于回调与迭代,且必须 `return` 其值——没有隐式子节点收集,所以 README 的示意树要改。
4. **布局是一套映射到原生布局的可移植词汇表**(CSS flexbox / GTK boxes / AppKit stack views / TUI 字符网格),不是共享 Emo 布局引擎;TUI 保留一个小 Emo 盒模型。
5. **样式是带类型值**,配工厂与 `with_*` 复制——不用字符串 map,不用默认参数(E4009)。
6. **状态是 Elm**,压在显式原语上;事件是登记在 Emo 侧的带类型消息,以后端可见的 `Int64` tag 暴露。
7. **后端是一个 Emo 接口**(`mount`/`patch`/`run`);九动词 `ui_*` 契约是原生实现细节。
8. **平台库共享收敛命名**;平台特有组件在调用点带上平台包名。
9. **顺序:TUI 与 SSR 先行,原生工具包其次,浏览器 DOM 最后。**
10. **不加新语法**;带检查的 block/函数类型是唯一值得之后掂量的语言诉求,不是关口。
11. **EmoUI 各包活在本仓库的 `projects/emo-ui/` 下**(已定 2026-10-15,`CHECK.md`)。该目录以将来那个仓库命名,好让 `git subtree split` 之后能带着历史把它拆出去;`projects/emo-os/` 与 `projects/emo-shell/` 由同一条决定预留,排期之前保持为空。终端输入(T48.5)随它一起落定为 `sqlite3` 形状的标准库包。

- [x] **T48.1** — 可移植 `ui` 核心包:`Node` 树脊与原语、带类型 `Style` 及其 `with_*` 复制、布局词汇表、`Backend` 接口。纯 Emo,全部五个托管 target —— 这也让 A/B 拼写 spike 发现的两个 codegen 缺陷成为本任务的一部分。**两项均已于 2026-10-15 落地:** `c` 的类元数据表移出方法符号所在的 `<cname>__<member>` 命名空间(现为 `vt_<cname>_fields` / `vt_<cname>_methods`,归入 `vt_<cname>` 与 `iface_<name>` 惯例),以及 `ocaml` 原生 `String` 的 `+` 补上它的 `= Emo_check.String` 分支(在 `emit_native_expr` 里产出 `(^)`);`spike/emo-ui-spelling/codegen/` 下的两个夹具就是回归,其 `check.sh` 断言两者的构建与运行。**核心包已于 2026-10-15 落地**:`projects/emo-ui/` 下 `ui.emo` 与它自己的 `package.emo`(`emo/ui`,声明全部五个托管 target)并列;它回答了 spike 留给它的 children 问题——children 仍是显式的 `Array[Node]`,而遍历之前不知道的子节点列表用 `ArrayBuilder` 攒,不是用 Emo 的 `Array.append` 循环。`projects/emo-ui/check.sh` 是这个包的关口。写它时又翻出一个工具链缺陷,已在此修掉:`emo emoji build` 把每个 target 的产物命名为 `emoji-<target>`,而 `beam` target 拒绝这样的模块名,于是任何声明了全部五个 target 的包都过不了发版前置关口。
- [x] **T48.2** — Elm 循环:`App`(model/`update`/`view`)、`ui.on(msg)` tag 登记表与 `ui.dispatch(tag)`、`ui.run(view, update, model, backend)`;tag 往返测试,以及保留式 `patch` 对全量重建。**已于 2026-10-15 落地**:`projects/emo-ui/ui.emo` 连同它的 `test.emo`(十四条断言,由 `./check.sh` 跑)。tag 登记表是循环自己持有、并交给 `view` 的 `Registry` 对象,而不是 Layer 5 草拟的模块级表——模块级 `const` 在编译目标上每次读取都会重跑初始化式,而模块级 `var` 只有 `ocaml` 支持(`CHECK.md`)。循环在 `ocaml`、`typescript`、`beam` 上可编译;`c` 拒绝 `ui.run` 收下的裸 def,`wasm` 拒绝 `update` 需要的双参动态调用——把这两个函数放到 `Handler` 接口后面之后,同一个循环五个 target 全部可编译(`CHECK.md`、`projects/emo-ui/probe/`)。
- [x] **T48.3** — 无头 `debug` 后端:把树渲染成稳定文本,作为逐字节一致的金测 harness。**2026-10-15 落地**为 `projects/emo-ui/debug.emo`(核心自己那个包里的一个模块,好让核心的测试也能用它)加 `projects/emo-ui/golden/`(处在消费者位置上的包,`deps { "emo/ui" = "0.1.0" }`,经 `./check.sh` 现场搭出的 registry 抵达核心)。文本形式是一个节点一行、每层两个空格,先属性再一份字段顺序固定的样式摘要;`Debug` 就在这份文本之上实现 `Backend`,把循环交给它的每一棵树记进日志,而它的 `run()` 什么也不驱动——无头意味着没有输入源,事件靠手工步进。`golden/main.emo` 是一块涵盖每个原语、`w=`/`h=` 两个分支、全部四个 `Align` 取值、一个空属性与嵌套容器的界面;`expected.txt` 是解释器的输出,在 `ocaml`、`c`、`typescript`、`beam` 上相同,而 `wasm` 根本降不下核心(即 T48.2 的循环形状)。过程中掉出两处静默的跨 target 分歧,已连同最小对照记下(`CHECK.md`):操作数曾按 target 的顺序求值,`ocaml` 与其它 target 相反——2026-10-17 已修,所有 target 统一从左到右;枚举在 `typescript` 上插值出的字节不同、在 `beam` 上根本插不了(`probe/eval_order`、`probe/enum_print`)。
- [x] **T48.4** — `ui-tui`:字符网格布局(那个小 Emo 盒模型)与 ANSI 绘制;一段脚本化输入的金测。**2026-10-16 落地**为 `projects/emo-ui/tui/`(包 `emo/ui_tui`:`ui_tui.emo` 与 `test.emo`),声明四个能写 stdout 的托管目标——`wasm` 的运行时没有 `printf`,所以终端后端不是 `wasm` 包。盒模型以字符格为单位度量核心的 `Style`:列是纵向堆叠、行是横向排列,`padding`、`gap`、`align`、`grow`、`width`、`height` 决定每个子节点的位置;`screen(root, w, h)` 把网格作为 `Array[String]` 交回,于是这套算术不必靠字节就能测;`paint(root, w, h)` 把一帧写成 ANSI(清屏、归位、每行一行),转义字节经 `printf("%c", [27])` 发出,因为字符串字面量的转义是最小集合、0x1b 不在其中。`Tui` 在其之上实现 `ui.Backend`,`Input`/`Script` 是脚本化事件源:`run()` 从输入拉取 tag,交给循环的 sink,直到输入说没有了,这就是金标不碰终端的原因(T48.5 替换的是源,不是接缝)。`tui/golden/` 是两个包的消费者(`deps` 指向 `emo/ui` 与 `emo/ui_tui`):一块界面包含一行带居中较矮子节点的 row、一个带 grow spacer 的 scroll、一个定宽 text input 与两个按钮,由一段点击 Add、Add、Sub 的脚本驱动。`expected.txt` 是解释器的输出,在 `ocaml`、`typescript` 与 `beam` 上相同;`c` 能编译后端,却拒绝金标那个循环形状(`Global`)——T48.2 留下的那个决定,如今深了三个 target。`tui/check.sh` 是关口(包通过类型检查、十三条断言跑过、四个声明的 target 都能构建、`wasm` 的 `printf` 拒绝被钉住、金标字节被比对)。金标逼出的两个 `beam` 缺陷在这里修好,都记在 `CHECK.md`:`Block` 值的裸 def 被发射成指向未导出函数的远程 fun,`erlc` 接受但加载器让它无法调用(`main/0` 报 `undef`);循环体里的 `case` 重绑外层 `var` 时没有把重绑穿出,于是分支里设置的 `while` 退出永远看不到。`test/emo_cli` 的 `beam_block` 与 `beam_var` 两组是回归。`examples/tui_menu/` 是用法示例——同样的模式,换成一个四行菜单与更长的脚本——同一个关口在它声明的每个 target 上检查它。
- [ ] **T48.5** — 终端输入:raw mode 与按键事件,做成 **`sqlite3` 形状的标准库包**——包自带 `.c`/`.h`,经 `foreign def` 调用,由 manifest 的 `targets` 把关——而不是 UI 框架侧或编译器侧的产物(已定 2026-10-15,`CHECK.md`);行模式先行。
- [ ] **T48.6** — `ui-ssr`:节点树到 HTML 加样式表,在全部五个托管 target 上逐字节一致;交互模型是表单与链接。
- [ ] **T48.7** — 原生打包机制:per-package 的 manifest 字段(`pkg_config` 与/或编译/链接 flags,以及收集 `.m` 的那部分);应用级构建脚本不是受支持的路径。T48.8 与 T48.9 的关口。
- [ ] **T48.8** — `ui-macos`:九动词 AppKit shim,压在回调契约上;一致性语料跑通。demo 尺度——`c` 目标的长跑内存是 step 49(`CHECK.md`)。
- [ ] **T48.9** — `ui-gtk`:GTK 4 shim,用 `pkg-config` 构建;一致性语料跑通。demo 尺度,同 T48.8。
- [ ] **T48.10** — 浏览器运行时路径:TypeScript 运行时拆出浏览器安全版(或一个 `dom_*` 家族)加打包步骤;T48.11 的关口。
- [ ] **T48.11** — `ui-browser`:压在浏览器路径上的 DOM 后端;一致性语料跑通。
- [ ] **T48.12** — 一致性语料:一个示例应用跑在每个后端上,全程用同一个可移植 app 模块。
- [ ] **T48.13** — 文档:README 的 EmoUI 一节改成数组子节点写法并写入已定决策;`docs/emo-ui.md` 中够格进 README 的部分落定为已定设计;EmoUI 各包的参考写进它自己的仓库。

---

## M16 — 值语义家族的回收

`c` 目标的回收模型(T23.5,2026-10-11)只对带身份的那些格做引用计数——实例、闭包、`Box`——而所有值语义的种类(字符串、元组、数组、map、list、bytes、枚举、装箱标量)都住在 bump arena 里,直到进程退出才释放。UI 每个事件重跑一次 `view()`,用的恰好就是这些种类——这就是把一个整洁度问题变成产品问题的原因。2026-10-14 的 arena-scope spike 实测了代价、排除了廉价的解法,并落定了方向:region 回收 100% 的 arena 字节与 0% 的泄漏,因为身份是在 region 之外 `malloc` 的,而 arena 的聚合体跨过它的边界 retain 它们——reset 于是把那些引用计数永久搁死。真正的解法是值语义家族的引用计数,也就是本里程碑(`CHECK.md`、`spike/arena-scope/`)。这里没有任何东西是 step 48 的先决条件:原生后端以 demo 尺度构建,限制写进文档。

### Step 49 — 值语义家族的回收 · `plan/step-49-value-reclamation.md`

**前置:** 无——明确不是 step 48 的先决条件。
**完成判定:** 一个长跑的 `c` 目标程序持有平坦的工作集——arena 字节与身份存活数不再随每次渲染上涨,而是跟随活着的树;数组增长是线性而非二次;每个 target 上既有的金测逐字节不变;解释器与非 `c` 目标不受影响。

- [ ] **T49.1** — 运行时:把身份纪律(`emo_identity_kind`、`emo_retain`/`emo_release`,以及往聚合体里存值的那些构造器)从三种身份格扩展到值语义家族,让一个值格能走到引用计数归零、聚合体释放它所持有的东西;包含「值语义的构造不会成环」这一审计。发射器本来就对每个动态绑定做 retain 与 release(`emo_c.ml:1851`、`:423`),所以这一项从运行时侧起步。
- [ ] **T49.2** — 粒度:在每种动态类型都可能持有内存之后,决定 autorelease pool 拥有什么并实现它——表达式内部的临时值是难的那一半,`may_own` 加上随之而来的构造器审计(`emo_c_runtime.c:1753`)。
- [x] **T49.3** — 数组的形状:一个 O(1) 的 append 或一个 builder,让 k 元素数组的增长在字节与 retain 上都不是二次的;T48.1 的 children 表示取决于这个答案。**2026-10-15 已定 —— 走 builder,并且是语言层的新类型(`ArrayBuilder`),而不是 `Array` 的表示层改动。** 方法面 `new()` / `push` / `length` / `get` / `to_array`,解释器与五个宿主目标全上(`riscv64` 按名拒绝,退出码 65,`Map` 的先例);第一条静态可知类型的 `push` 钉住被 push 链最底端那个 `const` 绑定的元素类型(`docs/intro/syntax.md`,可变性)。这一项点名的第二种形状——从 `List` 转回可索引的 `Array`——刻意不做。数组这一半由此在没有动运行时的前提下得到回答,所以 step 49「数组增长是线性而非二次」这条判据现在可以从语言侧达成,而不必等 T49.1;T48.1 的表示问题是解除了阻塞,并已由核心包给出答案(2026-10-15):children 是一份显式的 `Array[Node]`,而动态的子节点列表由容器自己攒。
- [ ] **T49.4** — 闸门:把 spike 的渲染阶梯与 region 探针做成签入的测试——今天失败、之后通过,只针对 `c` 目标,且 `dune test` 全绿。
- [ ] **T49.5** — 文档:`CHECK.md`、`docs/emo-ui.md` 及其 zh-CN 镜像,以及 step 48 的 demo 尺度注记都改为指向此处。

---

## M17 — 跨 target 一致性

2026-10-14 的一次 target 可行性调查,把并发相关的承诺逐条对照了每个实现,发现三处规则与代码不一致(`CHECK.md`,跨 target 不变量)。其中两处从来就不是开放的设计问题:`docs/intro/concurrency.md` 早就承诺未捕获的错误「只杀掉出错的那个进程」,`docs/intro/syntax.md` 早就承诺 Map、Box、List 与 ArrayBuilder 在进程边界上按快照复制——解释器、独立 OCaml 运行时与 BEAM 都遵守这两条,`stdlib/registry/sync/0.1.0/sync.emo` 更是白纸黑字写明了句柄的发送规则。`c` 目标是唯一跑偏的实现,所以这里做的是**一致性修复,不是语言设计**:没有承诺被改动,README 也没有变化。第三处是同一形状的 emitter 侧问题——能力表本该是 `foreign def` 的唯一闸门,但它对每个 target 都放行 `Float64`/`String`/`Bool`,于是一个 `foreign def` 绕过了闸门,直接抵达 `wasm` 与 `beam` 两个 emitter。本里程碑自己的发现是:调查对 `raise` 缺口的代价估算是错的,而且错得很远——它设想的机制(`setjmp`/`longjmp`,外加沿每个被展开的 C 帧做引用计数排空)从来就不需要,因为运行时的 autorelease pool 本就是挂在 fiber 上的堆分配帧链,而 fiber 的收尾路径早已存在。这里的一切都局限在运行时与 emitter 内部。

### Step 50 — 跨 target 一致性 · `plan/step-50-cross-target-conformance.md`

**前置:** 无。
**完成标准:** `c` 目标里派生的进程 raise 后独自死亡、父进程继续运行;可变值在 `c` 目标进程之间发送后送达的是快照;`foreign def` 在 `wasm` 与 `beam` 上按名拒绝并以 65 退出;每个 target 上既有的金测逐字节不变;`CHECK.md` 把三处都记为已定,并把 `typescript` 的 send 缺口点名列为剩余项。

- [x] **T50.1** — `foreign def` 的拒绝:`emo_wasm.ml` 与 `emo_beam.ml` 逐函数、就在本该降级它的代码旁,用 `Emo_ir.Lower_error` 拒绝 `foreign def`——riscv 的先例——于是 CLI 把它渲染成退出码 65。调查留下的悬念(「最后是干净的拒绝,还是一个悄悄缺席的符号」)答案是后者:IR 把符号挂在一条其余部分普通的 `func` 记录上、函数体为空,所以两个 emitter 都在为一条没有 Emo 函数体的声明发射一个真实的函数。
- [x] **T50.2** — `c` 目标的 `raise` 结束逻辑进程:`emo_raise` 在当前 fiber 不是根的时候排空它的帧链并停掉它,而调度器之外或根进程里的 raise 保持「渲染并 `exit(1)`」这条路(`docs/intro/concurrency.md`)。`halt()` 走同一个排空——它此前泄漏整条帧链,是另一处形状完全相同的站点。没有 emitter 改动,也没有展开器:帧链在堆上,而 fiber 的收尾路径早已存在。
- [x] **T50.3** — `c` 目标的 `send` 送快照:`emo_deep_copy` 在发送处重建可变的那些种类,信箱持有这份副本,遵循解释器自己的规则,覆盖本运行时装有的那些种类。随之而来的是一行 emitter 改动——信箱的 take 会释放它唯一的那份持有,所以 receive 的扫描现在自己持有一份。
- [x] **T50.4** — 文档:`CHECK.md` 的跨 target 条目改写为已定并修正代价估算,`docs/intro/concurrency.md` 里按引用传递那句修掉,T23.6 的注记更新,设计闸门表更新,本里程碑补上。`typescript` 目标 send 仍共享这一项记为条目的开放剩余项,而不在这里修,因为修它属于浏览器运行时拆分(T48.10)的工作。

---

## M18 — `c` 目标上的 TLS

TLS 从来不缺位于标准库——`net_tls_connect`、`net_tls_connect_insecure` 与 `net_listen_tls` 早已是内建,解释器的调度器与独立 OCaml 运行时通过 opam `ssl` 库实现了它们,`typescript` 映射到 `node:tls`,`http` 的 `https://` 更是在纯 Emo 源码里路由到 `net.tls_connect`。缺口在 `c` 目标——也就是默认 target:三个名字落进 `emo_unsupported`,`https` 恰好死在 `emo build` 默认运行的地方。这里做的是一致性,不是新表面:C 运行时以 ocaml 调度器为语义基准,把三个内建落在系统 OpenSSL/LibreSSL 之上;链接按 IR 的实际使用闸住,不碰 TLS 的程序绝不链接 OpenSSL;原型全部手写,因为没有哪个 target 平台欠我们一份 OpenSSL 头文件;用户级 FFI 路线经过评估后被拒绝(`CHECK.md`)。

### 步骤 51 — `c` 目标上的 TLS · `plan/step-51-tls-c-target.md`

**前置:** 无。
**完成标准:** `https://` 请求在 `c` 上端到端跑通(captive TLS server,与解释器的 `expected.txt` 逐字节一致);验证通过的握手、verify-fail 钉子、insecure 轮转与服务端 TLS echo 在解释器与 `c` 上全绿;不用 TLS 的 `c` 构建既不链接也不依赖 OpenSSL(`nm` 钉子),每个 target 上既有的金测逐字节不变;运行时自造的 reason 字符串在 interp / `c` / 独立 ocaml 运行时三方逐字节一致;文档把故事讲全(`docs/stdlib/net.md`、`docs/stdlib/http.md`、zh-CN 镜像)。

- [ ] **T51.1** — 链接闸门:`emo_c_runtime.c`/`.h` 里圈出的 TLS 段——手写原型加冻结常量,`EMO_HAS_TLS` 下是真实现,否则是 `emo_unsupported` 函数体——emitter 为三个名字开显式臂并翻起 IR 走查的 `uses_tls` 旗标,CLI 经 cclib 槽位有条件地追加 `-DEMO_HAS_TLS` + `-lssl -lcrypto`,前置一个探测调用、失败时报出修复办法;c_goldens 里用 `nm` 钉住「不用 TLS 的构建不引用任何 `SSL_` 符号」。
- [ ] **T51.2** — 客户端握手:TCP 复用既有的 `emo_net_connect`,随后非阻塞 `SSL_connect` 按 `WANT_READ`/`WANT_WRITE` 停车(调度器的 poll 循环补上可写等待钩子);`TLS_client_method`、TLS 1.2–1.3 窗口、系统信任库、SNI、`SSL_set1_host` + `SSL_get_verify_result`、带库自身版本串的版本下限拒绝、`the TLS handshake with <host>: ` reason 前缀,以及 CA + 服务端证书夹具(`SAN=localhost,127.0.0.1`)经 `SSL_CERT_FILE` 驱动的验证通过回环握手。
- [ ] **T51.3** — 数据面与 insecure 变体:读/写按 `fd → SSL*` 侧表分流,停车纪律与握手相同;`close()` 走 `SSL_shutdown` 并释放;超时语义对齐 ocaml 侧 conn;`net_tls_connect_insecure` 是同一条路只关验证。
- [ ] **T51.4** — 服务端:`net_listen_tls` 加载 PEM 对(失败时报 ocaml 同形的 `cannot load the TLS certificate for <host>:<port>`),监听 fd 登记上下文,`accept` 执行 `SSL_accept` 并登记连接;解释器与 `c` 各跑一个程序内的 TLS echo 服务端 + 客户端,落在本机 `127.0.0.1:0`。
- [ ] **T51.5** — 金测:`examples/https_roundtrip` 打 harness 的 captive ocaml-ssl TLS 服务端,`expected.txt` 取自解释器、在 `c` 上逐字节一致,挂进 c_goldens;独立 OCaml 运行时补上它自己的 TLS 轮转测试——那条路实现了 TLS 却从来没测过。
- [ ] **T51.6** — 文档:`docs/stdlib/net.md` 的 TLS 限制改成已实现的故事(ocaml-ssl / node:tls / 系统 OpenSSL-LibreSSL,写明版本下限),`docs/stdlib/http.md` 的「`https` 需要 TLS,而 `c` 拒绝」退场,zh-CN 镜像、闸门表与 `plan/README.md` 状态表同步。
