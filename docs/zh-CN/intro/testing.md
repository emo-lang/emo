# 测试

`emo test` 运行项目的测试。约定与模块树一样是结构性的：项目 `test/` 目录下的每个 `.emo` 文件都是测试文件，其中的每个顶层 `def test_*` 都是一个测试。根部的 `test.emo` 文件是普通模块，不是测试文件——目录才是标记。

```emo
// test/arithmetic.emo
def test_add() {
  expect_equal(3, main.add(1, 2))
}
```

- **断言是 `expect_*` 内建。** `expect_equal(expected, actual)` 按语言的结构化 `==` 比较；`expect_true(value)` 与 `expect_false(value)` 接受 Bool；`expect_fail(message)` 无条件失败。断言失败抛出唯一的 `Exception` 类——与任何契约违例同一纪律——消息点名断言并渲染双方值：`expect_equal: expected 3, got 2`。
- **每个测试隔离运行。** 运行器在独立的调度器运行中调用每个测试并捕获其输出，一个测试的进程、输出与失败不会泄漏到下一个。raise——无论是断言还是其他——只失败当前测试；运行时错误(`E30xx`)判为 error，单独报告。
- **先检查整棵树。** `emo test` 对每个模块(含测试文件)执行与 `emo run` 相同的静态阶段;任何地方有静态错误即以退出码 65 中止。全部通过退出 0,有失败或错误退出 1。测试函数不接受参数——带参数的 `def test_*` 会被报告,绝不调用。
