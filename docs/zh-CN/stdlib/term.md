# `term` 包

标准库的终端输入表面:按行读取、raw mode、解码后的按键事件,以及终端尺寸——全部作用在 stdin(文件描述符 0)上。它是标准库里第二个原生绑定包:调用是 `foreign def`,绑定到包自带的一小段 C shim;包声明 `targets = ["c"]`。构建会自己编译这段 shim,使用方只需普通 `require`,不用传任何标志。

解释器拒绝外来代码(E3009),其他 target 在解析阶段就拒绝这个包,所以 `emo run` 跑不了触碰它的程序;用 `emo build`(默认 target 就是 `c`)。

## 使用这个包

```emo
require "term"
```

标准库随编译器发布,但它的包和别的包一样带版本:`require "term"` 需要在 manifest 的 `deps` 里写 `"term" = "0.1.0"`。

## 错误

遵循标准库的约定,失败的调用返回 `(R.ok, value)` 或 `(R.error, reason)`;reason 是一个以包名开头的 String,并点明操作——`term: enable_raw: not a terminal`、`term: size: Inappropriate ioctl for device`。输入结束不是错误:`read_line` 返回 `""`,`read_key` 返回 `Key.eof`。

## 按行读取

```emo
def read_line() (R, String)
```

从 stdin 读一行,**保留行终止符**——和 `bufio` 一样的选择,这样空行(`"\n"`)与输入结束(`""`)永远不会是同一个答案。最后一行没有终止符时按原样返回。含内嵌 NUL 的 String 会在那里截断,和每个 C 边界一样。

## 终端与尺寸

```emo
def is_tty() Bool
def size() (R, (Int64, Int64))
```

`is_tty` 在 stdin 是终端时为真。`size` 从终端驱动取 `(列, 行)`;stdin 不是终端(或驱动报不出尺寸)时返回 `(R.error, reason)`。

## Raw mode

```emo
def enable_raw() (R, Int64)
def restore() (R, Int64)
```

`enable_raw` 把 stdin 切到 raw mode:字节不缓冲、不回显,Ctrl-C 与 Ctrl-Z 是按键而不是信号。切换前设置会被保存;`restore` 恢复它。两者成功时都返回 `(R.ok, 0)`。`enable_raw` 是幂等的,raw mode 关闭时 `restore` 什么也不做。

进程退出时会自动恢复保存的设置,所以没有显式 `restore` 就返回的程序也会把终端留在可用状态。不走出退出路径就结束进程的信号(`SIGKILL`,或程序尚未处理的 `SIGTERM`)绕过这一步;恢复手段是 shell 的 `reset` 命令。

## 按键事件

```emo
enum Key {
  char, ctrl, enter, tab, back_tab, backspace, escape,
  up, down, left, right, home, end, insert, delete,
  page_up, page_down,
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  alt, unknown, eof
}

def read_key() (R, (Key, Int64))
```

`read_key` 阻塞等待下一个按键,返回枚举成员和一段 code:

| 成员 | code |
|---|---|
| `char` | 字符的 Unicode 标量值(按 UTF-8 解码) |
| `ctrl` | Ctrl-@ 到 Ctrl-Z,记为 `0`–`26` |
| `alt` | 紧随其后的 ASCII 字节值(控制键为 `1`–`26`) |
| `unknown` | 未解码的转义序列的最后一个字节 |
| `eof` | `0` |
| 其他成员 | `0` |

Raw mode 让按键按下即到达;不开 raw mode 时终端自己的行规程仍然生效,`read_key` 看到的是整行。只有在 raw mode 开着时,Ctrl-C 才以 `Key.ctrl`、code `3` 的形式交给程序。

解码器识别终端为方向键、Home/End、Insert/Delete、Page Up/Page Down、F1–F12、Shift-Tab 与 Alt+按键发送的序列。Esc 之后 50 毫秒内没有下一字节就是 `Key.escape`——区分单个 Esc 与序列开头,这是终端的惯例做法。修饰键参数(`Esc [ 1 ; 5 A` 之类)会被接受并忽略:表面暂时没有修饰位,所以 Ctrl-Up 读作 `Key.up`。鼠标报告、bracketed paste 与焦点事件不解码;它们以 `Key.unknown` 到达。

## 边界与限制

- **只读 stdin。** 包读文件描述符 0,也就是 TUI 绘制的那个终端。读第二个终端,或由调用方指定文件描述符,不在范围内。
- **Unix 终端。** 包只支持 `c` target,使用 POSIX termios;Windows 控制台不是目标。
- **没有 resize 事件。** `size()` 按需回答当前尺寸;SIGWINCH 接线是 UI 框架的下一步,不属于这个包。
- **Esc 的时序。** Esc 之后那 50 毫秒的等待是包里唯一的时序。远程或很慢的终端若把一个转义序列的字节拆得比这更开,就会先看到 `Key.escape`,再看到剩下的字节。

## 示例

```emo
require "term"

def main() {
  const (R.ok, _) = term.enable_raw()
  var more = true
  while more {
    const (R.ok, key) = term.read_key()
    case key {
      (term.Key.ctrl, 3) -> { more = false }
      (term.Key.enter, _) -> { println("enter") }
      (term.Key.char, code) -> { println("char ${code}") }
      _ -> {}
    }
  }
  term.restore()
}
```

可运行的示例是 `examples/term_demo`,它一直按行读到输入结束。
