# EmoUI probe:语言给声明式树的东西

四个小程序,支撑 [`docs/emo-ui.md`](../../docs/zh-CN/emo-ui.md) 里的发现。它们是语言探测,不是 UI——每个回答一个「树今天能写成什么样」的问题。

在本目录下,用仓库的编译器跑:

```sh
../../_build/default/src/emo_cli/emo.exe run probe1_block_children.emo
# 或者用已安装的二进制:
emo run probe1_block_children.emo
```

- `probe1_block_children.emo` —— 返回数组的尾随 block 交付子节点;一串子节点调用语句的 block 交付 `void`,子节点被丢弃。README 那份示意树按原样不可执行。
- `probe2_recursive_node.emo` —— 类在自身 `init` 里指称自己(`children Array[Node]`)能通过检查,接口在签名里指称自己也能通过检查。spike 当年的 E4005 变通不再是被迫的。
- `probe3_iteration_and_messages.emo` —— `return` 每个元素节点的迭代 block 能用;枚举作为事件身份挂在节点上。收集器带一个累加器,因为 `Array.append` 追加的是一个元素而不是一个数组:`[head].append(each_from(...))` 会构造出嵌套数组,而且照样通过类型检查。那个惯用法的代价由 `spike/emo-ui-spelling` 测量。
- `no-defaults/probe4_no_default_params.emo` —— `def hello(name String, count Int64)` 的 `hello("a")` 是 E4009。样式故事必须用工厂加 `with_*` 复制。它位于一个嵌套包里(自带 `package.emo`),所以其他 probe 的 `emo run` 不会编译到它。
- `first_class_def/probe5_first_class_defs.emo` —— 裸 def(`inc`)与模块限定的 def(`lib.inc`)都是值,能满足 `Block` 参数并可调用。每平台入口可以直接把 `app.view` / `app.update` 传进去。同因,自带嵌套包。

## 预期输出

```console
$ emo run probe1_block_children.emo
card got: [#VNode(kind: "text:a"), #VNode(kind: "text:b")]
card
card got: void
card

$ emo run probe2_recursive_node.emo
column
2
hi

$ emo run probe3_iteration_and_messages.emo
2
user: ada
user: grace
increment

$ (cd first_class_def && emo run probe5_first_class_defs.emo)
2
11
```

`probe4` 是负面检查:`cd no-defaults && emo check
probe4_no_default_params.emo` 报 E4009。
