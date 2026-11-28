# `emosh` shell 指南

`emosh` 是用 Emo 写的通用命令解释器，住在 `projects/emo-shell`——是一个程序，不是一个包。它读入行，切成词与算符，扩展环境变量，运行经 `dup2` 接线的逐段 fork 管道：经典 shell 的形状，从提示符到 exec 用同一门语言写成，骑在标准库自己的 `os` 表面上(`fork`、`execvp`、`waitpid`、`pipe`、`dup2`、环境变量、信号)加上做行读取的 `bufio`。

本指南覆盖各里程碑已落地的表面。写明的都是 shell 做的;没写的 shell 都不做——文末的边界清单就是诚实的列表。

## 构建与运行

```console
$ cd projects/emo-shell
$ emo build main.emo --target c -o emosh
$ ./emosh                    (终端上交互态)
$ ./emosh < script.esh       (脚本从 stdin 喂入)
$ ./emosh - < script.esh     (显式短横:同上,按名字说话)
$ ./emosh script.esh args    (脚本文件;args 是 $1、$2、…)
$ ./emosh -c "echo hi $1"    (单行,其状态即 shell 的状态)
```

不带参数时，模式由 fd 0 和 fd 2 是什么决定：两者都在终端上才有 `emosh> ` 提示符——提示符走 **stderr**，所以无论会话怎么跑，被重定向的 stdout 都保持干净。其余一律是逐行读取、无提示符的脚本。带脚本文件时，行来自文件，会话永不交互，文件后的参数成为位置参数;`-` 把同样的事按名字说给 stdin。`-c` 跑这一行——连接符照常——并以其状态离场;行后跟一个可选词则充作 `$0`，其余是 `$1`、`$2`、…(`emosh -c 'echo $0 $1' shell hello`)。`-c` 缺命令串以状态 2 拒绝，未知选项以状态 2 拒绝，打不开的脚本文件报 os reason 并以 127 离场。

shell 声明 `ocaml` 与 `c` 两个 target——`emo run main.emo` 在解释器下运行(文件之后的词作为程序的 `os.argv` 传入，shell 会把它们当自己的参数解析)，`fixtures/` 里的金测把两个 target 的输出逐字节钉死。

## 一行的生命周期

一行走 lex → parse → expand → execute，顺序固定;畸形行永远不会杀掉 shell(语言里没有 catch,shell 里也没有 raise)：reason 打到 stderr，状态变 2。

```
line     := item ( ";" item )* ";"?        (行尾的 `;` 无害)
and_or   := item ( "&&" | "||" item )*
item     := pipeline | compound | declaration
pipeline := command ( "|" command )*
command  := ( word | redirection )*
redirection := "<" | ">" | ">>" word | "N<" | "N>" | "N>>" word
             | "N>&M" | "N<&M" | ">&M" | "<&M"
compound := "if" list "{" list "}" [ "else" ( if | "{" list "}" ) ]
          | "while" list "{" list "}"
          | "for" "var" name "=" expr ";" expr ";" expr "{" list "}"
          | "def" name "(" ")" "{" list "}"
declaration := ("const" | "var") name "=" word
```

条目之后的 `&` 把它送进后台——`a | b &` 是一个作业，`while … } &`
也是，见下文。控制流说 Emo 的话：大括号块，没有 `then`/`fi`/`do`/
`done` 终结关键字。关键字(`if`、`while`、`for`、`def`、`const`、
`var`)只在命令可以出现的位置、且是裸的未引用词时才被认出;`{` 与
`}` 作为独立词是保留的——字面大括号请加引号。

## 词与引号

一个词是行被切开后的那些部件;引号在词法期解决，并作为一个标记记住——因为后面有两条规则在乎字符从哪来：被引的 `~` 还是波浪号，被引的 `*` 还是星号：

