# EmoUI 组合方式 —— 一棵树怎么写出来

写于 2026-10-15。这是一份讨论记录,不是已定设计。组合方式这个决定本身是已定的、没有改动:**children 是一个显式的 `Array[Node]`**([`emo-ui.md`](emo-ui.md) 决策 3 —— [`visualization.md`](visualization.md) 决策 14 为 plot 选了同一个形状)。本文档记录的是这个决定底下的论证:一棵组件树有哪些写法,哪些机制是开着的、哪些是关着的,以及唯一真正还没定的那个问题。

写它是因为这个问题会反复回来,而且有两种问法 —— *组件是不是该往上下文里发射、而不是返回值?* 以及 *EmoUI 是不是需要一门模板语言?* —— 两者的答案都不是从决定本身能倒推出来的。

**更新(2026-10-18,T48.13)。** README 现在公布的是已定的数组子节点写法;下面引用的那棵树保留为本文档写作时所要考察的形式。组合方式的决定与「已关掉机制」的清单一字未改;唯一开放的问题——数组写法是否该再长出字面量拼法——仍然开放。

## 问题

[`README.md`](../../README.md) 曾把这段当作 EmoUI 的示意语法公布出来(后来已修订;此处保留为论证的起点):

```emo
page(title: "Home") {
  navbar() {
    logo()
    menu(routes)
  }

  list(users) -> (user User) {
    card(user) {
      text(user.name)
      text(user.bio)
    }
  }
}
```

[`emo-ui.md`](emo-ui.md) 对它的判语是:**照写是跑不通的。** 理由很窄,而且值得说准 —— 本文档里几乎每一段论证都是它的推论。`text(user.name)` 作为语句是一条被丢弃的表达式:它产出一个 `Node`,而这个值到不了任何地方。块是 `Void`,值被丢掉,外层组件收不到任何 children。

所以问题不是"块是怎么工作的",而是再往里一步:**当块里的语句丢弃了自己的值时,一个叶子怎么知道它属于哪个容器?**

## 块今天能给出什么

五条语言事实,全部现行:

- **附着的块就是调用的最后一个实参。** `page(title: "Home") { ... }` 传一个零参块,`list(users) -> (user User) { ... }` 传一个带参块([syntax.md](intro/syntax.md))。语言里没有另一个"块槽位"—— callee 是按声明的形参接它的。
- **接收块的形参声明为 `Block`**([type-system.md](intro/type-system.md)),而 `Block` 是 `Unknown`。块实参的块体不会被拿去检查。
- **被丢弃的表达式语句合法且安静。** checker 对它的全部规则就是 `ignore (check_expr ctx env e)`(`src/emo_check/emo_check.ml:2541`)。这正是 README 那棵树能通过类型检查、却什么也交付不了的原因。
- **`Void` 块体完全不写 `return`** —— "it takes no `return` at all, its body simply ends" —— 而有声明返回类型的块体每条路径都必须 `return`;没有"最后一条表达式即返回值"这回事([syntax.md](intro/syntax.md))。
- **控制流是语句形态的。** `if` 和 `case` 是语句,只有一处例外:一行的 `if` 表达式能取一个值,但它必须整体留在一行内、每个分支恰好一条表达式([syntax.md](intro/syntax.md))。`for` 与 `while` 是语句([syntax.md](intro/syntax.md)),而且已经在所有目标上落地(T26、T27)。

最后一条影响的是**写法**而不是机制:它意味着有条件或有迭代的 children 必须先绑定进一个变量、才能出现在 children 数组里,或者用那个一行 `if` 表达。

## 三难

一个块如果丢弃了自己语句的值,想让它有用,就只能由某个东西告诉每个被丢弃的值去哪儿。供给这个东西的方式恰好只有三种,没有第四种:

