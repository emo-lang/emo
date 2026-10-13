# OCaml 后端

`emo build --target ocaml` 发射单个 OCaml 源文件,用 OCaml 工具链编译成独立二进制。它是用来构建 Emo 自身的后端,也是唯一一个构建时需要系统 `cc` 之外工具链的目标:`ocamlfind` 外加 `unix` 与 `ssl` 两个包。默认目标是 `c`——见 [`docs/zh-CN/c-backend.md`](c-backend.md)。

## 流水线

```
parse → check → lower(Emo_ir)→ specialize → 发射 OCaml → ocamlopt → 二进制
```

中层 IR(`Emo_ir`,`src/emo_ir`)与特化 pass(`Emo_ir.specialize`)与其他所有后端共用,描述在 [`docs/zh-CN/c-backend.md`](c-backend.md)。本后端特有的是发射与工具链:

- **发射**(`Emo_codegen.emit`)打印单个 OCaml 源文件。动态代码编译为传递 `Emo_eval.value`、调用目标运行时(`src/emo_codegen/ocaml/emo_ocaml_runtime.ml`)的函数;特化函数编译为原生 OCaml 类型——不去箱的 `int`/`float`/`bool` 算术与直接调用。
- **CLI**(`emo build --target ocaml`)把 `main.ml` 与 `emo_ocaml_runtime.ml` 写入 `.emo-build/`,先单独编译运行时,再用 `-open Emo_ocaml_runtime` 把程序链接上去(`ocamlfind ocamlopt -package unix,ssl`)。运行时以生成数据的形式随编译器走(步骤 25),因此构建不会去宿主构建树里查找 `emo_runtime.cmxa`。

## 阶段 A:发射 OCaml 源码

计划留了一个实现选择:发射 OCaml **源码文本**,还是在内存中构造 OCaml **模块树**(借助 compiler-libs)再编译。步骤 14 交付的是源码发射:

- **源码文本是一个稳定的契约。** 发射出的文件是普通 OCaml,由已安装的工具链编译——不依赖 compiler-libs 内部 API,而那些 API 在 OCaml 版本之间会变。构造树的发射器会把后端钉死在 compiler-libs 的版本上,OCaml 每次升级都变成一次后端迁移。
- **可调试性是直接的。** 生成的文件就在 `.emo-build/main.ml`;工具链报错指向一个用户打得开、读得懂的行。
- **优化器照样生效。** `ocamlopt` 对发射源码跑的 Flambda / Closure 中端与对任何源码相同;特化发生在 Emo 自己的 pass 里(Emo 的类型知识在那里),机器层面的事交给 OCaml。
- **代价。** 解析和类型检查发射文件会花掉树发射器能省下的时间;生成代码也用不上只存在于树层面的特性(跨模块内联提示)。当前规模下两者都无所谓:基准集的整条流水线只需几百毫秒的工具链时间。

只有当另一个目标想复用构造树路径时才重新审视——后端共享的层是 IR,不是发射器。

## C FFI

绑定表面是 `foreign def`;它的能力表与 `c` 后端的直接 ABI 路径见 [`docs/zh-CN/c-backend.md`](c-backend.md):

```emo
foreign def sqrt(x Float64) Float64 = "sqrt"
```

OCaml 后端经生成的包装器编译:裸 OCaml external 收到的是装箱的 `value` 实参(对 C 的 `double` 是错的),而且 `sqrt` 这类符号名会与 OCaml 编译器内联的原语冲突(在 macOS ARM64 上生成坏编码)。因此 `emo build` 为每个绑定生成一个 C 包装器——`.emo-build/ffi_stubs.c`——在边界处拆箱(`Double_val` / `String_val` / `Bool_val` 进,`caml_copy_double` / `caml_copy_string` / `Val_bool` 出),且只接受 `Float64`、`String`、`Bool`。

其余 FFI 档位留在 `c` 后端:`Int64` 参数、`Void` 返回、struct shape 与回调在 `ocaml` 上都于检查期拒绝(E4200),编组档位之外的任何类型同样拒绝。用 `--cclib` 链接额外的 C 库(`emo build main.emo --cclib m`),它会给链接加上 `-l<lib>`;指向真实文件的 cclib 按内容进入构建缓存键。`foreign def` 只能在编译产物里运行——解释器以 E3009 拒绝。