- 裸文本可扩展——`$var`、`$?`、词首 `~`、glob 字符在这里生长;
- `'单引号'` 是字面，逐字节——什么都不扩展，转义不生效，内部不可能出现 `'`;
- `"双引号"` 可扩展——`$var` 生长，`\$` `\"` `` \` `` `\\` 转义自身;其余反斜杠原样保留;
- 引号外的反斜杠把下一字节转成字面——**裸的行尾反斜杠续行**，交互态以 `> ` 提示下一行(被双引号落在行尾的 `\\` 同样把引号伸到下一行;未闭合的单引号照旧拒绝);
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
- `${var:-word}` —— 已设且非空时取值，否则取 `word`(word 也会扩展;不支持嵌套花括号——第一个 `}` 就终结了形态)。
- `$?` —— 上一条命令的退出状态。
- `$0` —— shell 启动时的名字：裸跑是程序名，脚本模式是脚本路径，`-c` 模式是行后给的那个词(给了才算)。
- `$1` … `$9` 与 `${N}` —— 位置参数：脚本文件的参数或 `-c` 的参数，越界为空。
- `$#` —— 位置参数的个数。
- `$@` —— 位置参数各自成词，一个都没有时整个消失——但前提是形态独占整个词(`"$@"` 或裸 `$@`);混进其他文本(`x$@`)保持字面，严格性规则守着"一个扩展后的词是一个参数"。
- `$$` —— shell 自己的进程 id。
- `$!` —— 最后一个后台作业的 pid;还没有后台作业时是空串。
- 裸写、未加引号的词首 `~` —— `$HOME`;未设置时波浪号原样保留(`~user` 不是这里的形态，被引的波浪号 stays 波浪号)。

规则叫不出名字的 `$` 形态保持字面——整个形态，而不只是那个美元符：`${1x}` 就按文本 `${1x}` 运行。同样的诚实也适用于词里在形态之前就带了个 `}` 的情况：`a}b${SETV}c` 里的 `${SETV}` 照样扩展。

**扩展之后没有词切分。** 一个扩展后的词永远是一个参数——装着空格的变量原样整体传递，换来的诚实代价是完全没有字段切分。扩展的结果也永不 glob——哪什么才 glob，见下一节。

## glob

裸写、不在任何引号里的 `*`(任意一串字符)与 `?`(恰好一个字符)把一个词变成它匹配的那些名字，排序输出：

```console
$ cd projects/emo-shell/fixtures && echo *.esh
defaults.esh errors.esh flow.esh globs.esh pipes.esh redirs2.esh redirs.esh words.esh
```

规则写明，免得意外：

- 被引的文本永不 glob——`echo "*.emo"` 打印 `*.emo`，扩展产生了 `*` 也保持字面;glob 读的是每个字符从哪来;
- 模式按路径段行走：`src/*.emo` 列 `src` 留匹配;列不动的目录静默出局;末段对文件与目录一视同仁;
- 段首的 `.` 才匹配隐藏名;没有它隐藏名保持隐藏，`.` 与 `..` 永不出现;
- **无匹配拒绝该命令**——`emosh: no matches: *.zzz`，状态 1——因为拿着模式当字面参数跑下去，只会把这一手遮过去;
- 重定向目标只有一个名字，不 glob。

## 重定向与管道

`<` 把命令的 stdin 接到文件，`>` 把 stdout 写进文件(创建或截断)，`>>` 追加——每个描述符都有同样的权利：`N<` / `N>` / `N>>` 把描述符 `N` 对准文件(`2>` 是它们日常的脸面)，`N>&M` / `N<&M` 把描述符 `N` 对准 `M` 已去的地方，`>&M` 与 `<&M` 免去数字直说 stdout 与 stdin(`>&2` 是经典的"输出到 stderr")。每个文件都在命令即将运行前打开，在 fork 子进程里。数字只有当整个裸词恰是这个数字时才算描述符：`echo hi 2> log` 收走错误，`echo hi2> log` 把 `hi2` 传给 `echo` 并重定向 stdout，经典的读法。顺序即语义：`cmd > f 2>&1` 双双进 `f`，`cmd 2>&1 > f` 的 stderr 留在 stdout 原来的地方。纯重定向的命令也是命令：`> log` 截断 `log`，`2> log` 照样清空。

