# GC 堆 —— arena、对象模型,与用 Emo 写的收集器

## 决策

GC 自举(plan/step-89)开启了 runtime-independence 原则等待已久的轨道:一个用 Emo 写的垃圾收集器,如同 wasm 运行时那样。解释器运行(`emo run`)是第一个宿主。Step 90 把机器的最后一块拼图放进了位:堆是**一个 arena** 的词,分配器——`gc` 包自己的自由表——通过 `heap_carve`/`heap_release` 刻块与释放,词走裸 `heap_load`/`heap_store` 通道。arena 之上的对象模型——定长 **struct** 块、带计数的 **array** 块、被追踪的 **ref**、mark-sweep、带切分与合并的自由表——全是 Emo 代码。一份源码服务每一个应答相同门的宿主;解释器模拟的 arena 就是 spec,内存真实的 target 在被授予的区域上实现同样的门(plan/step-90-gc-ladder.md 记录阶梯:分配器、载荷装箱、压缩收集、真实内存宿主——四级已全部走完;plan/step-91-riscv64-gc-host.md 把最后一个宿主放上金属,这条轨道自己的主顾)。

本轨道不翻 T23.5 的案。宿主运行时的回收模型——identity 对象引用计数、值语义走 arena——原样成立;本轨道是自带托管堆的库,不改任何运行时的值模型。它先回答的是回收模型答不了的诉求:一个能走环的收集器(引用计数永远收不回环),以及 freestanding target 缺的那块拼图——`runtime-and-freestanding.md` 把「分配器、垃圾收集器」列为运行时自己的工作,金属上没有宿主可借。

## 对象模型

- **一个 arena。** `heap_new(words)` 造它,每轮运行一次;真实宿主改为授予一个区域。分配器工作的一切地址都是 arena 内的词偏移。
- **一个词靠奇偶自描述。** 偶数词是标量,左移一位存储;奇数词是引用,即刻块时应答的句柄;`0` 是 null,可入引用槽。这个打标就是堆的全部类型纪律:收集器能走一个它没有类型过的堆,而同一条位规则正是 riscv64 动态值模型的规则——spec 可平移。
- **句柄携带地址与代数:`(gen << 42) | (offset << 1) | 1`。** 代数随偏移的每次绑定增长,所以释放前铸的句柄在同一批词的下一次绑定处响亮死去——陈旧句柄的结局穿过 arena 依然成立,无需墓碑。
- **槽 0 是头词。** 它打包 magic(位 63:48)、kind(47:46——1 struct,2 array)、代数(45:24)、收集器的标记位(23)、逻辑尺寸(22:0,至多 2^23 词)。数据在槽 1..n;`gc` 包的访问器做了平移,调用者的字段索引从 0 起。
- **门按职责分。** 宿主持有 arena、偏移到块的绑定、以及带检查的字段访问(`struct_get` 等验证 kind、代数与边界)。分配器的裸通道——`heap_load`/`heap_store`,arena 内不检查——是自由表和标记位工作的通道;变异者永不碰它,与「槽 0 归收集器」同一条纪律。

## 门

| 门 | 签名 | 作用 |
| --- | --- | --- |
| `heap_new(words)` | `Int64 → Int64` | 造 arena,每轮一次;应答词数 |
| `heap_load(addr)` | `Int64 → Int64` | 读一个 arena 词——分配器的裸通道 |
| `heap_store(addr, w)` | `Int64 → Int64 → Void` | 写一个 arena 词 |
| `heap_carve(addr, n, kind)` | `Int64 → Int64 → Int64 → Int64` | 把一段范围绑成块(写头词),应答句柄 |
| `heap_release(h)` | `Int64 → Void` | 解绑一块,清零其头词 |
| `heap_rebind(h, addr)` | `Int64 → Int64 → Int64` | 只搬绑定(词走裸通道) |
| `heap_slide(pairs)` | `Array[Int64] → Array[Int64]` | 压缩门:全部绑定块按目的序,一次序列完成搬词与换绑 |
| `heap_float_bits(f)` | `Float64 → Int64` | 位转换:一个 float 精确的 64 位 |
| `heap_bits_float(w)` | `Int64 → Float64` | 位转换回读 |
| `float_array_get(a, i)` | `Int64 → Int64 → Int64` | float 数组的裸位,带检查 |
| `float_array_set(a, i, w)` | `Int64 → Int64 → Int64 → Void` | 写裸位,带检查 |
| `struct_get(b, i)` | `Int64 → Int64 → Int64` | 读槽 i(0 头词,1..n 数据),带检查 |
| `struct_set(b, i, w)` | `Int64 → Int64 → Int64 → Void` | 写槽 i,带检查 |
| `array_len(a)` | `Int64 → Int64` | 答逻辑词数 |
| `array_get(a, i)` / `array_set(a, i, w)` | — | array 的槽,同规则 |
| `block_kind(h)` | `Int64 → Int64` | 1 struct,2 array |
| `block_size(h)` | `Int64 → Int64` | 逻辑尺寸 |
| `ref_new(w)` | `Int64 → Ref` | 建一个持词 w 的根格 |
| `ref_read(r)` | `Ref → Int64` | 读根的词 |
| `ref_write(r, w)` | `Ref → Int64 → Void` | 重指根 |
| `ref_roots()` | `→ Array[Ref]` | 活根,一次 major 周期之后——移动式收集器重指它们 |
| `heap_blocks()` | `→ Array[Int64]` | 每个绑定块的句柄,按地址序 |
| `heap_words()` | `→ Int64` | 绑定块的物理词总数 |

