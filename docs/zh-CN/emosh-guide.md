# `emosh` shell 指南

`emosh` 是用 Emo 写的通用命令解释器,住在 `projects/emo-shell`——是一个程序,不是一个包。它读入行,切成词与算符,扩展环境变量,运行经 `dup2` 接线的逐段 fork 管道:经典 shell 的形状,从提示符到 exec 用同一门语言写成,骑在标准库自己的 `os` 表面上(`fork`、`execvp`、`waitpid`、`pipe`、`dup2`、环境变量、信号)加上做行读取的 `bufio`。

本指南覆盖各里程碑已落地的表面。写明的都是 shell 做的;没写的 shell 都不做——文末的边界清单就是诚实的列表。

## 构建与运行

```console
$ cd projects/emo-shell
$ emo build main.emo --target c -o emosh
$ ./emosh                    (终端上交互态)
$ ./emosh < script.esh       (脚本从 stdin 喂入)
$ ./emosh script.esh args    (脚本文件;args 是 $1、$2、…)
$ ./emosh -c "echo hi $1"    (单行,其状态即 shell 的状态)
```

不带参数时,模式由 fd 0 是什么决定:终端拿到 `emosh> ` 提示符,其余一律是逐行读取、无提示符的脚本。带脚本文件时,行来自文件,会话永不交互,文件后的参数成为位置参数。`-c` 跑这一行——连接符照常——并以其状态离场;行后跟一个可选词则充作 `$0`,其余是 `$1`、`$2`、…(`emosh -c 'echo $0 $1' shell hello`)。`-c` 缺命令串以状态 2 拒绝,未知选项以状态 2 拒绝,打不开的脚本文件报 os reason 并以 127 离场。

shell 声明 `ocaml` 与 `c` 两个 target——`emo run main.emo` 在解释器下运行,`fixtures/` 里的金测把两个 target 的输出逐字节钉死。

## 一行的生命周期

一行走 lex → parse → expand → execute,顺序固定;畸形行永远不会杀掉 shell(语言里没有 catch,shell 里也没有 raise):reason 打到 stderr,状态变 2。

```
line     := and_or ( ";" and_or )* ";"?
and_or   := pipeline ( "&&" | "||" pipeline )*
pipeline := command ( "|" command )*
command  := ( word | redirection )*
redirection := "<" | ">" | ">>" word | "2>" | "2>>" word | "2>&1"
```

管道之后的 `&` 把整个条目送进后台——`a | b &` 是一个作业,见下文。

## 词与引号

一个词是行被切开后的那些部件;引号在词法期解决,并作为一个标记记住——因为后面有两条规则在乎字符从哪来:被引的 `~` 还是波浪号,被引的 `*` 还是星号:

- 裸文本可扩展——`$var`、`$?`、词首 `~`、glob 字符在这里生长;
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
- `${var:-word}` —— 已设且非空时取值,否则取 `word`(word 也会扩展;不支持嵌套花括号——第一个 `}` 就终结了形态)。
- `$?` —— 上一条命令的退出状态。
- `$0` —— shell 启动时的名字:裸跑是程序名,脚本模式是脚本路径,`-c` 模式是行后给的那个词(给了才算)。
- `$1` … `$9` 与 `${N}` —— 位置参数:脚本文件的参数或 `-c` 的参数,越界为空。
- `$$` —— shell 自己的进程 id。
- `$!` —— 最后一个后台作业的 pid;还没有后台作业时是空串。
- 裸写、未加引号的词首 `~` —— `$HOME`;未设置时波浪号原样保留(`~user` 不是这里的形态,被引的波浪号 stays 波浪号)。

规则叫不出名字的 `$` 形态保持字面——整个形态,而不只是那个美元符:`${1x}` 就按文本 `${1x}` 运行。同样的诚实也适用于词里在形态之前就带了个 `}` 的情况:`a}b${SETV}c` 里的 `${SETV}` 照样扩展。

**扩展之后没有词切分。** 一个扩展后的词永远是一个参数——装着空格的变量原样整体传递,换来的诚实代价是完全没有字段切分。扩展的结果也永不 glob——哪什么才 glob,见下一节。

## glob

裸写、不在任何引号里的 `*`(任意一串字符)与 `?`(恰好一个字符)把一个词变成它匹配的那些名字,排序输出:

```console
$ cd projects/emo-shell/fixtures && echo *.esh
defaults.esh errors.esh flow.esh globs.esh pipes.esh redirs2.esh redirs.esh words.esh
```

规则写明,免得意外:

- 被引的文本永不 glob——`echo "*.emo"` 打印 `*.emo`,扩展产生了 `*` 也保持字面;glob 读的是每个字符从哪来;
- 模式按路径段行走:`src/*.emo` 列 `src` 留匹配;列不动的目录静默出局;末段对文件与目录一视同仁;
- 段首的 `.` 才匹配隐藏名;没有它隐藏名保持隐藏,`.` 与 `..` 永不出现;
- **无匹配拒绝该命令**——`emosh: no matches: *.zzz`,状态 1——因为拿着模式当字面参数跑下去,只会把这一手遮过去;
- 重定向目标只有一个名字,不 glob。

