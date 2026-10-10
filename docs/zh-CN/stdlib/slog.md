# `slog` 包

标准库的结构化日志器:每条记录一行,logfmt 或 JSON 两种格式,按最
低级别过滤。纯 Emo 写在共享运行时之上,所以包所声明的每个目标都
回答相同的字节。

日志器是一个不透明句柄——`slog.new` 产出它,`slog.child` 派生一个
改名的副本——句柄本身就携带名字、最低级别和格式。日志器是普通的
值:幕后没有可配置的东西,没有需要清理的东西,包里没有任何全局状
态。

## 使用包

```emo
require "slog"
```

`require` 与清单严格配对:`slog` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript"]

  deps {
    slog = "0.1.0"
  }
}
```

声明的目标就是今天可用的目标:wasm 和 beam 运行时尚未实现 `Map`,
而 attrs 是一个 `Map`。它们落地之日,清单随之加宽。

## 接口

```emo
def level_debug() Int64
def level_info() Int64
def level_warn() Int64
def level_error() Int64

def format_logfmt() Int64
def format_json() Int64

def new(name String, min Int64, format Int64) String
def child(handle String, name String) String
def enabled(handle String, level Int64) Bool

def debug(handle String, msg String, attrs Map[String, String])
def info(handle String, msg String, attrs Map[String, String])
def warn(handle String, msg String, attrs Map[String, String])
def error(handle String, msg String, attrs Map[String, String])
```

级别有序,`debug < info < warn < error`:低于日志器最低级别的记录
什么都不打印;`enabled` 在调用者构建记录之前回答同一个问题。子日
志器把名字嵌在父名之下(`web` + `db` 得到 `web.db`),并继承级别与
格式。

## 记录

记录写到 stdout,每条一次 `println`,不带时间戳:Emo 没有时钟,
确定性的输出比调用者不得不伪造的戳记更值钱。手上有时间的调用者,
把它当作普通属性传进来即可。

logfmt 格式:

```emo
level=info logger=web msg=listening addr=127.0.0.1:8080
level=warn logger=web msg="slow query" ms=412 table=users
```

json 格式把同一条记录渲染成一行一个对象:

```emo
{"level":"info","logger":"worker","msg":"job done","job":"resize","ms":"38"}
```

两种格式都先输出 `level`、`logger`、`msg`,再按 map 顺序输出
attrs。值的每个字节都能裸存活于行内时(无空格、控制字节、`"`、
`=`、`\`)裸着输出,否则带转义加引号;UTF-8 文本原样通过。json 格
式按 RFC 8259 转义。

attrs 是 `Map[String, String]`:数字和布尔先用插值渲染再传入
("${port}")。

## 严格性

每次调用都先验证句柄和键,再过滤——坏键就是错误,哪怕这条记录本
来也不会打印。属性键只允许 ASCII 字母、数字、`_`、`.`、`-`,一个
键在两种格式里读起来才一致。每个拒绝都抛出普通的 Emo 异常,说清
失败的到底是什么;过滤是唯一的沉默。

## 错误

- `slog: logger name must not be empty` —— `new` 或 `child` 传入
  空名字;
- `slog: unknown level 7` / `slog: unknown format 5` —— `new` 或
  `enabled` 处越界;
- `slog: not a logger handle: web` —— 该传句柄的地方传了普通名
  字;
- `slog: malformed logger handle: slog:x:9` —— 句柄损坏;
- `slog: invalid attribute key "has space"` —— 键只允许 ASCII 字
  母、数字、`_`、`.`、`-`。

## 金测

金测(`examples/slog_demo`)覆盖两种格式、级别过滤、子日志器、引
号与转义(引号、`=`、空值、UTF-8)以及 `enabled`——解释器、
ocaml、c、typescript 四路逐字节一致。
