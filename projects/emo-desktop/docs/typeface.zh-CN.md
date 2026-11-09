# 任意字号的字型(M17)

桌面端的字型自 A14.2 起就是真正的字型库——界面用 Inter,单元格网格用
JetBrains Mono——但它以三个像素 strike 的形式旅行(Inter 16 与 24、
JetBrains Mono 16),由 `glyphs/rasterize.py` 在主机端经 Pillow 的
FreeType 烘进 `font.emo`。想要 32 像素标题、20 像素正文,或为更密的
屏幕把整个界面放大一倍的窗口,今天没有答案:尺寸被冻结在生成器停下的
地方,每加一个 strike 就让 `font.emo` 再长出 96 个字形的覆盖度。
文字本身在它占据的像素上已经清晰——最大化的窗口重排并重绘,渲染的
strike 就是显示器的原生像素——桌面缺的是**尺寸的自由**,以及随之而来的
缩放整个界面的自由(2x 屏幕就是一屋子管线烘不出来的字号)。

M17 把光栅化搬进 OS。字面以二次贝塞尔轮廓旅行(剥开覆盖度网格,它们
从来就是),Emo 光栅器在首次使用时把任意字形打到任意像素字号,结果存进
一个与其 app 同寿的 strike。以下决定于 2026-11-09 拍板;阶梯是
A17.1 至 A17.4。

## 决定

- **D7——轮廓以生成模块旅行。** 每个字面编译为一个 `face_*.emo` 数据
  模块,由 `glyphs/outlines.py` 从钉死的 TTF 写出,正如 `gen.py` 从网格
  写出 `font.emo`。运行期没有文件读字型——六个 target 不需要新的文件
  能力,hosted 金测保持单源,金属镜像携带轮廓正如它曾携带像素。轮廓比
  它替代的像素更小:Inter 的 96 字形是 3,383 词、8 个 chunk,JetBrains
  Mono 是 2,973 词、7 个 chunk,对比它们退役的三份 strike 的 4,269 词
  ——而且一张表现在回答所有字号,不再只有三个。
- **D8——光栅器是 OS 自己的,纯整数,带规范参照。** 全部算术是
  `Int64` 上的 26.6 定点——路径上没有 `Float64`,所以每个 target 按构造
  落在同一个字节上。算法的事实之源是仅用标准库的 Python 参照
  (`glyphs/reference.py`,A17.3 写);Emo 光栅器必须逐字节复现它,金测
  钉的正是这一点。FreeType 降为视觉审计,不再是裁判。
- **D9——覆盖度八位。** strike 每像素存一个覆盖度字节(A14.2 网格的
  十六级是存储选择),直接喂给表面已在跑的 source-over 算术。
- **D10——接缝保形。** `ink` 保持五参形状;它的 strike 实参从 `Int64`
  表索引拓宽为 `Strike`——A17.2 构建的按尺寸稠密对象。`text` 与
  `text_width` 各自接收要画的 strike,每个调用点报出自己的字号。
- **D11——像素管线在 A17.4 退役。** `font.emo`、`glyphs/gen.py` 与
  `coverage.txt` 退场;`glyphs/rasterize.py` 留作审计的参照渲染器。
  一条文本路径,不是两条。
- **D12——扩展各有触发器,一个都没拉。** hinting(14px 以下发虚)、
  kerning 对、分数 advance、CJK 覆盖度、字重面,各自在需求真实时
  重开;见非目标一节。

## face 格式(format 1)

face 模块(`face_inter.emo`、`face_mono.emo`)是生成的文本,gate 里由
`outlines.py --check` 对着它的 TTF 校验。它携带:

- 来自 `head` 与 `hhea` 的标量 def:`units_per_em`(Inter 2048、JBM
  1000)、`ascent_fu`(1984 / 1020)、`descent_fu`(−494 / −300,hhea
  的符号)、`line_gap_fu`,以及 `glyphs`(恒 96:gid 0 是该字面自己的
  `.notdef`,gid 1..95 是按码序的 0x20..0x7E)。
- `glyph_of(c String)`,标签已在用的 alphabet `index_of` 步进,表外的
  一切回答 0——`.notdef`。
- `bases`,每字形一词:切片在轮廓区的首词。
- 轮廓本体,448 词一 chunk,藏在 `outline_word(k)` 后——与 `font.emo`
  的表同一套 chunk 纪律。一个字形的切片是:

