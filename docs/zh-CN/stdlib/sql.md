# `sql` 包

标准库的 SQL parser:SQL 文本进,抽象语法树出,纯 Emo 实现,只依赖共享运行时——字节,以及 `float` 包的精确十进制转换。没有按 target 区分的运行时工作:凡是能编译这门语言的 target,答案逐字节一致。

## 使用这个包

```emo
require "sql"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "sql"` 需要在 manifest 的 `deps` 块里钉上 `"sql" = "0.1.0"`。

## 语法树

`parse` 返回一个 `Stmt`:一个接口,每个语句种类一个类——`Select`、`CreateTable`、`Insert`、`Update`、`Delete`、`Begin`、`Commit`、`Rollback`——用 `StmtKind` 枚举判别。语句内部,表达式是 `Expr` 节点(每个 `ExprKind` 一个类),表引用是 `TableRef` 节点(每个 `TableKind` 一个类)。三个接口都回答 `to_string()`:规范的 SQL 渲染——关键字大写、JOIN 种类写全、别名带 `AS`。节点的字段公开且在构造后冻结;`Expr` 背后的具体类用 `is()` 缩窄来读:

```emo
const (R.ok, stmt) = sql.parse("SELECT name, count(*) AS n FROM users GROUP BY name")
if stmt.is(sql.Select) {
  println(stmt.columns.length())
  const item = stmt.columns[1]
  if item.is(sql.SelExpr) {
    println(item.alias_e[0])   // "n"
  }
  println(stmt.group_by.length())
}
```

可选部分以 0-or-1 数组承载——`Select` 的 `where_e`、`having_e`、`limit_e`、`offset_e`,`SelExpr`、`TblNamed`、`TblSubquery` 的 `alias_e`,`TblJoin` 的 `on_e`,`CaseExpr` 的 `operand_e` 和 `else_e`——与列表字段(`group_by`、`order_by`、`from_t`、`using`、`InTest` 的 `choices`)的"空即缺席"读法一致。

## 解析

```emo
def parse(text String) (R, Stmt)
```

严格的字节级解析:关键字大小写不敏感;标识符与带引号标识符(`"a""b"` 解码为 `a"b`);字符串字面量用标准的 `''` 转义(没有反斜杠转义——标准 SQL 本来就没有);`?` 与 `?NNN` 参数(索引从 1 起算,故 `?0` 拒绝);`--` 与 `/* */` 注释;完整的表达式语法——字面量、带限定的列名、支持 `DISTINCT` 与 `*` 参数的函数调用、`CAST`、`CASE`、`EXISTS`、标量子查询,以及 `OR` / `AND` / `NOT` / 比较 / `LIKE` / `IN`(列表或子查询)/ `BETWEEN` / `IS [NOT] NULL|TRUE|FALSE` / `+ - * / %`,其中 `||` 与加减同级——标准就是这么定的。

一切格式错误的输入都返回 `(R.error, reason)`,而不是编出一棵树:reason 是一个字符串,准确说明发生了什么、在哪个字节偏移,如 `sql: expected an expression at byte 7`。严格性规则:不允许链式比较(`a = b = c` 拒绝);不允许编造子句——`WHERE`、`GROUP BY`、`HAVING`、`ORDER BY`、`LIMIT`、`OFFSET` 每个至多出现一次,且只能按此顺序出现,因此重复或顺序颠倒的子句一律拒绝,而不会被悄悄重排;一次 `parse` 调用只解析一条语句;表达式嵌套上限 512 层(与格式包一致)。越界的数拒绝——超出 `Int64` 的整数(`-9223372036854775808` 本身可以到达,符号折进字面量)和超出 binary64 的浮点数。

## 切分查询字符串

```emo
def split(text String) (R, Array[String])
```

协议的 Query 一条字符串里可以带多条语句。`split` 只词法分析一次,在词
法器自己的 `t_semi` token 处切分,因此字符串字面量、带引号标识符、
`--` 注释与 `/* */` 注释里的分号不会切;空片段丢弃,没有任何语句的
字符串答空数组。词法错误就是切分的错误——未闭合的字面量仍是解析器
会给的同一个 `42601`,绝不是被悄悄切开的语句。每个返回片段都已 trim,
可以单独交给 `parse`。

```emo
const (R.ok, parts) = sql.split("select 1; select ';' as semi")
// 两条语句:"select 1" 与 "select ';' as semi"
```

## 支持的语句

`SELECT` 全链路:带 `DISTINCT` 的选择列表(`*`、`t.*`、带可选 `AS` 别名的表达式)、`FROM` 表列表(可带 schema 限定、可带别名)、子查询,以及 `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` / `NATURAL` 连接,带 `ON` 或 `USING`;`WHERE`、`GROUP BY`、`HAVING`、`ORDER BY`(带 `ASC`/`DESC`)、`LIMIT`、`OFFSET`。单独的 `JOIN` 即内连接;`NATURAL` 连接不带 `ON` 或 `USING`。

### CREATE TABLE

`CREATE TABLE users (id BIGINT NOT NULL PRIMARY KEY, name TEXT NOT NULL, score DOUBLE PRECISION, handle VARCHAR(12))`。v0 类型是 `INTEGER`、`BIGINT`、`REAL`、`DOUBLE PRECISION`、`TEXT`、`VARCHAR(n)`、`BOOLEAN`、`BYTEA`——精确拼写,没有别名(`INT`、`BOOL`、`SERIAL` 等拒绝);`VARCHAR` 需要正的 `(n)`。支持列级 `NOT NULL` 与 `PRIMARY KEY`,各自至多一次、顺序任意;规范渲染先写 `NOT NULL` 再写 `PRIMARY KEY`。重复列名拒绝。

### INSERT

`INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')`——列清单可选,值是一行或多行带括号的表达式。每行的表达式数相同;有列清单时还等于列数,不一致拒绝。列清单里的重复名字拒绝。

### UPDATE 与 DELETE

`UPDATE users SET name = 'Ada', active = TRUE WHERE id = 1`——互异的赋值(重复列拒绝)与可选 `WHERE`。`DELETE FROM users WHERE id = 1`——`WHERE` 可选。

### 事务控制

`BEGIN`、`COMMIT` 与 `ROLLBACK` 作为独立语句解析并原样渲染;状态由会话面(不是解析器)携带。

不支持——每一项都返回 `(R.error, reason)`,绝不猜测:`INSERT ... SELECT`、`ON CONFLICT`、`RETURNING`、表级约束与 `UNIQUE`/`DEFAULT`/`CHECK`/`REFERENCES`、`CREATE INDEX`、`UPDATE ... FROM`、`DELETE ... USING`、`WITH`、集合运算(`UNION`/`INTERSECT`/`EXCEPT`)、窗口函数、方括号风格的带引号标识符、`LIKE` 的 `ESCAPE` 子句(`parse` 只收一条语句;`split` 是多语句的入
口)。

## 渲染

每个节点的 `to_string()` 都会按规范重建语句:

```emo
const (R.ok, q) = sql.parse("select * from users where id = ?1")
println(q.to_string())
// SELECT * FROM users WHERE id = ?1
```

带引号标识符只在拼写需要时才渲染引号:`weird name` 这样的名字往返为双引号形式,`name` 保持裸写。源码里显式的括号会保留(`Paren` 节点),因此渲染结果总是如实呈现书写者的分组。
