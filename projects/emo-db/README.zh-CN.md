# emo-db

emo-db 是 Emo 自己的客户端-服务器 SQL 数据库:一条 PostgreSQL 方言
门面,底下先接行存的 OLTP、后接列存的 OLAP。设计定案见
[`docs/zh-CN/emo-db.md`](../../docs/zh-CN/emo-db.md);本目录是项目本体。
弧一收尾:M28(RocksDB 存储半边)、M29(记录层)、M30(SQL 门面的
DML/DDL)、M31(计划器与执行器)、M32(事务与会话面)、M33
(PostgreSQL 线协议)与 M34(符合性与文档)都已落地。弧二——列引
擎——进行中:M35(列存格式)已落地。

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
  scan/filter/project 计划、CREATE TABLE/INSERT/UPDATE/DELETE 执行
  器,以及会话面——BEGIN/COMMIT/ROLLBACK、每语句快照、经
  `LockClient` 的表锁。
- `engine_demo/` —— 引擎金测:SQL 文本进,命令标签、计划树与行出;
  错误值;关闭再重开。
- `txn_demo/` —— 会话面金测:一个锁管理器进程、两个骑同一 Store 的
  会话进程、读已提交、写-写阻塞与死锁。
- `wire/` —— 项目内的 `emo/wire` 包:PostgreSQL 协议 v3 的简单查询
  路径跑在 `net` 上——启动(拒 SSL/GSSENC、trust 认证)、
  ParameterStatus/BackendKeyData/ReadyForQuery、带多语句字符串的
  Query、带 v0 类型 OID 的 RowDescription、文本格式 DataRow、
  CommandComplete、EmptyQueryResponse 与 ErrorResponse。每连接一个
  会话 actor,骑共享 Store 与会话面的表锁。
- `wire_demo/` —— 线协议服务器:全新数据库、经 ready 文件报告端口的
  临时监听、固定数量的连接。
- `wire_client/` —— 标准库 `postgres` 客户端对 emo-db:跑与 psql 相
  同的 SQL 脚本,走 libpq 的简单路径。
- `column_demo/` —— 列存格式的金测:`STORE = COLUMN` 建列存表、一个
  事务里 1030 行跨过 1024 行的块边界、按 rowid 序的块扫描、重开,以
  及不建索引/不要主键的拒绝。
- `corpus/` —— SQL 表面写成数据:六个 `.test` 文件、126 个用例,
  SQLLogicTest 精神——`statement ok` 钉标签、`statement error` 钉
  `code: message` 行、`query` 钉行。
- `corpus_runner/` —— 语料唯一的代码:每次调用一台全新数据库、按参
  数顺序执行文件、按文件计数、收集失败。
- `bench/` —— 基准工作负载与 `run.sh`;`results.md` 记录实测数字。
- `check.sh` —— 闸门:解析 RocksDB、暂存 registry、检查四个包、把五
  个嵌入式 demo 各跑三遍对照各自的 `expected.txt`、把语料跑三遍逐字
  节一致、烟测 bench 的计数、用 psql 与 `postgres` 客户端驱动线协议
  (每个阶段一台全新服务器,各自逐字节钉死),并钉死两条拒绝(解释
  器 E3009、非 `c` target 的 E5007)。

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
(或删除);update 的唯一检查排除该行自己的 rowid。事务的 `Txn` 把
每次写缓进一个 `WriteBatch`,按每语句快照读,在快照上覆盖自己的
pending 条目(读己之写),只在 COMMIT 时发布 rowid 计数——COMMIT 用
`write_sync` 写这个批量,WAL 在回答前 fsync。重开时用
`list_families` 枚举 family,并校验目录点名的每个索引 family 都曾
存在——缺一个是损坏,不是可以悄悄重建的东西。

索引键只保证精确前缀(等值扫描是 seek 加前缀走),不保序;范围扫描
与流式扫描等后面的计划器。

## 引擎

`emo/engine` 是第一条完整的 SQL 到行链路,它的会话面就是事务边
界。`execute` 用 `sql` 包解
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

BEGIN 开启事务,COMMIT 写它的批量(含 fsync),ROLLBACK 丢弃;事务
内的语句取每语句快照,没有事务的语句在自己的 autocommit 事务里
跑。失败语句中止事务。写语句经挂上的 `LockClient` 拿表锁并持有到
COMMIT/ROLLBACK;锁管理器是一个 Emo 进程,带 FIFO 等待队列、
wait-for 图,死锁以 `40P01` 中止。`txn_demo` 跑两个会话与管理器,
展示读已提交、写-写阻塞与死锁。

