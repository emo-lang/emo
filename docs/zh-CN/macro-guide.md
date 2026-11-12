# 宏指南

宏是一个在**编译期**运行的普通 `def`:它接收被装饰声明作为语法树,返回替换的语法树,编译器在检查之前拼接进去——所以宏生成的一切都是真实的、被检查的 Emo 代码,在所有 target 上成立。本指南讲怎么写、怎么用。语言级规则在[宏](intro/macros.md);设计记录与被否决的备选在 [`design/macros.md`](../design/macros.md)。

## 两个指令

指令是首 token 为 `#` 或 `@` 的 `//` 行——保留名空间,像其他语法一样检查,各自独占一行、紧贴其下的声明:

```emo
// #macro
def trace(f Syntax) Syntax {
  ...   // 编译期运行
}

// @trace
def double(n Int64) Int64 {
  return n * 2
}
```

- **`// #macro`** 声明其下的 def 是宏。签名必须是标量参数后接恰好一个 `Syntax` 参数并返回 `Syntax`——`Syntax` 参数就是被装饰声明的树。
- **`// @name`** 应用宏。展开后,被装饰声明被宏的返回物替换,宏 def 自身被**抹除**——没有运行期存在。
- 未知的 `#name` 或 `@name` 是编译错误,所以 `// #macor` 这样的错拼永远不可能静默变成注释。
- 指令可叠加:同一声明上方多行,离声明最近的先生效。
- `@name` 带点分路径(`// @eq_macros.derive_eq`)应用兄弟模块的宏;裸名是本地的,同名的本地宏遮蔽外部宏。

展开后模块读起来就像手写代码——自己看:

```
emo dump main.emo          # 展开后的表面,target 编译的东西
emo dump main.emo --raw    # 文件按解析所见——指令、宏 def 都在
```

## 第一个宏,逐行读

完整实例在 [`examples/trace_macro_demo`](../examples/trace_macro_demo/main.emo)——下面的宏包装 def,让每次调用记录参数与应答:

```emo
// #macro
def trace(f Syntax) Syntax {
  const name = Syntax.name(f)               // "double"
  const params = Syntax.params(f)           // 参数树
  const ret = Syntax.result(f)              // 结果类型树
  const hidden_name = Syntax.gensym(name)   // 新的、不相撞的名字
  const original = Syntax.rename(f, hidden_name)
  const wrapper = Syntax.new_def(name, params, ret, [
      Syntax.call_stmt("println", [
        Syntax.interp([
          Syntax.lit_string("trace: " + name + "("),
          Syntax.ident(Syntax.param_name(params[0])),
          Syntax.lit_string(")")
        ])
      ]),
      Syntax.const_stmt("r",
        Syntax.call(Syntax.ident(hidden_name), [Syntax.ident(Syntax.param_name(params[0]))])),
      Syntax.return_stmt(Syntax.ident("r"))
    ])
  return Syntax.seq(original, wrapper)
}
```

读法:原 def 挪到隐藏名(`double__1`),可见名变成记录、用**被装饰声明自己的参数树**转发、返回的 wrapper。转发调用与签名来自同一批树——它不可能与签名漂移,这正是此机制要消除的那类错误。

## `Syntax` API

读取器拆开声明;构造器造树。宏应用必须产出声明(一个 def/class,或一列展平的)——单独的表达式碎片是错误。

| 读取器 | 应答 |
| --- | --- |
| `Syntax.name(f)` | def 或 class 的名字 |
| `Syntax.params(f)` | def 的参数树 |
| `Syntax.param_name(p)` | 参数名 |
| `Syntax.result(f)` | def 的结果类型树 |
| `Syntax.fields(f)` | class 的字段树(名字;无类型——见限制) |
| `Syntax.field_name(fd)` | 字段名 |

| 构造器 | 造出 |
| --- | --- |
| `Syntax.rename(f, new_name)` | 改名的 def |
| `Syntax.new_def(name, params, result, body)` | 一个 def;`body` 是语句树数组或整个 `quote` |
| `Syntax.seq(a, b)` | 序列(嵌套展平) |
| `Syntax.with_methods(class, methods)` | 把 def 树追加为方法的类 |
| `Syntax.ident(s)` / `Syntax.self_expr()` | 名字 / `self` |
| `Syntax.lit_string(s)` / `lit_int(n)` / `lit_bool(b)` / `lit_float(f)` | 字面量表达式 |
| `Syntax.interp(parts)` | 从文本与表达式树拼 `"a${x}b"` |
| `Syntax.call(f, args)` / `Syntax.call_stmt(f, args)` | 调用表达式 / 语句 |
| `Syntax.member(e, name)` | `e.name` |
| `Syntax.bin_eq(l, r)` / `Syntax.bin_and(l, r)` | `l == r` / `l && r` |
| `Syntax.empty_map()` | `{}`——生成状态的常量 |
| `Syntax.const_item(name, e)` | 模块级 `const` |
| `Syntax.new_param(name, type_tree)` | 参数 |
| `Syntax.named_type(s)` | 具名类型树(`Bool`、类自己的名……) |
| `Syntax.gensym(base)` | 新的、不相撞的名字 |

## quote 表面

`Syntax.new_def` 的语句列表够造 wrapper,但把体按**代码**铺开更好读。`quote { ... }` 把花括号按普通 Emo 解析(真 span、真错误),每个 `${expr}` 洞拼接一个在宏体内求值的表达式树:

