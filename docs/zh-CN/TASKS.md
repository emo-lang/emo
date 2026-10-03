# 开发任务清单

> 中文版,与英文版 [docs/TASKS.md](../TASKS.md) 内容一一对应;更新英文版时请同步更新本文件。

从 `plan/step-01-project-scaffold.md` 到 `plan/step-14-other-targets.md` 汇总而成的编号任务清单。plan 文件仍是规格说明——下面每个任务所属的步骤文件里有完整的目标、范围与验收标准。本文件是进度追踪表。

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
| M1 — MVP 解释器 | 01–07 | 单文件 Emo 程序(函数、类、枚举、异常)可通过 `emo run` / `emo repl` 运行,错误信息可读。 |
| M2 — 编译期体验 | 08–10 | 渐进类型检查器、结构化模块系统、基于 MVS 的包解析;多包项目可构建、可运行。 |
| M3 — 并发与网络 | 11–12 | 基于效果(effect)调度器的进程与消息传递;直风格(direct style)网络 API。 |
| M4 — 编译目标 | 13–14 | 通过 `emo build` 生成原生代码;随后是 wasm / TypeScript / BEAM / qemu。 |

## 设计闸门

`CHECK.md` 中记录、并阻塞下述任务的未落定决策。开始被闸门挡住的工作之前,先落定它们:

| 决策 | 阻塞的任务 | 落定前的临时方案 |
| --- | --- | --- |
| CLI 命令名 | T1.3、T7.1–T7.2 | 已在 M1 落定——`run` / `repl` / `check` / `version` 已随 M1 交付 |
| 字符串转义规则 | T2.3、T2.4 | 最小集合 `\n \t \\ \' \"` |
| 进程获取自身 pid 的机制 | T11.1 | 已落定——`self_pid()` 内置、`Pid` 类型渲染为 `<pid N>`、`halt()`;核心不提供用户态 kill/wait |
| 异常捕获语法 | T12.5、步骤 12 验收 | 暂无 catch 形式;仅有未捕获异常报告 |
| 清单/锁文件文件名、scope 前缀格式、版本区间、deps CLI 命令名 | T10.2、T10.5–T10.6、T10.8 | `package.emo`、`emo.lock`、`owner/name`、仅精确版本、`emo deps *` |
| C FFI 绑定表面语法 | T13.6 | 已落定——`foreign def name(params) Ret = "c_symbol"`,仅 `Float`/`String`/`Bool`,经生成的 C 包装器编组 |

---

## M1 — MVP 解释器

### 步骤 01 — 项目脚手架与 CLI 骨架 · `plan/step-01-project-scaffold.md`

**前置:** 无。
**完成标准:** 干净检出后 `dune build` 和 `dune test` 通过;`emo version` 输出 `emo 0.0.1`;占位子命令以非零码退出;CI 在 Linux 和 macOS 上全绿。

- [x] **T1.1** — 创建 `dune-project` 和 `src/` 各库骨架(`emo_support`、`emo_lexer`、`emo_parser`、`emo_ast`、`emo_eval`、`emo_check`、`emo_cli`),用能编译的占位模块填充。
- [x] **T1.2** — 实现 `emo_support`:span、severity、diagnostic、渲染器;为渲染器写单元测试。
- [x] **T1.3** — 用 cmdliner 实现 `emo_cli`;把四个子命令接到占位动作上。
- [x] **T1.4** — 为每个库添加 alcotest 冒烟测试和 CI 工作流(setup-ocaml、`dune build`、`dune test`,Linux + macOS)。
- [x] **T1.5** — 添加 `.ocamlformat`(conventional profile);整体格式化一次(`dune build @fmt` 通过)。

### 步骤 02 — 词法分析器 · `plan/step-02-lexer.md`

**前置:** 步骤 01。
**完成标准:** 测试覆盖所有 token 类别、插值嵌套(`"a ${ "b ${x}" } c"`)、多行输入的位置精度,以及每个错误用例;`dune test` 全绿。