| 词 | 字段 |
|----|------|
| 1 | advance,font units |
| 1 | 顶点数(上限 4095) |
| 1 | 轮廓数(上限 255) |
| ⌈轮廓数/4⌉ | 轮廓终点索引,每词四个 16 位小端字段 |
| 其余 | 每顶点一词 |

  顶点词把 on-curve 旗标装进最高字节(第 56 位,唯一定义的旗标),把
  与前一顶点的有符号差量——首顶点相对原点——装进两个 28 位字段。全部
  无符号,全部低于 2⁶¹。off-curve 顶点让路径从它弯过;成串的已在生成
  期解析。

`outlines.py` 替 OS 侧解析器解决掉的事:cmap(format 4 或 12,取
`(3, 1)` 子表;每个 ASCII 码点必须命中,否则生成器拒绝)、隐式
on-curve 中点(向下取整,插在相邻 off-curve 顶点之间,每条轮廓旋转到
on-curve 顶点开头)、复合字形(部件带平移抵达;带缩放或点索引锚定的
按名拒绝——两张钉死的面都没用)。

advance 交叉检查在生成器的两种模式下都跑:每个 strike 的 95 个
advance 从 font units 缩放后必须等于网格记录的值,精确有理数四舍五入。
FreeType 自己的 hinting 偶尔挪动一个 advance 一像素(当前 Inter 的
`5` 在 16px、`T` 在 24px);一像素之差报告并放行,两像素及以上拒绝
——走歪的 cmap 或 hmtx 步进会歪得很远,不会只歪一像素。

## 光栅器(A17.3)

规范算法,先写成 `glyphs/reference.py`(仅标准库,像网格一样可审),
再移植进 `raster.emo` 的 Emo,逐字节对齐:

- **坐标。** font units 的顶点 `fu` 在 strike 字号 `px` 下落到 26.6
  定点:`v26 = (2·fu·px·64 + upem) / (2·upem)`,向下取整——精确有理数
  四舍五入,全程整数。strike 的 y 自行盒顶向下;字面的 y-up 轮廓按
  `y26' = ascent_px·64 − y26` 翻转。
- **度量。** `ascent_px` 与 `descent_px` 向上取整缩放:
  `ceil(fu·px / upem)`——这是 FreeType 做而网格证实的那一处取整
  (Inter 16:1984·16/2048 = 15.5 → 16;24:23.25 → 24;三份 grid
  strike 的每个 ascent、descent 与 `.notdef` advance 都精确复现)。
- **展平。** 二次曲线按 de Casteljau 中点拆分细分,每次中点
  `floor((a+b)/2)`,直到二阶差 `|p0 − 2c + p1|` 不超过 64(26.6 下的一
  像素)——曲线对弦的最大偏差是该差的四分之一,所以每段都在真曲线的
  四分之一像素内。深度上限 8,边表先精确算容(每条二次 Σ 4^depth);
  越界拒绝。
- **面积累积。** 每条线段按其跨越的行逐行裁剪,在行内按列行走,交点
  处向下取整的精确插值。由 Green 定理,像素的被覆盖面积是每条穿越边
  的带符号碎片 `∫ clamp(x − 64c, 0, 64) dy` 之和:起点列与终点列各拿
  自己的梯形——`(w_top + w_bottom)·h / 2`,向下取整——严格居中的列拿
  整的 `64·h`,而位于碎片左侧的每一列也都拿到,以后缀和的 cover 携带
  (`cover[起始列 − 1] += h`,符号随边的下降方向)。清扫把
  `cells[c] + 64·cover_suffix[c]` 相加、取绝对值——nonzero winding
  从带符号和里直接掉出来——再舍入 `min(255, (|A| + 8) >> 4)`。水平线
  没有贡献;竖直线就是它所在列的梯形。
- **墨的位置。** `left = floor(min_x26 / 64)`,
  `top = floor(min_y26' / 64)`,`w` 与 `h` 取与轮廓相交的行列界——与
  今天网格的 `left`、`top` 同一套笔位/行盒语义。
- **顺序无关。** cells 累积的是精确整数;唯一一次舍入发生在清扫。
  展平顺序、边顺序,动不了任何一个字节。

对 FreeType 的审计(Pillow,借 `rasterize.py` 的机械)是一份开发期
报告——逐字形、逐字号的级别差——不是 gate;gate 是参照自己的字节,
钉进金测,在每个 target 上完全一致。

## Strike(A17.2)

