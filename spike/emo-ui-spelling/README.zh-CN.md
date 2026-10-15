# EmoUI 拼写:一个真实屏幕在 A 与 B 两种写法下的代价

一个围绕[第 48 步](../../docs/zh-CN/TASKS.md)(EmoUI)的 spike,用来补上
[`docs/emo-ui-composition.md`](../../docs/zh-CN/emo-ui-composition.md) 自己承认的那个证据缺口 ——
它正是那个注记最后一个问题至今未决的原因:

> EmoUI 的子节点是显式的 `Array[Node]`(选项 A)。Emo 的文法该长出可感知标记的部分
> (C,解析器里的树字面量),还是 EmoUI 该自带第二套语法(D,一个外部翻译器,产出
> `.emo`)?注记自己的答案是「写一个屏幕然后数行数」。这就是那个屏幕,数完了。

**结论:做 B;而数字表明树字面量挣不回它的代价 —— 至少挣不回 C 要价的那份。**
两个真实屏幕,A 写法 95 行,B 写法 40 行,同一棵树,渲染字节一致。树字面量删掉
**A 里 72 个括号 token、B 里 18 个,而两种写法里 `children:` 标签都是 0 个** ——
因为构造函数是位置参数,所以组合注记里选项 B 样例赖以立足的那个标签
(`children: kids.to_array()`)在真实代码里根本不出现。更糟的是,`screens_a.emo`
里真正难受的那 44 行非空代码是**迭代构造器**,而一个「脱糖成 A 的那串嵌套调用」
的字面量会原封不动地继承它们。付得起的是 B,它是一个容器问题而不是语法问题,
而且在 C 或 D 之下都不会白做,因为两者脱糖到同一棵树。C 剩下的理由是工效学上的,
本实验测不出来;D 的理由比注记设想的更强,因为翻译器可以把字面量**内部**的循环
直接下降成 B 的容器形态。

一条保留意见,因为任务本来就是要用数字回答:**本实验量的是 A 和 B。
关于 C 和 D 的说法是从那两列推出来的,不是对 C 或 D 的测量** —— 两者都没有被
建起来,建其中任何一个都是下一次实验,不是这一次。