- [x] **T2.1** — `emo_lexer` 中的 token 类型与带位置的 token 流。
- [x] **T2.2** — 两类标识符(`LOWER_IDENT` / `UPPER_IDENT`)、关键字、运算符。
- [x] **T2.3** — 数字与字符字面量,含转义处理。
- [x] **T2.4** — 插值字符串的 token 方案,带嵌套测试。
- [x] **T2.5** — 保留换行信息的流式 API。
- [x] **T2.6** — 错误用例:每个都经 `emo_support` 以正确的行列号拒绝。

### 步骤 03 — 解析器:表达式 · `plan/step-03-parser-expressions.md`

**前置:** 步骤 02。
**完成标准:** README 中的每个表达式片段都解析为预期 AST(金测/golden 测试);优先级被固定(`1 + 2 * 3`、`a && b || !c`、`x.foo(1)[i].bar?()`);`dune test` 全绿。

- [x] **T3.1** — `emo_ast` 的表达式/语句类型,每个节点都带 span。
- [x] **T3.2** — 按优先级表实现的 Pratt 式表达式解析器。
- [x] **T3.3** — 调用解析:位置参数 + 具名参数、尾随块语法糖。
- [x] **T3.4** — 箭头块;`if` / `else`(单一形态,无链式)。
- [x] **T3.5** — 带深度追踪的换行终止规则。
- [x] **T3.6** — 从词法部分重组插值字符串。
- [x] **T3.7** — 解析器测试:优先级表、行尾悬空运算符的续行、非法输入报错。

范围说明:按内容规则解析的元组字面量、元组模式、`case` / `receive` / `do` / 发送语法都在本步骤内完成解析(语义在步骤 05 / 11 之前保持"尚未实现"错误)。

### 步骤 04 — 解析器:声明 · `plan/step-04-parser-declarations.md`

**前置:** 步骤 03。
**完成标准:** README 中的 `User`、`Greeter` / `English`、`welcome`、`Color` 片段解析为金测 AST;反向测试(camelCase `def`、`UPPER` 变量、枚举载荷、重复 `init`、给 `init` 标返回类型)以正确的消息和 span 拒绝;`dune test` 全绿。

- [x] **T4.1** — 声明 AST 节点;顶层项序列。
- [x] **T4.2** — `def` 解析,含 `init` 豁免与 `?` 命名规则。
- [x] **T4.3** — `class`(单一 `init` 规则,从 `self.x =` 收集字段)。
- [x] **T4.4** — `interface` 仅签名的类体。
- [x] **T4.5** — `enum` 成员列表。
- [x] **T4.6** — `raise` 语句。
- [x] **T4.7** — 带 span 的命名规范检查;多错误恢复。
- [x] **T4.8** — 金测:README 示例干净解析;违反命名规范产生预期错误。

### 步骤 05 — 解释器:核心值与求值 · `plan/step-05-interpreter-core.md`

**前置:** 步骤 04。
**完成标准:** 验收程序可运行(`fib(20)` → 6765、插值问候语、`count_down(1000000)` 且栈保持平坦);`dune test` 全绿,含深递归用例。

- [x] **T5.1** — 值 ADT + 相等性;环境链。
- [x] **T5.2** — 带 tag 检查运算符的表达式求值。
- [x] **T5.3** — 插值;`print` 内建;`.to_string()`。
- [x] **T5.4** — 闭包捕获(词法作用域,按引用指向环境)。
- [x] **T5.5** — 求值器中的尾调用循环;深递归测试。
- [x] **T5.6** — `if` / `return` 语义;带 span 的运行时类型错误。
- [x] **T5.7** — 端到端运行真实程序的 alcotest 测试(断言捕获到的 stdout)。

范围说明:数组、元组和 `Box`(三个操作构成的完整操作集)都属于本步骤的值模型。`print` 是临时名字——I/O 表面设计落定后提升进 README。

### 步骤 06 — 解释器:类、枚举、接口 · `plan/step-06-interpreter-objects.md`

