# playwright 快速上手

用 `playwright` 包驱动真实浏览器:启动 driver、连接、打开页面、取 DOM。下面每一步都是可运行代码。

先看一个关键点:**浏览器不是 Emo 启动的**。`playwright` 包是纯客户端,只经 websocket 对官方
`playwright run-server` 讲驱动的通道协议。浏览器的 launch 由 driver 在握手时完成,以
`preLaunchedBrowser` 交到 initialize 应答里(server 处于 `denyLaunch` 模式),客户端从不 launch 任何东西。

## 一、起一个 driver

```sh
npx playwright run-server --port 9933
```

默认引擎是 chromium,换引擎:

```sh
npx playwright run-server --port 9933 --browser firefox
```

## 二、引入包

`require "playwright"`,manifest 里钉住精确版本:

```emo
deps {
  "playwright" = "0.1.0"
  "dom" = "0.1.0"        // 要按 CSS 选择器查 DOM 时才需要
}
```

`emo deps add dom 0.1.0` 会把新包钉进 `package.emo` 并写入 `package.lock`。

## 三、流程

`连接 → browser() → new_page() → goto → 取内容 → close`

1. `playwright.connect("127.0.0.1", 9933, 30.0)` —— 拨号并完成 initialize 握手,得到
   `(R, Playwright)`。浏览器名骑在 `?browser=` 查询参数上,换引擎用
   `connect_with("firefox", host, port, timeout)`。
2. `pw.browser()` —— 取 driver 预先 launch 好的那个 Browser,不发起调用,直接返回对象。
3. `browser.new_page()` —— 内部先 `newContext` 再 `newPage`(browser 通道本身没有 page 门)。
4. `page.goto(url)` —— 导航答 `PageResponse`;`is_null?()` 为真表示这次导航没赢得响应
   (`about:blank`、data url)。
5. 取 DOM —— 见下一节。
6. 收尾 —— `page.close()`,然后 `pw.close()`。**不要调 `browser.close()`**:`pw.close()`
   挂断连接,server 随之收走浏览器。

```emo
require "dom"
require "playwright"

case playwright.connect("127.0.0.1", 9933, 30.0) {
  (R.error, why) -> { println("connect: ${why}") }
  (R.ok, pw)     -> {
    const browser = pw.browser()
    case browser.new_page() {
      (R.error, why) -> { println("new_page: ${why}") }
      (R.ok, page)   -> {
        case page.goto("https://example.com") {
          (R.error, why) -> { println("goto: ${why}") }
          (R.ok, resp)   -> {
            if !resp.is_null?() {
              println("${resp.status()} ${resp.url()}")
            }
          }
        }
        case page.content() {
          (R.error, why) -> { println("content: ${why}") }
          (R.ok, html)   -> {
            case dom.parse(html) {
              (R.error, why) -> { println("parse: ${why}") }
              (R.ok, doc)    -> {
                case doc.find("h1") {
                  (R.error, why) -> { println("find: ${why}") }
                  (R.ok, hits)   -> {
                    println("h1 count: ${hits.length()}")
                    println("h1 text: ${hits.text()}")
                  }
                }
              }
            }
          }
        }
        case page.close() {
          (R.error, why) -> { println("close: ${why}") }
          (R.ok, _)      -> {}
        }
      }
    }
    case pw.close() {
      (R.error, why) -> { println("close: ${why}") }
      (R.ok, _)      -> {}
    }
  }
}
```

## 四、取 DOM 的两条路

- **单个元素的文本**:`page.text_content("#hello")` 答 `Text`。选择器没匹配到元素**不是错误**,
  而是经 `is_null?()` 读的 null 文本(valkey 的 null 回复,同一读法),真值再 `as_string()`。
- **整页 DOM / 结构化查询**:`page.content()` 答序列化后的整页 HTML,交给 `dom` 包解析——
  `dom.parse(html)` 得到 `Document`,`Document.find(sel)` 得到 `Selection`,再走
  `text()`、`attr()`、`attr_or()`、`html()`、`find()` 等 goquery 形状的门。

`playwright` 包本身没有 `evaluate`、没有 locator、没有事件回调,所以"查 DOM"的能力全部来自
`dom` 包,而 `dom` 只能看见 `content()` 那一份已渲染的 HTML 字符串。`dom.parse` 是严格解析
(标签必须闭合、文本里的裸 `&` 和 `<` 拒绝、不合成 `html`/`head`/`body` 骨架),`content()`
的输出通常满足;不满足时答 `(R.error, reason)` 并带字节位置,不 raise。

## 五、错误的三分法

- driver 拒绝调用:值 `(R.error, "playwright: " + 驱动原文)`;
- 线路故障(期限、关闭、服务端离去):值 `(R.error, websocket/net 原因)`;
- 调用方自己的错(空选择器、空 key、未知浏览器名):raise。

引擎永不因驱动数据 raise;畸形消息是 reason,不是崩溃。

## 六、注意事项

- **跑在 `c` target 上。** CHECK.md 记录:解释器的 det 调度器在"驱动调用挂起 + 通道有数据"时
  会踩到 parked read 的 EBADF,同一阶梯在 `c` runtime 上逐字节全绿。`emo build main.emo`
  (默认 c)产出原生可执行文件后运行;交付前的真机验证也是在这条路径上做的。
- **每门调用都带 30 秒死线。** 页面永远遇不到的选择器等满预算后以 driver 的超时错误返回,
  不会把进程永久吊住;`connect` 的 timeout 约束每一次交换,`0.0` 表示无限等待。
- **v1 的面就这些**:`goto`、`click`、`fill`、`press`、`title`、`content`、`text_content`、
  `screenshot`、`close`。contexts、locator 语义、`evaluate`、事件门、下载、tracing 都还没有。
- 协议是 driver 自己的,不是公开标准;本包照 driver 此刻的讲法跟线(对照 playwright 1.65.0
  / chromium headless shell 158.0.8127.18 真机验证)。

## 参考

- 包概览与限制:[`docs/zh-CN/stdlib/playwright.md`](stdlib/playwright.md) ·
  [`docs/stdlib/playwright.md`](../stdlib/playwright.md)
- 英文版:[`docs/playwright-get-started.md`](../playwright-get-started.md)
- 可跑的真机示例:`examples/playwright_live`(自己经 `httpd` 提供页面,手工运行)
- 不需要浏览器的金测示例:`examples/playwright_demo`(自带迷你 driver)