1. **环境式收集器。** 某个"当前容器"随处可达 —— 动态作用域、进程级的汇聚点。叶子不必被告知就能往里追加。
2. **编译器隐式穿线的参数。** callee 的签名被编译器塞进一个隐藏的上下文参数;叶子往它发射。
3. **显式的收集器参数。** 块声明它,组件传它,调用点把它写出来。

## 前两种为什么是关着的

**环境式收集器直接违反可变性规则。** [syntax.md](intro/syntax.md) 把可变表面定为一个封闭的集合 —— `var`、`Box`、`Bytes`、`List`、`Map`、`ArrayBuilder` —— "nothing else mutates in place" 之外什么也不许。一个进程全局且隐式的收集器,会是这门语言里最大的一次违例:这六个具名类型无一不是由显式调用构造、并经由代码自己写下的名字去修改,而环境式收集器没人去取、谁都能往里写。它也和并发模型正面相撞:嵌套容器需要一个收集器栈,而 `send` 交付的是快照,收集器没法跟着它正在填的那棵树跨进程边界。[`emo-ui.md`](emo-ui.md) 已经否掉过这个形状("implicit state, against the design philosophy")。

把 `ArrayBuilder` 加进这个集合并不重新打开这个问题:这条规则关掉的是**不可命名**的可变,不是类型的数量。builder 由 `ArrayBuilder.new()` 造出、绑到作者自己选的名字上、再经由那个名字追加 —— 它的可见程度与旁边的 `List` 别无二致,而上面的反对针对的是可见性,不是「能有几个类型可变」。

**隐式参数要付的是"第二种调用约定"。** [syntax.md](intro/syntax.md) 写着的正是它要破的那条规则:"Parameter types are always explicit"。一个签名为 `def text(s String) Void` 的组件会发射 —— 而读者既看不出它会发射,也看不出发射到哪里。它同时也是 EmoUI 桌面上最大的一笔语言改动,比 [`emo-ui.md`](emo-ui.md) 已估价为 "a language change of real size" 的 checked block/function type 还大:闭包表示、`Block` 类型、checker、以及六个后端全都要带上这个额外参数,`Block` 还要多出一种携带它的形态。Compose 付的正是这笔钱 —— Kotlin 编译器插件给每个 `@Composable` 函数加上 `$composer` 参数和 changed-flags 位掩码 —— 而且值得说清楚,这笔钱在那边买到了东西:槽表里的位置记忆化,也就是 Compose 细粒度重组的根基。EmoUI 选了相反的机制(见下面"发射不改变数据模型"),所以它会付这笔钱却拿不到这个收益。

## 先例

"Compose、SwiftUI、Flutter 都是靠发射来组合的"这个说法站不住。三个里面有两个在返回值那一极:

| | 组件怎么组合 | 在哪一极 |
|---|---|---|
| **Compose** | `@Composable` 函数返回 `Unit`,发射进 composition;编译器注入 `$composer` | 发射 |
| **SwiftUI** | `var body: some View` 返回一个值;`@ViewBuilder` 的 `buildBlock` 把每条语句的值收进 `TupleView` | 返回 |
| **Flutter** | `Widget build(BuildContext context)` 返回 `Widget`;children 是显式的 `children: [...]` 列表 | 返回 |
| **React / JSX** | `createElement` 返回元素树;JSX 脱糖成这些调用 | 返回 |
| **Elm** | `view : Model -> Html msg` 返回一棵树 | 返回 |

两条值得记住的更正:

- **SwiftUI 不是发射 —— 它是被否掉的那个机制换了个不写 `return` 的拼法。** result builder 收的是块里各语句的**值**。这正是 [`emo-ui.md`](emo-ui.md) 作为 ask 2 和方案 4 否掉的"隐式 child 收集"。它产出的树是一个不可变值,由 SwiftUI 去 diff —— 和 EmoUI 的 `patch` 同一极。
- **Flutter 就是数组式。** `BuildContext` 不是收集器,它是 inherited widget 的查询入口(主题、media query),之所以显式传,是因为 Dart 没有环境上下文。Flutter 的 element 树确实会往父节点注册 element,但那在框架的重建过程内部,应用代码看不见。

