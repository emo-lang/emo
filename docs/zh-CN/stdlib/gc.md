# `gc` 包

GC 堆的分配器与收集器:自由表和 mark-sweep 用纯 Emo 写,骑在解释器
运行准入的对象模型门上([`docs/gc-heap.md`](../gc-heap.md) 是设计
笔记)。arena 是宿主的;它之上的一切——刻块、带切分与合并的自由
几何、追踪、sweep——都是这个包。一份源码服务每一个应答相同门的
宿主;解释器运行是第一个,而在所有 build target 上整个家族在检查
期拒绝(E4032)——包在那里能解析,门在程序里拒绝,所以诚实的席位
只有运行。

## 使用包

```emo
require "gc"

gc.arena(65536)   // 每轮一次:分配器从此刻画的 arena
```

标准库随编译器一起发布,但它的包和其他包一样带版本:`require "gc"`
需要 manifest 的 `deps` 块里有 `"gc" = "0.1.0"`。`arena` 造堆——
有限的 arena 正是重点,没有自由区间能应答的分配就是响亮的结局。

## 对象模型一口气版

堆词靠奇偶自描述:偶数词是标量(左移一位存储),奇数词是引用——
即分配时块应答的句柄——`0` 是 null。`struct` 是定长字段数,
`array` 是带计数的词段,每块的槽 0 是收集器的头词。下面的访问器
做了平移,调用者的字段索引从 0 起;槽 0 留给收集器。

变异者纪律:要被收集尊重的句柄放进根——`ref_new`——并且收集期间
不分配。裸 `var` 里的句柄对收集器不可见;它指名的块死在下一次
`collect`。

## 词的打标

```emo
def is_ref(w Int64) Bool    // 奇偶位——槽的类型就是词的类型
```

## arena 与分配器

```emo
def arena(words Int64) Void     // heap_new + 自由表整装出发
def free_words() Int64          // arena 尚未刻出的词
def addr_of(h Int64) Int64      // 句柄的头词偏移
```

自由几何是这个包自己的数据:两张 Map,一张按区间起点、一张按区间
末尾后一个词。分配是首适配,take 切开选中的区间;释放与 Map 点名
的邻居合并。

## struct 访问器

```emo
def s_new(fields Int64) Int64             // 从自由表 take,刻块
def s_set(b Int64, i Int64, v Int64) Void         // 存标量
def s_get(b Int64, i Int64) Int64                 // 读标量
def s_set_ref(b Int64, i Int64, h Int64) Void     // 存句柄或 null
def s_get_ref(b Int64, i Int64) Int64             // 读句柄或 null
```

`_ref` 一对拒绝偶数非零词——停在引用位置上的标量——放行 null:
`0` 就是空引用,用 `is_ref` 或 `!= 0` 检验。

## array 访问器

```emo
def a_new(n Int64) Int64                  // 分配,应答句柄
def a_len(a Int64) Int64                  // 词数
def a_set(a Int64, i Int64, v Int64) Void         // 存标量
def a_get(a Int64, i Int64) Int64                 // 读标量
def a_set_ref(a Int64, i Int64, h Int64) Void     // 存句柄或 null
def a_get_ref(a Int64, i Int64) Int64             // 读句柄或 null
```

## 收集器

```emo
def collect() Int64    // 从根标记,sweep 其余,应答收回的词数
```

sweep 把每个不可达块的区间还给自由几何、与邻居合并——一次收集
释放的词,就是下一次分配刻出的词,demo 的第二代即为例证。

一次完整收集:行走从解释器运行应答的根出发,沿每个奇数词推进,
标记位切环,把工作栈排空到图的尽头,释放一切未标记的。它应答
sweep 收回的物理词数。指向已释放块的根在门口响亮死去(E3050)——
和每扇门给陈旧句柄的结局一样。

## 何时 raise

调用者的错误会 raise:偶数非零词按引用存储或读取;没有自由区间能
应答的分配(`gc: the arena has no free range for the request`)。
数据的错误是堆自己的错误——门的 E3050–E3052 与 E3054–E3057(陈旧
句柄、块 kind 错、词越界、负数或超大分配、carve 压上绑定块、第二
个 arena),在 [`docs/gc-heap.md`](../gc-heap.md) 里逐条命名。
