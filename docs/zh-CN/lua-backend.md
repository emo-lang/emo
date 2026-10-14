# Emo 与 Lua 后端 —— 一份评估

写于 2026-10-14。这是一份技术可行性评估,不是已定的设计决策;文中关于
项目状态的描述以写作日期的仓库为准,关于 Lua 版本的描述以 Lua 5.4
(后端会选定的目标版本)和 Lua 5.5.1(2026-08-03 发布)为准;LuaJIT 2.1
及各衍生方言只在区分决定答案的地方单独标注。2026-10-14 已定案:后端
按下文的复评触发条件挂起——见 CHECK.md。

问题:Emo 要不要长出一个生成 Lua 源码的 codegen 后端——成为解释器、
C、OCaml、TypeScript、wasm、BEAM 和 freestanding riscv64 之外的第八个
目标?

## 结论

**做得到,而且在三个方面比现有任何目标都更贴合——但贴合只在 Lua 5.3
及以后成立,而这条下限恰好落在让 Lua 目标有价值的那批宿主机上。**
Lua 5.3 引入的整数子类型原生满足 Emo 的 Int64 回绕不变量;Lua 的
coroutine 与 C 目标用 `ucontext` fiber 实现的协作式进程模型是同一个
东西;Lua 还保证真尾调用,而 C 和 TypeScript 两个目标都只是近似。对面
摆着的是:让「一坨 Emo 产物被别人的进程 `require` 进去」这件事有意思的
那批宿主——Neovim、OpenResty、Redis、Love2D、Roblox——是 LuaJIT、
Lua 5.1 或 Luau,全都没有整数子类型,因此全都满足不了这条不变量。

建议:不排期,按下文的复评触发条件挂起。真正能支撑它的那个收益——
一个能装进宿主既有进程的产物——用 C 目标或 wasm 目标上的嵌入面来做,
代价更小。

## 生成 Lua 要做什么

仓库事实,以写作日期为准:

- **后端形态。**各后端没有共享模块签名,每个都是独立 emitter,在
  `build_file` 里手写分发分支(`src/emo_cli/emo_cli.ml:166`;分支从
  wasm 的 `:186` 排到 riscv64 的 `:492`)。最小的 emitter 是
  TypeScript 目标的 `emo_ts.ml`,726 行,产出一个 `.ts` 文件;单一
  语言里最大的是 `emo_c.ml`,3,230 行,产出 `main.c` 和 `emo_defs.h`,
  运行时作为生成数据随编译器分发(`emo_c_runtime.c` 3,114 行加 445 行
  头文件,由 dune 规则打包)。Lua 目标是一个 `emo_lua.ml` 加上运行时的
  Lua 移植,接上一个分发分支、一行 doctor、一个缓存键——与其他每个
  目标同形。
- **emitter 规模。**TypeScript emitter 的 726 行是下限而非估计:
  TS 把类、`instanceof` 和字符串处理都交给了宿主语言,而 Lua 得用
  metatable 手搭类、接口、枚举和函数组。按 900–1,300 行 OCaml 计。
- **运行时规模。**C 3,114、OCaml 3,715、TypeScript 2,414。Lua 自带
  的库很薄——没有字节类型、没有 map、没有像样的日期格式化——所以 Lua
  运行时落在这个区间的上沿:2,000–2,600 行。
- **测试。**`test/emo_cli/emo_cli_test.ml` 里与 `c_goldens`、
  `wasm_goldens`、`beam_goldens` 并排的 `lua_goldens` 列表和 runner;
  `test/emo_project/emo_project_test.ml` 里一个 golden 套件;以及共享的
  43 个 `examples/*/expected.txt`。「每个目标逐字节复现解释器输出」的
  家规将延伸到第八个实现——而这里它恰恰是最贵的一环,因为 Lua 的算术
  与格式化默认值不是 Emo 的(见下)。
- **stdlib 面。**包清单按目标设门(`targets = [...]`),而拒绝是实现
  完备后的正常形态、不是缺口:registry 里十七个包中有十个是纯 Emo,
  声明全部五个 hosted 目标,原样可用;`os`、`file`、`bufio` 声明
  `ocaml, c`;`net`、`http`、`slog` 声明 `ocaml, c, typescript`;
  `sqlite3` 只有 `c`。Lua 目标要么实作 `os_*`/`file_*` 这一组(20 个
  加 2 个 builtin),要么像 TypeScript 那样整组拒绝——`ts_runtime.ts`
  一个 `os_*`/`file_*` builtin 都没实作。