管道逐段 fork 子进程，经管道接线：`a | b` 让 `a` 的 stdout 骑在管道上、`b` 的 stdin 骑在管道上。管道的退出状态取最后一段。管道里遇到的内建与其他一切一样，在 fork 子进程里运行——`exit` 在其中结束的是那个子进程，不是会话，经典的读法。

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

`;` 无条件分隔，`&&` 仅成功才运行下一条，`||` 仅失败才运行。被跳过的条目状态向前承接，所以经典行为如预期：

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

信号死亡按 `128 + 信号` 计，即内核自己的编码、由 `os.wait_signal` 解码的那个。`exit` 接可选状态(无参取最后一个)，经内核低字节折叠——`exit 300` 剩 44，`exit -1` 剩 255——非数字参数拒绝并置状态 2。脚本的退出状态是最后一条命令的;交互态输入结束同样带着最后状态离场。

## 控制流与声明

流程形态是 Emo 自己的——大括号块、数值 `for`、声明关键字——在
Emo 放语句的地方运行 shell 命令列表：

```console
$ var who = "shell"
$ const greeting = "hello"
$ echo $greeting $who
hello shell
```

- `const NAME = WORD` 绑定一个变量;重声明已冻结的名字——用
  `const`、`var` 或 `unset`——会拒绝(`NAME: is a constant`)。
  `var NAME = WORD` 同样绑定;再 `var` 覆盖值。值的读法有两种：带引号
  的部分绑定其扩展文本拼成的一个词(`$x` 会长;glob 不动：声明的值
  不做 glob);裸的一串按整数表达式求值(`var acc = acc + i`)。
  `$NAME` 先读声明的绑定再读环境，`unset` 两者都除。
- `NAME = EXPR` 重赋已声明的绑定——循环体里的 `n = n - 1`、`for`
  body 里的 `acc = acc + i`。值的读法与声明相同。未声明的名字拒绝
  (`NAME: is not declared`——绑定只经 `var` 与 `const` 打开)，
  已冻结的拒绝重赋(`NAME: is a constant`)。
- 命令位的裸词与比较符串，当头部指已声明的绑定、以数字开头、或
  是开括号时，就是表达式语句——shell 对 emo repl 的自己的读法：
  `var s = 0` 之后的 `s + 1` 打印 `1`，`2 * 3` 打印 `6`，
  `( 2 + 3 ) * 2` 打印 `10`，比较式答 1 或 0;整数字面量与绑定的值
  都可带前导负号(`-5`，沉过零的计数器)。单独一个名字原样答
  它绑定的值，字符串或数字 alike——`const c = "foo"` 之后的 `c`
  打印 foo;只有更长的串才要求数字。内建与函数的名字
  保持命令(`echo hi` 永不求值)，引号头部强制命令读法
  (`'git' status`);比较符在普通命令里作普通词骑行
  (`grep == hi` 真跑 grep，`echo a == b` 原样打印)。会话自己的
  名字压过 PATH 的命令，管道的一段也可以是值的生产者
  (`g | tr a-z A-Z`)。
- `if LIST { LIST } else { LIST }` 与 `while LIST { LIST }`——条件
  有两种形态。**命令列表**：以其最后命令的退出状态决定(0 继续)。
  **数值比较**：`if s > 5 { … }`、`if s == 3 && s < 10 { … }`——当
  条件里的每个 token 都是裸词或比较/布尔运算符、且出现比较符时，
  它按整数表达式求值，读声明的绑定与环境(`$i` 形也按值读入)。
  无 `else` 且条件为假时答 0;`else` 可链 `else if … { … }`，解析
  期压平为嵌套。
- `while` 同上：条件命令列表成功即运行 body;零轮答 0。
- `for var I = EXPR; I < EXPR; I = I + EXPR { LIST }`——数值 for，
  Emo 自己的形：头的三个表达式是裸变量名上的整数算术(`$#` 也可
  计入)，循环变量是每轮赋值的声明绑定、循环后恢复原值，步进按头
  写的 `I = I + EXPR` 赋值。

`break` 与 `continue` 离开或步进循环;`return [n]` 离开函数——
各自在不属于它的地方拒绝(`break: only in a loop`、
`return: only in a function`)。

