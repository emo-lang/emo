# `playwright` 包

纯 Emo 的 Playwright 客户端:经 `websocket` 包对着官方 `playwright run-server` 讲驱动的通道协议,驱动浏览器。net 表面上的直接风格——每一次调用都像其他套接字活一样把进程停在调度器上。线路永不因驱动数据 raise:被拒的调用是值 `(R.error, "playwright: " + 驱动原文)`,线路故障是带 websocket 或 net 原因的值,只有调用方自己的错才 raise。

```emo
playwright.connect(host, port, timeout)            // (R, Playwright) —— chromium
playwright.connect_with(name, host, port, timeout) // (R, Playwright) —— firefox、webkit
pw.browser()        // Browser —— 服务端为本连接预 launch 的那个
pw.close()          // (R, Playwright) —— 挂断;服务端随之收走浏览器

browser.new_page()  // (R, Page)
browser.version()   // (R, String)
browser.close()     // (R, Browser)

page.goto(url)      // (R, PageResponse) —— 先 is_null?(),再 status() 与 url()
page.click(sel)     // (R, Page)
page.fill(sel, t)   // (R, Page)
page.press(sel, k)  // (R, Page)
page.title()        // (R, String)
page.content()      // (R, String)
page.text_content(sel)  // (R, Text) —— 先 is_null?(),再 as_string()
page.screenshot()   // (R, Bytes) —— PNG,从驱动的 base64 里解出
page.close()        // (R, Page)
```

目标:`["ocaml", "c", "typescript"]`(构建在 `websocket`、`json`、`base64` 之上)。参考:[`docs/zh-CN/stdlib/playwright.md`](stdlib/playwright.md) · 示例:`examples/playwright_demo`。

## 引入

`require "playwright"`,manifest 里钉住包:

```emo
deps {
  "websocket" = "0.1.0"
  "playwright" = "0.1.0"
}
```

## 连接

先起一个 driver——本包是客户端:

```sh
npx playwright run-server --port 9933
```

然后 `playwright.connect("127.0.0.1", 9933, 5.0)`。run-server 在连接到达时启动浏览器并随握手交付——浏览器名骑在端点的 `?browser=` 查询参数上(`connect_with("firefox", ...)` 发 `/?browser=firefox`),客户端自己从不 launch 任何东西。initialize 握手从驱动沿途介绍的对象里钉住根 Playwright 通道与预 launch 的浏览器;应答落下之后,`pw.browser()` 即已就绪。timeout 约束每一次交换;`0.0` 表示无限等待。

## 门面

每一扇等页面的门都在调用的 metadata 里携带预算——驱动自己的 30000 ms 默认值,也是驱动真正读取的每调用死线字段(metadata 不带 timeout 就等于没有死线:页面永远遇不到的选择器会把驱动的应答无限期吊住)。

`goto` 应答这次导航赢得的响应——它的 `status()` 与 `url()`——或者导航什么也没赢得时的 null 响应(`about:blank`、data url);`is_null?()` 分开两种情形,json 的读法。`text_content` 应答一个 `Text`:选择器没匹配到元素不是错误,而是经 `is_null?()` 读取的 null 文本——valkey 的 null 回复,同一读法。`click`、`fill`、`press` 把 page 原样交还,门面可见地串联;调用方留空的 selector 或 key 是调用方的错,直接 raise。

`screenshot()` 要一张 PNG,把驱动的 base64 应答解进 `Bytes`。`typescript` 上适用 base64 包自带的 String 载体规则:PNG 是任意字节,该目标上诚实的读法是从构造上就精确的字母表取道——base64 天然精确,`ocaml` 与 `c` 上解码逐字节精确。

## 错误

三分法,valkey 的规矩:驱动拒绝调用是 `(R.error, "playwright: " + 驱动的消息)`(dispatcher 自己的包裹已拆开);线路故障——期限、关闭、服务端离去——是带 websocket 或 net 原因的值;调用方的错 raise。引擎永不因驱动数据 raise:畸形消息是 reason,不是崩溃。

## 示例

`examples/playwright_demo` 拿本仓库自带的迷你 driver 跑完整门面——一个照真线形应答的假 `run-server`,真 websocket 帧上分片消息、ping、八字节长度形态一应俱全,金测不需要浏览器也不需要 Node。金测逐字节钉死整个往返。

`examples/playwright_live` 是真机检查:真 `run-server` 驱动真 headless chromium,页面由程序自己经 `httpd` 在本地提供——版本、导航、标题、DOM 文本、一张截图、缺失选择器应得的超时错误。它不进任何金测名单(需要安装与在跑的 driver),手工运行;验证过的 driver 版本记在 `CHECK.md`。

## 限制

- 三个目标:与 `websocket` 同一道闸。
- 驱动的协议是驱动自己的,不是公开标准;本包照驱动此刻的讲法跟线,并如实记录验证过的版本,而不是许诺一个永远的版本号。**对照 playwright 1.65.0(chromium 158.0.8127.18,macOS arm64)真机验证,整条阶梯在 `c` 目标上跑通。** 本文钉住的形状:run-server 的预 launch(`denyLaunch`)、`?browser=` 选择、根通道上的 initialize 握手、`new_page` 的先 context 后 page 两跳(browser 通道自己没有 page 门)、metadata 携带的每调用死线、以及上面的门面方法。
- 驱动的服务端应答的 WebSocket accept 并非派生自客户端 key(它自家的客户端从不校验),所以拨号走 `websocket.connect_insecure`——这里的协议证明是 initialize 握手本身。
- 驱动发出的事件(导航、加载、控制台)被吸收或跳过;v1 没有事件门面。`__create__` 与 `__dispose__` 有处理——对象表骑在它们身上。
- 无 context、无 locator 语义、无 `evaluate`、无落盘截图、无下载、无 tracing。上面那些门就是全部面。
- `typescript` 的那条注意随 `base64.decode` 自带的载体走。
