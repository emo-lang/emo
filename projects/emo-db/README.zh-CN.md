# emo-db

emo-db 是 Emo 自己的客户端-服务器 SQL 数据库:一条 PostgreSQL 方言
门面,底下先接行存的 OLTP、后接列存的 OLAP。设计定案见
[`docs/zh-CN/emo-db.md`](../../docs/zh-CN/emo-db.md);本目录是项目本体。
M28(RocksDB 存储半边)是第一笔落地;目录、行编码、计划器、事务与线
协议在 M29–M34 跟上。

## 布局

- `rocksdb/` —— 项目内的 `emo/rocksdb` 绑定:包内自带 C shim,骑
  RocksDB 官方 C API,`targets = ["c"]`,`pkg_config = ["rocksdb"]`。
  公开面是 `Db`、`Cf`、`Batch`、`Iter` 与 `Snapshot`;原始
  `foreign def` 在 `internal/` 下。
- `kv_demo/` —— KV 金测:文本与内嵌 NUL 的值、一次原子批量、前缀
  扫描、快照隔离、关闭再重开。`expected.txt` 是钉死的输出;
  `package.lock` 钉住绑定。
- `check.sh` —— 闸门:解析 RocksDB、暂存 registry、构建 demo、跑三遍
  对照 `expected.txt`,并钉死两条拒绝(解释器 E3009、非 `c` target
  的 E5007)。

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

M28 于 2026-11-12 落地:绑定、KV 金测、以及 C ABI 的字节视图。下一
步是 M29——记录层(目录、行编码、rowid 分配、二级索引)。
