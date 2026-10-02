# 原生后端

`emo build` 如何把 Emo 程序变成独立二进制,以及步骤 13 落定的那个开放设计项:阶段 A 的 OCaml 发射形态。

## 流水线

```
parse → check → lower(Emo_ir)→ specialize → 发射 OCaml → ocamlopt → 二进制
```

- **`Emo_ir`**(`src/emo_ir`)是所有后端共同 lower 的中层 IR:一个由具名函数组成的程序,值带类型——每个表达式携带步骤 08 检查器的类型,限定引用解析为模块限定名,类的方法表显式呈现。新增后端意味着从 IR lower,永远不再从 AST lower(步骤 14 的各目标)。
- **特化**(`Emo_ir.specialize`)是对 IR 的不动点 pass:当函数内每个值都是原生类型(参数、局部量、中间量),且它调用到的全是其他已特化函数时,该函数可特化。特化函数保留动态包装器,未标注调用点和一等引用照常工作。
- **发射**(`Emo_codegen`)打印单个 OCaml 源文件。动态代码编译为传递 `Emo_eval.value`、调用运行时(`src/emo_runtime`)的函数;特化函数编译为原生 OCaml 类型——不去箱的 `int`/`float`/`bool` 算术与直接调用。
- **CLI**(`emo build`)把源码和 C FFI 桩写入 `.emo-build/`,用 `ocamlfind ocamlopt` 编译,并链接编译器自身构建树里的运行时库。产物是单个可执行文件;构建包就是 `emo build`——没有单独的安装步骤。

## 阶段 A:发射 OCaml 源码

计划留了一个实现选择:发射 OCaml **源码文本**,还是在内存中构造 OCaml **模块树**(借助 compiler-libs)再编译。步骤 13 交付的是源码发射:

- **源码文本是一个稳定的契约。** 发射出的文件是普通 OCaml,由已安装的工具链编译——不依赖 compiler-libs 内部 API,而那些 API 在 OCaml 版本之间会变。构造树的发射器会把后端钉死在 compiler-libs 的版本上,OCaml 每次升级都变成一次后端迁移。
- **可调试性是直接的。** 生成的文件就在 `.emo-build/main.ml`;工具链报错指向一个用户打得开、读得懂的行。
- **优化器照样生效。** `ocamlopt` 对发射源码跑的 Flambda / Closure 中端与对任何源码相同;特化发生在 Emo 自己的 pass 里(Emo 的类型知识在那里),机器层面的事交给 OCaml。
- **代价。** 解析和类型检查发射文件会花掉树发射器能省下的时间;生成代码也用不上只存在于树层面的特性(跨模块内联提示)。当前规模下两者都无所谓:基准集的整条流水线只需几百毫秒的工具链时间。

只有当步骤 14 的某个目标想复用构造树路径时才重新审视——后端共享的层是 IR,不是发射器。

## C FFI

绑定表面是 `foreign def`:

```emo
foreign def sqrt(x Float) Float = "sqrt"
```

发射出的 OCaml **不**直接声明 C 符号。裸 external 收到的是装箱的 `value` 实参(对 C 的 `double` 是错的),而且 `sqrt` 这类符号名会与 OCaml 编译器内联的原语冲突(在 macOS ARM64 上生成坏编码)。因此 `emo build` 为每个绑定生成一个 C 包装器——`.emo-build/ffi_stubs.c`——在边界处拆箱(`Double_val` / `String_val` / `Bool_val` 进,`caml_copy_double` / `caml_copy_string` / `Val_bool` 出),用 `cc` 编译并链接。

目前只有 `Float`、`String`、`Bool` 能跨边界编组;其他类型在检查期拒绝(E4200)。用 `--cclib` 链接额外的 C 库(`emo build main.emo --cclib m`)。`foreign def` 只能在编译产物里运行——解释器以 E3009 拒绝。