**前置:** 步骤 05。
**完成标准:** README 的对象示例原样可跑(值语义的 `User`、`Color`、鸭子类型的 `welcome`、结构化的 `is()`);反向测试(在 `init` 之外 `self.x =`、调用缺失方法、未捕获 raise)按规格报错;`dune test` 全绿。

- [x] **T6.1** — `ClassDef` / `Instance` 值;`init` 窗口标记;字段冻结。
- [x] **T6.2** — 方法分派 + `self`;`NoMethodError`。
- [x] **T6.3** — 实例的深 `==`;共享结构的不可变性测试。
- [x] **T6.4** — 枚举单例;`TypeValue`;带结构化接口检查的 `is()`。
- [x] **T6.5** — `raise`;内建 `Exception`;未捕获异常终止。
- [x] **T6.6** — 实例、枚举、异常的 `.to_string()`。

### 步骤 07 — CLI 与诊断 · `plan/step-07-cli-diagnostics.md`

**前置:** 步骤 01–06。
**完成标准:** 每个 `examples/*.emo` 在 CI 中以预期输出运行;含三个解析错误的文件一次报告全部三个、行列号正确、`--no-color` 下稳定;REPL 可交互运行步骤 06 的验收块。**达成 M1 完成标准。**

- [x] **T7.1** — `run` 命令,含阶段流水线与退出码(词法/解析 65,求值 70,未捕获异常 1)。
- [x] **T7.2** — REPL:多行读取、持久环境、值回显。
- [x] **T7.3** — 诊断渲染器完善(源码摘录、错误码、提示、颜色、错误上限);基于金测渲染的单元测试。
- [x] **T7.4** — 求值器中的未捕获异常追踪管道。
- [x] **T7.5** — `examples/` 金测接入 CI。
- [x] **T7.6** — 人工过一遍:运行每个示例,交互使用 REPL。

收尾说明:把 M1 验证过的临时决定(`print`、尾随块语法糖)提升进 README。

---

## M2 — 编译期体验

### 步骤 08 — 渐进类型检查器 · `plan/step-08-type-checker.md`

**前置:** 步骤 01–07。
**完成标准:** 每个 README 示例类型检查干净;带注解的错误语料(错误返回类型、非法具名参数、`var` 逃逸、收窄误用)以正确 span 拒绝;零误报纸料通过且无任何诊断;`emo check` 可用,且 `emo run` 先跑同一检查。

- [x] **T8.1** — 类型表示 + 注解收集 pass。
- [x] **T8.2** — 在 `Unknown` 纪律下的语句/表达式检查。
- [x] **T8.3** — 签名检查;箭头块推断。
- [x] **T8.4** — 基于 `is()` 收窄的流敏感环境。
- [x] **T8.5** — 结构化接口一致性。
- [x] **T8.6** — `var` 逃逸检测。
- [x] **T8.7** — 调用点检查;具名参数校验。
- [x] **T8.8** — `case` 检查:模式类型化、`when` 守卫须为 `Bool`、可判定枚举的穷尽性,以及可判定 `(Enum, ...)` 元组的首元素穷尽性(带守卫的分支不计入覆盖)。
- [x] **T8.9** — `emo check` 命令;接入 `emo run`。
- [x] **T8.10** — 测试类别:严格注解拒绝、推断成功、零误报纸料。

后续:把选定的 `var` 逃逸分析近似方案写进 `docs/`。

### 步骤 09 — 结构化模块系统 · `plan/step-09-modules.md`

**前置:** 步骤 01–08。
**完成标准:** README 的 `shop/` 目录树原样可跑(路径即模块、`const` 别名);从 `shop` 之外引用 `shop.internal.discounts` 报错并同时点名两个模块;两模块循环被拒绝并给出完整链路;多文件测试全绿。

