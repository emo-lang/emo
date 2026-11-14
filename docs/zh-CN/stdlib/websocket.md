# `websocket` 包

构建在 `net` 之上的纯 Emo WebSocket 双半(RFC 6455):客户端用 `connect` 拨号,服务端用 `accept` 接下一条已接受的连接,双方在同一个 `Websocket` 上会合,交换单位是一条文本消息。帧是传输层的事,留在这层屋顶之下——客户端发出前加掩码、收到带掩码的帧即拒绝,服务端对两条规矩各执一 mirrors;ping 用原载荷应答,不请自来的 pong 跳过,close 帧被应答并终结消息流;对端拆成多帧的消息在 `recv_message` 应答前先拼回整条。

目标:`["ocaml", "c", "typescript"]`(构建在 `net`、`base64`、握手指纹用的 `crypto`、帧掩码用的 `rand` 之上)。参考:[`docs/zh-CN/stdlib/websocket.md`](stdlib/websocket.md) · 示例:`examples/websocket_demo`。

## 引入

`require "websocket"`,manifest 里钉住包与其传递依赖:

```emo
deps {
  "net" = "0.1.0"
  "websocket" = "0.1.0"
}
```

## 拨号与接下

```emo
websocket.connect(host, port, path, timeout)          // (R, Websocket) —— 校验 accept
websocket.connect_insecure(host, port, path, timeout) // (R, Websocket) —— 跳过这一项校验
websocket.accept(conn)                                // (R, Websocket) —— 服务端门
```

`connect` 走 TCP 拨号、发出升级请求、并拿自己发出的 key 校验 accept 头——这是对端真讲这套协议的唯一证明。path 必须以 `/` 开头(否则是调用方的错,直接 raise)。`connect_insecure` 是同一趟拨号只跳过这一项校验,给那些 accept 根本不派生自客户端 key 的对端——playwright 的 `run-server` 应答的 accept 它自家客户端从不校验——tls_connect_insecure 的规矩:名字说出没校验的是什么。`accept` 读取升级请求,除非它确实请求升级、写明版本 13、并带上 key,否则拒绝;随后应答 `101`,交还服务端的这一侧。timeout 约束拨号与其后每一次交换(net 的每操作期限);`0.0` 表示无限等待。

## 消息面

```emo
ws.send_text(data)      // (R, Websocket) —— 一条文本消息出去
ws.recv_message()       // (R, String) —— 下一条进来,分片已拼回
ws.set_timeout(seconds) // 由此往后的每操作期限
ws.close()              // (R, Websocket) —— 一个 close 帧,然后关套接字
```

`recv_message` 顺路处理遇见的控制帧:ping 用原载荷应答,不请自来的 pong 跳过,close 帧被应答、套接字关闭、并在 reason 里点名这个终结。对端的 close 读过之后,`close` 应答的便是套接字自己的拒绝——同一个终结,读了两遍。二进制帧按名拒绝:这套包服务的协议都讲文本。

## 错误

标准库的三分法。被拒的握手、该带掩码却裸来的帧、超期的期限、离去的对端——每一个都是值 `(R.error, reason)`,reason 说出到底哪里坏了:包自己发现的原因带 `websocket:` 前缀,传输层的原因保留 net 原文。调用方的错——少了开头 `/` 的 path——直接 raise。

## 示例

一个程序,两半,回环打通——`examples/websocket_demo` 逐字节钉死的形状:

```emo
const (R.ok, listener) = net.listen("127.0.0.1", 0)
do echo_serve(listener)                  // accept,然后回声直到对端关闭

case websocket.connect("127.0.0.1", listener.port(), "/", 5.0) {
  (R.error, why) then { println("connect failed: ${why}") }
  (R.ok, ws)     then {
    case ws.send_text("hello 回环") {
      (R.error, why) then { println("send failed: ${why}") }
      (R.ok, _)      then {
        case ws.recv_message() {
          (R.error, why) then { println("recv failed: ${why}") }
          (R.ok, back)   then { println(back) }
        }
      }
    }
  }
}
```

## 限制

- 三个目标:与 `net` 同一道闸(WASI preview1 没有套接字)。`typescript` 上套接字是 Node 的;帧路径在所有目标上是同一份 Emo 代码,逐字节一致。
- 只讲文本帧。二进制帧按名拒绝。
- 无扩展、无 permessage-deflate、无子协议。
- 对端把一条消息拆进超过 4096 个分片即拒绝,不硬骑。
- 握手两头各自至多走 200 行头。
