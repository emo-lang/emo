# `file` 包

标准库的直接风格文件 IO:一次调用读入整个文件,一次调用写出整个
文件。调用跑在调度器上,磁盘慢时停驻的是调用进程而不是整个程序
——与 `net` 包对待套接字是同一种直接风格。

## 使用包

```emo
require "file"
```

标准库随编译器一起发布,但它的包和其他依赖一样带版本:`require "file"` 需要在 manifest 的 `deps` 块里钉上 `"file" = "0.1.0"`。本包声明 `ocaml` 和 `c` 两个目标,其他目标的构建会拒绝它。

## 接口

```emo
def read(path String) (R, String)
def write(path String, contents String) (R, Int64)
```

`read` 返回文件的字节,失败时返回 `(R.error, reason)`——reason 是
String,写明路径和内核的说法:
`file: cannot read notes.txt: No such file or directory`。

`write` 创建或截断该路径,写完全部 `contents` 字节,返回写入的字
节数——永远是全部,否则失败以错误元组返回。路径不可写时同理。

## 路径

路径按原样使用:相对路径相对进程的工作目录解析,工作目录由
`os.getcwd` 读取、`os.chdir` 改动。`file` 自己不做路径规范化,也不
做权限判断——内核说什么,reason 就说什么。

## 什么时候往下走

`file` 是一次性形态:整文件进,整文件出。任何流式、追加或需要缓
冲的场景,走 `os` 的裸描述符(`open_read`、`open_write`、
`open_append`、`read`、`write`、`close`),有助益时前面再架
`bufio`。

## 目标

`["ocaml", "c"]`——拥有 Unix 形态宿主的目标。示例
(`examples/file_read`)写一个文件、读回、覆盖、核对往返;golden
输出逐字节校验。
