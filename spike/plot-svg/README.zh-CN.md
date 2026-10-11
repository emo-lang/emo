# 绘图 spike:用纯 Emo 画出一张真正的二维图

这个 spike 在动手建任何绘图库之前先回答一个问题:**只靠 Emo 的值类型和
字符串拼接——没有 FFI、没有图形运行时——能不能产出真正的二维图表?**
答案是能——`main.emo` 把"月份对销售额"的图画进了 `chart.png`,而它的
源程序只有 `Float64`、`Array`、`String` 和循环。

配套的正式评估——分档、架构、这个 spike 暴露的目标缺口,以及待讨论的
设计问题——在 [`docs/zh-CN/visualization.md`](../../docs/zh-CN/visualization.md)。

## 运行

```sh
emo run main.emo > chart.svg
rsvg-convert -w 760 -h 460 chart.svg -o chart.png   # 任意 SVG 查看器均可
```

`chart.svg` 是入库的产物;`chart.png` 是外部转换器把该 SVG 栅格化后的
结果,只为让人不装查看器也能看见效果。

## 这个 spike 证明了什么

- **渲染器不是难的部分。** 比例尺、nice-number 刻度(Heckbert 的
  `nicenum`)、绘图框、网格线、坐标轴标签、折线序列及其标记点,全都由
  普通 Emo 代码自然得出。产物是标准、可编辑、分辨率和无关的 SVG。
- **文本是白送的。** 每个标签都是一个 SVG `<text>` 元素,字体查找、
  shaping、栅格化都归查看器。Matplotlib 不得不随包 FreeType 的最大
  原因——也是 Emo 栅格后端只能单列一层、且只能后做的原因——在 SVG 这
  一层整体消失。
- **一个纯 Emo 的数学垫片补上了第一处缺口。** `log10` 不在核心浮点
  面上,于是刻度算法用两个 `while` 循环数 10 的幂。统计层日后要的
  `exp`、`log` 与正态分位函数,需要的是同一个形状——一层有序的、纯 Emo
  的小数值层。

## 这个 spike 发现的缺口

它同时也是一次目标矩阵探测。同一份源码在 `develop` 树(`v0.28.1`)上:

| 目标 | 折线图 | 带坐标轴与刻度的图 |
|---|---|---|
| `emo run`(解释器) | 可运行 | 可运行 |
| `ocaml` | 可运行,与解释器逐字节一致 | **失败**:`non-native expression in specialized body`(`Type_ref margin_t`) |
| `typescript` | 构建通过 | 构建通过 |
| `c` | **拒绝**:“does not support method calls yet” | **拒绝**:“does not support the type-level method `fig_w.to_int64`” |
| `wasm` | **拒绝**:`to_float64` 无静态分派 | **拒绝**:同上 |
| `beam` | **拒绝**:`to_float64` 无分派 | **拒绝**:同上 |

由此得两条结论,均记入评估文档:

1. **浮点方法分派的目标对齐是前提。** 一张图要用到数值上的
   `to_float64`、`to_int64`、`floor`、`ceil`、`to_string`;今天六个
   后端里有三个发射不出这些。一个按标准库惯例声明五个目标的库,在这
   个缺口补上之前无法存在。
2. **`ocaml` 的失败是 bug,不是设计上限。** 更简单的图能构建,且与解释
   器逐字节一致,所以更复杂那张图的 specialization 失败是发射器的缺陷,
   值得在库动工之前先报一个 bug。

两者都不阻塞设计,但都钉死了工作顺序。