所以发射阵营真实存在,但被点名的三门语言里只有一门在里头 —— 而每一门"组件不是靠返回值来组合"的语言都为这种风格付了代价:Compose 付给编译器插件,Kotlin 的 type-safe builder 付给 receiver lambda,Ruby 的 DSL(Sinatra、`Rack::Builder`、`Builder::XmlMarkup`、Shoes)付给 `instance_eval`。

最后这一组值得单独拎出来,因为它才是让 Ruby 那种树真正跑起来的机制。**`yield` 不是它**:`yield` 是 callee 调用 caller 的块的方式,而 Emo 已经有了 —— syntax.md 把块定为最后一个实参,组件按声明的名字调用它。Ruby 的 DSL 能工作,是因为块被 `instance_eval` 到**容器对象上**,于是裸写的 `navbar` 解析成那个容器的方法。那是 self 重绑定,也正是 Emo 最付不起的一种:它让块里每个裸标识符的含义随块被传到哪里而改变 —— 那正是"读者看不见的结构"的定义。

## 发射不改变数据模型

后端接缝消费的是一个 `Node` **值**:

```emo
interface Backend {
  def mount(root Node) Void
  def patch(old Node, new Node) Void
  def run() Void
}
```

([`emo-ui.md`](emo-ui.md) Layer 6;带 key 的 reconciliation 在那里被记为 growth edge。)所以发射器无论如何都得在内部把树物化成值 —— 发射改变的是"谁来建这个数组"和"调用点怎么断句",不是程序算出了什么。

这就是全部的交换。代价一侧:发射形状的树完全没有类型检查,因为它的块体是 `Block`,而 `Block` 是 `Unknown`([`type-system.md`](intro/type-system.md))。EmoUI 公布的承诺是 props **确实**被检查 —— "props are checked by the built-in type checker (gradual typing)" —— 而数组式 children 是唯一能保住它的拼法。Emo 自己的语法规则在这里把案子结了:"Brevity alone never earns a construct."

## 模板语言有三种形态

"模板语言"不是一件事。三种形态行为不同,而只有一种威胁到类型检查:

- **文本 + 洞,由引擎求值** —— ERB、Handlebars、Vue 单文件组件。表达式由运行时在自己的作用域里求值,宿主的 checker 根本看不到。
- **自带 checker 的模板编译器** —— Angular 的 `strictTemplates` 拿模板表达式去对组件声明的类型检查。
- **翻译成宿主源码** —— Templ → Go、Svelte → JS、JSX → JS。宿主原有的 checker 直接跑在生成物上,静态检查一点没丢。

第一种正是 README 那句 "**no template language — the UI is plain Emo code**" 当初针对的东西,也正是 [`configuration.md`](intro/configuration.md) 面对同样诱惑时定下的东西:"Because the type checker is built in, configuration schemas are just type declarations checked by the same pass — no second schema language needed."

第三种是真选项,而且它**不**劈开 checker。"模板语言会劈开类型检查"这个说法在这一点上说宽了,决定确实可以窄着重开。

## Templ,以及哪些东西转移不过来

Templ 是第三种形态的现成样本:`.templ` 文件由 Templ 自己的 parser 解析,`templ generate` 产出 `.templ.go`,再由 `go build` 去做类型检查。Templ 的"类型安全"**就是** Go 编译器在检查生成的 Go。

Templ 保住的东西比看上去窄。它检查你嵌进去的 Go 表达式,不检查文档本身:`<div>` 塞进 `<tr>` 不报错,而 spread 属性是 `templ.Attributes` —— 一个 `map[string]any` —— Templ 自己的文档就标明了它不受检查。所以能转移过来的是**表达式级**类型,不是结构级类型。

