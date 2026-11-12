# `emosh` shell 指南

`emosh` 是用 Emo 写的通用命令解释器,住在 `projects/emo-shell`——是一个程序,不是一个包。它读入行,切成词与算符,扩展环境变量,运行经 `dup2` 接线的逐段 fork 管道:经典 shell 的形状,从提示符到 exec 用同一门语言写成,骑在标准库自己的 `os` 表面上(`fork`、`execvp`、`waitpid`、`pipe`、`dup2`、环境变量、信号)加上做行读取的 `bufio`。

本指南覆盖 v0 表面。写明的都是 shell 做的;没写的 shell 都不做——文末的边界清单就是诚实的列表。

## 构建与运行

```console
$ cd projects/emo-shell
$ emo build main.emo --target c -o emosh
$ ./emosh                (交互态)
$ ./emosh < script.esh   (脚本从 stdin 喂入)
```

模式由 fd 0 是什么决定:终端拿到 `emosh> ` 提示符,其余一律是逐行读取、无提示符的脚本。shell 声明 `ocaml` 与 `c` 两个 target——`emo run main.emo` 在解释器下运行,`fixtures/` 里的金测把两个 target 的输出逐字节钉死。

## 一行的生命周期

一行走 lex → parse → expand → execute,顺序固定;畸形行永远不会杀掉 shell(语言里没有 catch,shell 里也没有 raise):reason 打到 stderr,状态变 2。

```
line     := and_or ( ";" and_or )* ";"?
and_or   := pipeline ( "&&" | "||" pipeline )*
pipeline := command ( "|" command )*
command  := ( word | redirection )*
redirection := "<" | ">" | ">>" word
```

## 词与引号

一个词是行被切开后的那些部件,引号在词法期解决,不留记忆:

- 裸文本可扩展——`$var`、`$?`、词首 `~` 在这里生长;
- `'单引号'` 是字面,逐字节——什么都不扩展,转义不生效,内部不可能出现 `'`;
- `"双引号"` 可扩展——`$var` 生长,`\$` `\"` `` \` `` `\\` 转义自身;其余反斜杠原样保留;
- 引号外的反斜杠把下一字节转成字面;
- 词首的 `#` 注释到行尾;
- 空引号串仍构成一个词(`touch ''` 会 touch)。

```console
$ export NAME=world
$ echo $NAME
world
$ echo 'single $NAME stays'
single $NAME stays
$ echo "double $NAME expands"
double world expands
$ echo \$NAME-literal
$NAME-literal
```

## 扩展

- `$var` / `${var}` —— 变量的值;未设置为空。
- `$?` —— 上一条命令的退出状态。
- `$0` —— shell 启动时的名字。
- 未引号词首的 `~` —— `$HOME`;未设置时波浪号原样保留(`~user` 不是这里的形态)。

**扩展之后没有词切分。** 一个扩展后的词永远是一个参数——装着空格的变量原样整体传递,换来的诚实代价是完全没有字段切分。也没有 glob。

## 重定向与管道

`<` 把命令的 stdin 接到文件,`>` 把 stdout 写进文件(创建或截断),`>>` 追加——每个文件都在命令即将运行前打开,在 fork 子进程里。纯重定向的命令也是命令:`> log` 截断 `log`。

管道逐段 fork 子进程,经管道接线:`a | b` 让 `a` 的 stdout 骑在管道上、`b` 的 stdin 骑在管道上。管道的退出状态取最后一段。管道里遇到的内建与其他一切一样,在 fork 子进程里运行。

```console
$ printf 'b\na\nc\n' | sort
a
b
c
$ echo first > f.txt
$ echo second >> f.txt
$ cat < f.txt
first
second
```

## 连接符与状态

`;` 无条件分隔,`&&` 仅成功才运行下一条,`||` 仅失败才运行。被跳过的条目状态向前承接,所以经典行为如预期:

```console
$ false && echo no || echo rescued
rescued
$ true
$ echo status=$?
0
$ false
$ echo status=$?
1
```

信号死亡按 `128 + 信号` 计,即内核自己的编码、由 `os.wait_signal` 解码的那个。`exit` 接可选状态(无参取最后一个),经内核低字节折叠——`exit 300` 剩 44,`exit -1` 剩 255——非数字参数拒绝并置状态 2。脚本的退出状态是最后一条命令的;交互态输入结束同样带着最后状态离场。

## 内建

| 内建 | 行为 |
|---|---|
| `cd [dir]` | 换目录;无参取 `$HOME` |
| `pwd` | 打印工作目录 |
| `echo args...` | 词间一空格连接,末尾一换行 |
| `exit [n]` | 以状态 `n` 离开 shell |
| `export NAME=VALUE` | 设入环境;子进程继承 |
| `unset NAME` | 从环境移除 |
| `true` | 状态 0 |
| `false` | 状态 1 |

`export` 与 `unset` 改的是真环境,shell 此后 fork 的每条命令都继承:

```console
$ export GREET=hi
$ printenv GREET
hi
$ unset GREET
$ printenv GREET
$ echo status=$?
1
```

`echo` 无旗标——词,逐字,一换行。`cd` 到不存在的目录会报 os reason 并把状态留在 1。

## 错误

错误行先带 shell 名,再带命令名——经典形状:

```console
$ no-such-command
emosh: no-such-command: command not found      (状态 127)
$ echo x > /no/such/dir/f
emosh: os: open /no/such/dir/f: No such file or directory   (状态 1)
$ echo dangling |
emosh: syntax error: unexpected end of line    (状态 2)
$ echo stray &
emosh: syntax error: & is not supported yet    (状态 2)
```

交互态遇到任何一个都继续;脚本也一样继续——只在你说停的地方(`&&`、`exit`)或输入结束处停。

## 信号

shell 在一切模式下忽略 `sig_pipe`(写进死管道不能杀解释器),交互态再忽略 `sig_int` 与 `sig_quit`:Ctrl-C 丢弃当前行——终端自己的线路规程负责冲行——shell 存活。每个 fork 子进程在 exec 前恢复默认处置,前台命令该被 Ctrl-C 杀死时就那样死。

cooked 模式下,Ctrl-C 之后要等下一行完成才会再见到提示符;行编辑器(raw 模式、历史、补全)是下一个里程碑的活,不是这一个的。

## 诚实的边界

v0 契约,写明免得猜:

- 无控制流——没有 `if`、`while`、`for`,没有函数;
- 无 glob、无 `~user`、无 `${var:-default}` 形态、无 `$1` 位置参数;
- 无后台任务——`&` 按名拒绝;
- 无行编辑器——终端自己的 cooked 模式读入;无历史,无补全;
- 扩展后无 IFS 字段切分;
- 无子 shell 括号、无 here-doc、无 trap、无别名。

这些底下的 os 表面(进程组、`WNOHANG`、stat 家族)就是里程碑点名时活要去的地方。

## 与标准库的关系

`emosh` 是 `os` 包完整表面的示范工程——fork 纪律、`dup2`、`execvp`、环境、信号——以及 `bufio` 行读取的示范工程。shell 发起的每个调用,参考 `docs/stdlib/os.md`。