- **CI。**release 矩阵是四个平台(linux x86_64/aarch64、macos
  x86_64/arm64,`release.yml:26-32`),每台要装一个 Lua 解释器;而且
  Lua 是所有候选目标里唯一「次版本号一变、整数语义就悄悄变」的。

## 版本墙

这一节决定整个问题。README 把 Int64 回绕定为跨目标不变量——每个目标都是
64 位二进制补码,按 2⁶⁴ 取模回绕,处处一致(README,Numeric types,
第 205 行)——`docs/numeric-width.md` 是它背后的论证。Lua 家族里满足
这条的只有两代:**Lua 5.3 引入了独立的 64 位有符号整数子类型**,5.4 和
5.5 沿用,溢出按二进制补码回绕,位运算原生。家族里其余全部只有一种
数值类型,double:

| 宿主 | Lua | 整数子类型 |
| --- | --- | --- |
| Neovim | LuaJIT 2.1 | 无 |
| OpenResty | LuaJIT 2.1(`luajit2` fork) | 无 |
| Redis | 5.1 | 无 |
| Love2D | LuaJIT | 无 |
| Roblox | Luau | 无 |
| Wireshark | 5.2 | 无 |
| World of Warcraft | 5.1 衍生 | 无 |
| 独立运行 | 5.4 / 5.5 | **有** |

Lua 目标存在的意义就是够到的那批宿主,全在「无」那几行。在 double 上
模拟 64 位整数,就是 numeric-width 定案里记录为**从未采用**的双字
hi/lo 方案(CHECK.md,numeric width);为了一个以宿主进程为全部意义的
目标把它复活,是两头不讨好。

版本跨度也不会自己收窄。Lua 5.5.0(2025-12-22)把 `global` 收为保留字
——一个叫 `global` 的 Emo 标识符需要转义,而 `sanitize_ident` 今天只
重写 `?`——让 `for` 的循环控制变量只读,并破坏了与旧版本的二进制 chunk
兼容。要同时覆盖 5.1 到 5.5 加 LuaJIT 加 Luau,那不是一个目标,而是
Zig 那笔 churn 税再加上两条方言轴。

## 逐机制对照

| Emo 机制 | Lua 对应 | 评价 |
| --- | --- | --- |
| 标签值模型(低位打标) | Lua 自带的动态值,一个 Emo kind 对应一种 | 顺——Lua 本身动态类型,编码方式是后端自己的事 |
| Int64 回绕(跨目标不变量) | 5.3+ 的整数子类型 | 5.3+ 顺,更低不可能——这就是版本墙 |
| `Float64` = IEEE 754 binary64 | Lua 的 number 子类型 / double | 顺,但见浮点渲染那一行 |
| String 是字节序列 | Lua 字符串就是字节序列 | 顺——唯一一个不需要为 String 的表示做任何编码决策的目标 |
| `Bytes`(可变) | Lua 字符串不可变,且没有字节缓冲类型 | 有摩擦:整数表,或带 `__index`/`__newindex` 的 userdata |
| `Array` | table 的稠密 1..n 段 | 顺,索引偏一;Emo 数组按构造稠密,`#t` 保持良定义 |
| `Tuple` | table | 顺 |
| `Map`,插入有序且可观测 | table,迭代顺序未规定 | 有摩擦——顺序是可观测输出(README:64、`examples/map/expected.txt`),所以 Map 需要旁挂一个 key 数组并手写迭代 |
| `List` | table 加显式的头尾纪律 | 顺 |
| `Box` | 单元素 table | 顺 |
| 类 / 接口 / 枚举 / 函数组 | metatable 与 `__index` | 有摩擦,但编码自由度真实:`is(Interface)` 在每个目标上都是结构判定,没有任何东西强制某一种布局 |
| 协作式进程模型(`send` 是显式让出点) | coroutine | 顺,且结构性同构——C 目标的 `ucontext` fiber 担的正是这个角色 |
| `receive` | yield/resume 加一个显式调度器 | 顺;解释器的确定性调度器就是范本 |
| 真尾调用 | Lua 保证 | 顺,且优于 C(goto 重绑)和 TypeScript(驱动循环,有记录的局限) |
| `raise` 结束进程;没有 `catch` 构造 | `error()` 加 `coroutine.resume` 返回 `false, err` | 顺——已定的错误分家只需要在协程顶端放一个 `pcall`,因为压根没有要实现的展开构造 |
| `foreign def` | 经由 Lua C API 到 C | 拒绝(见下) |
| printf 处处逐字节一致(README:68,C17 §7.21.6.1) | `string.format` 委托给 C 的 `sprintf` | 顺——Lua 的 C 血统唯一恰好在 Emo 需要的地方兑现 |
| `Float64` 按 OCaml 的 `%g` 规则打印 | `string.format` 给的是 C 的 `%g` | 有摩擦:BEAM 与 wasm 都手写了 OCaml 的规则,而 C 的 `%g` 不是它 |

