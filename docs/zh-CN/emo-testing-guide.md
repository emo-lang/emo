# Emo 测试指南

Emo 自带测试运行器和四个断言内建。没有要安装的框架，没有要写的 import，
没有要加的 `deps` 条目:`emo test` 按约定发现测试，而 `expect_equal`、
`expect_true`、`expect_false`、`expect_fail` 是每个程序都已经拥有的
裸名字。

断言失败会抛出语言唯一的 `Exception` 类。Emo 没有捕获构造，所以在
`emo test` 内部，OCaml 运行器是唯一捕获这次抛出的地方——一个失败的
断言只让自己那个测试失败，不影响别的。

## 快速开始

一个项目就是带有 `package.emo` manifest 与 `test/` 目录的目录:

```text
my-project/
  package.emo
  main.emo
  test/
    arithmetic.emo
```

`package.emo` 是普通 manifest;项目留在本地时，普通名字就够:

```emo
package {
  name = "arithmetic"
  version = "0.1.0"
  targets = ["c"]

  deps {}
}
```

`main.emo` 放着被测试的代码:

```emo
def add(a Int64, b Int64) Int64 {
  return a + b
}
```

`test/arithmetic.emo` 放着测试:

```emo
def test_add() {
  expect_equal(3, main.add(1, 2))
}

def test_negative() {
  expect_equal(-1, main.add(-3, 2))
}
```

在项目根目录运行它们:

```console
$ emo test
ok test.arithmetic.test_add
ok test.arithmetic.test_negative
2 tests, 2 passed
```

`emo new <name>` 会脚手架出这个布局，被测试的代码在 `src/lib.emo`
(模块 `src.lib`)，一个通过的测试在 `test/greet.emo`。

## 测试发现

- **根就是工作目录。** `emo test` 要求当前目录里有 `package.emo`;没有
  就报告 `E5010` 并以 65 退出。
- **`test/` 下的每个模块都是测试模块。** 嵌套目录也算
  (`test/parser/json.emo` 是测试模块)。根部的 `test.emo` 是普通模块，
  不是测试文件——目录才是标记。
- **测试模块里每个顶层 `def test_*` 都是一个测试。** 名字必须以
  `test_` 开头。类或函数组里的测试不会被收集。
- **测试不接受参数。** 带参数的 `def test_*` 以 `E5008` 报告为
  `ERROR <module>.<test>`，并且绝不调用。运行器忽略测试的返回值;通常
  的形式是 Void `def`。
- **顺序是确定的。** 模块按路径排序运行，模块内的测试按名字排序运行。

没有名字过滤，也没有 `skip` 属性:整棵 `test/` 树都会运行。

## 断言内建

| 内建 | 参数 | 何时通过 | 失败消息 |
| --- | --- | --- | --- |
| `expect_equal(expected, actual)` | 任意两个值 | 两个值结构相等 | `expect_equal: expected <expected>, got <actual>` |
| `expect_true(value)` | 一个 `Bool` | 值为 `true` | `expect_true: got false` |
| `expect_false(value)` | 一个 `Bool` | 值为 `false` | `expect_false: got true` |
| `expect_fail(message)` | 一个 `String` | 从不 | 消息本身 |

四个都返回 `Void`，所以当语句用。在 `emo test` 之外，失败是普通的未捕获
异常;把它们变成测试失败的是运行器。

### `expect_equal(expected, actual)`

用语言的结构化 `==` 比较，也就是普通代码用的同一个关系:

- 原语按值比较;`Int64`、`Byte`、`Char`、`String` 中类型不同的值永不
  相等，因为没有跨类型强制;
- 元组、数组、`List` 与 `ArrayBuilder` 逐元素比较;
- `Bytes` 按内容比较，`Box` 按它持有的值比较，`Map` 按条目比较，与
  插入顺序无关;
- 类实例按类与字段值比较。

两个参数在 checker 里都是无类型(`Unknown`)，所以任意两个值都可以
比较。失败时，断言用双方正常的 `to_string()` 形式渲染。

```emo
expect_equal(3, main.add(1, 2))
expect_equal([1, [2, "x"]], [1, [2, "x"]])
expect_equal(("ok", 3), result)
```

一次失败读起来是:

```text
expect_equal: expected 3, got 2
```

### `expect_true(value)` 与 `expect_false(value)`

接受一个 `Bool` 表达式——比较、谓词调用或 Bool 变量:

```emo
expect_true(main.is_even(4))
expect_false(main.is_even(5))
expect_true(user.is_older?())
```

值不对时以确切消息 `expect_true: got false` 或 `expect_false: got true`
失败。非 Bool 参数是运行时错误:checker 把参数留在 `Unknown`，运行时
报告 `` E3001: `expect_true` expects a Bool, got Int64 ``，运行器把它
报告为 `ERROR`，而不是 `FAIL`。

### `expect_fail(message)`

总是抛出，原样携带 `message`。它是其余三个无法表达的条件的安全出口:

