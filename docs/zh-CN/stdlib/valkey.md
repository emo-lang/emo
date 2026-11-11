# `valkey` 包

标准库的 Valkey 客户端,用纯 Emo 写在 [`net`](stdlib/net.md) 包之上。通篇直接风格:一条命令读起来就是普通函数调用,socket 忙碌时调度器在底层挂起进程。线上协议是 RESP2——每个请求就是协议所说的 bulk 字符串数组,每个回复就是协议应答的回复类型之一。本包声明 `ocaml`、`c` 与 `typescript` 三个目标(`targets = ["ocaml", "c", "typescript"]`);依赖解析在其他一切目标上拒绝它。

一条连接、一条命令、一个回复。客户端写完请求、读走该命令点名的那一个回复——没有流水线,没有连接池,没有把掉线藏起来的自动重连。服务器说的话以值返回,线上断掉的部分同样以值返回。

## 引入

```emo
require "valkey"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "valkey"` 需要在 manifest 的 `deps` 块里钉上 `"valkey" = "0.1.0"`;它依赖的 `net` 由 `valkey` 自己的 manifest 带入。本包声明 `ocaml`、`c`、`typescript` 三个目标。

## 连接

```emo
valkey.connect(host, port, timeout)                    // (R, Valkey)
valkey.connect_unix(path, timeout)                     // (R, Valkey)
valkey.connect_tls(host, port, timeout)                // (R, Valkey)
valkey.connect_tls_insecure(host, port, timeout)       // (R, Valkey)
```

- `connect` 走 TCP 拨号并回答 `Valkey` 句柄;`connect_unix` 走 Unix 域 socket(对应服务器端 `unixsocket /path` 启动的实例)。
- `connect_tls` 走 `net.tls_connect`——对系统信任库做证书校验,默认开启。`connect_tls_insecure` 是显式、可见的危险开关,用于自签名环境,和 `net` 里的那扇门同名同义。
- `timeout` 以秒为单位,约束**每一次交换**:写和其后的每次读各拿一份预算(`net` 的逐操作截止时间),所以一条命令的最坏情形是这个值的小倍数。`0.0` 表示无限等待;负值在任何 socket 打开之前就以错误元组返回。

每一种失败——连接被拒、名字解析不了、TLS 被拒——都是携带 `net` 自身 reason 的错误元组。

## 命令

类型化的门,一条命令一个方法。每个都以 `(R, …)` 回答:该命令契约所命名的值,答案可能缺席时是 null 回复,失败时是错误元组。命令名按大写发送(`GET`),线上呈现的就是协议自己的拼写:

```emo
// 连接
v.ping()                          // (R, String) — "PONG",或回显
v.echo(msg)                       // (R, String)
v.auth(password)                  // (R, String) — "OK"
v.select(db)                      // (R, String) — "OK"
v.command(args)                   // (R, Reply) — 任意命令,原始回复
v.set_timeout(seconds)            // Void — 约束其后的每次交换
v.close()                         // (R, Valkey)

// 字符串
v.get(key)                        // (R, Reply) — bulk,或 null 回复
v.set(key, value)                 // (R, String) — "OK"
v.set_ex(key, value, seconds)     // (R, String) — "OK",EX 形式
v.setnx(key, value)               // (R, Bool)
v.mset(pairs)                     // (R, String) — pairs Array[(String, String)]
v.mget(keys)                      // (R, Array[Reply]) — 内部可为 null
v.append(key, value)              // (R, Int64) — 新的字节长度
v.strlen(key)                     // (R, Int64) — 字节长度
v.getrange(key, start, stop)      // (R, String)
v.incr(key)                       // (R, Int64)
v.decr(key)                       // (R, Int64)
v.incr_by(key, n)                 // (R, Int64)
v.decr_by(key, n)                 // (R, Int64)

// 键
v.del(keys)                       // (R, Int64) — 删掉了几个
v.exists(keys)                    // (R, Int64) — 存在几个
v.keys(pattern)                   // (R, Array[String])
v.type(key)                       // (R, String) — "string"、"none"、…
v.rename(key, new_key)            // (R, String) — "OK"
v.expire(key, seconds)            // (R, Bool)
v.ttl(key)                        // (R, Int64) — 秒数、-1 或 -2
v.persist(key)                    // (R, Bool)
v.dbsize()                        // (R, Int64)

// 哈希
v.hset(key, field, value)         // (R, Int64) — 新建 1,覆盖 0
v.hget(key, field)                // (R, Reply) — bulk,或 null 回复
v.hdel(key, fields)               // (R, Int64)
v.hexists(key, field)             // (R, Bool)
v.hlen(key)                       // (R, Int64)
v.hkeys(key)                      // (R, Array[String])
v.hvals(key)                      // (R, Array[String])
v.hgetall(key)                    // (R, Array[(String, String)])

// 列表
v.lpush(key, values)              // (R, Int64) — 新长度
v.rpush(key, values)              // (R, Int64)
v.lpop(key)                       // (R, Reply) — 头部,或 null 回复
v.rpop(key)                       // (R, Reply) — 尾部,或 null 回复
v.lrange(key, start, stop)        // (R, Array[String])
v.llen(key)                       // (R, Int64)
v.lindex(key, index)              // (R, Reply) — 或 null 回复
v.lset(key, index, value)         // (R, String) — "OK"

// 集合
v.sadd(key, members)              // (R, Int64) — 加进去几个
v.srem(key, members)              // (R, Int64) — 移除了几个
v.smembers(key)                   // (R, Array[String])
v.sismember(key, member)          // (R, Bool)
v.scard(key)                      // (R, Int64)
```

