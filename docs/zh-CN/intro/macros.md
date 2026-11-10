# 宏

Emo 的元编程机制是编译期宏:一个用 `// #macro` 标记的普通 `def`,在编译期间运行,接收被装饰声明作为语法树,返回替换的语法树,拼接进程序后像普通代码一样检查。应用写在被转换声明上方的 `// @name`。完整的工作设计(含被否决的备选与后续步骤)在 [`design/macros.md`](../../design/macros.md);面向任务的完整走读——指令、`Syntax` API、quote 表面、实例配方与错误码表——见[宏指南](../macro-guide.md)。

## 两个指令命名空间

首 token 是 `#` 或 `@` 的 `//` 注释不是注释——是指令,编译器像其他语法一样检查它。其余注释都是散文,保持惰性。

- **`#` 是角色命名空间**——编译器所有,声明下面那个东西*是什么*。`// #macro` 声明其下的 def 在编译期运行,展开后从程序中抹除。`#` 名字集合固定;未知名字是编译错误(E2029),所以 `// #macor` 这样的错拼永远不可能静默降级成散文。
- **`@` 是应用命名空间**——`// @name` 把宏 `name` 应用到下面的声明上。`@name` 像其他名字一样解析:必须指向本模块内用 `// #macro` 声明的 def。把 `@` 用在非宏名字上是错误(E4300),两个命名空间不会混淆。

放置规则:指令独占一行,紧贴其下的声明(空行让它浮空——E2030);指令可叠加,离声明最近的行先生效;函数体内或语句上方的指令是错误(E2031);同一宏不能对同一声明应用两次(E2032);宏 def 不接受应用(E4310)。

```emo
// #macro
def trace(f Syntax) Syntax {
  ...   // 普通 Emo,编译期运行
}

// @trace
def double(n Int64) Int64 {
  return n * 2
}
```

## 宏模型

- **声明形状**:宏取零或多个前导编译期**标量**参数(`Int64`、`String`、`Bool`、`Float64`、`Byte`、`Char`),后接恰好一个尾随 `Syntax` 参数——被装饰树——并返回 `Syntax`(否则 E4302)。`Syntax` 是保留的、仅编译期存在的类型——在 `#macro` def 之外不得拼写或引用(E4301)。
- **先检查后运行**:宏体像任何 def 一样做类型检查;没通过类型检查的宏在执行前就被拒绝。
- **按构造确定**:宏体跑在编译器自带的解释器上,一切 effect 被拒,一切触及宿主的内置(`rand_bytes`、`os_*` 族)被拒(E3030)。不需要效应系统来说明这一点——编译期 profile 里这些钩子根本不存在。步数预算约束运行,失控的宏让构建失败而不是挂死编译器。
- **抹除**:展开后 `#macro` def 消失——运行期没有绑定,发布的程序不携带数据从未要求的机器。
- **拼接后再检查**:生成的代码随模块一起检查。转发参数个数错的 wrapper、绑定签名不允许的值的 wrapper,都以普通检查器错误在拼接处定位并让构建失败。
- **拒绝即 raise**:无法包装的形状——多参数 def、`Void` 结果——用 `raise Exception.new("...")` 明说,raise 以展开期编译错误(E4308)浮出并携带消息。

被装饰 def 体内的递归引用最终的、装饰后的绑定——体在全部展开之后、对着展开后的声明检查。宏编造的名字来自 `Syntax.gensym`,它发放不会与用户代码相撞的新名字。

## 应用参数

应用处供给宏的前导标量参数:`// @memoize(2)` 在编译期求值 `2` 并绑到 `memoize` 的 `limit`。括号必须紧贴指令名(E2034),实参是指令自己一行上的普通逗号分隔表达式,角色指令不取参数(E2035),个数(E4306)与每个实参对已声明参数的类型(E4307)都在展开期求值它们的那个"仅内置"环境里静态检查——编译期 profile 看不见的名字在检查处就以同样答案失败。

## quote 表面