## 重定向与管道

`<` 把命令的 stdin 接到文件,`>` 把 stdout 写进文件(创建或截断),`>>` 追加,`2>` 与 `2>>` 把 stderr 照同样规矩对准文件——每个文件都在命令即将运行前打开,在 fork 子进程里。`2` 后面跟了 `>` 时,只有整个裸词恰是这个数字才算 stderr 重定向:`echo hi 2> log` 收走错误,`echo hi2> log` 把 `hi2` 传给 `echo` 并重定向 stdout,经典的读法。`2>&1` 让 stderr 跟随 stdout 已去的地方,顺序即语义:`cmd > f 2>&1` 双双进 `f`,`cmd 2>&1 > f` 的 stderr 留在 stdout 原来的地方。纯重定向的命令也是命令:`> log` 截断 `log`,`2> log` 照样清空。

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
$ nosuch-cmd 2> err.txt
$ cat err.txt
emosh: nosuch-cmd: command not found
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

## 后台任务

管道之后的 `&` 让它后台运行:`sleep 5 &` 拉起作业就继续走——拉起是否成功就是该条目的状态,拉起本身就是分隔符(`a & b` 随即运行 `b`)。作业取最小空位号,`$!` 应答它的 pid。

shell 在每个提示符前轮询自己的作业;完成的作业得到它的一行——`[1] done sleep 5`,非零时状态跟在 `done` 之后——然后离开作业表。后台作业运行在自己独立的进程组里,终端的 Ctrl-C 只瞄准 shell 的组,永远够不到它;前台命令保持经典纪律,该被 Ctrl-C 杀死时就那样死。

| 内建 | 行为 |
|---|---|
| `jobs` | 先轮询一次,再列仍在运行的:`[1] 4821 running sleep 5` |
| `fg %n` | 泊车等完该作业的整条管道;以其状态作答 |
| `bg %n` | 这里没有任何东西会停——`emosh: bg: job 1 already in background` |
| `wait [%n]` | 等那一个,或等全部;未知作业是 127 |
| `kill [-N] target...` | 给 pid 发信号,`%n` 打整组(缺省 15) |

诚实的边界,写明:`fg` 只是等——没有终端交接调用,作业保有自己的进程组,Ctrl-C 够不到被这样带回来的作业;后台作业的 stdin 仍是 shell 的(没有 `/dev/null` 重定向——两个作业抢读是用户自己的事);shell 离场时把仍在运行的作业留在身后,与脚本的 shell 一致。

```console
$ sleep 5 &
$ jobs
[1] 4821 running sleep 5
$ kill %1
$ echo status=$?
0
```

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
$ echo stray 2>&11
emosh: syntax error: only 2>&1 is supported    (状态 2)
$ echo *.nope
emosh: no matches: *.nope                      (状态 1)
$ ./emosh -z
emosh: unknown option: -z                      (状态 2)
$ ./emosh ./no-such-script.esh
emosh: os: open ./no-such-script.esh: No such file or directory   (状态 127)
```

交互态遇到任何一个都继续;脚本也一样继续——只在你说停的地方(`&&`、`exit`)或输入结束处停。

## 信号

shell 在一切模式下忽略 `sig_pipe`(写进死管道不能杀解释器),交互态再忽略 `sig_int` 与 `sig_quit`:Ctrl-C 丢弃当前行——终端自己的线路规程负责冲行——shell 存活。每个 fork 子进程在 exec 前恢复默认处置,前台命令该被 Ctrl-C 杀死时就那样死。

cooked 模式下,Ctrl-C 之后要等下一行完成才会再见到提示符;行编辑器(raw 模式、历史、补全)是下一个里程碑的活,不是这一个的。

## 诚实的边界

契约,写明免得猜:

- 无控制流——没有 `if`、`while`、`for`,没有函数;
- 位置参数到头就到头:只有 `$1` … `$9` 与 `${N}`——无 `shift`,无 `$#`,无 `$@`;
- 后台任务有了,但终端不谈判:`fg` 只是等,Ctrl-C 够不到它带回来的作业(终端交接调用——`tcsetpgrp`——是等着落地的 os 半边);这里没有任何东西会停作业,`bg` 恒答 `already in background`;后台作业的 stdin 仍是 shell 的;
- 无行编辑器——终端自己的 cooked 模式读入;无历史,无补全;
- 扩展后无 IFS 字段切分;
- 无 `~user`,无嵌套 `${…}` 形态,无不带冒号的 `${var-word}`;
- 无子 shell 括号、无 here-doc、无 trap、无别名;
- `2>&` 里不是 `2>&1` 的一律拒绝;没有 `<&`、`>&`,`2>` 家族之外的 fd 号也没有。

这些底下的 os 表面(进程组、`WNOHANG`、stat 家族)就是里程碑点名时活要去的地方。

## 与标准库的关系

`emosh` 是 `os` 包完整表面的示范工程——fork 纪律、`dup2`、`execvp`、环境、信号——以及 `bufio` 行读取的示范工程。shell 发起的每个调用,参考 `docs/stdlib/os.md`。