数字在[测量](#测量)一节;它们支撑的论证在[结论](#结论)一节。

## 出发点

`docs/emo-ui-composition.md` 已定:组件的子节点是显式的 `Array[Node]`(选项 A,
`docs/emo-ui.md` 决定 3);已否决:emission、self-rebinding、环境收集器;只留下一个
未决问题:**Emo 的文法该长出可感知标记的部分,还是 EmoUI 该自带第二套语法?**
它的收尾一节承认了它为什么还悬着 —— 「两个分支都没有拿真实代码试过」——
并开出了本实验的方子,且指定了顺序:先做 B,把 T48.1 的可移植内核和一两个真实
UI 屏幕用 A 写法写出来,让行数去决定。

这个 spike 就是那件事,另外把 B 写法也真写了一遍,好让比较发生在两个程序之间,
而不是在一个程序和一个提案之间。

写的过程中冒出三件注记不可能测到的事,每一件都改变了「A 写法的代价」是多少:

1. **`Array.append` 追加的是一个元素,不是一个数组**
   (`src/emo_eval/emo_eval.ml:2055`)。于是 `docs/emo-ui.md` Layer 1 里公布、
   并被 `spike/emo-ui-probe/probe3_iteration_and_messages.emo` 抄录的迭代惯用法
   —— `[head].append(each_from(...))` —— 构造出的是 `[n0, [n1, [n2, []]]]`,
   一个**嵌套**数组,而不是扁平的 `Array[Node]`。它能通过类型检查,是因为元素
   经由 `Block` 而来,而 `Block` 是 `Unknown`(`src/emo_check/emo_check.ml:294`),
   且 `conforms` 在任一侧为 `Unknown` 时就返回真(`emo_check.ml:1011`)。
   probe 3 当年打印的那个 `2` 就是这个被掩盖的症状:任何长度 ≥ 2 的列表它都是 `2`,
   而输出里没有任何东西说明这一点。`screens_a.emo:96` 忠实复现了那个惯用法,
   `main.emo` 在一个真实屏幕上把它显示出来;probe 3 和 Layer 1 的例子此后都已修正。
2. **不存在 `List` → `Array` 的转换。** `grep to_array src/` 是空的,所以组合注记
   里写的选项 B 根本编译不过,那个转换得手写 —— 而手写就落在 `append` 之上,
   也就是仍然是二次的。`ui.emo:279` 写了它;`measure.emo` 给它算了价。
3. **混合类型的子节点字面量不被检查。** 同质的会被检查:
   `spine.column(["not a node"])` 是 `E4004: argument 'children' expects
   Array[spine.Node], got Array[String]`。但
   `spine.column([spine.text("ok"), "not a node"])` 被接受,因为该字面量
   退化成 `Array[Unknown]`,而 `Unknown` 对一切都 conform。A 的「构造时检查
   props」(`docs/emo-ui.md:274`)只在这个洞之前成立,而这个洞正是 Block 惯用法
   藏身其中的同一个洞。

## 两个屏幕

两个屏幕,选得让可移植原语在它们之间全部出现,并且两个硬骨头都刻意在场。
`screen_profile` 是一个表单:标题、头像带、一个**条件**错误横幅、一列**迭代出来的**
字段行、一行迭代出来的按钮、一个 spacer、一段许可证。`screen_inbox` 是一个列表:
工具栏、一个**包着迭代的条件**(没有消息时是空状态,否则是消息行)、页脚。

第二个才是决定形状的那个。Emo 的数组不能拼接,所以「夹在两个固定子节点之间的
条件子节点」没法靠拼接两个数组做出来 —— 整个列表必须从一个带分支的构造器里出来。
`screens_a.emo` 给了它两种答案,两种都留了档:`screen_profile_dup` 把整个子节点
数组写了两遍(21 行),`screen_profile` 写了一个显式的 `concat` 构造器(再多 6 行机械)。
`screens_b.emo` 用一个 `List` 和一个 `if` 回答。

`components.emo` 装了两种写法**逐字共享**的一切 —— 每个子节点列表固定的控件,
以及 `root_style()`。所以 A 与 B 的差量恰好是那些*动态*列表怎么拼装,而不是两个各自
独立写出来的屏幕之间的 diff。这才让下面的行数有意义。

两种写法并排 —— `screen_profile` 的字段列:

```emo
// A(screens_a.emo)—— 每种元素类型一个构造器 def,因为没有泛型
def field_rows(xs Array[model.Field], i Int64,
               into Array[ui.Node]) Array[ui.Node] {
  if i == xs.length() {
    return into
  }
  return field_rows(xs, i + 1, into.append(components.field_row(xs[i])))
}
const rows = field_rows(m.fields(), 0, [])
```

```emo
// B(screens_b.emo)—— 一个循环,一个容器
const rows = List.new([])
const fields = m.fields()
for var i = 0; i < fields.length(); i = i + 1 {
  rows.push_back(components.field_row(fields[i]))
}
```

```emo
// A-naive(screens_a.emo)—— docs/emo-ui.md Layer 1 公布的惯用法
def each_from(xs Array[model.Field], i Int64, f Block) Array[ui.Node] {
  if i == xs.length() {
    return []
  }
  const head = f(xs[i])
  return [head].append(each_from(xs, i + 1, f))
}
```

第三个和第一个一样是七行,看起来*更简单* —— 不用在递归里穿一个累加器 ——
却构造出错误的树。`main.emo` 对三者都做了断言,并打印结果:naive 那一列的
`length() = 2`,而 B 的是 `3`;它的 `child[1]` 是一个嵌套的 `[#ui.Row(...` 数组,
而不是第二个字段行。

## 测量

这里的一切都由本目录下的脚本产出;见[复现](#复现)。

### 源码代价

逐文件的词法统计:非空非注释行 `L`;字节数;一个被解析的树字面量会直接删掉的
标签与括号;以及它们占 `L` 的比例。

```
file                    L   bytes  children:  brackets    sugar   sugar/L
ui.emo                212    4902          3        46       49     0.231
components.emo         65    2254          0        18       18     0.277
debug.emo              81    2200          0         4        4     0.049
model.emo             133    3645          0        20       20     0.150
tags.emo               26     553          0         8        8     0.308
app.emo                23     720          0         0        0     0.000
features.emo          104    2432          1        24       25     0.240
measure.emo           186    5213          0        90       90     0.484
screens_a.emo          95    3091          0        72       72     0.758
screens_b.emo          40    1533          0        18       18     0.450
main.emo               63    2754          0        20       20     0.317
naive_crash.emo         1      79          0         0        0     0.000
```

这些是词法代理量,不是可读性证明,而它们在这里有意义只为一个原因:
`main.emo` 断言两种写法渲染出字节一致的树,所以 `screens_a.emo` 与
`screens_b.emo` 之间的词法差异不可能是它们构造的东西的差异。

### 树字面量会抹掉什么

先读 `children:` 那一列,因为意外在这里。**两个屏幕里它都是 0。** 构造函数
按位置接收子节点(`def column(children Array[Node], style Style) Node`),
所以组合注记里选项 B 样例围绕的那个标签 —— `page(title: "Home",
children: kids.to_array())` —— 在代码里根本不出现。带 `children:` 的文件只有
`ui.emo`(3 个,构造函数自身的定义)和 `features.emo`(1 个,一个探针)。
在这些屏幕上,树字面量删掉的**只有括号**。

其次,括号数是*下界*,而且它不在 A 的代价重心上。字面量还会删掉那些局部数组和
`concat` 调用 —— 在 `screen_profile` 上是三个局部量加两次 `concat` 调用,
在 `screen_profile_dup` 上是整个被复制的数组,21 行 —— 这些都不在表里,
因为词法统计看不见它们。所以 `sugar/L` 对屏幕的*静态*部分低估了字面量。没问题。

但它碰不到占大头的那部分:

| 项 | `screens_a.emo` | `screens_b.emo` |
|---|---|---|
| 非空行总数 | 95 | 40 |
| 构造器机械(A:第 14–56、96–102 行;B:3 个内联 `for` 循环) | **44** | **0** |
| 条件拼接(A:`concat` + dup 变体;B:一个 `if`) | 6 + 21 | 3 + 7 |
| 括号 | 72 | 18 |

那 44 行是 `no_nodes`、`concat`、`field_rows`、`action_buttons`、`message_rows`
和 `each_from` —— 存在的意义是把一个 `Array[Field]` 变成 `Array[Node]` 的构造器。
一个「脱糖成恰好是 A 的那串嵌套调用」的树字面量(组合注记自己对 C 的描述)
会把它们一个不落地继承下来,因为那个迭代是*数据驱动的变换*,不是树的形状:
字面量给你的是把一份你已经知道的子节点列表写得更漂亮的方式,而这些构造器存在
是因为在你遍历完 `fields()` 之前你并不知道它。字面量只有在它自己也长出一个循环
形态时才能删掉它们 —— 而那是一个比树字面量大得多的语言改动。

所以字面量的诚实账本是:它删掉括号和静态管线,留下让 A 变成 B 的 2.4 倍的那 44 行。

### 子节点数组的构造成本

五种策略,同一份输入、同一个元素构造器、同一个声明返回类型,在一条倍增阶梯上跑。
`copies` 建模的是 `emo_array_append` 的 `8·(len+2)` 单元。

| 策略 | k=32 appends | k=32 copies | 结果 |
|---|---|---|---|
| `build_cons` —— 文档里的 `each_from`,忠实复现 | 32 | 768 | **`len == 2`,嵌套** |
| `build_acc` —— `into.append(mk(x))` | 32 | 4480 | 正确,二次 |
| `build_concat` —— 建在 `append` 上的拼接助手 | 496 | 51584 | 正确,更差的二次 |
| `build_list` —— `List` 构造 + 手写转换 | 32 | 4480 | 正确;与 `build_acc` 完全相同 |
| `build_map` —— `Map.set` 然后 `.values()` | **0** | **0** | 正确,**完全没有数组增长** |

两个结果要紧。

`build_list` 与 `build_acc` *完全相同*。这正是要点:`List` 本身是 O(1) 的
(k=32 时 `push_back` 是 32 次 push、0 次 copy —— 见 `pushes` 列),但 `ui.emo:279`
那个手写转换是一次一个 `append` 地把 list 排进数组,于是二次代价只是搬进了转换里。
B 的工效学收益是真的、是白拿的;B 的*渐近*收益在转换做出来之前并不存在。

`build_map` 完全没有数组增长 —— 0 次 append、0 次 copy、k 次 `set` —— 所以运行时
已经有一条从键值集合到数组的 O(k) 通路,经由 `Map.values()` 和它那按插入序的
底层 list。一条必须说清的保留意见,因为计量器测不到它:`copies` 只统计 `Array.append`
会搬动的字节,所以这只说明线性通路存在,不说明 `Map.set` 是免费的。无论如何要点
都成立 —— `List` → `Array` 的转换应当是一个遍历 deque 的运行时原语,而不是一段
在 `append` 上打转的 Emo 循环。

### 嵌套数组 bug,在一个真实屏幕上

`screens_a.emo:104`(`screen_profile_naive`)就是那个公布的惯用法,用在 profile
屏幕上。`main.emo` 对它做了断言并打印:

```
naive  field column, length   = 2
       field column, child[1] = [#ui.Row(style: #ui.Style(padding: 0.0, gap: 8.0, align: start, grow: fa...
B      field column, length   = 3
       field column, child[1] = #ui.Row(style: #ui.Style(padding: 0.0, gap: 8.0, align: start, grow: fal...
```

`naive_crash.emo` 是同一棵树交给后端的结果,也是这个症状的真实形状:
`E3007`,退出码 70。那个嵌套数组不是实例,于是渲染遍历的第一次 `is()` 在任何分支
被走到之前就抛了。`debug.emo` 里那个 `Unknown ${n}` 兜底 —— 写出来正是为了让
非节点可见而不是报类型错 —— 对非节点是不可达的,因为 `is()` 是抛异常而不是返回假。
这件事本身就值得知道:**后端没法防御性地渲染一棵它不信任的树。**

### 检查器覆盖

`mismatch/` 里放了一副削简的脊骨和两个犯同样错误的文件 —— 子节点槽位里放
`String`:

- `mismatch/homogeneous.emo` —— `spine.column(["not a node"])`。**被诊断**,
  E4004,而且它是这个包里唯一一条诊断。
- `mismatch/mixed.emo` —— `spine.column([spine.text("ok"), "not a node"])`。
  **不被诊断**,自己一行都不画。

注意 E4004 的消息说了什么:它点出参数名 `children`,把 `Array[String]` 拿去和
`Array[spine.Node]` 比。这是检查恰好按设计工作,而它之所以可用,*只*因为那个
子节点槽位有一个声明好的数组类型可比。混合情形里击败它的机制就是发现 3 里
那个:混合字面量推断为 `Array[Unknown]`,`conforms` 递归进元素类型,而 `Unknown`
对 `Node` conform。所以 A 写法对一个*全错*的字面量关上了 props 检查的洞,
对一个*部分错*的字面量仍然开着 —— 而后者是更可能犯的错,也是更贵的错,
因为那个对的元素让树看起来是对的。

任何树字面量至少要同样好地保住这个承诺,最好更好:既然字面量知道那个子节点槽位
的声明类型,它正是那个*能*把每个元素拿去对 `Node` 检查、而不是对刚推断出来的
数组元素类型检查的构造。这对 C 或 D 是支持而非反对的论据 —— 但它是对检查器
漏洞的修复,而修检查器比让文法可感知标记小得多。

### 目标矩阵

这个内核本该是可移植的。对整包跑 `emo build`,按目标:

| 目标 | 结果 |
|---|---|
| 解释器 | 能跑;golden 字节一致 |
| `typescript` | 能构建 |
| `ocaml` | **失败** —— 原生 `String` `+` |
| `c` | **失败** —— `fields` 上的字段表冲突 |
| `wasm` | 整包失败(仅因 Map);去掉 `measure.emo` 后能构建 |
| `beam` | 整包失败(仅因 Map);去掉 `measure.emo` 后能构建 |

其中两个是内核自己的锅,一个是 spike 专属文件的锅,三者都是 `src/` 的缺陷,
在这里被隔离出来并且**没有修** —— 本 spike 不改 `src/` 下任何东西:

1. **`c` —— 类的字段名表与一个名叫 `fields` 的方法相撞。** 生成的 C 把字段表
   命名为 `<module>__<Class>__fields`,方法 `fields` 也是同一个名字,于是两者
   相撞:`error: redefinition of 'main__Holder__fields' as different kind of
   symbol`。这张表的名字是固定的 —— `<module>__<Class>__fields`,跟字段本身
   叫什么无关 —— 所以这个相撞只需要包里*任何地方*有一个名叫 `fields` 的**方法**,
   而本 spike 自己的 `Model.fields()`(`model.emo:92`,表单模型上一个再普通不过的
   访问器名)就是一个,这就是整个内核为 `c` 构建失败的原因。
   `codegen/field_table/` 把它隔离出来;另外四个目标能构建那个文件。
   修法:给字段表改名(`__field_names`),让任何成员都遮蔽不了它。
2. **`ocaml` —— 原生 `String` `+`。** 对两个 `String` 局部量,生成的 OCaml 是
   `(Int64.add (v_a) (v_b))`:
   `Error: This constant has type string but an expression was expected of
   type int64`。根因在 `src/emo_codegen/emo_codegen.ml:654-656`:未装箱的
   `emit_native_expr` 有一个 `Float64` 分支(`+.`)和一个 else 分支
   (`Int64.add`),而**没有 `String` 分支**。装箱的 `emit_expr` 路径把 `Add`
   交给 `Emo_runtime.add`,后者是处理 String 的 —— 所以这是特化路径独有,
   只在每个操作数都可原生表示时才会走到(两个 `String` 局部量;一次自递归的
   `String` 调用,也就是 `debug.emo` 的 `indent`)。`codegen/native_string_add/`
   把它隔离出来;另外四个目标能构建那个文件。修法:加一个
   `= Emo_check.String` 分支,产出 `(^)`。
3. **`wasm` 和 `beam` —— `Map`。** `the wasm target does not support Map
   yet`。本 spike 里唯一的 `Map` 是 `measure.emo` 的 `build_map`,所以内核
   自身在两个目标上都没问题;去掉 `measure.emo` 后整包能为 `wasm` 和 `beam`
   构建,而 `ocaml` 和 `c` 仍然失败。记录而不绕过,因为它是一个真实的限制:
   任何用到 `Map` 的 T48.1 内核都不能落在那些目标上。

`check.sh` 对这张表的每一行做断言,所以 `src/` 里的修复会在这里变成 FAIL,
而不是留成一段过时的文字。

## 结论

**做 B。测量挣不回 C,而它让 D 比注记设想的更好看。**

**B 是付得起的那一步,而且它是一个容器问题,不是语法问题。** 两个真实屏幕:
95 行对 40 行,同一棵树,同样的渲染。B 的语法代价是零,并且同时消掉构造器 def
和条件拼接问题 —— `ui.column(concat(head, concat(banner, tail, 0), 0), style)`
变成一个 `if` 加一个 `push_back`。它只差一样语言侧的东西才不止是工效学收益:
一个 `List` → `Array` 转换。`build_map` 那一行说明运行时已经有那条线性通路,
所以那个转换是一个运行时原语,不是一个设计问题。而且 B 在 C 或 D 之下都不白做:
两者脱糖到同一棵树。

**C 的要价买到的东西比注记设想的少。** 字面量删掉括号 —— A 里 72 个、B 里 18 个、
标签 0 个 —— 加上静态管线,而它留下那 44 行迭代构造器,因为那些存在的意义是遍历
`fields()`,那不是树的形状。C 声明的代价是一次真实的语言改动:解析器、检查器、
六个后端、格式化器、LSP,以及一套可感知标记的文法。为了删掉括号和一次 `concat`
调用付这些,不是数字支撑得起的交易。只有当字面量长出一个循环形态时 C 才值得,
而那时被定价的东西已经不再是「一个树字面量」了。

**D 比注记允许的更强,理由正是注记自己给的。** 注记支持 D 的理由是它是一次
知道目标的文本变换,所以能靠脱糖化解 block 问题。同一个性质让字面量*内部*的循环
可以直接下降成 B 的容器形态 —— 标记里的一个 `for` 变成 `List.push_back` 而不是
`append` —— 于是 D 删掉括号、静态管线,*以及*那 44 行构造器,不需要语言改动,
而且可以在 EmoUI 仓库里做,让语言仓库完全不受影响。D 的代价是一套第二语法和
一套第二工具链(格式化器、LSP、错误映射),这是真实的,但它是工具链代价,
不是文法代价。

**T48.1 该交付什么。** 子节点是 `Array[Node]` —— 已定,而测量支持它:子节点列表
在构造时被检查,后端用 `is()` 收窄,`patch` 比较树。但*构造*一侧绝不能是在 Emo
里用 `Array.append`:那既是二次路径又是嵌套 bug,而文档在这一次修正之前公布的
恰恰是这个。
把 `children_of` 作为遍历 deque 的运行时 `List` → `Array` 转换交付,A 写法最贵的
那部分 —— 44 行和 O(k²) —— 不用改语法就消失了。

**这个顺序暗示的是:B,然后如果工效学仍然难受就做 D,只有当 D 的第二套工具链
比一套可感知标记的文法更贵时才做 C。** 这比注记希望了结的claim要小,而它是
数字支撑得起的 claim —— 两个屏幕上的一次实验,不是一次普查。

## 对文档的修正

先记录在此,随后落实:

- **[`docs/emo-ui.md`](../../docs/zh-CN/emo-ui.md) Layer 1 的 `each_from` 例子是错的。**
  `Array.append` 追加一个元素,所以 `[head].append(each_from(xs, i + 1, f))`
  构造出 `[n0, [n1, [n2, []]]]`。它能编译只因为元素经由 `Block` 而来,
  而 `Block` 是 `Unknown`;它下面那句「This works (probe 3)」正是被掩盖的 `2`。
  已换成真正产出扁平 `Array[Node]` 的构造器,并修正 probe 3 的说法。
- **[`docs/emo-ui.md`](../../docs/zh-CN/emo-ui.md) Layer 0 的 `interface Node` 只有 `style()`。**
  spike 的 `Node` 另外声明了 `def children() Array[Node]` 并且能通过检查 ——
  Layer 0 的草图早于 `docs/emo-ui.md:116` 记录的递归接口发现,而那处已经写明
  接口在签名里指称自己是可以的。Layer 0 已更新到与已知事实一致。
- **[`docs/emo-ui-composition.md`](../../docs/zh-CN/emo-ui-composition.md) 选项 B 调用了 `kids.to_array()`。**
  不存在这样的转换。样例已改为本 spike 不得不手写的那个转换,证据缺口一节
  追加了这些测量结果。
- **[`spike/emo-ui-probe/probe3_iteration_and_messages.emo`](../emo-ui-probe/probe3_iteration_and_messages.emo)
  及其 README 把被掩盖的 `2` 记成了预期输出。** probe 已重写为产出扁平数组;
  预期输出块已更新。
- **记录,但不修正:** [目标矩阵](#目标矩阵)里那三个 `src/` 缺陷,以及混合字面量
  的检查器漏洞。两者都是给语言的发现,不是文档错误,本 spike 不改 `src/` 下任何东西。
  `check.sh` 把它们钉住。

## 复现

在本目录下,用仓库的编译器
(`../../_build/default/src/emo_cli/emo.exe`,可用 `$EMO` 覆盖):

```sh
./count.sh    # 源码代价表
./run.sh      # main.emo 与 naive_crash.emo,与 golden 做 diff
./check.sh    # 22 条断言:什么能检查、什么不能、哪些目标能构建
```

`run.sh` 把 `emo run main.emo` 和 `emo run naive_crash.emo` 与
`expected_main.txt`、`expected_naive_crash.txt` 做比较,所以内核或任一写法里的
改动会以 diff 的形式浮现。`naive_crash.emo` 以 `E3007` 和退出码 70 收尾 ——
那*就是*它的结果,所以退出码是被比较输出的一部分。两个脚本都在比较前剥掉绝对
路径,所以 golden 不会带上上次是谁跑的。

`check.sh` 每条期望都先声明再比较,这正是要点:三个目标失败和两个检查器结果
都被钉住,所以 `src/` 里的修复会在这里变成 FAIL,而不是留成上面一段过时的文字。

这里没有任何东西接进 `dune test` 或 CI,`src/` 下也没有任何改动。
`.emo-build/` 装中间产物,已在全局 gitignore 中。

## 文件

| 文件 | 是什么 |
|---|---|
| `ui.emo` | T48.1 可移植内核:`Style` 加 `with_*` 复制、`Node`、八个控件、`Backend`、`children_of` |
| `components.emo` | 两种写法逐字共享的每个控件(仅子节点列表固定的那些) |
| `screens_a.emo` | 两个屏幕的 A 写法,外加 `screen_profile_dup` 与 `screen_profile_naive` |
| `screens_b.emo` | 同样两个屏幕的 B 写法,40 行 |
| `debug.emo` | T48.3 无头后端:节点树 → 稳定的缩进文本 |
| `model.emo`、`app.emo`、`tags.emo` | `Field`/`Message`/`Model`/`Msg`、`update`/`view`、事件 tag 注册表 |
| `measure.emo` | 五策略子节点数组构造阶梯 |
| `main.emo` | 断言、golden 报告、测量 |
| `naive_crash.emo` | 嵌套数组 bug 的真实症状:`E3007`,退出码 70 |
| `features.emo` | 内核所依赖的五个语言特性,每一个都是承重的 |
| `mismatch/` | 检查器对错误子节点字面量的覆盖(嵌套包) |
| `codegen/field_table/`、`codegen/native_string_add/` | 两个 `src/` 缺陷,各自隔离(嵌套包) |