缺键不是错误。答案可以为空的那些门——`get`、`hget`、`lpop`、`rpop`、`lindex` 以及 `mget` 的元素——返回回复树本身,缺席经 `is_null?()` 读取。服务器的错误回复(`-WRONGTYPE …`、`-ERR …`)是错误元组,`"valkey: "` 前缀加服务器原文,错误码骑在 reason 里,匹配得着。

## 回复:`Reply` 树

`v.command(args)` 与携带缺席的门回答一个 `Reply`——一个 interface,客户能收到的每种 RESP2 类型对应一个类。简单字符串与 bulk 字符串同为一类:线上画的那条区分线,调用者并不需要。

```emo
enum ReplyKind { rnull, rstring, rint, rarray }

interface Reply {
  def kind() ReplyKind
  def is_null?() Bool
  def as_string() String          // 仅 rstring;错型 raise
  def as_int() Int64              // 仅 rint
  def as_array() Array[Reply]     // 仅 rarray
}
```

`kind()` 与 `is_null?()` 不靠猜地分辨;`as_*` 访问器是调用者的断言——`get(key).as_string()` 只有在该键确实存着字符串时才是正确的代码——断言失败就 raise,json 的规矩。容器经 `is()` 窄化进具体类(`valkey.ReplyArray`),其上 `as_array()` 列出元素,字段随行。

```emo
case v.command(["OBJECT", "ENCODING", "greeting"]) {
  (R.error, why)      -> { println("refused: ${why}") }
  (R.ok, reply)       -> {
    if reply.is_null?() {
      println("nothing there")
    } else {
      println(reply.as_string())   // embstr
    }
  }
}
```

## 错误

分法是标准库自己的那套:预期失败是值,违规才 raise:

- **服务器拒绝一条命令**——`-WRONGTYPE`、`-ERR unknown command`、`-ERR wrong number of arguments`、`-MOVED`,对端以 `-` 应答的一切——是 `(R.error, "valkey: " + 服务器原文)`。
- **线上断掉**——连接被拒、截止时间到、服务器在回复中途关连接、协议解析不了的回复(未知的类型字节、畸形的计数、没有终止符的 bulk)——是错误元组;客户端自己发现的问题带 `valkey:` 前缀,传输层上报的带 `net` 自己的 reason。
- **调用者破坏契约**——`v.command([])`、`v.del([])`、`set_timeout` 的负 `timeout`——raise。这些是调用者自己的 bug,确定性且只在自己身上,不是线上的数据。

## 示例

`valkey_demo` 示例让整个命令面对一个迷你 RESP2 服务器跑全程——服务器就骑在同一个程序里,线上客户端的这半边和文件自己的服务器那半边对话,不需要任何外部进程:

```emo
require "valkey"
require "net"

const (R.ok, listener) = net.listen("127.0.0.1", 0)
// ...一个服务器进程在 listener 上 accept ...

case valkey.connect("127.0.0.1", listener.port(), 5.0) {
  (R.error, why) -> { println("connect failed") }
  (R.ok, v)      -> {
    case v.ping() {
      (R.error, why) -> { println("ping failed: ${why}") }
      (R.ok, pong)   -> { println(pong) }        // PONG
    }
    case v.set("greeting", "hola") {
      (R.error, why) -> { println("set failed: ${why}") }
      (R.ok, ok)     -> { println(ok) }          // OK
    }
    case v.get("greeting") {
      (R.error, why) -> { println("get failed: ${why}") }
      (R.ok, reply)  -> { println(reply.as_string()) }   // hola
    }
    v.close()
  }
}
```

## 限制

- **三个目标。** 包声明了 `targets = ["ocaml", "c", "typescript"]`;wasm、BEAM、riscv64 构建在解析期就会被拒绝。在 `c` 上 UDP 与 Unix 域 socket 仍被拒绝(继承自 `net`),名字只解析为 IPv4 地址。
- **只讲 RESP2。** 客户端说的是 Valkey 不经 `HELLO` 升级就应答的那套协议:不会收到 boolean、double、verbatim、map、set、push 回复,各扇门也不会去读它们。RESP3 的多出来的部分,等有需要它的门再说。
- **一条命令一个回复。** 无流水线,无事务(`MULTI`/`EXEC` 经 `command` 一条一条发),pub/sub 与阻塞命令不做类型化门——`command(args)` 什么都能发,但等不来的回复会在截止时间到时报错误元组。
- **无重连、无连接池。** 一个句柄一条连接,`close()` 说关才关;掉线就是错误元组,重连是调用者显式、可见的动作。
- **深层回复按嵌套层级递归**,与 `http` 包的 header 走读同一形状——嵌几千层的回复是敌意输入,正常服务器不会发。
- **回复以 String 承载。** 在 `ocaml` 与 `c` 上 String 就是字节串,任意字节的 bulk 载荷原样精确到达。在 `typescript` 上 String 是 JS 字符串——与 crypto 包在 Bytes 迁移之前记录的承载限制相同——非合法 UTF-8 的 bulk 载荷在此处有损解码。程序以文本持有的键和值在三个目标上都精确;请求侧的长度经 `to_bytes()`(UTF-8 编解码器)计算,所以多字节参数的 bulk 长度在所有目标上都是线上的真实字节数。
