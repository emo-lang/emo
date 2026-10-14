# 原生构建

`emo build` 把程序编译为独立的原生二进制——一条命令、一个可执行文件，应用无需单独的安装步骤。默认 target 是 `c`：发射的 C 由系统 `cc` 编译，构建不需要 OCaml 工具链；`--target ocaml` 发射 OCaml，走构建 Emo 自身的那个后端：

```console
$ emo build main.emo -o myapp
built myapp
```

- **运行时随二进制附带。** 调度器与网络栈是后端的库：生成进程、服务 HTTP 的程序编译后运行如一，没有解释器、没有运行时下载。
- **编译产物以解释器为标准。** 每个示例编译为二进制后，其输出与 `emo run` 逐字节一致——在 CI 中断言，而非假设。
- **类型反哺性能。** 类型完全已知的函数编译为特化的原生代码——去箱数字、直接调用——检查器无法钉住的区域保持动态语义。`benchmarks/` 记录数字（同一全带类型声明的程序，特化后明显快于 `--no-specialize`）。
- **构建是增量的。** 构建按内容哈希缓存：未变化的程序（与运行时）重建时不调用工具链，构建报告 `(cached)`。
- **C 互操作是一条 `foreign def`。** 声明给出 C 符号名——`c` 目标经 C ABI 直调；`ocaml` 目标通过生成的 C 包装封送：

  ```emo
  foreign def sqrt(x Float64) Float64 = "sqrt"
  ```

  `Float64`、`String` 与 `Bool` 现在可跨界；其他类型被检查器拒绝。用 `--cclib` 链接额外的 C 库（`emo build main.emo --cclib m`）。外部定义只在编译程序中运行——`emo run` 拒绝它们。无法兑现 `foreign def` 的目标会在检查期拒绝它：`c` 与 `ocaml` 能兑现，而 `wasm`、`typescript`、`beam` 与 freestanding 的 `riscv64` 都会拒绝。
- **C 经接口回调进 Emo。** `foreign def` 的参数可以名一个单方法接口——它就是回调类型。`c` 目标向 C 侧传递一个生成的 trampoline 和作为不透明 `void *userdata` 的对象；回调的 C 签名是该方法的参数（与任何 foreign 实参同样封送）后跟收尾的 `void *userdata`,调用它即分发到接收者自己的方法：

  ```emo
  interface Handler {
    def on_click(tag Int64) String
  }

  foreign def set_handler(h Handler) Void = "set_handler"

  set_handler(MyHandler.new())   # C 侧稍后调用 cb(tag, data)
  ```

  回调方法的参数留在封送层（`Float64`、`String`、`Bool`、`Int64`）,返回额外允许 `Void`。满足同一接口的两个不同类的对象各自分发到自己的方法——对象就骑在 userdata 里。没有该契约的目标在检查期拒绝该参数,与任何无法兑现的 `foreign def` 一致。
- **复合数据以 struct 形状跨界。** 类型为 tuple——或载体类——的 `foreign def` 参数按值传递一个 C 结构体:元素类型按序就是布局,嵌套 tuple 在结构体内再嵌一层结构体,类实例贡献它 init 赋值的字段(类的形状就是它的 init 签名)。复合返回以 tuple 回来:

  ```emo
  foreign def stretch(r ((Float64, Float64), Float64)) (Float64, Float64) = "stretch"

  stretch(((1.0, 2.0), 3.0))   # 结构体内嵌结构体加标量,按值传递
  ```

  `c` 目标声明与 C 侧相同的 `typedef struct`——落在 `emo_defs.h`,shim 对着真实布局编译——按值的调用约定交给 C 编译器。形状字段留在封送层;类类型返回会拒绝(请写 tuple),没有该机制的目标同样拒绝。
- **默认构建只需要一个 C 编译器。** `c` 目标调用系统 `cc`；`--target ocaml` 需要 OCaml 工具链——与构建 Emo 本身相同的那个。
