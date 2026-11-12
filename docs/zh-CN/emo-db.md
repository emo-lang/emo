# emo-db —— 设计定案

写于 2026-11-12。这是 emo-db(Emo 自己的数据库)的已定设计:产品是
什么、形状背后的决策、把它建出来的天梯、以及仍然开放的部分。可行性
背景见 `docs/zh-CN/sql-database.md`(2026-10-06);那份评估的分档框
架就是本项目继承的诚实量尺。这里的决策已与项目所有者定案;开放项按
开放陈述,并附原因。

## 产品,一段话说清

emo-db 是用 Emo 写的客户端-服务器 SQL 数据库。一条 SQL 门面——
PostgreSQL 方言,走 PostgreSQL 线协议——后面是两台引擎:先做行存的
OLTP,后接列存的 OLAP,按表选择。底下的存储层不手写:行存骑
RocksDB,绑定姿势是 `sqlite3` 和 `postgres` 两个包已经实证过的那套。
目标是生态里熟知的两件产品——PostgreSQL/MySQL 式的事务服务与
ClickHouse 式的分析——合为一个项目、一条门面。

## 为什么一个项目,不拆两个

两个目标共性大于差异,而共性的部分恰是大头:SQL 解析、AST、类型系
统、目录、计划脚手架、表达式求值、错误码、线协议、客户端工具。拆两
个项目重复的正是这一整块,并且注定撞上数据库工程最经典的灾难——两
套 SQL 方言各自漂移。真正不同的只有存储格式和执行器,而在单项目内
它们本来就是两个隔离的包。

组合本身也是两个项目单独都给不出的产品故事:一条 SQL 门面、按表选
存储(`STORE = ROW` / `STORE = COLUMN`)、一个 planner 把每条查询路
由到持有该表的引擎。这是 TiDB(TiKV + TiFlash)和 SingleStore 的形
状——按表的 HTAP,不是按产品的。拆成 `emo-db-sql` 与 `emo-db-olap`
因这些理由被否决。若将来 OLAP 引擎大到独立仓库开始划算,再从
emo-db 里析出——按体重做的决定,不预付拆分税。

## 决策

**D1 —— 存储层用 RocksDB,不手写。** fsync、WAL、compaction、压缩
都是 RocksDB 的活。这是可行性评估自己点名的 CockroachDB/TiDB 先例
(「两家都不自己造 B 树」),并且它把评估里 Tier B 的第一道硬门——
没有 fsync 就没有 WAL——直接化掉,因为 fsync 的纪律不再由我们来
写。绑定走 `postgres`/`sqlite3` 的形状:包内自带 C shim,骑官方 C
API(`rocksdb/c.h`),经 `foreign def` 与 manifest 的 `link` /
`pkg_config` 字段点名库。键与值骑 D10 的借用视图以 `Bytes` 跨界。
仅 `c` target;其余 target 在解析处拒绝,解释器在运行时拒绝。

**D2 —— 一个项目,一条 SQL 门面,两台引擎。** 如上。目录、类型、门
面、线协议、工具从第一笔提交起就共享;行存与列存两台引擎是同一个
planner 底下分开的包。

**D3 —— OLTP 先行。** OLTP 弧把共享门面建起来,OLAP 引擎随后插进它
底下。反过来——DuckDB 形状的分析引擎先行——到一个可信 v1 确实更
小,但它没有线协议、没有事务面,两弧都需要的共享门面也没建起来。
RocksDB 这个决定本身就是行存形状的,顺序由此钉死。

**D4 —— 客户端-服务器。** 产品是一个服务器:用本项目构建出的 Emo 程
序,经 `net` 接连接,一连接一个会话 actor(`httpd` 的先例)。嵌入式
进程内库形态不在 v0 范围;架构上没有任何东西堵死它将来补上。

**D5 —— PostgreSQL 线协议 v3。** 这条协议是事实互操作标准(评估原
话):线做对的那天,psql 与更大的 PG 驱动生态都能连上来。Emo 自己的
证明是即时的——标准库的 `postgres` 客户端说的就是 libpq 的协议,Emo
程序经一个现成的包就能对上 emo-db。这个客户端同时就是自食其力的金
测。

