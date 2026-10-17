# `sqlite3` 包

标准库的数据库接口:对 SQLite 预备语句(prepared statement)API
的直接风格绑定。它是标准库第一个原生绑定包——调用经
`foreign def` 落到包目录里自带的一个小型 C shim,系统 sqlite3 库
由清单的 `link` 字段声明。构建会自行编译 shim 并链接该库:消费方
只需 `require`,不需要 `--cclib`,除了平台自带的 sqlite3 之外也
无需安装任何东西。

包声明 `targets = ["c"]`——它的调用是外部代码,解释器会以
E3009 拒绝,其他目标则在解析或构建期拒绝。`emo run` 无法执行用到
它的程序;请用 `emo build` 构建(默认目标即 `c`)。

## 使用

```emo
require "sqlite3"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "sqlite3"` 需要在 manifest 的 `deps` 块里钉上 `"sqlite3" = "0.1.0"`。本包只声明 `c` 目标——它带有原生代码,只有 `c` 目标能构建它。

## 错误

沿用标准库的约定:每个会失败的调用都抛出普通的 Emo 异常,消息指
出操作并携带 SQLite 自己的错误文本——
`sqlite3: prepare: no such table: notes`——没有错误码,没有
nil。唯一不抛异常的边界是 `step()`:行读到尽头是值
(`false`),不是失败。语句的执行错误在 `step()` 处浮现;`reset()`
只把语句清回起点以便复用,不会重复抛出 `step()` 已经抛出过的错误
(raise 会终止进程);`finalize()` 是语句的最后一次机会,残留错误
在此抛出而非被丢弃。

## 连接

```emo
def open(path String) Database
```

`open` 打开 `path` 处的数据库——`":memory:"` 是临时的内存数据
库——打不开时抛出异常。用完调用 `close()`。

```emo
class Database {
  def exec(sql String) Void
  def prepare(sql String) Statement
  def last_insert_rowid() Int64
  def changes() Int64
  def close() Void
}
```

`exec` 运行一条或多条分号分隔、不返回行的语句——DDL 和一次性写
入——出错即抛异常。`prepare` 把一条 SQL 文本编译成
`Statement`,语法或模式错误即抛异常。`last_insert_rowid` 是该连
接最近一次插入的 rowid;`changes` 是最近一次 insert/update/delete
触及的行数。`close` 在有未 finalize 的语句占住连接时抛异常。

## 语句

```emo
class Statement {
  def bind_int(i Int64, v Int64) Void
  def bind_float(i Int64, v Float64) Void
  def bind_text(i Int64, v String) Void
  def bind_null(i Int64) Void
  def step() Bool
  def reset() Void
  def finalize() Void
  def column_count() Int64
  def column_name(i Int64) String
  def column_int(i Int64) Int64
  def column_float(i Int64) Float64
  def column_text(i Int64) String
  def column_is_null(i Int64) Bool
}
```

工作循环:绑定参数,`step()` 逐行推进,有当前行时读取列,
`reset()` 回到开头再跑一遍,用完 `finalize()`。

**绑定下标从 1 起**——它们命名 SQL 文本里的 `?NNN` 参数——**列
下标从 0 起**,这是 SQLite 的约定。`step()` 在有当前行时回答
`true`,行尽时回答 `false`;其余结果一律抛异常。列读取遵循
SQLite 的类型转换规则;NULL 列按访问器读出为 `0`、`0.0` 或
`""`,用 `column_is_null` 区分 NULL 与真实的零值或空串。

## 边界与限制

字符串过 C 边界时以 NUL 结尾:含内嵌 NUL 的 String 会在边界处截
断,两个方向皆然。blob 暂不支持,要等 `Bytes` 能过 FFI——绑定
blob 会在检查期被拒绝,与所有不受支持的外部类型一样。

## 示例

```emo
require "sqlite3"

const db = sqlite3.open(":memory:")
db.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")

const insert = db.prepare("INSERT INTO notes (title) VALUES (?1)")
insert.bind_text(1, "first")
insert.step()
insert.finalize()

const query = db.prepare("SELECT id, title FROM notes")
while query.step() {
  println("row ${query.column_int(0)}: ${query.column_text(1)}")
}
query.finalize()
db.close()
```

完整示例——各种类型的参数绑定、带 NULL 处理的步进读取、变更行
数——见 `examples/sqlite3_demo`。