- [x] **T9.1** — 模块路径解析(文件 ↔ 模块名;冲突即错误)。
- [x] **T9.2** — 惰性 `Module` 值接入求值器的成员访问。
- [x] **T9.3** — 加载顺序编排;仅加载一次语义。
- [x] **T9.4** — 检查期间提取引用图。
- [x] **T9.5** — `internal/` 子树私有检查。
- [x] **T9.6** — 带链路报告的循环检测。
- [x] **T9.7** — 按内容哈希的进程内缓存。
- [x] **T9.8** — `examples/` 下镜像 README `shop/` 树的多文件测试项目。

注意:已在步骤 10 解决——项目以其最近的 `package.emo` 为根;无清单的目录树仍沿用工作目录规则。

### 步骤 10 — 包与版本解析 · `plan/step-10-packages.md`

**前置:** 步骤 01–09。
**完成标准:** README 的 `require "acme/json_tools"` 场景对固定注册表(fixture registry)可跑通;从 `deps` 移除依赖但 `require` 仍在是编译错误;冲突的精确版本解析为最高版本且第二次运行校验锁文件校验和;`targets` 不含当前目标的依赖在解析期报错。**达成 M2 完成标准。**

- [x] **T10.1** — `require` 解析 + 作用域规则。
- [x] **T10.2** — 清单阶段 A:严格 schema 解析器,带 span 报错。
- [x] **T10.3** — 严格的 require/deps 配对检查。
- [x] **T10.4** — 带目标兼容性闸门的 MVS 解析器;针对版本格(unit lattice)的单元测试。
- [x] **T10.5** — 锁文件读/写/校验;不匹配报错。
- [x] **T10.6** — 注册表客户端 + 内容寻址缓存 + 供测试的目录注册表。
- [x] **T10.7** — 清单阶段 B:带步数预算的受限 profile 求值。
- [x] **T10.8** — 端到端 fixture:两个本地包,其一依赖另一,解析、锁定、构建、运行。

同时:把步骤 09 的过渡性根规则换成基于清单的根规则——已完成;根规则现在优先取最近的 `package.emo`。

---

## M3 — 并发与网络

### 步骤 11 — 进程与消息传递 · `plan/step-11-concurrency.md`

**前置:** 步骤 01–10。
**完成标准:** 乒乓(100 万条消息)与扇出/扇入(1000 个 worker)在 Eio 版和自研 effects 调度器下都正确;消息处理中途 raise 的进程独自死亡、父进程继续;发送 `Box` 送达快照;递归数百万次的 receive 循环保持原生栈平坦;确定性调度器下 `dune test` 全绿。

- [x] **T11.1** — 设计 pass:在 `CHECK.md` / README 中落定自 pid 机制(`do`、`<-`、`receive { ... }` 与 `Box` 操作集均已决定)。本步骤其余任务的前置闸门。
- [x] **T11.2** — 基于 Eio 的进程/邮箱抽象;spawn/send/receive。
- [x] **T11.3** — 崩溃隔离;供未来监督者使用的进程退出信号。
- [x] **T11.4** — 快照随发送语义的 `Box`。
- [x] **T11.5** — 供测试用的确定性调度器日志。
- [x] **T11.6** — 阶段 B:同一接口之下的自研 effects 调度器。
- [x] **T11.7** — 压力测试:乒乓、扇出/扇入、深 receive 循环递归。

### 步骤 12 — 网络库 · `plan/step-12-networking.md`

**前置:** 步骤 01–11。
**完成标准:** 一个 Emo HTTP 服务器 + 客户端在 localhost 上于单个 `emo run` 程序内完成往返,全程直风格;超时与连接被拒各自以精确消息抛出 Emo 异常;对测试证书的 TLS 握手在校验失败时拒绝连接。**达成 M3 完成标准。**

- [x] **T12.1** — 调度器之上的 TCP socket 表面;优雅关闭语义。
- [x] **T12.2** — UDP + Unix 域套接字。
- [x] **T12.3** — 走同一挂起路径的 DNS 解析。
- [x] **T12.4** — OpenSSL TLS 绑定;证书校验错误以 Emo 异常呈现。
- [x] **T12.5** — HTTP 客户端;带每连接一进程辅助器的 HTTP 服务器。
- [x] **T12.6** — 带目标元数据的标准库打包;fixture 式集成测试(回环监听、顺序确定)。

