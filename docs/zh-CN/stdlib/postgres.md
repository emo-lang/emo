# `postgres` 包

标准库的 PostgreSQL 客户端:对 libpq——PostgreSQL 自家 C 客户端
库——的直接风格绑定。调用经 `foreign def` 落到包目录里自带的
一个小型 C shim,libpq 由清单的 `pkg_config` 字段解析——
pkg-config 同时供给 shim 的头文件路径和链接用的 `-lpq`。消费方
只需 `require`,不需要 `--cclib`,除了平台自带的 libpq 之外也
无需安装任何东西(Debian 系是 `libpq-dev`;Homebrew 是 `libpq`,
或 `postgresql@18` 加上其 pkgconfig 目录进 `PKG_CONFIG_PATH`)。
它面向 PostgreSQL 18 的 libpq 构建,能对线协议可达的任何服务端
说话——18.6 只是它构建时所针对的版本。

包声明 `targets = ["c"]`——它的调用是外部代码,解释器会以
E3009 拒绝,其他目标则在解析或构建期拒绝。`emo run` 无法执行用到
它的程序;请用 `emo build` 构建(默认目标即 `c`)。

## 使用

```emo
require "postgres"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:
`require "postgres"` 需要在 manifest 的 `deps` 块里钉上
`"postgres" = "0.1.0"`。本包只声明 `c` 目标——它带有原生代码,
只有 `c` 目标能构建它。

## 错误

沿用标准库的约定:预期失败是值。`connect`、`exec`、`query` 以
`(R.ok, ...)` 或 `(R.error, reason)` 作答,reason 是以
`postgres: ` 开头的 `String`,携带服务端自己的单行消息,失败的
语句还带上 SQLSTATE:

```emo
postgres: query: relation "no_such_table" does not exist (sqlstate 42P01)
postgres: connect: connection to server at "localhost" (127.0.0.1),
port 5432 failed: Connection refused
```

服务器宕机是值,数据撞上的约束冲突也是值(`23505` 是唯一约束
冲突)——两者都是普通的 `(R.error, ...)` 分支,用 `case` 匹配,
不抛异常。只有违反契约才抛:读出 `Rows` 边界、`finish()` 之后
再读、`close()` 之后再用 `Conn`、语句走错门(`exec` 拒绝返回
行的语句,`query` 拒绝没有结果集的语句),或者把不是该类型的
文本用类型化读取(`i64`/`f64`/`bool`)去读。

## 连接

```emo
def connect(options ConnOptions) (R, Conn)
def connect_info(info String) (R, Conn)
def options() ConnOptions
```

`connect` 是常规路径:从 `postgres.options()` 出发,用 `with_*`
构建器设好连接所需,再交出去。

```emo
class ConnOptions {
  def with_host(host String) ConnOptions
  def with_port(port Int64) ConnOptions
  def with_database(database String) ConnOptions
  def with_user(user String) ConnOptions
  def with_password(password String) ConnOptions
  def with_connect_timeout(connect_timeout Float64) ConnOptions
  def info() String
}
```

没设的字段落到 libpq 自己的默认——本机 unix socket、操作系统的
用户名、与用户同名的数据库。构建器返回全新的 options,不改原
值。`with_connect_timeout` 限定 libpq 连服务器可花的秒数
(默认 0.0,等待不设上限)。

`connect_info` 是裸路径:libpq conninfo 字符串原样透传,承载
options 没命名的关键字——`sslmode`、`application_name`、
service 文件条目等等:

```emo
const (R.ok, conn) = postgres.connect_info(
  "host=db.internal sslmode=verify-full dbname=shop user=ada")
```

连接被拒——端口不对、密码不对、数据库不存在——以
`(R.error, reason)` 作答,reason 携带 libpq 自己的消息。用完
`close()`;服务端看到 socket 关闭,会把没提交的事务回滚掉。

## 执行 SQL

```emo
class Param {
  def stage(stg Int64, i Int64) Void   // 包自身的机制
}

def text(v String) Param
def i64(v Int64) Param
def f64(v Float64) Param
def bool(v Bool) Param
def none() Param

