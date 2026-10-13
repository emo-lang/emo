# C 后端

`emo build` 的默认目标:发射 C 源码,用系统 `cc` 编译,链接出携带 Emo
自身 C 运行时的独立二进制——不需要 OCaml 工具链,也不需要 OCaml 运行时。
它是步骤 23 交付的自持 hosted 后端。另一个 hosted 后端 `--target ocaml`
发射 OCaml,见 [`docs/zh-CN/ocaml-backend.md`](ocaml-backend.md)。

## 流水线

```
parse → check → lower(Emo_ir)→ specialize → 发射 C → cc → 二进制
```

- **`Emo_ir`**(`src/emo_ir`)是所有后端共同 lower 的中层 IR:一个由具名函数组成的程序,值带类型——每个表达式携带步骤 09 检查器的类型,限定引用解析为模块限定名,类的方法表显式呈现。新增后端意味着从 IR lower,永远不再从 AST lower(步骤 15 的各目标)。
- **特化**(`Emo_ir.specialize`)是对 IR 的不动点 pass:当函数内每个值都是原生类型(参数、局部量、中间量),且它调用到的全是其他已特化函数时,该函数可特化。特化函数保留动态包装器,未标注调用点和一等引用照常工作。
- **发射**(`Emo_codegen.C.emit`,`src/emo_codegen/emo_c.ml`)打印一个 C 翻译单元外加 `emo_defs.h`。原生类型以 C 标量跨越;动态代码 lower 到运行时的打标签字值模型。
- **CLI**(`emo build --target c`)把 `main.c`、`emo_c_runtime.c`、`emo_c_runtime.h` 与 `emo_defs.h` 写入 `.emo-build/`,再用一次 `cc -O2 -std=c11` 调用把它们编出来。产物是单个可执行文件;构建包就是 `emo build`——没有单独的安装步骤。

## 运行时

C 运行时(`src/emo_codegen/c/emo_c_runtime.c` 与 `.h`)是普通 C,由和发射程序同一次 `cc` 调用编译。它承载动态值模型(一个打标签字,cell 种类放在头字里)、字符串布局、针对带身份对象的引用计数纪律,以及调度器。运行时以生成数据的形式随编译器走(步骤 25),因此构建不会在 `emo` 二进制旁边查找任何东西。相关决策记录在 CHECK.md 与 `plan/step-23-c-target.md`。

## C FFI

绑定表面是 `foreign def`,它点名 C 符号:

```emo
foreign def sqrt(x Float64) Float64 = "sqrt"
```

C 后端直接经 C ABI 调用该符号——没有包装器生成器。能力表(CHECK.md)按目标区分,`c` 是最宽的一档:

- **参数**可以是 `Float64`、`String`、`Bool`、`Int64`(指针长度,承载不透明句柄)、单方法 interface(回调),或 struct shape。
- **返回**可以是 `Float64`、`String`、`Bool`、`Int64`、`Void`——"只管发不管回"调用的形状——或由可编组类型组成的 tuple。
- **Struct shape** 按值跨越。tuple 参数就是一个 C `struct`,成员按顺序是各元素类型,嵌套 tuple 在 struct 里再嵌一个 struct;carrier class 是同一个形状换成类来写——每个字段按顺序赋值给同名的 init 参数,且每个字段都留在该档位内。复合**返回**以 tuple 跨回;类类型的返回被拒绝("name the tuple"),因为 C 值无法携带对象身份。相同布局共用一个 `typedef`。
- **回调**:interface 类型的参数展开为两个相邻的 C 参数,函数指针与不透明 `void *userdata`。回调的 C 签名是该方法编组后的参数后接末尾的 `void *userdata`,生成的 trampoline 经 `emo_send` 派发。interface 保持单方法且留在编组档位内。

程序导出的每一份外部可达声明——def、foreign 符号、尾调用簇、类构造器与方法,以及 struct typedef——还会写入 `.emo-build/emo_defs.h`,FFI shim 以此对着编译器自己的声明编译:任何一侧漂移的签名都会在 cc 时报错,而不是在运行时静默出错。

其余类型在检查期拒绝(E4200)。用 `--cclib` 链接额外的 C 库(`emo build main.emo --cclib m`):裸名字变成 `-l` 旗标,以 `-`/`/` 开头的值原样透传,指向真实文件的 cclib(如 shim 目标文件)按内容进入构建缓存键——编辑它即可让缓存的二进制失效。`foreign def` 只能在编译产物里运行——解释器以 E3009 拒绝。`ocaml` 后端只兑现 `Float64`/`String`/`Bool`,经生成的 C 包装器实现(见 [`docs/zh-CN/ocaml-backend.md`](ocaml-backend.md))。

## 包自带原生代码

绑定 C 库的包把整条链接收进自己的清单和目录树,消费方不必传任何旗标:

- **清单的可选 `link` 字段声明系统库。** `link = ["sqlite3"]` 会变成 c 目标 cc 命令行上的 `-lsqlite3`。只接受裸库名——旗标或路径形状的条目在读取清单时拒绝(`--cclib` 保留原样透传旗标的角色)。
- **包目录树里的 `.c`/`.h` 文件是包的一部分。** 它们随 `.emo` 模块一起被收集、校验、嵌入编译器自带的标准库、并随发布打包;c 目标会把依赖包的 C 源文件编进程序唯一的一次 cc 调用。出参 shim 就住在这里:包的 `foreign def` 绑定 shim 的精确 ABI 包装(`sqlite3` 包即如此),而 shim 对着生成的 `emo_defs.h` 编译,签名漂移在两个方向上都会在 cc 时报错。
- **只有 c 目标兑现包的原生输入。** 其他目标由清单的 `targets` 在解析期拒绝;若一个包声明了当前目标却仍携带原生输入,构建会以 E5007 拒绝,而不是静默丢掉链接。源文件按内容、库按名字进入构建缓存键。

无法兑现 `foreign def` 的目标会在检查期拒绝它,而不是编出坏调用:今天 c 目标与 `ocaml` 后端可以兑现,而 `wasm`、`typescript`、`beam` 与 freestanding 的 `riscv64`(在 C 互操作落地之前)都会拒绝。目标可用性也通过 manifest 的 `targets` 机制声明,因此包在解析期即被拒绝。