有两件事完全转移不到 Emo:

- **Templ 之所以是一个独立工具,是因为 Go 的语法不能扩展。** Go 在设计上拒绝语法扩展,所以模板必须住在自己的文件里,带着自己的 parser、formatter、LSP、源映射,以及构建里的一个 `generate` 步骤。Emo 的语法能扩展 —— 这正是 README 用 "Emo's syntax is shaped to serve it" 说出来的前提。照抄 Templ 的**形态**,等于把一个为 Emo 并不拥有的约束而发明的绕行方案进口进来,连同它全部的成本。
- **Templ 的生成物不可读** —— 魔数前缀的临时变量、往 buffer 里写、逐句 error 传播 —— 因为它是发射形状的。那才是源映射必需的原因。Emo 的脱糖目标是一条纯表达式:嵌套调用加一个 `Array[Node]` 的 children 实参,没有临时变量、没有 buffer、没有 error 管道。生成的 Emo 是可读的,这意味着脱糖的自然归宿是 Emo 自己的 parser,而不是一个生成器。

而且有一处会比 Templ 更好:脱糖目标是 typed tree constructor 而不是 byte buffer,children 实参货真价实是 `Array[Node]`,所以树的结构和表达式一起被检查。

## 摆在桌上的选项

- **A —— 数组式 children,不加糖。** 已定(决策 3)。零语言改动。动态那一块啰嗦。
- **B —— 数组式 children,外加一个廉价容器。** `List` 是那个原地变的 O(1) 双端队列,`push_back` 返回 list,所以循环可以直接往里填;缺的是 `List -> Array` 的通道([arena-scope](../../spike/arena-scope),"A side finding for EmoUI")。零语法改动,拿走的是让 A 变贵的那些啰嗦:

  ```emo
  def view(users Array[User]) Node {
    const kids = List.new([])
    kids.push_back(navbar(children: [logo(), menu(routes)]))
    for var i = 0; i < users.length(); i = i + 1 {
      kids.push_back(card(
        user: users[i],
        children: [text(users[i].name), text(users[i].bio)]
      ))
    }
    return page(title: "Home", children: children_of(kids))
  }
  ```

  这里写成调用 `children_of(...)` 而不是方法 `kids.to_array()`,是因为语言里不存在这样的转换;在 Emo 里手写它,就等于建在 `append` 之上 —— B 的二次代价于是不是消失,而是搬到了那里。`spike/emo-ui-spelling` 把这些全量过一遍,并发现 `Map.set` 加 `Map.values()` 是唯一完全不产生数组增长的容器通路 —— 所以这个转换该落在运行时里遍历双端队列,而不是落在一个库 def 里。

  **这段读法在 2026-10-15 关掉了(T49.3),而且不是以这里点名的两种形状中的任何一种。** 语言多了第三个容器:`ArrayBuilder` 用 `push` 原地增长、摊还 O(1),`to_array()` 就是那份拷出 —— 于是 B 的成本曲线不再需要给 `List` 补一个转换,而上面那次测量也正是它没有落在双端队列上的原因之一。上面那条已定的选择照旧成立(A:静态那种情形根本不需要容器;children 表示是否要从已定的 `Array[Node]` 挪开,是 T48.1 的事——而可移植核心已在 2026-10-15 定下:保留 `Array[Node]`,列表用 `ArrayBuilder` 攒)。变了的是:B 缺的那块不再缺了。

- **C —— Emo 自己语法里的树字面量。** parser 层脱糖,目标恰好是 A 的那组嵌套调用。checker、`Array[Node]` children、`patch`、六个后端全都不动;代价是一笔真实的语言改动(parser、checker、六个后端、formatter、LSP),并且让 Emo 的语法对标记敏感。
- **D —— 外部翻译器,产出 `.emo`。** Templ 的形态:自己的 parser、自己的文件,产出 Emo,再由现有 checker 检查。**完全不动编译器** —— 这正是它便宜、可原型的原因 —— 而且它可以住在 EmoUI 仓库里,语言仓库一行不改。代价是第二套语法、第二套工具链(formatter、LSP、把错误映射回源文件),以及一个构建步骤。