```console
$ def greet() {
  echo greet:$1
}
$ greet world
greet:world
$ for var i = 1; i <= 3; i = i + 1 {
  echo tick $i
}
tick 1
tick 2
tick 3
$ var n = 2
$ while n > 0 {
  echo n=$n
  n = n - 1
}
n=2
n=1
$ echo final=$n
0
```

块可以在一行打开、数行之后闭合——shell 以 `>` 要下一行，直到大
括号配平，与行尾反斜杠续行同一机制。body 里定义的声明与函数都是
会话自己的(没有局部变量)，`for` 的变量在循环离开后恢复原值。

## 后台任务

管道之后的 `&` 让它后台运行：`sleep 5 &` 拉起作业就继续走——拉起是否成功就是该条目的状态，拉起本身就是分隔符(`a & b` 随即运行 `b`)。作业取最小空位号，`$!` 应答它的 pid。

shell 在每个提示符前轮询自己的作业;完成的作业得到它的一行——`[1] done sleep 5`，非零时状态跟在 `done` 之后——然后离开作业表。后台作业运行在自己独立的进程组里，终端的 Ctrl-C 只瞄准 shell 的组，永远够不到它;前台命令保持经典纪律，该被 Ctrl-C 杀死时就那样死。

| 内建 | 行为 |
|---|---|
| `jobs` | 先轮询一次，再列仍在运行的：`[1] 4821 running sleep 5` |
| `fg %n` | 泊车等完该作业的整条管道;以其状态作答 |
| `bg %n` | 这里没有任何东西会停——`emosh: bg: job 1 already in background` |
| `wait [%n]` | 等那一个，或等全部;未知作业是 127 |
| `kill [-N] target...` | 给 pid 发信号，`%n` 打整组(缺省 15) |

诚实的边界，写明：`fg` 只是等——没有终端交接调用，作业保有自己的进程组，Ctrl-C 够不到被这样带回来的作业;后台作业的 stdin 仍是 shell 的(没有 `/dev/null` 重定向——两个作业抢读是用户自己的事);shell 离场时把仍在运行的作业留在身后，与脚本的 shell 一致。

```console
$ sleep 5 &
$ jobs
[1] 4821 running sleep 5
$ kill %1
$ echo status=$?
0
```

## 行编辑器

交互会话读入走 shell 自己的行编辑器——raw 模式、历史、补全，以 Emo 写在 os 终端层(`os.tty_raw`/`os.tty_restore`)之上。每次读入期间终端进 raw，该行运行之前退回熟模式：你敲的键如实到达，跑的命令活在经典终端上。

- 按键：方向键移动、↑/↓ 走历史，Backspace 与 Delete 按整字符擦除(UTF-8 续字节逐一走查)，Home/End 跳转，Ctrl-A 与 Ctrl-E 到行首行尾，Ctrl-K 抹到行尾，Ctrl-U 抹全行，Ctrl-W 抹光标前一个词，空行上 Ctrl-D 结束会话，Tab 补全;
- 历史：↑ 召回本会话与之前会话敲过的行——最近 1000 条写进 `EMO_STATE_DIR` 下的 `emosh-history`，否则 `$XDG_STATE_HOME/emo`，否则 `$HOME/.local/state/emo`，会话结束时一次写盘：并发会话的后写者赢下文件，硬杀丢掉其后的输入(repl 自己的那份诚实);
- 补全：Tab 把光标下的词补到所有候选的公共前缀，第二次 Tab 在行下一行列出它们。行首词按命令补全——内建、会话函数、然后 PATH 所服务的每条命令;后继词按工作目录的文件名补全。给词加引号打消补全，与引号打消关键字同一道理;
- `EMOSH_ASSUME_TTY` 让编辑器的按键与渲染跑在管道上、跳过 raw 模式——编辑器自己的金测由此驱动，测试里脚本化一段编辑会话也走这条路。

## 内建