### Lua 算术静默不同之处

有四条规则与 Emo 不同,每一条都给出错误答案而不是诊断,每一条都需要
手写 helper:

- **除法。**Emo 的 `/` 向零截断(`emo_div_i64`,
  `emo_c_runtime.c:2498`,并带 `INT64_MIN / -1` 返回 `INT64_MIN` 的
  守卫)。Lua 的 `/` 对整数产出浮点,Lua 的 `//` 是*向下取整*除法。
  `-7 / 2` 在 Emo 是 `-3`,在 Lua 是 `-4`。
- **取模。**Emo 的 `%` 是截断余数(`emo_mod_i64`,
  `emo_c_runtime.c:2504`);Lua 的 `%` 是向下取整。`-7 % 2` 在 Emo 是
  `-1`,在 Lua 是 `1`。
- **右移。**Emo 的 `>>` 是算术右移、补符号位(`emo_shr_i64`,
  `emo_c_runtime.c:2618`;`docs/TASKS.md:445`);Lua 的 `>>` 是逻辑右移、
  空位补零,并且会先把浮点操作数转成整数。
  每一处可能为负的左操作数上的 `>>` 都要走 helper。
- **浮点渲染。**Emo 按 OCaml 的 `%g` 规则打印浮点,Erlang 和
  JavaScript 的原生格式化都对不上——BEAM 运行时和 wasm 宿主各自手写了
  一遍。Lua 的 `string.format` 委托给 C 的 `sprintf`,所以它能用在
  printf 上,但不经核查不能用在浮点上:C 的 `%g` 不是 OCaml 的。

## Lua 目标会拒绝什么

- **`foreign def`。**能力表在*每个*目标上都放行 `Float64`、`String`、
  `Bool`,把 `Int64` 和 `Void` 留给 `c`(CHECK.md,`foreign def` on
  non-native targets),而裸符号声明在 Lua 里没有对应物——Lua 经 C API
  才够得到 C,那意味着后端要吐出一份 shim 并让用户去编译。
  TypeScript、wasm、BEAM 今天都整类拒绝 foreign def;Lua 目标加入它们
  这一列。(wasm 与 BEAM 只在 checker 层拒绝、emitter 层没有守卫这件事,
  已单独记在 CHECK.md。)
- **`sqlite3`。**`targets = ["c"]`、`link = ["sqlite3"]`、包内自带原生
  源码;Lua 不改变其中任何一条,而 resolution 的门是第一道。
- **`Bytes`。**可实现,但代价真实,因为 Lua 字符串不可变且没有缓冲
  类型。
- **`Int32`/`Float32`。**不是 Lua 的成本:checker 今天根本没有 `Int32`
  和 `Float32`,数值宽度在每个目标上是同一个故事。

有一个没人定过、Lua 目标只会继承而不会回答的问题:README 承诺进程边界
上对 Map、Box、List 做快照拷贝(第 195–198 行),而 `c` 后端是共享
单元;解释器则深拷贝。新目标必须选一边,而这处分歧已记在 CHECK.md 里
待定。

## 核心两难