**float 数组(kind 3)。** 一个 float 的 64 位装不进奇偶通道——移位往返只保真最高位重复的词,一半的 double 会被毁。float 有自己的块类型:每个数据槽都是裸位(`heap_float_bits`/`heap_bits_float` 是转换对),内部没有引用,收集器追踪 float 数组但不走它的词。字节在标量通道完全保真(0..255 移位往返无损);`gc` 包的字节访问器在读取时检查范围。`struct_new`/`array_new` 在 step 90 退休:分配是分配器的事——包的 `take` 在自己的自由区间上跑首适配、调 `heap_carve`——而绕开自由表铸块的门是个策略漏洞。`heap_free` 随之退休:sweep 经 `heap_release` 释放、把区间亲手还给几何。

## 根

`Ref` 是一个解释器看得见的可变词。每个 `Ref` 值的格弱注册:宿主自己的收集器是活性 oracle,程序丢弃的根在下一次 major 周期自然出册——无代价、无 drop 动词,use-after-drop 这一类错误从构造上就死掉了。`ref_roots()` 读之前强制一次 major 周期,收集看到的恰好是变异者还持着的东西;快照有序,行走与序无关。

变异者纪律就是有根句柄规则(SpiderMonkey `Rooted` 的形状):要被收集尊重的句柄放进 `ref`;裸 `var` 里的句柄对收集器不可见,它指名的块死在下一次 `collect`。收集不分配——工作栈是宿主内存——分配点就是普通的包调用,所以不存在会出错的暂停协议。

## `gc` 包

门上的纯 Emo。访问器扛移位(`s_set` 存 `v << 1`,`s_get` 答 `w >> 1`,算术移位往返负数),`_ref` 访问器拒绝偶数非零词——停在引用位置上的标量——null 放行。访问器把字段索引平移一位,调用者的字段从 0 起,槽 0 留给收集器。

`collect()` 是 mark-sweep:从根出发沿奇数词标记,头词的位切环;排空工作栈直到游标追上 builder 的长度(行走深入到图的尽头,不只在根旁一步);sweep `heap_blocks()`,释放未标的、清掉已标的。它应答本次 sweep 收回的词数。

指向已释放块的根在门口响亮死去——E3050——和每扇门给陈旧句柄的结局一样。

## 压缩(Emo,不是宿主)

`collect` 标记并清扫;`compact` 全做之后还滑一遍。活块——地址序、
目的从零——作为 `(句柄, 偏移)` 对交给 `heap_slide`,宿主验证连
续性、搬词、按一序列换绑(向左滑保证每次写都不越过下一次读,该趟
不可能踩到尚未取走的源)。包经自己的前向表重写一切引用——先字段,
后根(`ref_roots` 因此答 `Ref` 格)——并把自由几何重置为滑后背后
的那一个区间。碎片是堆路过的一种状态,不是它保存的一种状态。

## 分配器(Emo,不是宿主)

自由几何是 `gc` 包自己的数据:两张 Map,`by_start`(start → size)与 `by_end`(end → start)。分配是首适配——take 切开选中的区间、留下余量——释放则与两张 Map 点名的邻居合并,无需扫描。arena 有限(`heap_new` 说出存在多少词),没有区间能应答的分配就是响亮的结局:`gc: the arena has no free range for the request`。`gc.arena(words)` 开启一轮运行,`gc.free_words()` 读几何,`gc.addr_of(h)` 解码句柄的偏移——demo 印出的复用是分配器的地址回答,不是一个计数。

## per-target 矩阵

准入原则是裸内存家族原则的反转:target 准入 GC 堆,当且仅当 target 的内存归收集器管。

| Target | 门 |
| --- | --- |
| 解释器运行 | 准入——门就是这个运行的对象模型 |
| `c` | 准入——运行时在真实 `malloc` 的词上持有 arena 与绑定(T90.4) |
| `riscv64` | 准入——镜像给收集器授予一个区域;门是镜像的运行时助手(step 91) |
| `ocaml`、`typescript`、`browser`、`wasm`、`beam` | 在检查期按名拒绝(E4032) |