| 内建 | 行为 |
|---|---|
| `cd [dir]` | 换目录;无参取 `$HOME` |
| `pwd` | 打印工作目录 |
| `echo args...` | 词间一空格连接，末尾一换行 |
| `exit [n]` | 以状态 `n` 离开 shell |
| `export NAME=VALUE` | 设入环境;子进程继承 |
| `unset NAME` | 从环境移除 |
| `true` | 状态 0 |
| `false` | 状态 1 |
| `help` | 打印 shell 的内建命令 |

`export` 与 `unset` 改的是真环境，shell 此后 fork 的每条命令都继承：

```console
$ export GREET=hi
$ printenv GREET
hi
$ unset GREET
$ printenv GREET
$ echo status=$?
1
```

`echo` 无旗标——词，逐字，一换行。`cd` 到不存在的目录会报 os reason 并把状态留在 1。

## 错误

错误行先带 shell 名，再带命令名——经典形状：

```console
$ no-such-command
emosh: no-such-command: command not found   (状态 127)
$ ./nonexec-script
emosh: ./nonexec-script: os: execvp: Permission denied   (状态 126)
$ echo x > /no/such/dir/f
emosh: os: open /no/such/dir/f: No such file or directory   (状态 1)
$ echo dangling |
emosh: syntax error: unexpected end of line    (状态 2)
$ echo stray 2>&x
emosh: syntax error: bad descriptor redirection    (状态 2)
$ echo *.nope
emosh: no matches: *.nope                      (状态 1)
$ ./emosh -z
emosh: unknown option: -z                      (状态 2)
$ ./emosh ./no-such-script.esh
emosh: os: open ./no-such-script.esh: No such file or directory   (状态 127)
```

交互态遇到任何一个都继续;脚本也一样继续——只在你说停的地方(`&&`、`exit`)或输入结束处停。

## 信号

shell 在一切模式下忽略 `sig_pipe`(写进死管道不能杀解释器)，交互态再忽略 `sig_int` 与 `sig_quit`：Ctrl-C 丢弃当前行——终端自己的线路规程负责冲行——shell 存活。每个 fork 子进程在 exec 前恢复默认处置，前台命令该被 Ctrl-C 杀死时就那样死。

一行正在输入时，编辑器以 raw 模式持有终端、自己读 Ctrl-C：当前行被废弃，shell 以全新提示符再问——半输入的字节永远到不了命令。真正在跑的命令保持经典纪律(命令运行期间终端是熟模式)，该被 Ctrl-C 杀死时就那样死。

## 诚实的边界

契约，写明免得猜：

- 没有 `case`、`until`、`select`、`[[`，for 头之外没有算术括号;
- 复合命令不进管道(`if … } | cat` 拒绝)，也没有词表迭代
  (`for x in words`——for 只有数值形);函数调用不带重定向;
- 位置参数到头就到头：只有 `$1` … `$9`、`${N}`、`$#` 与 `$@`——无 `shift`，无 `$*`;声明与赋值的值都是一个词;
- 后台任务有了，但终端不谈判：`fg` 只是等，Ctrl-C 够不到它带回来的作业(终端交接调用——`tcsetpgrp`——是等着落地的 os 半边);这里没有任何东西会停作业，`bg` 恒答 `already in background`;后台作业的 stdin 仍是 shell 的;
- 编辑器一次只编辑一行：未闭合块的 `>` 续行单独编辑，↑ 召回的是单行、不是整块;超过一行终端宽度的行会折行，单行重画会糊;补全的 PATH 候选按目录枚举顺序到达，无排序、无模糊匹配;
- 扩展后无 IFS 字段切分;
- 无 `~user`，无嵌套 `${…}` 形态，无不带冒号的 `${var-word}`;
- 无子 shell 括号、无 here-doc、无 trap、无别名;
- dup 形态把一个描述符对准另一个——不做关闭(`N>&-` 拒绝)，`<>`(读写)也不是这里的形态。

这些底下的 os 表面(进程组、`WNOHANG`、stat 家族)就是里程碑点名时活要去的地方。

## 与标准库的关系

`emosh` 是 `os` 包完整表面的示范工程——fork 纪律、`dup2`、`execvp`、环境、信号——以及 `bufio` 行读取的示范工程。shell 发起的每个调用，参考 `docs/stdlib/os.md`。
