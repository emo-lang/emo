# 模块与可见性

Emo 的模块系统完全是结构化的：没有 `import`、没有 `export`、没有可见性关键字、也没有承载可见性的命名约定。**目录树即模块树：**

```
shop/
  order.emo           # 模块 shop.order
  pricing.emo         # 模块 shop.pricing
  internal/
    discounts.emo     # 模块 shop.internal.discounts —— 子树私有
  checkout.emo        # 模块 shop.checkout
```

- **树的根在 manifest 处，而 manifest 就在你站的地方。** 工作目录就是项目根，必须放着 `package.emo`；它之上的目录永不查找（E5010），不在该包树内的入口也会被拒绝（E5011）。所以上面那棵树是从 `shop/` 读的，而 `emo run order.emo` 在别处跑并不等价——它要么在那里不属于包内任何模块，要么因缺少 manifest 而停下。
- **路径即模块。** 文件自动成为其路径上的模块——无需注册、无需声明。
- **引用即限定路径。** 什么都不导入；路径直接使用，如同 URL。路径太长时，普通 `const` 绑定为其起别名——没有新语法，因为 import 语句本来就只是别名赋值：

  ```emo
  const order = shop.order

  def checkout(cart Cart) Decimal {
    const total = order.total(cart)
    return total
  }
  ```

- **可见性是结构化的。** 函数与块内的定义因作用域私有；模块级定义是公开的（可按限定路径寻址）；`internal/` 目录是子树私有的，由编译器强制——`shop/internal/` 之下的 everything 可在 `shop` 及其后代内使用，在其他任何地方都是编译错误。
- **类型名与值一样，是模块路径限定的。** 类型引用就是一条路径：其他模块里的 `ui.VNode` 指向 `ui.emo` 的 `VNode`，裸名 `Order` 指本模块自己的类型，包内的相对写法与值一致（包内的 `internal.svg.Renderer`）。`is()` 能跨边界收窄，构造遵循同一条规则——`sync.WaitGroup.new(2)`、`ui.Point.new(...)`——声明类型所在的模块在首次使用时加载。因此两个模块可以有同名类型：它们是两个不同的类型，各自以模块寻址。隐私规则对类型与值同样生效：`internal/` 下声明的类型只在其子树内解析。
- **依赖图是显式的。** 路径引用就是依赖声明，带来自动模块发现、增量编译与编译期循环检测。