A 与 B 兼容:B 就是 A 把容器问题回答掉。C 与 D 脱糖到同一个目标,这也是 B 在两条路下都不白做的原因。

翻译器还澄清了一件事:**树字面量是靠脱糖把块问题解掉的。** `navbar() { logo(); menu(routes) }` 在对目标有完全视野的文本变换下变成 `navbar(children: [logo(), menu(routes)])` —— 不是发射。这就是它的吸引力真实存在的原因,也是它不改变上面那个三难的原因:脱糖的结果就是 A。

## 哪些关了,哪些还开着

**关了。** 发射、self 重绑定、环境式收集器 —— 各有各的理由,都在上面。隐式 child 收集作为语言规则继续被否([`emo-ui.md`](emo-ui.md) ask 2):不存在"收集块内表达式语句"的构造。而第一种形态的模板语言 —— 自带走作用域的求值引擎 —— 既违背 README 写下的原则,也违背 configuration 的先例。

**开着。** EmoUI 到底要不要一个树字面量;如果要,是 C(放进 Emo 的语法)还是 D(外部翻译器)。问题的窄形态是:*是 Emo 的语法变得对标记敏感,还是 EmoUI 自带第二套语法?*

**证据缺口。** 两个分支都还没被真实代码检验过。没有人写过一个界面的数组式 EmoUI 并量过它到底多难受;本文档里的示例都是示意的。便宜且可逆的顺序是:做 B,按 A 的拼法写出 T48.1 的可移植核心和一两屏真实界面,再据此决定 C 还是 D —— 那时候这个问题可以用行数回答而不是用论证,而且两个答案都不浪费 B,因为两者脱糖到同一棵树。

**证据,量于 2026-10-15。** `spike/emo-ui-spelling` 写出了 T48.1 内核(可移植,`Array[Node]` children)和上面那两屏的两种拼法,外加一个无头调试后端,好让树真的渲染出来:

- **A 是 95 行,B 是 40 行**,渲染字节一致 —— 同样两屏,每一个子节点列表固定的控件都在两者之间逐字共享,所以差量恰好是动态列表怎么拼装。
- **A 那 95 行里有 44 行是迭代构造器**(`no_nodes`、`concat`、`field_rows`、`action_buttons`、`message_rows`、`each_from`)。它们存在的意义是把一个 `Array[Field]` 变成 `Array[Node]`,而那是数据驱动的变换,不是树的形状。
- **树字面量在这里删掉的是括号,仅此而已**:A 里 72 个括号 token,B 里 18 个,而**两种写法里 `children:` 标签都是 0 个** —— 构造函数按位置接收 children,所以本文档选项 B 样例围绕的那个标签在真实代码里根本不出现。
- 姊妹文档公布的 `each_from` 惯用法(`[f(xs[i])].append(each_from(...))`)**是错的**:`Array.append` 追加的是一个元素,所以它构造出嵌套数组,而它能通过类型检查只因为元素经由 `Block` 而来。没有任何东西会报告它;两屏渲染结果不同,只有一条子节点计数断言会注意到。修正后的收集器带一个累加器。
- **B 的渐近收益目前并不存在。** `List` 填充是 O(1),但手写的 `List -> Array` 转换是在 `append` 上打转的循环,所以它的拷贝次数与朴素累加器**完全相同**(k=32 时 4480 个单元)。反过来,`Map.set` 加 `Map.values()` 在整条阶梯上都是 **0** 次数组追加、**0** 次拷贝 —— 线性通路在运行时里已经存在,所以这个转换该是遍历双端队列的运行时原语。