**D6 —— 并发控制归 Emo 的 actor 平面,不用 TransactionDB。** 会话
actor 持有事务状态:写缓进 RocksDB 的 WriteBatch,COMMIT 是一次原子
写、RocksDB 的 WAL 在底下顶着,ROLLBACK 丢弃整个 batch。读骑
RocksDB 快照——先做读已提交(每语句一快照),后做可重复读(每事务
一快照加冲突检测)。写-写冲突走 Emo 自己的锁管理器。两个理由:普通
C API 比 TransactionDB 的 C 面更小更稳;锁管理器正是评估那句
「actor 模型映射到数据库控制面」的落地——Emo 的并发优势恰好就在这
个平面上。

**D7 —— v0 类型子集。** INTEGER、BIGINT、REAL、DOUBLE PRECISION、
TEXT、VARCHAR(n)、BOOLEAN、BYTEA(骑 `Bytes`)。REAL 与 DOUBLE
PRECISION 在 v0 都按 binary64 存储;REAL 的 4 字节收窄等 Float32 或
一个舍入例程。挂起:NUMERIC(等语言的 Int128/bignum——评估列过的
缺口)、DATE/TIMESTAMP(等日历库;将来一个独立包的候选)。

**D8 —— v0 线协议范围:simple query 路径。** Startup、trust 认证、
Query / RowDescription / DataRow / CommandComplete / ReadyForQuery、
带 PG 错误字段约定的 ErrorResponse、多语句字符串。psql 靠这些就开得
动全部表面。挂起:extended protocol(prepared statements——多数驱
动的默认)、scram-sha-256、SSL。

**D9 —— 天梯。** 弧一是里程碑 M28–M34,一里程碑一步,步骤 65 到
71。退出标准在 `docs/zh-CN/TASKS.md`;天梯形状:

| 里程碑 | 步骤 | 落地 |
| --- | --- | --- |
| M28 —— RocksDB 半边 | 65 | 项目脚手架与 C shim,连同 `Bytes` 借用视图(D10):open/close、get/put/delete、WriteBatch、iterator、快照、column family。 |
| M29 —— 记录层 | 66 | 目录 column family、行编码、rowid 分配、每索引一个 column family 的二级索引——行住在共享的 `data` family 里,键是表 oid + rowid。 |
| M30 —— SQL 门面长 DML 与 DDL | 67 | `sql` 包在 SELECT 旁长出 CREATE TABLE / INSERT / UPDATE / DELETE——纯 Emo,每个 target 逐字节一致。 |
| M31 —— 计划器与执行器 | 68 | 第一条完整的 SQL 到行全链路:计划节点(scan/filter/project、insert/update/delete)、骑记录层的表达式求值、嵌入式测试面。v0 的 SELECT 是单表(投影、WHERE、等值索引扫描);连接、聚合、ORDER BY/LIMIT 与子查询等 M34。 |
| M32 —— 事务与会话面 | 69 | BEGIN/COMMIT/ROLLBACK、骑每语句快照的读已提交、每事务一个 WriteBatch 且 COMMIT 做 fsync、Emo 锁管理器。v0 是表级锁。 |
| M33 —— 线协议 | 70 | PG 协议 v3 simple 路径;psql 端到端、`postgres` 客户端直连。 |
| M34 —— 符合性与文档 | 71 | SQL 语料、实测性能表、文档 EN+zh。 |

**D10 —— 字节视图:`Bytes` 以借用视图过 C ABI。** RocksDB 的键与
值是任意字节——内嵌的 NUL 是普通数据——而 sqlite3/postgres 绑定的
NUL 结尾 String 跨界会把它截断。`c` target 的 foreign ABI 为此长出
一个形状:`Bytes` 参数以 `{data, len}` 跨界,只在调用期间借用(C 侧
绝不保留);`Bytes` **返回**仍然拒绝,因为 C 缓冲区的所有权无法穿过
通用 ABI——读操作走调用方提供的 out 参数(先问长度,再拷入),字节
的所有权始终在 Emo 侧。解释器保持 E3009,其余 target 保持各自的封
送层。这是 v0 唯一需要的语言改动,随 M28 的绑定一起落地,因为行编
码(M29)不可能建在 NUL 结尾的字符串上。

## 架构

自顶向下:

