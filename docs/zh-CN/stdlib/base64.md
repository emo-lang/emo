# `base64` 包

标准库的 RFC 4648 base64 编解码器:字节进,带填充的 base64 文本出,
再原样返回。纯 Emo 写在共享运行时之上,所以每个目标回答相同的字节
——golden 首次骑上全部五张名单,这是第一个做到的标准库包。

## 使用包

```emo
require "base64"
```

`require` 与清单严格配对:`base64` 必须钉在 `package.emo` 里:

```emo
package {
  name = "acme/myapp"
  version = "0.1.0"
  targets = ["ocaml", "c", "typescript", "wasm", "beam"]

  deps {
    base64 = "0.1.0"
  }
}
```

## 接口

```emo
def encode(data String) String
def decode(text String) String
```

`encode` 永远输出标准字母表(`A-Z a-z 0-9 + /`)加 `=` 填充,每三
个字节一组、每组四个字符。`decode` 回答文本所指的精确字节。

## 严格性

解码器只接受编码器能产出的东西——其余都是错误并抛异常,带出错字
节偏移:

- 只认标准字母表,`=` 填充只许出现在最后一个量子;
- 最后一个量子持两个或三个数据字符(一个不行,四个不行,未填充且
  长度非四的倍数就是短了);
- RFC 要求为零的填充位必须真的是零——`QR==` 是错误,不是 `QQ==`
  的同义词。

不容忍空白,不接受换行拆行:拆过行的消息由调用方先拼回再解码。每次
拒绝都抛普通 Emo 异常——`base64: non-zero padding bits at byte 1`
——没有错误码,没有 nil。

## 错误

```emo
def err: base64: <什么错> at byte <偏移>
```

偏移指向输入停止是合法 base64 的第一个字节——出错的字符、第一个
放错位置的 `=`,或最后一个量子耗尽的位置。

## 测试向量

golden(`examples/base64_demo`)骑 RFC 4648 第 10 节的向量——
`""`、`f`、`fo`、`foo`、`foob`、`fooba`、`foobar` 编码再解码——外加
多字节 UTF-8 载荷,在解释器、ocaml、c、typescript、wasm、beam 上
逐字节一致。