解释器运行以 target `interpreter` 检查(`emo run` 的检查传入它);`c` target 在自己的检查里准入,`riscv64` 与之同行。其余托管席位与 LSP 保持宿主默认,gc 门的程序在编辑器里显示拒绝,与 `peek8` 程序在 `riscv64` 之外的样子相同。在 `c` 宿主上,变异者纪律多了一条自己的规则:分配或生根的脚本级绑定是 `var`,绝不是 `const`——`c` target 会记忆化脚本 const,含副作用的初始化器会在首次读取时重跑,顶着第一个名字的第二次分配。金属上区域随每个 profile 的镜像走,kernel-profile 的程序可以裸调门但不能 `require` 包(E5014,kernel profile 自己的规则)。`Ref` 跨进程边界传递同一个格——注册表是这个运行自己的,一个根怎么算都是一个。`heap_words` 数物理词;解释器自己的块、装箱值、builder 存储仍是宿主的内存,没有门为它们命名。

## 金属(riscv64)

第三个宿主,也是这条轨道立项时的那位主顾:同样的二十四扇门,骑在镜像自己的内存上,没有宿主运行时可借。镜像在自己的 `.bss` 里给收集器授予一个区域——`emo_gc_region`:一 MiB 的 arena、绑定表(8192 项,每项 32 字节:offset、代数、kind、size)、根表(4096 格)、slide 的暂存。区域答不了的请求就是响亮的结局——门按名拒绝,解释器的文案上串口。

门是随程序编译的运行时助手(`emo_gc_heap_new` 们),每个带检查的访问器对绑定表验证 kind、代数与边界,与解释器求值器的方式相同。区域之上的一切仍是同一份 Emo 包——demo 的分配器、收集器与压缩原样编译进镜像。

`Ref` 落为 tagged 值模型的 kind 12,金属的 Map 落为 kind 13——都是运行时自身引用计数之下的 identity kind,归零的释放从根表摘链(c 宿主的精确 oracle 规则,用金属的话重述)。`raise` 在本宿主关上最后一道缺口:`Raise` 语句降为 `emo_raise`,异常值按 c 宿主的方式渲染(裸消息透传,`Exception` 实例从 field 0 取 message 字段),未捕获的 raise 是响亮结局的打印与退出。模块级 `var` 也降了——格在镜像的静态内存里,序言在体之前初始化——`gc` 包自己的 `by_start`/`by_end` 像任何值一样骑进镜像。

验收是 demo 的 24 行金测在三个宿主上逐字节一致——解释器运行、编译的 `c`、金属——金属侧三 boot 稳定,经嵌入镜像的 EmoOS 内核引导(`@emo_os` 套件的 `gc_metal` 组驱动这条腿)。

## 错误

| 代码 | 含义 |
| --- | --- |
| E3050 | 不是活块:偶数词、未绑定偏移、陈旧代数、未经 `heap_new` 的堆 |
| E3051 | kind 错:struct 门落在 array 块上,或反之 |
| E3052 | 槽越出块的 `0..n`,或 arena 词越过 arena |
| E3054 | 负数尺寸 |
| E3055 | 块或 arena 越过尺寸护栏(2^23 / 2^41 词) |
| E3056 | `heap_carve` 与绑定块重叠 |
| E3057 | `heap_new` 造第二个 arena |
| E4032 | 检查期拒绝,每门一条,落在所有未准入堆的 target 上 |

E3053(重复释放)随 `heap_free` 在 step 90 退休——已释放的块即未绑定,第二次释放与一切陈旧句柄同为 E3050。

## 收口

自举的证明,随阶梯成长:分配器与收集器都是 Emo 代码,解释器是它们的宿主,`examples/gc_demo` 是验收——有根的链和被穿透标记的 array 活过杀死四千个无根节点的收集,环(引用计数永远收不回的形状)在根松手的瞬间死去,而**第二代分配落进 sweep 还回来的词里**(word 18 与 word 12027——junk 区和环自己的地址空间),arena 从不增长。金测:demo 的十七行在解释器运行上逐字节,checker 套件里的 `gc_heap_tests`,以及在每个拒绝 target 上逐门点名的 `gc_refusal` 负向金测。

阶梯已走完:float 与 byte 载荷装箱(T90.2)、偏移句柄已经让引用可重写的移动式/压缩收集器(T90.3)、以及真实内存宿主——c target 运行时(T90.4)与 riscv64 tagged-word 堆(step 91)——在被授予的内存上应答同样的门,同一份 Emo 分配器与收集器编译进去。轨道以第一位主顾被服侍而收口:EmoOS 用户程序的堆归收集器管,demo 的金测把三个宿主钉在一起。
