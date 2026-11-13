# Emo Playground

访客在浏览器里写 Emo 代码、在服务器上运行它的 web 应用:一个编辑页面、
一组示例下拉、一个 Run 按钮,答案就在下方。它是 [`projects/emo-playground/`](.)
下自己的项目——用 Emo 写成,由 Emo 自己的 `httpd` 服务,把提交交给 Emo
自己的解释器运行。

## 一次运行如何发生

一次提交就是一个新目录加一个子进程:

1. `POST /api/run` 携带 `{"code": "..."}`——一个 JSON 请求体,由服务器的
   body 预算封顶在 64 KiB。
2. 运行引擎把代码写成 `runs/` 下一个新目录里的 `main.emo`,旁边是一份把
   标准库的托管包固定为依赖的 manifest——于是 `require "json"`、
   `require "os"` 们都能解析,而解析门自己的错误就是访客看到的一切其余
   包的拒绝(`dom`、裸金属和仅 FFI 的包刻意不在这个名单上)。
3. 两根管道、一次 fork、一次 exec:子进程的 stdin 是 `/dev/null`,工作目录
   就是那个新目录,stderr 是运行目录里的一个文件(`stderr.txt`——文件永远
   不会阻塞写它的人),运行 `emo run main.emo --curfew N`——N 来自服务器的
   配置。子进程先把自己挪进自己的进程组,并在 exec 之前 fork 一个看门狗:
   另一个解释器,运行 tick 程序(服务器启动时写在运行目录旁的一个纯打转
   程序),curfew 是运行的加一个余量。
4. 父进程关掉自己的管道写端,然后一个收集进程把 stdout 排到 EOF,应答的
   连接停在 `receive` 里等它完成。越过 1 MiB 输出预算的流照常排空——沉默
   的生产者永远不可能把子进程卡死在写满的管道上——但只保留预算之内的
   部分,原位放一个截断标记。stderr 的文件在子进程被 reap 之后读。
5. 裁定从裸 wait 状态解出:`ok`、`compile`(退出码 65/66——静态阶段)、
   `curfew`(退出码 124,和 `timeout(1)` 的答案同一个数)、`crash`(其余
   一切,信号死亡渲染为 128 加信号号)、`internal`(退出码 127——exec 本身
   没有发生)。答案是一份 JSON 文档:`status`、`exit`、`curfew`、`stdout`、
   `stderr`。
6. 运行目录被清扫;它的不存在就是目标。

进程组纪律关掉了 fork 逃逸口:一次提交里 fork 出来、滞留不走的进程会握着
管道写端越过它父进程的死亡,收集进程永远看不到 EOF——答案会一直挂着,
直到服务器重启。子进程 fork 出来的一切都在同一个组里,宿主上没有别人属于
它;看门狗的 curfew 一过,解释器的受委派击杀(`EMO_RUN_GROUP`)就交给
工具链:整个组在那个时刻结束,写端随它关闭,答案到达。余量保证子进程自己的
裁定(0、65、66、124)先于击杀,也覆盖卡死在系统调用里的运行子进程——它
自己的 curfew 永远够不到它。

运行的绝对路径从不抵达访客——诊断里写的是 `main.emo`,而工具链的
lockfile 提示(写进一个即将被清扫的目录)从答案里被擦掉。

## curfew

失控的 `while true {}` 必须结束,而 Emo 没有时钟——slog 自己的文件头记录着
这个决定。所以时钟住在工具链里:`emo run --curfew SECONDS` 把一个墙钟截止
交给这一次解释执行,每 65,536 步检查一次。过了截止,运行以退出码 124 结束,
stderr 带着裁定,页面把它说出来。`--target` 的产物不使用 curfew,而
`--curfew` 搭配 `--target` 会被拒绝:这个标志只管解释器自己的运行。

## 信任模型

curfew 约束解释器的 CPU;它不做隔离。用户代码带着解释器的全部库面在宿主
机器上运行:它能读写文件、fork 进程、打开网络连接。已定的缓解是每次运行的
新目录、stdin 来自 `/dev/null`、body 和输出预算、curfew、以及进程组纪律:
一次提交 fork 出来的一切都在同一个组里,宿主上没有别人属于它,看门狗的
curfew 会结束整个组(P2.1)——提交不可能通过一个留下的进程活过自己的
curfew。真正的公开部署仍然需要一个自己的边界——容器或专用用户——作为
[P2.2](docs/TASKS.md) 追踪。

## 配置

每个旋钮都是一个带既定默认值的环境变量,启动时读一次;格式不对的值让程序
当场停下,消息里点出变量名。

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `PG_HOST` | 绑定地址 | `127.0.0.1` |
| `PG_PORT` | 绑定端口 | `8080` |
| `PG_EMO` | runner exec 的 `emo` 二进制 | PATH 上的 `emo` |
| `PG_CURFEW` | 运行的 curfew,整秒,1..120 | `5` |
| `PG_WEB_DIR` | 静态资产目录 | `web` |
| `PG_RUNS_DIR` | 运行目录的创建处 | `runs` |

## 运行它

在项目目录下(manifest 的树就是模块树,资产和示例从旁边的磁盘读):

```console
$ emo run main.emo
playground serving http://127.0.0.1:8080 — curfew 5.0s
```

然后在浏览器打开这个地址,或者用手敲它:

```console
$ curl -s -X POST -d '{"code":"println(\"hello\")"}' http://127.0.0.1:8080/api/run
{"status":"ok","exit":0,"curfew":5.0,"stdout":"hello\n","stderr":""}
```

## 测试它

```console
$ emo test
```

24 个测试:引擎直接驱动——一个已知程序的字节、一个点名 `main.emo` 的编译
错误、curfew、输出预算的截断、被清扫的目录、fork 逃逸口的答案在 curfew 加
余量时到达、被看门狗停下的卡死运行——加上按 web 服务器指南自己的测试
方式驱动的路由,以及一个走内核挑选端口的线上测试。## 布局

```
package.emo        manifest:托管包,以及测试套件自己的依赖
main.emo           入口:一份 Config,tick 程序,一个 listener,等待
config.emo         环境旋钮,启动时校验
server.emo         listener 和路由表
handlers.emo       路由:页面、资产、示例、/api/run
runner.emo         运行引擎:管道、fork、exec、看门狗、收集、清扫
web/               页面(index.html、style.css、app.js)
web/examples/      下拉加载的程序
test/              测试套件:test_runner.emo、test_web.emo
```

本 README 的中文版就在本文件;英文原版是
[`README.md`](README.md)。