**Lua 目标的全部意义在宿主进程,而宿主进程是 5.1。**其他每个 Emo 目标
产出的都是自己拥有进程的程序。Lua 的独特价值恰恰相反:一个 `.lua` 文件
丢进 Neovim、OpenResty 或 Redis 被 `require`,与别人写的代码并排跑——
这是现有目标都做不到的事,因为连 wasm 目标也要求宿主有 wasm 引擎。而
那正是满足不了 Int64 不变量的那批人。改成编译独立运行的 Lua 5.4,产出
的程序比 C 目标的慢、比 TypeScript 目标的更不可移植:它在跟 Emo 自己的
目标抢地盘,而不是够到一个新宿主。

**方言空间拥挤,且有一半已被放弃。**MoonScript(停维护约十年)、
YueScript、Teal、Fennel、TypeScriptToLua、Haxe 的 Lua 后端、Amulet ML、
Urn。「Emo 编译到 Lua」会被读成这份名单上又多了一个。这与任何设计都不
冲突——设计哲学管的是 Emo 自己的表面语法,不是底层基座,目标独立性也是
已定的设计——但这是 C 目标不用付的一笔解释成本,而且它落在项目所面向的
工业、系统与嵌入式受众的对立面。

一个次级顾虑,恰好出在原本预期 Lua 会赢的那条轴上:**coroutine 是协作式
的,但并非处处可让出。**Lua 禁止跨 C 调用边界让出;5.2 引入、5.4 扩展的
continuation 函数覆盖了多数库回调,但不是全部,而且例外集合是函数级、
版本级的细节。因此在 Lua 上跑的 Emo stdlib,不能在 C 库回调进来的地方
走到 `send`。

## 更便宜的替代:嵌入面,而不是一门语言

如果目标就是「一坨 Emo 产物跑在别人已经拥有的进程里」,C 目标和 wasm
目标离它比 Lua 后端近得多,而且都没有版本墙:

- **一份写明的 C 嵌入 ABI。**C 目标本来就在产出自带运行时、标签值模型的
  单文件二进制;一个公开的 `emo_init`/`emo_call` 形状的接口,就能让宿主
  嵌进 Emo,既不用生成任何语言的源码,也不需要在宿主那侧放解释器。
- **一份写明的 wasm 宿主接口。**wasm 目标已经存在;宿主嵌入需要的是一个
  明确的 import/export 面,不是又一种语言。

这是一个值得评估的方向,不是已定的计划;两条路都比做一个后端小——它们
要依赖的运行时都已经写好并验证过了。

## 建议

1. **挂起 Lua 后端。**现在就把重新评估的触发条件写下来,让门槛显式:
   出现一个具体的嵌入宿主,其 Lua 是 5.3 或更高,或能迁移过去;出现一个
   只有 Lua 目标才能满足的语言需求;或出现证据表明 Emo 的用户就在 Lua
   方言生态里。三者都没有时,5.1 下限与方言拥挤的定位噪音就成立。
2. **如果目标是嵌入,改为评估嵌入面**——一份 C 嵌入 ABI,或 wasm 目标的
   宿主接口——作为独立的小步。同样的收益,没有版本墙,而且它依赖的运行时
   已经存在。
3. **已发布的目标一概不动。**本次调研不为解释器、C、OCaml、
   TypeScript、wasm、BEAM 或 riscv64 排任何工作。调研途中发现的三处跨
   目标分歧已记入 CHECK.md,是待定案的决定,不是本评估接手的工作。

值得留下的一条可复用结论:向零截断的除法、截断取模、算术右移,以及
OCaml 的 `%g`,在任何默认值不同的宿主上都需要各自手写一个 helper。
Lua 一次四条全中,且方向一致——它的运算符属于家族里向下取整、逻辑移位、
C 格式化那一支——所以长杆在 golden 层,不在 emitter。

## 参考

- Lua 5.4 参考手册:<https://www.lua.org/manual/5.4/>
- Lua 5.3 变更(引入整数子类型):
  <https://www.lua.org/manual/5.3/manual.html#8.1>
- Lua 5.5 参考手册:<https://www.lua.org/manual/5.5/>
- LuaJIT:<https://luajit.org/>
- OpenResty 的 `luajit2` fork:<https://github.com/openresty/luajit2>
- Luau:<https://luau.org/>
- Neovim 的 Lua 指南:<https://neovim.io/doc/user/lua.html>
- 先例:TypeScriptToLua <https://typescripttolua.github.io/>、Fennel
  <https://fennel-lang.org/>、Teal
  <https://github.com/teal-language/tl>、MoonScript
  <https://moonscript.org/>
