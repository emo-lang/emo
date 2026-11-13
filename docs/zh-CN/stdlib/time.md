# `time` 包

标准库的时钟:操作系统的墙钟和单调时钟由三个运行时门承载,包里其
余的一切都是这些读数之上的纯 Emo。一个时刻是一个 `Time`——字段用
纯 Emo 计算的不可变值;差距是普通的 `Int64` 毫秒;定时家族
(`sleep`、`after`、`tick`)让进程泊车,和调度器泊其他一切的方式一
样。能在 golden 里钉住的部分,在包声明的每个目标上都逐字节相同。

## 使用包

```emo
require "time"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "time"` 需要在 manifest 的 `deps` 块里钉上 `"time" = "0.1.0"`。

## 单位

- **一个时刻是 UTC 纪元毫秒的 `Time`。** `Int64` 毫秒是每个宿主目
  标的墙钟都诚实具备的最粗分辨率(Node 的 `Date.now` 钉住了下
  限),而且越过任何值得关心的日期都还在 Int64 之内。`Time` 是不可
  变的类值:内容相等的两个实例 `==`,跨进程边界和其他类值一样以快
  照拷贝传递。
- **时长是普通的 `Int64` 毫秒。** 没有包装类型——包想要的算术就是
  每个目标都有的算术。转换家族(`time.seconds(2)`、`time.days(3)`
  ……)扮演常量的角色,`t.add(ms)` 移动一个时刻。
- **定时家族说秒**,和 `net` 的超时一样:`time.sleep(0.25)` 是四分
  之一秒,`time.tick(3) { ... }` 是每三秒。区间截断到整毫秒——包
  诚实的下限——其余的拒绝,而且拒绝得很响。

## 错误

本包抛出,不回答错误元组:它能产生的每种失败都是调用方自己参数的
契约违约。负的或非有限的区间、越过 1e9 秒上限的区间,抛出
`Exception`,点名调用和取值;格式排版畸形,抛出并点名字节。时钟门
本身不会失败——读数总在。

## 时钟

```emo
def now() Time
def of_ms(ms Int64) Time
def of(year Int64, month Int64, day Int64, hour Int64, minute Int64, second Int64, ms Int64) Time
def mono() Int64
```

`now()` 读操作系统的墙钟,UTC。`of_ms` 和 `of` 构造一个固定时刻——
日历构造函数是纯算术(Hinnant 的 days_from_civil),所以
`time.of(year: 2026, month: 11, day: 13, ...)` 在每个目标上、在
golden 里,都指同一个时刻。

`mono()` 读单调时钟——一个永不回退的读数,是流逝测量所骑的仪器。
墙钟会跳;这个不会。两次读数直接相减:

```emo
const start = time.mono()
run_the_thing()
println(time.mono() - start)   // 流逝的纳秒
```

单位是纳秒;分辨率是目标自己的(原生目标是 `clock_gettime`,Node
是 `hrtime`,wasm 和浏览器是 `performance.now()`,BEAM 是
`monotonic_time`)。

## `Time`

```emo
def unix_ms() Int64
def add(ms Int64) Time
def before?(other Time) Bool
def after?(other Time) Bool

def year() Int64            // UTC 日历字段
def month() Int64           // 1..12
def day() Int64             // 1..31
def hour() Int64            // 0..23
def minute() Int64          // 0..59
def second() Int64          // 0..59
def millisecond() Int64     // 0..999
def weekday() Int64         // 0 星期日 .. 6 星期六
def epoch_days() Int64      // 自纪元起的整天数,向下取整
def format(layout String) String
def format_iso() String
def format_http() String
```

每个字段都是毫秒读数之上的纯算术,所以答案在每个目标上都相同。
`add` 接收带符号的毫秒——负数向回走。默认渲染(`to_string`、插
值)是 ISO 形式。

日历**永远是 UTC**。本地时区是目标自己的虚构——同一个进程在不同
机器上打印不同的日期——所以包不携带它;UTC 的答案才是可复现的
那个。

## 格式化

`t.format(layout)` 从左到右走排版。九个记号,其余逐字节的字面量:

| 记号 | 渲染 | 示例 |
|---|---|---|
| `YYYY` | 年,补零到四位 | `2026` |
| `MM` | 月,补零 | `11` |
| `DD` | 日,补零 | `13` |
| `hh` | 时,补零 | `08` |
| `mm` | 分,补零 | `30` |
| `ss` | 秒,补零 | `15` |
| `mmm` | 毫秒,补零到三位 | `123` |
| `Mmm` | 月份的英文短名 | `Nov` |
| `Www` | 星期的英文短名 | `Fri` |

```emo
const t = time.of(year: 2026, month: 11, day: 13, hour: 8, minute: 30, second: 15, ms: 123)
println(t.format("YYYY-MM-DD hh:mm:ss"))   // 2026-11-13 08:30:15
println(t.format("Www, DD Mmm YYYY"))      // Fri, 13 Nov 2026
println(t.format_iso())                    // 2026-11-13T08:30:15.123Z
println(t.format_http())                   // Fri, 13 Nov 2026 08:30:15 GMT
```