```emo
const wrapper = Syntax.new_def(name, params, ret, quote {
  if ${cache}.has(${arg}) {
    return ${cache}.get(${arg})
  }
  const r = ${Syntax.ident(hidden_name)}(${arg})
  ${cache}.set(${arg}, r)
  return r
})
```

洞拼接**表达式树**——提升保持显式:名字用 `${Syntax.ident(name)}`,字面量用 `${Syntax.lit_int(limit)}`。模板内的声明结构是字面的(def 的名字、参数、结果归构造器管),带引号字符串里的插值保持为生成代码自己的。

## 应用参数

宏的前导标量参数(`Int64`、`String`、`Bool`、`Float64`、`Byte`、`Char`)由应用处供给,编译期求值,在应用点静态检查——个数与类型:

```emo
// #macro
def memoize(limit Int64, f Syntax) Syntax {
  ...   // 这里 `limit` 是 Int64,像任何编译期值一样用
}

// @memoize(2)
def slow_double(n Int64) Int64 {
  return n * 2
}
```

宏无法包装给到的形状——`Void` 结果、配方需要单参却来了多参——用 raise 拒绝:

```emo
if Syntax.params(f).length() > 1 {
  raise Exception.new("memoize wraps a single-parameter def")
}
```

raise 以展开期编译错误浮出,携带消息。

## 类派生

应用的座位也收类:`// @derive_eq` 写在 `class` 上方,把类树交给宏;宏读字段列表,用 `Syntax.with_methods` 追加生成的方法——它们像手写的一样住在类里,随模块检查。完整实例在 [`examples/derive_eq_macro_demo`](../examples/derive_eq_macro_demo/main.emo):

```emo
// #macro
def derive_eq(f Syntax) Syntax {
  const name = Syntax.name(f)
  const fields = Syntax.fields(f)
  const po = Syntax.new_param("other", Syntax.named_type(name))
  var acc = Syntax.lit_bool(true)
  var have = false
  var i = 0
  while i < fields.length() {
    const fname = Syntax.field_name(fields[i])
    const cmp = Syntax.bin_eq(
        Syntax.member(Syntax.self_expr(), fname),
        Syntax.member(Syntax.ident("other"), fname))
    acc = if have { Syntax.bin_and(acc, cmp) } else { cmp }
    have = true
    i = i + 1
  }
  const eq = Syntax.new_def("eq?", [po], Syntax.named_type("Bool"), [
      Syntax.return_stmt(acc)
    ])
  return Syntax.with_methods(f, [eq])
}

// @derive_eq
class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }
}
```

生成的判等不可能遗漏类声明的任何字段——这正是此机制消除的漂移。

## 跨模块共享宏

宏模块是普通模块,其 `#macro` def 没有运行期存在。从另一个模块用限定拼写应用,与值引用同一路径形状:

```emo
// @eq_macros.derive_eq
class Point { ... }
```

完整实例在 [`examples/derive_shared_macro_demo`](../examples/derive_shared_macro_demo/main.emo)——`eq_macros.emo` 里一次派生,`main.emo` 里两个类应用。

## 规则与限制

- **宏体自足**:只引用自己的参数、`Syntax` 命名空间与内置。helper 要么自身 `// #macro`(随之抹除),要么把逻辑内联。
- **按构造确定**:编译期 profile 拒绝一切 effect 与一切触及宿主的内置(`rand_bytes`、`os_*` 族)与打印。步数预算约束运行。
- **拼接被检查**:生成代码像手写代码一样让构建失败——转发个数错的 wrapper 死于普通检查器错误。
- **被装饰 def 的递归指向最终的、装饰后的绑定**——生成的 wrapper 才是存在的东西,体看到的就是它(刻意区别于 Python)。
- **声明结构归构造器**:洞拼接表达式树;def 的名字、参数、结果用 API 构造。字段树带名不带类型,所以类型感知派生(JSON)等那个缺口。
- **包边界**:宏在包树内解析;require 库宏是有名后续。

## 错误码

| 码 | 含义 |
| --- | --- |
| E2029–E2035 | 指令放置与形状(未知角色、浮空、体内、重复、形错) |
| E3030 | 宏体内的 effect 或宿主内置 |
| E4300 | 未知宏,或 `@` 用在非宏上 |
| E4301 | `Syntax` / `quote` 越出编译期窗口 |
| E4302 | 宏签名不是标量 + `Syntax` → `Syntax` |
| E4303 | 拼接不是声明 / 体不是语句 |
| E4304 | 宏永不返回树(或返回非树) |
| E4306 / E4307 | 应用个数 / 实参类型 |
| E4308 | 宏 raise——带消息的拒绝 |
| E4309 | quote 洞不是表达式树 |
| E4310 | `@` 应用到宏 def |

## 四个可跑试点

[`examples/trace_macro_demo`](../examples/trace_macro_demo/main.emo)——最小包装。[`examples/memoize_macro_demo`](../examples/memoize_macro_demo/main.emo)——应用参数、生成运行期状态(私有 `Map`)、quote 铺开的 wrapper。[`examples/derive_eq_macro_demo`](../examples/derive_eq_macro_demo/main.emo)——类派生。[`examples/derive_shared_macro_demo`](../examples/derive_shared_macro_demo/main.emo)——同一派生从兄弟模块应用。每个都在解释器与编译 target 上逐字节一致。
