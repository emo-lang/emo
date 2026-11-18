# `hash` 包

摘要自己的包:SHA-256 与 SHA-224——一次性或流式——常数时间比较,以及小写十六进制渲染。纯 Emo 写在 `Int64` 与 `Bytes` 上,每个目标应答同样的字节,引擎由 RFC 向量钉死。

它是 [`crypto`](crypto.zh-CN.md) 包 SHA-2 的机器孪生:引擎逐字携带于此,因为 crypto 的错误面(守卫用 raise)把 `riscv64` 目标整个拒掉——编译器还没有可在那里降低的 raise——而机器的锁只需要摘要,不需要其余的 crypto 世界。两个包钉同一组向量,钉即孪生的证明:本引擎应答的任何字节,crypto 的也应答。等编译器的 `riscv64` raise 缺口合拢,本包折回 crypto,孪生退役。

英文原文: [`hash.md`](hash.md)。

一个根模块加一个 SHA-2 模块,按限定名调用:

```emo
def constant_time_compare(a Bytes, b Bytes) Bool
def hex_encode(data Bytes) String

// hash.sha2:   sha256, sha224, sha512, sha384, sha512_224, sha512_256,
//              以及流式 Digest 与 Wide 类
```

Bytes 进,Bytes 出;比较的判词就是字节的全部应答,不在任何秘密可能操纵的东西上分支。`sha256("noctalia")` 是 `721ee3c57b31edacf3bede6867f93ebaa5c46857ef633b972903f911cac0da14`——桌面锁金测钉住的向量,与 crypto 的 sha256 同样应答。