```emo
def test_parse() {
  const (R.ok, doc) = parse(input)
  if doc.count() != 3 {
    expect_fail("expected 3 nodes, got " + doc.count().to_string())
  }
  expect_equal(3, doc.count())
}
```

它的参数静态类型是 `String`;`expect_fail(42)` 是编译期类型错误
(`E4004`)，不是运行时错误。

### 参数错误

| 错误 | 静态捕获 | 运行时捕获 |
| --- | --- | --- |
| 参数个数不对 | `E4009` | `E3007` |
| `expect_fail` 收到非 `String` | `E4004` | `E3001` |
| `expect_true` / `expect_false` 收到非 `Bool` | —— | `E3001` |
| `expect_equal` 收到类型不匹配的值 | ——(任意两个值都合法) | —— |

`emo test` 先检查整棵树，所以静态形式会在任何测试执行之前停下整轮运行。

## 一轮运行如何报告

每个测试恰好产生一个结果:

- **pass**——测试返回且没有抛出。运行器打印 `ok <module>.<test>`。
- **fail**——某个断言失败，或测试抛出了其他异常。运行器打印
  `FAIL <module>.<test>`、渲染后的诊断(码 `E3010`，消息
  `uncaught exception: ...`)连同源码摘录，以及测试打印的一切。
- **error**——运行时错误(`E30xx`)，例如传给 `expect_true` 的不是
  Bool、越界索引，或带参数的测试函数。运行器打印
  `ERROR <module>.<test>` 连同诊断与捕获的输出。

模块路径包含 `test` 目录:`test/arithmetic.emo` 里名为 `test_add` 的
测试报告为 `test.arithmetic.test_add`。如果测试模块自己的顶层代码在
加载时抛出或出错，结果是 `ERROR <module>.<load>`，该模块的测试不会
运行。

一次典型的失败运行:

```console
$ emo test
FAIL test.fail.test_bad
  error[E3010]: uncaught exception: expect_equal: expected 3, got 2
  before
  loaded
1 test, 0 passed, 1 failed

failures:
FAIL test.fail.test_bad
  error[E3010]: uncaught exception: expect_equal: expected 3, got 2
```

运行器先打印渲染后的诊断——含源码摘录与指示符——再打印捕获的输出。
失败测试的调用栈跟在摘录之后，每行一帧;超过 20 帧的链显示最内层
20 帧，并注明隐藏了多少。测试打印的输出被捕获，只在该测试失败或出错
时显示;通过的测试不显示输出。汇总行统计全部三种结果:

```text
3 tests, 0 passed, 1 failed, 2 errors
```

有失败的完整运行结束后，运行器在 `failures:` 下把它们再列一遍，一个接
一个，让长运行以出错的地方收尾。每段回顾最多显示最内层十帧。

`emo test --fail-fast` 在第一个失败或出错的测试处停下;此时汇总只统计
已运行的测试，也没有回顾。

退出码:

| 码 | 含义 |
| --- | --- |
| `0` | 每个测试都通过，或 `test/` 下没有找到测试 |
| `1` | 至少一个测试失败或出错 |
| `65` | 某个静态阶段失败(词法、解析、检查或 manifest) |

整棵树在任何测试运行之前先做静态检查，所以任何地方的静态错误——无论
在测试文件里还是在被测试的代码里——都以退出码 65 停下整轮运行。
`emo test --locked` 在项目有依赖时额外要求 lockfile(供 CI 使用)，
缺失时以 66 退出。

## 隔离与共享状态

每个测试在各自的调度器运行中执行，有自己的捕获输出。运行器按测试捕获
抛出，所以一个失败不会停下其他测试——除非 `--fail-fast` 要求它停下。
测试启动的进程在它的调度器运行结束时被丢弃。

模块环境则不同:一个测试模块**只加载一次**，它的所有测试都在同一个
环境上运行。模块级的可变值——顶层 `var`，或在模块作用域创建的 `Box`、
`List`、`Map`、`ArrayBuilder`——被该模块的每个测试共享，不在测试之间
重置。测试之间不能互相观察时，请在测试内部(或它调用的辅助函数内部)
创建可变状态。

## 限制

- **四个断言，仅此而已。** 没有 `expect_contains`、`expect_gt` 或
  `expect_raises`;用 `expect_true` 套一个普通表达式来组合。
- **每个测试一次失败。** 断言会抛出，所以该测试剩下的部分不会运行。
  想看到全部独立检查时，把它们放进各自的 `def test_*` 函数。
- **没有参数化测试、过滤或钩子。** 没有 setup/teardown;测试就是普通
  函数，所以请调用共享的辅助函数。
- **仅解释器。** `emo test` 总是解释执行。编译后端不降低断言内建，
  编译构建会把 `test/` 下的每个模块排除在程序之外——测试不被检查、
  不被降低、不被发布。产品模块若调用断言，仍会到达后端的拒绝
  (wasm、beam、riscv64)或运行时失败(`c`、`ocaml`、`typescript`),
  所以请把断言留在 `test/`。
