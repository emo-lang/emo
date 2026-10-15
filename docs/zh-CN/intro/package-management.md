# 包管理

包直接嵌入模块系统：包名成为顶层模块路径前缀。库没有 `install` 步骤——依赖解析是构建的副作用。使用包用 `require`：

```emo
require "acme/json_tools"

def parse_config(text String) json_tools.Json {
  return json_tools.parse(text)
}
```

- **`require` 是把包的短名带入作用域的文件级语句。** 包侧无需对应物——包的公开面就是它的模块树。完全限定的路径永远可用。
- **包的模块树挂载在短名之下。** 包根的 `<short>.emo` 就是 `require` 绑定的模块 `<short>`;其余文件或目录都是它的子节点——`plot/internal/svg.emo` 就是 `plot.internal.svg`,`plot/mark.emo` 就是 `plot.mark`——所以两个包的 `internal` 和 `mark` 永不冲突。包内部引用以包根为基准书写(`plot.emo` 里的 `internal.scale` 即 `plot.internal.scale`),因此一个包无论单独构建还是挂载在前缀下,编译结果一致。
- **标准库无需 manifest 条目,第三方包需要。** 官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）并随编译器一起发布，所以 `require "json"` 隐式解析——连同这个依赖所拉入的标准库包。带 scope 的包（`acme/json_tools`）必须钉在 `deps` 里：require 一个没有钉的包是编译错误——严格优先，manifest 只因显式操作而改变。

- **中心注册表，端点可配置。** 包按 `name@version` 通过中心注册表寻址，由全局内容寻址缓存支撑、跨项目共享——没有每项目的依赖副本。注册表端点读 `EMO_REGISTRY` 环境变量——全局或每项目设置——服务私有与本地部署；未设置时，标准库的内置注册表随编译器附带并默认服务。
- **限定作用域的包名。** 第三方包在 scope 前缀下命名，归属显式，抢注无立足之地；scope 前缀成为模块路径前缀。官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）。
- **manifest 是 Emo 配置文件**，以受限 profile 书写（可终止、密闭、无副作用）。**依赖是精确版本**——开发与测试所用的版本——并且 **targets 声明包支持的编译目标**。绑定原生代码的包还在可选的 `link` 字段里声明要链接的系统库：

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]
    link = ["sqlite3"]

    deps {
      "json" = "2.3.1"
      "http" = "1.4.2"
    }
  }
  ```

- **`deps` 的键是字符串字面量**——这个块唯一的写法。包名在这里和在其它所有地方一样是数据(`name` 字段、`require`、lockfile、注册表),所以 scope 能叫什么不取决于词法:owner 是关键字(`emo`)或带连字符都写得出来。包字段(`name`、`version`、`targets`、`link`)仍是标识符绑定——一边是固定 schema 的字段,另一边是 名字→版本 的映射。

- **包可以自带原生代码。** 包目录树里的 `.c`、`.h` 文件是包的一部分——与 `.emo` 模块一同被收集、校验、发布。c 目标会把依赖包的 C 源文件编进程序，并链接其 `link` 字段声明的库，所以消费 `sqlite3` 这类原生绑定包只需 `require`——不用 `--cclib`，不用手写 shim。`link` 只接受裸库名。包的原生输入只有 c 目标兑现；其他目标在构建期拒绝这样的依赖，manifest 的 `targets` 则在解析期拒绝。

- **版本是语义化的（major.minor.patch），按最小版本选择（MVS）解析。** 当不同的包要求同一依赖的不同版本时，满足所有要求的最小版本胜出——对精确要求，取所命名的最高者。升级永远是显式操作。lockfile（`package.lock`）记录带校验和的解析结果，应纳入版本控制；`emo deps resolve` 写它，`emo deps update` 在 pin 变化后重新生成，`emo deps list` 读它——构建从不静默重写。校验和是对包内收集到的源文件（`.emo`，以及可能存在的 `.c`/`.h`）的 SHA-256：按路径排序，逐文件以 `path \0 content \0` 喂入——与注册表在发布时重算的摘要是同一个算法。（注册表协议冻结前校验和是 MD5；旧编译器写出的 lockfile 删掉重新 resolve 即可。）
- **目标兼容性在解析期检查。** 不支持当前构建目标的依赖，会以清晰的错误在解析期失败，而不是编译中途。
- **发布用 `emo publish`，在包根目录运行。** 命令校验 manifest（`owner/name` 形式的包名、合法的版本号），把全部收集到的源文件——`.emo` 及可能存在的 `.c`/`.h`，含子目录——加上可选的根部 `README.md` 打成确定性的 `.emoji` 归档（gzip tar，路径排序、元数据清零：同样输入永远产出同样字节），POST 到注册表。端点来自 `--registry`、`EMO_REGISTRY` 或最近一次 `emo emoji login`；API token 来自 `--token`、`EMO_TOKEN` 或该 registry 对应的已存登录——已存 token 只会发给铸造它的那个 registry。`--dry-run` 只在本地校验与打包，打印归档名、大小、校验和与文件清单，不发请求。版本不可变：发布已存在的版本会被拒绝——在 manifest 里 bump `version`。
- **共享包生命周期是 `emo emoji`** —— 以归档格式本身命名的命令组。`emo emoji new acme/string_tools` 脚手架一个可发布的包（`owner/name` 的 manifest、以包命名的公共模块、README）；`emo emoji build` 在 manifest 声明的每个目标下编译包的入口模块——发布前的门禁；`emo emoji login` 向注册表验证账号，并存入一个 push/yank/read 的 API token（`~/.config/emo/credentials`，0600，每个 registry 一个块，过期时间随 token 一并记录——`--expires-in-days` 可限定 token 的寿命），之后发布既不需要 flag 也不需要环境变量——有终端时询问邮箱与密码（密码关闭回显读取），否则从 stdin 读入两行；token 过期后，注册表会以专用错误码拒绝，`emo publish` 会提示重新 `emo emoji login`；`emo emoji publish` 与 `emo publish` 是同一次上传。
