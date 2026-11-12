# emo-db

emo-db 是 Emo 自己的客户端-服务器 SQL 数据库:一条 PostgreSQL 方言
门面,底下先接行存的 OLTP、后接列存的 OLAP。设计定案见
[`docs/zh-CN/emo-db.md`](../../docs/zh-CN/emo-db.md);本目录是项目本体。
M28(RocksDB 存储半边)、M29(记录层)、M30(SQL 门面的 DML/DDL)与
M31(计划器与执行器)已经落地;事务与线协议在 M32–M34 跟上。

## 布局

- `rocksdb/` —— 项目内的 `emo/rocksdb` 绑定:包内自带 C shim,骑
  RocksDB 官方 C API,`targets = ["c"]`,`pkg_config = ["rocksdb"]`。
  公开面是 `Db`、`Cf`、`Batch`、`Iter` 与 `Snapshot`;原始
  `foreign def` 在 `internal/` 下。`list_families` 在 open 之前枚举
  已存在的列族,记录层靠它重开带索引列族的库。
- `record/` —— 项目内的 `emo/record` 记录层:目录(表、列、类型、
  索引、oid 计数)、行与索引编码、`rowid` 分配,以及
  `Store`/`Table`/`Row`/`Value` 表面。字节编解码在 `internal/` 下。
- `kv_demo/` —— KV 金测:文本与内嵌 NUL 的值、一次原子批量、前缀
  扫描、快照隔离、关闭再重开。
- `record_demo/` —— 记录层金测:一张覆盖 v0 全部类型的 `users`
  表、NULL、BYTEA 内嵌 NUL、UTF-8 TEXT、重复唯一键、扫表、唯一与
  非唯一索引扫描,以及重开。
- `engine/` —— 嵌入式 SQL 引擎:分析器(名字、类型、PG 形状失
  败)、带三值 NULL 逻辑的类型化表达式树、带等值索引扫描的
  scan/filter/project 计划,以及 CREATE TABLE/INSERT/UPDATE/DELETE
  执行器。
- `engine_demo/` —— 引擎金测:SQL 文本进,命令标签、计划树与行出;
  错误值;关闭再重开。
- `check.sh` —— 闸门:解析 RocksDB、暂存 registry、检查三个包、把三
  个 demo 各跑三遍对照各自的 `expected.txt`,并钉死两条拒绝(解释器
  E3009、非 `c` target 的 E5007)。

## 绑定的形状

键与值是 `Bytes`,因此携带任意二进制数据——内嵌 NUL 也算。`Bytes`
以借用的 `{data, len}` 视图过 C ABI(D10),只在调用期间有效;读操作
填写调用方自己的 out 参数,因为 C 缓冲区的所有权无法穿过通用 ABI。

预期失败是值:`(R.ok, …)` 或 `(R.error, reason)`,reason 以
`rocksdb: ` 开头。缺失的键不是错误——`get` 答空数组(不存在)或单
元素数组(存在)。只有契约违约才 raise:已关闭的数据库、所有者关闭
后仍被使用的句柄、无效的 iterator、或与另一个数据库的列族混用的
batch。门面给活的 batch、snapshot、iterator 计数,并在有其一未关时
拒绝 `Db.close`,RocksDB 的内存因此不会在活句柄底下被释放。

调度器是协作式的:每次进 shim 的调用天然串行,shim 不带锁。事务与
锁管理器是数据库自己的(M32)。

## 记录层

目录是自己的 column family:两个 meta 键带着下一个表 oid 与索引
oid,每个表一个键,值里是版本化的定义(列、类型、标志、
`next_rowid`,以及每个索引的列)。行住在共享的 `data` family 里,
键是表 oid 加 `rowid`(各 8 字节大端)。每个二级索引一个自己的
family,名为 `idx_<oid>`,键是被索引值(各自标记存在或 NULL)加
`rowid`。

行编码是空值位图后跟按列序的非空值:`INTEGER` 4 字节大端且检查
范围,`BIGINT` 8 字节,`REAL` 与 `DOUBLE PRECISION` 在 v0 都是
binary64,`BOOLEAN` 一字节,`TEXT`/`VARCHAR(n)`/`BYTEA` 是 4 字节
长度加字节。`VARCHAR(n)` 按 UTF-8 码点计数。写之前先做唯一索引检
查;插入的行、索引条目与更新后的目录定义随后骑一次原子
`WriteBatch`,所以写失败不会推进 `rowid` 计数。`update` 与
`delete` 读旧行、移除它的索引条目,并在一次批量里写回新行/条目
(或删除);update 的唯一检查排除该行自己的 rowid。重开时用
`list_families` 枚举 family,并校验目录点名的每个索引 family 都曾
存在——缺一个是损坏,不是可以悄悄重建的东西。

索引键只保证精确前缀(等值扫描是 seek 加前缀走),不保序;范围扫描
与流式扫描等后面的计划器。

## 引擎

`emo/engine` 是第一条完整的 SQL 到行链路。`execute` 用 `sql` 包解
析,对目录解析名字与类型,回答一个 `Result`(PG 命令标签、投影的列
与行、计划文本)或一个 PG 形状的 `code: message` 失败串。v0 表面:
带投影与可选 WHERE 的单表 SELECT;索引列与常量之间的等值变成索引
扫描,其余是表扫描。CREATE TABLE 映射 v0 类型与列约束,主键列得到
一个唯一索引(`<table>_pkey`);INSERT 用 NULL 填充省略的列并做数值
加宽;UPDATE 与 DELETE 走同一套扫描选择,调用记录层的
update/delete。类型化表达式实现 SQL 的三值 NULL 逻辑、比较、
AND/OR、算术、文本 `||`、`IS`、`IN`、`BETWEEN`、`LIKE` 与
`CASE`;DISTINCT、连接、子查询、GROUP BY/HAVING、ORDER BY、
LIMIT/OFFSET、聚合、函数、CAST 与参数答 `0A000`。`engine_demo`
展示整个表面与错误值。

## 跑闸门

RocksDB 必须能被 `pkg-config` 解析:

```console
$ brew install rocksdb            # macOS
$ sudo apt install librocksdb-dev # Debian/Ubuntu
$ ./check.sh
```

库缺失时闸门大声失败,不静默跳过——绑定就是被测的东西。`EMO` 可指
向另一个编译器二进制;默认是
`../../_build/default/src/emo_cli/emo.exe`。

## 状态

M28 于 2026-11-12 落地:绑定、KV 金测、以及 C ABI 的字节视图。M29
同日落地:记录层、记录层金测、以及目录的重开路径。M30 落地 SQL 门
面的 DDL/DML,M31 落地嵌入式计划器/执行器及其金测。下一步是 M32
——事务与会话面。