1. **线协议** —— PostgreSQL 协议 v3 的 simple query 路径:分帧、
startup 与认证、查询循环、错误报告。`net` 接连接;一连接一个会话
actor。
2. **会话面** —— 每会话状态:当前事务的 WriteBatch 与快照、语句分
发、穿线协议回去的结果流、会话持有的锁。
3. **SQL 门面** —— `sql` 包,纯 Emo、每个 target 逐字节一致:AST
与解析器在现有 SELECT 旁长出 CREATE TABLE、INSERT、UPDATE、DELETE。
4. **计划器与执行器** —— 逻辑计划节点(scan、filter、project、
insert、update、delete)与骑在记录层值上的表达式求值。
5. **记录层** —— 目录(表、列、类型,按 oid,独立的 column
family)、行编码(空值位图、定宽与带长度前缀的变宽值)、rowid 分
配、二级索引:每索引一个 column family,键由被索引列加 rowid 编
成。行住在共享的 `data` column family 里,键是表 oid 加 rowid;目
录是自己的 column family;索引键只保证精确前缀(等值扫描是 seek
加前缀走),暂不保序。
6. **存储半边** —— 经包内 C shim 的 RocksDB:open/close、
get/put/delete、WriteBatch、iterator、快照、column family。键与值
骑 D10 的借用视图以 `Bytes` 跨界;读操作填写调用方自己的缓冲区。

有一个性质值得写明,因为整个绑定都骑在它上面:调度器的协作模型意味
着每次进 RocksDB 的调用天然串行——shim 自己不长锁,锁管理器仲裁的
是事务冲突,不是内存安全。M28 验证了这个前提;若某个 hosted
runtime 将来长出真并行,就在那里重查。

## 弧二 —— OLAP 形状(方向已定,切法未定)

- 列存 v1 同样骑 RocksDB:每列一个 column family,列块作 value。单
一存储依赖对两弧都成立;自有 Parquet 式段文件格式留作一条由性能证
据挣来的决策。
- 列批上的向量化表达式求值;扫描靠块级 min/max 统计剪枝。
- `CREATE TABLE ... STORE = COLUMN` 进目录;planner 按表存储路由。
HTAP 的门在这里开。
- 本弧重开的语言缺口:RocksDB 之外的二进制文件 IO(`os` 的 Bytes 形
状 fd 面)。到那时这个需求已与所有搬运二进制数据的 Emo 程序共享
——正是评估说过的缺口该关上的方式。

本弧的里程碑切法,等弧一的 planner 建到可以插的时候再写——不预
写。

## 诚实的代价

- 即使存储层外包,弧一仍是评估 Tier B 的形状减去存储工程:以人年
计,不以月计。天梯刻意切小——一里程碑一步,每步带逐字节钉死的金
测。
- 正确性负担不随语言变小。SQL 广度、崩溃语义、协议符合性,这些就
是产品本身。
- GC 尾延迟问题(评估的 #4)在性能被测量那天就到场;后端选择要
早、要有意识地做。
- churn 税是真的:pre-1.0 的语言一动,引擎跟着动;语言落的每次更
名,引擎的语料都跟着走。

## 开放项

按开放陈述,各自等自己的证据或决策:

- extended protocol——psql 与 libpq simple 路径之外的驱动提出需求
之时。
- scram-sha-256 与 SSL——真认证与真传输安全;`crypto` 包已经握着
全部零件。
- NUMERIC——等语言里的 Int128 或 bignum。
- DATE/TIMESTAMP——等日历包。
- 可重复读与串行化——等读已提交在并发下站稳之后。
- 备份与恢复——RocksDB checkpoint 与 pg_dump 形状的逻辑转储,两条
路都通,都未定。
- `Bytes` 的 foreign 返回——out 参数的规则覆盖弧一的全部读路径;返
回位置等一个真需要它的 API。
- 索引上的范围扫描——v0 的索引键只保证精确前缀、不保序;比较编码
与计划器的范围节点随 M34 的符合性广度落地。
- 流式扫描——v0 物化整行;游标形状的记录 API 等一个消费它的计划
节点。
- SELECT 的其余部分——连接、聚合、`GROUP BY`/`HAVING`、`ORDER
BY`/`LIMIT`、子查询、`DISTINCT` 与 `CAST`——v0 引擎拒绝它们;随
M34 的符合性广度落地。
- 记录 API 的非事务写——绑定的普通 `write` 没开 RocksDB 的
`sync`;事务的 COMMIT 调 `write_sync`。直接调记录 API 且需要持久性
的调用方走事务。
- 弧二的里程碑切法。