收尾说明:`net.*` / `http.*` 的确切名称已写入 README(Networking 一节);标准库以 `stdlib/registry` 下的目录注册表包形式发布,`targets = ["native"]`;验收示例为 `examples/http_roundtrip`。步骤决策见 `plan/step-12-networking.md`(Close-out)。**M3 退出标准已达成。**

后续:本步骤落定后,把标准库的准确模块/方法名(`net.*`、`http.*`)写进 README。

---

## M4 — 编译目标

### 步骤 13 — 原生后端 · `plan/step-13-native-backend.md`

**前置:** 步骤 01–12。
**完成标准:** 每个 `examples/*.emo` 都编译为输出与 `emo run` 完全一致的原生二进制(CI 中金测对比);特化后的数值代码在基准测试中显著优于未特化构建;`emo build` 构建的每连接一进程 HTTP 服务器通过负载测试;基准结果被记录。

- [x] **T13.1** — IR 定义 + 已检查 AST 的 lowering。
- [x] **T13.2** — 阶段 A:OCaml 发射、运行时链接、单二进制输出。
- [x] **T13.3** — 带增量缓存的 `emo build`。
- [x] **T13.4** — 接入 CI 的基准集(记录数字,而非只记通过/失败)。
- [x] **T13.5** — 阶段 B:以步骤 08 完整性检查为前置的类型驱动特化 pass(去装箱、直接分派)。
- [x] **T13.6** — C FFI 链接路径,待绑定表面语法落定后进行(被阻塞——先在 `CHECK.md` 落定)。
- [x] **T13.7** — 引导测试:`examples/` 全套编译出的二进制与解释器输出逐字节一致。

收尾:阶段 A 发射 OCaml 源码(权衡记录在 `docs/zh-CN/native-backend.md`);IR 位于 `src/emo_ir`,含阶段 B 的 `specialize` 不动点,T13.5 的特化随 T13.1/T13.2 提交交付。`foreign def` 按上表落定,经生成的 C 包装器编组(`emo build` 用 `cc` 编译它们);`Float`/`String`/`Bool` 可跨边界,其余类型以 E4200 拒绝。基准:`benchmarks/results.md` 记录 fib(30) 未特化 345ms 对特化 212ms(约 1.6 倍)、ping-pong、JSON 扫描,以及 HTTP echo 负载测试 112 req/s。引导:全部五个示例构建的二进制与 `emo run` 逐字节一致(`test/emo_project` 的 `bootstrap` 套件)。决策见 `plan/step-13-native-backend.md`(收尾)。**步骤 13 验收达成。**

### 步骤 14 — 其余目标:wasm、TypeScript、BEAM、qemu · `plan/step-14-other-targets.md`

**前置:** 步骤 01–13(按目标)。这些是路线条目,不是可直接执行的计划——每个目标排期时独立成步骤文件。推荐顺序:Wasm → TypeScript → BEAM → qemu。

- [x] **T14.1** — 某目标排期时,把它拆成完整标准格式(目标 / 范围 / 任务 / 验收)的 `step-NN-<target>.md`,并更新 `plan/README.md` 的状态表;其任务延续编号(`T15.*`,……)。
- [ ] **T14.2** — 记录每个目标落定了哪些关键决策、落定在哪(README / `CHECK.md` / docs)——保留轨迹。

各目标需落定的关键决策:Wasm —— WasmGC vs 自定义 GC(两者都先做原型);TypeScript —— 直风格到事件循环的映射、进程映射;BEAM —— 类的值语义 vs Erlang maps;qemu —— 可插拔运行时、链接脚本(风险最高;若 EmoOS 工作启动,`core` 库分层应提前)。

晋升轨迹:**TypeScript → `plan/step-15-typescript.md`**(2026-10-02,首个目标;其关键决策——IR 降级、统一 async、协作式任务——已在那个文件落定)。**Wasm → `plan/step-16-wasm.md`**(2026-10-02,第二个目标;GC 问题已落定——WasmGC,结构体与数组 + RTT 分派,无自定义堆)。推荐顺序中下一个是 BEAM。