`quote { ... }`——上下文拼写:仅当 `quote` 处于操作数起始位置(`=`、`(`、`,`、`[`、`return`、`do`、`->`)且同行紧跟花括号才是模板;其余 `quote` 都是普通名字——标准库的 JSON 转义器 `quote(s)` 与 sql 的 `== quote {` 条件收尾因此不受扰——把宏生成的代码按普通代码铺开:体在 quote 自己的 token 流上按 item 解析(真 span、真错误),每个 `${expr}` 洞拼接一个在展开期、于宏体内求值的表达式树。提升保持显式——`${Syntax.ident(name)}` 拼接名字,`${Syntax.lit_int(limit)}` 拼接字面量;洞产出非表达式树是错误(E4309)。模板内的声明结构是字面的(构造器掌管 def 的名字、参数、结果),带引号字符串里的字符串插值保持为生成代码自己的,宏体外的 `quote` 是普通编译期窗口错误(E4301)。`Syntax.new_def` 以整个 quote 作体,`Syntax.seq` 展平,宏的拼接就是它写下的那些声明。

## `Syntax` API

交给宏的值是被装饰 def 的树;它返回的值拼回原位——一个声明,或一列展平的声明(`Syntax.seq`)。读取器:`Syntax.name`、`Syntax.params`、`Syntax.param_name`、`Syntax.result`。构造器:`Syntax.rename`、`Syntax.new_def`(从名字、参数树、结果类型树和体构造 def——体是语句树数组或整个 quote)、`Syntax.ident`、`Syntax.lit_string`、`Syntax.lit_int`、`Syntax.lit_bool`、`Syntax.lit_float`、`Syntax.interp`、`Syntax.call`、`Syntax.call_stmt`、`Syntax.expr_stmt`、`Syntax.const_stmt`、`Syntax.return_stmt`、`Syntax.empty_map`、`Syntax.const_item`(宏为其生成的运行期状态拼接的模块级常量)、`Syntax.gensym`。宏应用必须产出声明——单独的表达式或语句碎片是错误(E4303)。

完整实例:[`examples/trace_demo`](../../examples/trace_demo/main.emo)——`trace` 宏的转发调用由被装饰声明自己的参数树构造,永远不会与签名漂移;[`examples/memoize_demo`](../../examples/memoize_demo/main.emo)——带编译期容量参数、私有 `Map` 常量和 quote 铺开 wrapper 的 `memoize` 宏,缓存命中跳过计算、驱逐则重算,输出可见。

## 类应用

应用的座位扩到类:`// @derive_eq` 写在 `class` 上方,把类树交给宏;宏读取字段列表(`Syntax.fields`、`Syntax.field_name`——名字;AST 不携带字段类型),返回变换后的类——`Syntax.with_methods(class, methods)` 把生成的 def 追加为普通方法,随模块一起检查。`Syntax.name` 应答类名;`Syntax.new_param`、`Syntax.named_type`、`Syntax.self_expr`、`Syntax.bin_eq`、`Syntax.bin_and`、`Syntax.member` 构造生成体。角色侧仍是 def 专属——`// #macro` 写在类上是错误,应用写在其他 item 上也是错误。

完整实例在 [`examples/derive_eq_demo`](../../examples/derive_eq_demo/main.emo):`@derive_eq` 生成把每个字段成对比较的 `eq?` 方法——生成的判等不可能遗漏类声明的任何字段,这正是此机制要消除的漂移。

宏体是自足的:只引用自己的参数、`Syntax` 命名空间与内置。编译器在任何宏体运行之前检查宏域(`#macro` def 与应用的编译期参数),展开之后检查整个模块——调用点引用了派生不产出的方法,就在那里失败。

## 跨模块宏

宏模块是普通模块,其 `#macro` def 没有运行期存在:应用通过程序的宏表解析,拼写是限定的,与值引用同一路径形状——一个模块里的 `// @eq_macros.derive_eq` 应用兄弟模块 `eq_macros.emo` 里声明的宏。裸名 `@macro` 只在声明模块内解析,同名的本地宏遮蔽外部宏。编译期参数检查跨模块成立(个数与类型对外部宏的已声明参数),自足规则对一切宏体成立。完整实例在 [`examples/derive_shared`](../../examples/derive_shared/main.emo):一次编写,另一个模块里的两个类应用。

## 宏不是什么

运行期代码生成——`eval`、开放类、`method_missing`——被拒绝作为语言机制:检查时刻不存在的生成代码无法被检查,每个运行时背一个解释器会拖垮 freestanding target,运行期结构会废掉类型反馈的性能故事。Emo 的运行期扩展单元已经存在:def 是一等值(`Block`),分发表是 `Map`,操作系统级扩展单元是进程。宏补上的是编译期那一半——派生、编译期检查的 DSL,以及按签名手写 wrapper 的漂移样板。
