# `sync` 包

标准库的协调包:wait group(等待组)——一个一次性的倒计数,让一
个进程等待 N 份工作完成。纯 Emo 写在进程原语之上——等待组就是一
个持有计数的进程,`done` 是一条消息,`wait` 是另一条——所以包所
声明的每个目标都回答相同的可观察行为,这里没有任何东西需要改动编
译器。

等待组是"等我的工人干完"的消息传递答案,也就是 Go 用
`sync.WaitGroup` 解决的那个形状,只不过用 actor 的方式拼写。它刻
意**不是**共享内存原语——Emo 没有可守卫的共享内存(消息是快照拷
贝),这正是包里没有 mutex 的原因:mutex 守卫内存,而这里没有可守
的内存。等待组什么也不守卫:它只计数。

## 使用包

```emo
require "sync"
```

`require` 与清单严格配对:`sync` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    sync = "0.1.0"
  }
}
```

等待组是每个目标都实现了的进程原语之上的纯消息传递,所以清单声明
全部五个目标。

## 接口面

```emo
def wait_group(n Int64) Pid
def done(wg Pid) Void
def wait(wg Pid) Void
def stop(wg Pid) Void
```

`wait_group` 启动一个 `n` 份工作的倒计时,回答组的 pid——其余每个
调用都以它为句柄。`done` 宣告一份工作完成;`wait` 阻塞到计数清
零,若已清零则立即返回;`stop` 结束计数进程。

扇出/扇入的形状:

```emo
const wg = sync.wait_group(3)  // 三份工作在前
do worker(wg)                  // ……每个以 sync.done(wg) 收尾
do worker(wg)
do worker(wg)
sync.wait(wg)                  // 第三次 done 时返回
sync.stop(wg)
```

多个进程可以在同一个组上 `wait`,每个都会被唤醒。零计数的组生而清
零:它的 `wait` 立即返回。

## 生命周期

计数在 `wait_group` 时一次性设定,只减不增:等待组是一次性的,没
有 `add`。计数进程在清零后泊车——迟到的 `wait` 仍然得到回答,迟
到的 `done` 仍然在调用方抛出——而一个永久泊车的进程会把整个程序吊
住,所以生命周期显式收尾:`stop` 结束计数进程,此刻仍泊在组上的
`wait` 会在其调用方抛出,而不是永远悬挂。守则很朴素:在最后一次
wait 之后 stop 掉组。

## 严格性

超出计数的 `done` 不会无声消失——这个调用会与计数进程往返一趟并
抛出,把调用方的错误在调用方点破,而不是任它沉进计数进程的信箱。
(被 `stop` 抢跑的调用——计数进程已经不在——像任何发给死进程的
消息一样丢弃。)`wait_group` 拒绝负数计数。

## 错误

- `sync: the count must not be negative, got -2` ——
  `wait_group` 的计数为负;
- `sync: the countdown already drained` ——超出计数的 `done`;
- `sync: the wait group was stopped under the wait` ——`stop`
  落下时仍泊着的 `wait`。

## 协议

线上双向的每一条消息都是打上 `"sync"`——包名——标签的元组,所以
等待组的流量永远不会撞上应用自己的消息:发往计数进程的是
`("sync", "dec", from)` 与 `("sync", "wait", from)`,回来的是
`("sync", "ok")`、`("sync", "underflow")`、`("sync", "drained")` 和
`("sync", "stopped")`。调用方永远看不到这些;写出来是因为信箱是公
共场所,一个隐藏线格的协议,在两个库共享一个进程信箱时是无法推理
的。

## 金样

金样(`examples/sync_demo`)覆盖扇出/扇入、同一组上的多个等待
者、零计数三种情形——在解释器、ocaml、c、typescript、wasm、beam
上逐字节一致。