### 步骤 15 — TypeScript 目标 · `plan/step-15-typescript.md`

**前置:** 步骤 01–13。
**完成标准:** `emo build --target typescript` 发射的 TypeScript 在 Node 上运行,示例子集(hello_world、fib、objects、language_tour、shop、pipeline、tcp_echo、http_roundtrip)的输出与 `emo run` 逐字节一致(CI 金测),且依赖缺少该 target 的包在发射前就被解析门拒绝。

- [ ] **T15.1** — 目标管线与核心发射器:`--target` 贯穿 CLI、项目与解析门;IR → TypeScript 核心子集发射器;带标签值的运行时。金测:hello_world、fib、objects。
- [ ] **T15.2** — 完整核心语义:模式与守卫、元组、数组、Box、插值、内容相等、跨文件模块引用。金测:language_tour、shop。
- [ ] **T15.3** — 并发:协作式任务、邮箱、选择性 receive、`self_pid`、`halt`。金测:pipeline。
- [ ] **T15.4** — 直风格 IO:socket 与 HTTP 经 Node API 包装为 await 的 promise;标准库 target 元数据加 `"typescript"`。金测:tcp_echo、http_roundtrip。
- [ ] **T15.5** — 引导:CI 中的按 target 金测套件,以及缺 target 包的解析门测试。

### 步骤 16 — Wasm 目标(WasmGC)· `plan/step-16-wasm.md`

**前置:** 步骤 01–13。
**完成标准:** `emo build --target wasm` 产出可运行于 Node WasmGC 的 `.wasm`(附带 `.wat` 可读形式),核心子集(hello_world、fib、objects、language_tour、shop)输出与 `emo run` 逐字节一致(CI 金测),且依赖缺少该 target 的包在发射前就被解析门拒绝。

- [x] **T16.1** — 后端骨架:`--target wasm` 管线(解析门读取 target);WAT 中间形式;二进制编码器;装箱结构体值模型 + RTT 分派。金测:hello_world、fib、objects。
- [x] **T16.2** — 完整核心语义:模式与守卫、元组、数组、Box、插值、内容相等、接口窄化、跨文件模块引用。金测:language_tour、shop。
- [x] **T16.3** — 引导:CI 中的 wasm 子集金测,以及缺 `"wasm"` 包的解析门拒绝测试。
- [x] **T16.4** — 并发:模块内协作式驱动实现 `do` / `<-` / `receive`,宿主定时器抢占点。金测:pipeline。(以 T16.2 为前置。)
- [ ] **T16.5** — WASI 与 IO 审计:标准库 `"wasm"` 元数据,以及宿主支持范围内的 io 金测。

### Step 17 — BEAM 目标(Core Erlang)· `plan/step-17-beam.md`

**前置:** Steps 01–16。
**完成标准:** `emo build --target beam` 发射 Core Erlang 文本并由 `erlc` 汇编为 `.beam`,核心子集(hello_world、fib、objects、language_tour、shop、pipeline)与 `emo run` 输出逐字节一致(CI 金测),解析门读取 `"beam"`。

- [ ] **T17.1** — 后端骨架:`--target beam` 管线;Core Erlang 发射器(模块、定义、字面量、call/apply、序列化),对照已探明的 OTP 29 文法。金测:hello_world。
- [x] **T17.2** — 值模型与算术:掩码 i64 回绕 Int、binary 字符串与插值、元组、数组、枚举、深内容相等。金测:fib。
- [x] **T17.3** — 类/实例(带标签 map)、Box 持有进程、闭包即 fun、case 模式与守卫。金测:objects、language_tour。
- [x] **T17.4** — 进程(`do` / `<-` / `receive` 走编译器同款 receive primop)、shop 多模块、pipeline 金测;CI `beam_examples` 组与 `"beam"` 解析门测试。