每(字面, 像素字号)一个 `Strike`,在 ASCII 表上稠密——无哈希、无
淘汰;字形落进的槽就是它的字母表位置。strike 的构造器按错误约定
作答——`(R.ok, strike)` 或 `(R.error, why)`——因为 raise 不是金属的:
riscv64 target 不 lower 它,而编译器会把包内每个模块拉进构建,所以
`raster.emo` 随金属镜像一起 lower,像 gate 自己的 syscall 应答那样
拒绝(它的构造器同样为此守着七个参数——金属拒绝更宽的)。

- `max_dim` 默认行盒向上取整到 8;墨迹超出的字形拒绝(生成器对自家
  表静态断言同一上界)。每槽 `ceil(max_dim² / 8)` 词,覆盖度字节
  八个一词打包;16px 下一张 strike 是 96 × 72 词 ≈ 54 KiB,24px
  ≈ 96 KiB,全部在构造时分配——Strike 是它 app 的引导期常量,winbuf
  的路数,此后每帧零开销。
- Strike 在构造时急切光栅化——设计里的"首次使用光栅化"在 A17.2 遇到
  语言事实时修正:数组是不可变值,可变容器(Box、List、Map)里没有
  blit 能按 `font.emo` 形状读取的按索引字存储,所以 strike 把九十六个
  字形全部光栅化进 init 存下的一块普通 `Array[Int64]`。引导期工作
  不变;blit 每帧读的是同一批词,此后每帧零分配。
- 每字形暴露的 meta 是两个词:base 与 advance;left、top、width、
  height。blit 不再需要别的。

editor 加载两张面;每张面每个 app 解析一次(几千词),strike 惰性
变暖。

## 接缝(A17.4)

```emo
def ink(x Int64, y Int64, f Strike, glyph Int64, color Int64) Void
def text(f Strike, label String, x Int64, y Int64, ink Int64, s Surface)
def text_width(f Strike, label String) Int64
```

动词的形状还是 A8.1 以来的那一个——每字形一次接口调用,金属侧不因
像素而装箱。后端一次取走两个 meta 词与覆盖度词,然后本地循环。
首日的 spike 是 `Array[Int64]` 在 riscv64 上跨模块线(winbuf 的字节表
证明参数位可行);若返回位被拒,词改由动词携带,签名在八参上限内变胖
——由证据决定,不靠猜。

`raster.emo` 加入 `emo/ui_fb` 包,做解析器、Strike 与光栅器的家;face
模块喂它。迁移把每个调用点换成具名 strike——header 与 dock 用它们的
header 字号,editor 的格用 mono 面——金测重生成一轮,lock 一并(M16
的教训:包的源动了,消费者的 lock 跟着动)。

## 阶梯

| # | 内容 | 验证 |
|---|------|------|
| A17.1 | `glyphs/outlines.py`:钉死的面 → 解析后的轮廓 → `face_inter.emo`、`face_mono.emo`;gate 漂移检查 | 生成器对网格的交叉检查;包通过 type-check |
| A17.2 | `raster.emo` 里的解析器与 Strike:读面,度量按钉死的公式缩放,槽分配 | hosted 金测:解析级事实,度量复现网格三 strike |
| A17.3 | `glyphs/reference.py` 然后 Emo 移植:展平、面积累积、清扫 | 钉死的字形集覆盖度逐 target 与参照字节一致;FreeType 审计报告 |
| A17.4 | 接缝迁移;像素管线退役;金属 bring-up | run.sh ×3 双传输逐字节、dune 全量、@fmt、fb gate、lock 重生成 |

## 非目标,各带触发器

- **Hinting**——字面按无 hinting 渲染,网格的像素也一样(Pillow 的
  mask 本就不带网格拟合)。14px 以下重开,那里 hinting 是字母与糊团
  的分界。
- **Kerning 对与分数 advance**——笔按整像素走,与今天相同。可见的对
  或大字号让间距发涩时重开。
- **亚像素定位的字形**——缓存按字形键控,不按相位。随分数 advance
  重开,从不单独重开。
- **CJK**——格式携带任意子集;CJK 面是更大的文件加稠密槽的问题,桌面
  需要那段文字时再决定。
- **字重面**——只有 Inter Regular 与 JBM Regular。chrome 要字重对比
  时,Semibold 面文件是即插件。
- **浮点算术**——没有,是决定不是遗漏:target 逐字节一致站在整数上,
  而这里没有什么是整数给不了的。