这些决定了什么:**B 是付得起的那一步,而且它是容器问题而不是语法问题。** C 的要价 —— parser、checker、六个后端、formatter、LSP、一套对标记敏感的语法 —— 买到的是括号,而那 44 行构造器一动不动,因为一个「脱糖成恰好是 A 的那串嵌套调用」的字面量会原样继承它们。只有当字面量也长出一个循环形态时 C 才对得起它的价钱,而那时被定价的东西已经不再是树字面量了。D 能做得比本文档设想的更好,理由正是本文档给 D 的理由:一次知道目标的文本变换可以把字面量*内部*的循环直接下降成 B 的容器形态,不碰语言就同时删掉括号和那些构造器。

所以:**做 B;然后如果工效学仍然难受就做 D;只有当 D 的第二套工具链比一套对标记敏感的语法更贵时才做 C。** 两个屏幕上的一次实验只支撑得起这么大的一个 claim,不多。那边那张目标矩阵也不是无关紧要的 —— 五个宿主目标里,今天只有 `typescript` 能编译这个内核。

**更新,2026-10-18:D 已经存在。** `projects/emo-ui/translator/` 把 `.emoui` 树文件降级成已定案的拼法 —— 一个 stdin 到 stdout 的过滤器,四个模块共 1,239 行 Emo,零编译器改动。配套的 demo(`translator/demo/`)把本文的两个屏幕用字面量形式写了一遍,并把它钉在旁边的 A 拼法上:`show.emo` 在四个模型(基线、空收件箱、显示横幅)上经 `debug.render` 断言两棵树相等,`check.sh` 重新生成已提交的产物并 diff,`expected_show.txt` 把渲染钉死。字面量文件 52 行,对 A 参照的 65 行 —— 差的那部分正是三个逐元素类型的 def 和那些 builder 语句,如今由翻译器代写;样本没有变大,claim 也不变大。这个原型关于 D 的形状所确定下来的事:翻译器本身保持便宜,因为叶子表达式是不透明的区段,它根本不去解析 Emo —— 第二套工具链的成本在别处:`.emoui` 的编辑器支持和 span 级精确的错误映射,两者都还没做。本文关死的机制依旧关死:降级发射进的是有名有姓的 builder,从来不是某个上下文。

## 参考

- [`emo-ui.md`](emo-ui.md) —— 评估;Layer 1 是组合方式的讨论,决策 3 是已定的拼法,ask 2 是隐式收集的禁令。
- [`visualization.md`](visualization.md) —— 决策 14,plot 选了同一个形状。
- [`intro/syntax.md`](intro/syntax.md) —— 附着的块、参数类型必须显式、`return` 纪律、语句形态、可变的六件。
- [`intro/type-system.md`](intro/type-system.md) —— `Block` 是 `Unknown`。
- [`intro/configuration.md`](intro/configuration.md) —— 配置即 Emo 表达式,"不要第二门语言"的先例。
- [`emo-ui-check.md`](emo-ui-check.md) —— 那几个 spike;`spike/components` 就是那个已经 byte-identically 跑通 AppKit 与 GTK 4 的 React/Elm 式应用。
- `spike/arena-scope` —— children 数组为什么想要另一个容器。那个容器现在有了:`ArrayBuilder` 回答了这条 ask,所以组合示例不必再用 `Array.append` 累加(它"追加一个元素即整数组拷贝"在 `src/emo_eval/emo_eval.ml:2147`);与它权衡过的"丢弃语句"那条事实在 `src/emo_check/emo_check.ml:2639`。
- `spike/emo-ui-spelling` —— 上面那个证据缺口所要的测量:两种拼法各写一遍的 T48.1 内核与两个真实屏幕、子节点数组构造阶梯、内核撞上的两个 `src/` codegen 缺陷(已于 2026-10-15 修掉,并入 T48.1;它们的夹具就是回归),以及 checker 对错误子节点字面量的覆盖。