class Conn {
  def exec(sql String, params Array[Param]) (R, Int64)
  def query(sql String, params Array[Param]) (R, Rows)
  def close() Void
}
```

带参数的语句经 libpq 的 `PQexecParams` 执行,占位符是 `$1`、
`$2`、……,取值按数组顺序以 `Param` 供给;零参数语句走简单查询路径
(`PQexec`)——不跑扩展协议的 PostgreSQL 协议服务器也能回答的那条。`postgres.i64(18)`
到达时是 `18`,`postgres.f64(1.5)` 是可往返的十进制,
`postgres.bool(b)` 是 `true`/`false`,`postgres.none()` 是
SQL NULL——不是空串,不是零。服务端从语句推断每个参数的类型,
`$1` 对 `integer` 列、对 `text` 列都能诚实比较。

```emo
const (R.ok, n) = conn.exec(
  "insert into users (name, age) values ($1, $2)",
  [postgres.text("ada"), postgres.i64(36)])
```

`exec` 以服务端报告的条数作答——插入、更新、删除的行数;没有
条数的命令(`CREATE TABLE` 与多数 DDL)答 0。本包每次调用只带一条
语句:不允许分号批量。
`query` 以 `SELECT`(或 `RETURNING`)产出的行集作答。

两扇门互相把关:返回了行的语句会拒绝 `exec`(“the statement
returned rows; query reads them”),没有结果集的语句会拒绝
`query`(“exec runs it”)。走错门是调用方程序的 bug,拒绝
信息会把它点出来。

## 读取行

```emo
class Rows {
  def count() Int64
  def columns() Int64
  def name(c Int64) String
  def index_of(wanted String) Int64
  def text(r Int64, c Int64) String
  def i64(r Int64, c Int64) Int64
  def f64(r Int64, c Int64) Float64
  def bool(r Int64, c Int64) Bool
  def is_null(r Int64, c Int64) Bool
  def finish() Void
}
```

按 `(row, column)` 读取,两者都是 **0 起**(libpq 的编号)。
类型化读取会核实服务端实际发来的内容:`i64` 把整格文本解析为
整数——不是整数的文本、或超出 `Int64` 范围的值,都会抛出并点名
那一列;`f64` 拒绝溢出 binary64;`bool` 认服务端的 `t`/`f` 和
它接受的字面拼写(`true`/`false`、`yes`/`no`、`1`/`0`)。
对两个宽度都放不下的 `NUMERIC`,不做静默收窄——`text` 扛住它,
更宽的数值类型是将来那个宽度的读取。

`text` 按服务端发来的字节作答;SQL NULL 读作 `""`,
`is_null` 负责分辨两者:

```emo
var r = 0
while r < rows.count() {
  if rows.is_null(r, rows.index_of("deleted_at")) {
    println("still active")
  }
  r = r + 1
}
```

`name(c)` 是服务端报告的列名;`index_of(wanted)` 是携带该名字的
第一列,没有则 `-1`(一个结果可以带两列同名,先者胜)。
`finish()` 释放行集——libpq 的 `PQclear`——之后的每次读取都会
抛;在那之前行集保持可读,任意顺序、任意次数。

## 边界与限制

字符串跨 C 边界以 NUL 结尾:`String` 里内嵌的 NUL 会让内容在
那里截断,两个方向都一样。语句走 PostgreSQL 的文本格式——
二进制参数、`COPY`、`LISTEN`/`NOTIFY`、游标、跨调用复用的
预备语句都不在本版本。一条连接同时只跑一条语句(线协议的
形状),调用会阻塞到服务端应答:并发要开两条连接,或者让
调度器上每个连接骑一个进程。事务控制就是普通 SQL——`begin`、
`commit`、`rollback` 和别的语句一样经 `exec` 执行;关闭的
连接留下的东西由服务端回滚。本包假定服务端 `client_encoding`
是 UTF-8——所有现代部署的默认。

## 示例

```emo
require "postgres"

const local = postgres.options().with_host("localhost").with_port(5432)
const (R.ok, conn) = postgres.connect(local.with_database("postgres"))

const (R.ok, n) = conn.exec(
  "insert into users (name, age) values ($1, $2)",
  [postgres.text("ada"), postgres.i64(36)])
println("inserted ${n}")

const (R.ok, rows) = conn.query(
  "select id, name from users where age > $1 order by id",
  [postgres.i64(30)])
var r = 0
while r < rows.count() {
  println("row ${rows.i64(r, 0)}: ${rows.text(r, 1)}")
  r = r + 1
}
rows.finish()

conn.close()
```

完整的示范——`exec` 跑 DDL、各种参数类型的写入(含 SQL
NULL)、带按名查找的类型化读取、错误分支——在
`examples/postgres_demo`,它对着 `localhost:5432` 上的真实
服务端运行。