排版严格,不是 Go 的参考时间:没有需要背的魔法日期,也没有猜测。
字母 `Y M D h m s` 是记号字母——一个没拼成完整记号的,是畸形的排
版,抛出并点名字节和排版的其余部分(`time: unknown layout token at
byte 27: MT`)。字面的大写 M 需要走预设或者字符串拼接——
`format_http` 的结尾 ` GMT` 正是因此拼在排版语法之外。超过四位的
年份整位打印;负年份在补零的绝对值前面打印负号。

`format_iso()` 是带毫秒和 `Z` 后缀的 RFC 3339。`format_http()` 是
IMF-fixdate,HTTP `Date` 头的形式。

## 差距

```emo
def since(t Time) Int64
def ms_between(a Time, b Time) Int64
def seconds_between(a Time, b Time) Float64
def minutes_between(a Time, b Time) Int64
def hours_between(a Time, b Time) Int64
def days_between(a Time, b Time) Int64
```

每个都回答 `b - a`,带符号:`b` 是较早时刻时为负。`since(t)` 从
`t` 量到墙钟的现在——所以时钟调整会显形;这是墙钟自己的诚实。要
一个永不跳动的测量,取两次 `mono()` 读数相减。

`*_between` 家族截断:90 秒是 0 分钟,1 小时是 0 天。
`seconds_between` 回答 `Float64`——毫秒自己的小数——其余是
Int64。日历日的差距(UTC 的午夜到午夜)在 24 小时计数不是调用方
想要的时候,从字段读。

## 转换

```emo
def milliseconds(n Int64) Int64
def seconds(n Int64) Int64
def minutes(n Int64) Int64
def hours(n Int64) Int64
def days(n Int64) Int64
def weeks(n Int64) Int64
```

乘成毫秒的普通乘法——常量的角色。喂给 `add` 和直接收毫秒的门:

```emo
println(launch.add(time.hours(25)).format("YYYY-MM-DD hh:mm:ss"))
// 2026-11-14 09:30:15
```

## 定时家族

```emo
def sleep(seconds Float64) Void
def after(seconds Float64, f Block) Void
def tick(seconds Float64, f Block) Void
```

`sleep(seconds)` 把调用进程泊车一个区间。这是真正的泊车:进程离开
运行队列,其他进程轮流上场,调度器在期限唤醒它。睡眠期间到达的消
息排队进邮箱,等唤醒——睡眠不会被提前唤醒。

`after(seconds, f)` 把块在自己的进程里跑一次,一个区间之后。调用
方立即继续;块自己的抛出只杀它自己的进程。没有取消——区间就是这
次排定运行的整个契约。

```emo
time.after(0.5) {
  println("半秒之后")
}
```

`tick(seconds, f)` **在调用进程里每个区间跑一次块,永远——心跳。
它从不返回。** 块自己的抛出或 `halt()` 就是停止,心跳程序里 tick
之后的代码是永远走不到的代码。这是 Go `time.Tick` 自己的纪律
("它不提供任何办法在启动之后停止它");`after` 是它旁边的排定单发。

```emo
// 三次 tick,然后心跳自己结束
def heart(total Int64, owner Pid) Void {
  const count = Box.new(0)
  time.tick(0.05) {
    count.replace(count.read() + 1)
    println("tick ${count.read()}")
    if count.read() == total {
      owner <- ("demo", "done")
      halt()
    }
  }
}

do heart(3, self_pid())
receive {
  ("demo", "done") -> { println("心跳结束了") }
}
```

`tick` 里的块在心跳进程里运行——那里的 `halt()` 结束心跳进程,程
序没有它继续走。

**调用方该知道的下限。** 区间截断到整毫秒:`time.sleep(0.0009)`
是一毫秒的睡眠。每个目标自己的计时器上限是第二层下限——Node 把单
个计时器钳在 2³¹−1 毫秒(约 24.8 天;运行时分片重排,契约在它之上
仍成立)——睡眠的真实长度永远不小于区间,绝不会更短。1e9 秒上限
(约 31 年)是包自己的,越过即抛出。

## 目标

`["ocaml", "c", "typescript", "wasm", "beam"]`。时钟半在包声明的每
个目标上运行——在 `wasm` 上经由两个宿主导入(`time_now_ms`、
`time_mono_ns`)。定时半在 `wasm` 上于调用处抛出,点名能力:wasm
驱动在一次宿主调用内同步跑完整个程序,在驱动学会 await 之前没有诚
实的泊车——`os` 包的进程半是先例。`riscv64` 不声明:裸金属内核有自
己的 tick。`browser` 目标也不声明——浏览器程序的定时是页面自己的
计时器——不过 TypeScript 的浏览器宿主已经带着这些门,以后声明它只
是包自己的 manifest 改动,不是编译器的。

## 参考

- 演示:`examples/time_demo`——从字段构造的固定时刻、每个格式记
  号、日历字段、between 家族、转换、一次睡眠前后的 `mono`、以
  `halt` 收尾的三次 tick、一次 `after`——在解释器、ocaml、c、
  typescript、beam 上逐字节相同。
- 定案记录:`CHECK.md`(`time` 条目)与
  `plan/step-81-stdlib-time.md`。