## 线协议

`emo/wire` 让服务器成真。`net` 监听接受连接;每连接一个进程读启动
包、在 trust 下答 AuthenticationOk、发 ParameterStatus 集合、
BackendKeyData 与 ReadyForQuery,然后跑简单查询循环。一个 Query 字
符串可以带多条语句:`sql.split` 在词法器自己的分号处切分,每条语句
走会话的引擎。SELECT 答 RowDescription(名字、OID、大小、文本格式)
与每行一条 DataRow——整数十进制、浮点用自己的渲染、布尔用 PG 的
`t`/`f`、BYTEA 用 `\x` 十六进制、NULL 用 -1 长度——再答
CommandComplete。命令只答自己的标签。空字符串答 EmptyQueryResponse。

错误答 ErrorResponse(SQLSTATE 与主消息),停掉剩余语句,并让会话干
净:引擎已经中止事务、释放锁,所以 ReadyForQuery 报 `I`,下一条
Query 照常工作。psql 驱动整个表面;标准库 `postgres` 客户端的零参
数语句走 libpq 的简单路径(`PQexec`),同一个服务器不需要扩展协议。
每个连接各自一个骑共享 Store 的 Engine,以及一个骑服务器唯一锁管理
器进程的 `RemoteLocks` 客户端,所以 M32 的表锁跨连接仲裁。

v0 的线协议只有简单路径:扩展协议(Parse/Bind/Execute)、SSL、
scram-sha-256 与 cancel 请求都不说。`server_version` 报 PostgreSQL
兼容级别(`16.4`),因为工具会解析它;产品自己的版本留在包里。

## 列存

弧二的第一落是格式(M35)。`CREATE TABLE ... STORE = COLUMN` 点名列
存表;目录的表定义带 `store` 字段(版本 2;版本 1 记录读作行存,旧
库原样打开)。列存表的行住在 1024 行块里,每列一个 column family
(`col_<oid>`):块值是行数、null 位图,然后是行编码自己宽度的值。
插入在事务的批量里重读并重写尾部半块,所以 pending 覆盖层与每语句
快照原样生效;重开像索引 family 一样校验每个列 family。列存表不建
索引——`PRIMARY KEY` 与二级索引答 `0A000`,块扫描就是访问路径。在
step 73 的批量执行器之前,引擎对列存表的 DML 与 SELECT 以具名的
`0A000` 桥接。

## 符合性与测量

语料把 SQL 表面写成数据,runner 是它唯一的代码。一条记录是表头
(`statement ok`、`statement error` 或 `query`)、语句的行,以及
`----` 之后的期望——一个命令标签、一行 `code: message`,或按
runner 的规范渲染(竖线分隔、`NULL`、`true`/`false`)的行。126 个
用例骑一台全新数据库;闸门把语料跑三遍逐字节一致。

bench 的模式只打印计数——`bench/run.sh` 给它们计时(一次预热、三
次计时)并写 `bench/results.md`;设计记录携带实测表。闸门只检查各
模式能跑并答对计数,从不检查时间。

## 跑闸门

RocksDB 必须能被 `pkg-config` 解析:

```console
$ brew install rocksdb            # macOS
$ sudo apt install librocksdb-dev # Debian/Ubuntu
$ ./check.sh
```

库缺失时闸门大声失败,不静默跳过——绑定就是被测的东西。线协议两个
阶段是例外:`PATH` 上没有 psql 就跳过 psql 阶段,`pkg-config` 解析不
到 libpq 就跳过 `postgres` 客户端阶段(与标准库探针相同的 Homebrew
keg 回退)。`EMO` 可指向另一个编译器二进制;默认是
`../../_build/default/src/emo_cli/emo.exe`。

## 状态

M28 于 2026-11-12 落地:绑定、KV 金测、以及 C ABI 的字节视图。M29
同日落地:记录层、记录层金测、以及目录的重开路径。M30 落地 SQL 门
面的 DDL/DML,M31 落地嵌入式计划器/执行器及其金测,M32 落地事务与
会话面及其两会话金测,M33 落地 PostgreSQL 线协议,psql 与
`postgres` 客户端为金测。M34 于 2026-11-13 落地:126 个用例的语
料、实测表,以及已交付表面文档收尾弧一。同日 M35 落地:列存格式
——解析器的 `STORE = COLUMN` 尾巴、目录的版本 2 `store` 字段、
1024 行块、列 family 与重开校验——引擎的 DML 与 SELECT 走具名桥
接。step 73 是列执行器。
