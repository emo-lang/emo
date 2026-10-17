# 包管理

包直接嵌入模块系统：包名成为顶层模块路径前缀。库没有 `install` 步骤——依赖解析是构建的副作用。使用包用 `require`：

```emo
require "acme/json_tools"

def parse_config(text String) json_tools.Json {
  return json_tools.parse(text)
}
```

- **`require` 是把包的短名带入作用域的文件级语句。** 包侧无需对应物——包的公开面就是它的模块树。完全限定的路径永远可用。
- **包的模块树挂载在短名之下。** 包根的 `main.emo` 就是 `require` 绑定的模块 `<short>`,包根没有 `main.emo` 时则是 `<short>.emo`——从一个项目发布出来的包保留它当初写就的入口文件;这个文件在包内也仍以当初的名字可达:`main.emo` 的兄弟文件写 `main.tagged()`,两种写法是同一个模块、同一份定义。其余文件或目录都是它的子节点——`plot/internal/svg.emo` 就是 `plot.internal.svg`,`plot/mark.emo` 就是 `plot.mark`——所以两个包的 `internal` 和 `mark` 永不冲突。包内部引用以包根为基准书写(`plot.emo` 里的 `internal.scale` 即 `plot.internal.scale`),因此一个包无论单独构建还是挂载在前缀下,编译结果一致。
- **每个 `require` 都要在 `deps` 里有对应的 pin——标准库也不例外。** 官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）并内嵌在编译器里发布，但它的包和其他包一样带版本号、彼此之间也以精确版本相互钉住，所以 `require "json"` 需要在 `deps` 里写 `"json" = "0.1.0"`，和 `acme/json_tools` 完全一样；被钉住的包自己依赖的包则通过它自己的 manifest 进来。require 一个 manifest 没有钉的包是编译错误，报错信息会直接给出要加的那一行；标准库没有发布的短名在 require 处报错。pin 的意义在于编译器升级不会把程序的依赖挪走：内嵌 registry 只增不删，旧的 pin 在新编译器上始终可解析，要挪动它是一次有意为之的 `emo deps update`——严格优先，manifest 只因显式操作而改变。

- **包扎根于你站的地方。** 根就是工作目录，它必须放着 `package.emo`——编译器从不向上看，所以在一个没有 manifest 的目录里启动的命令会以 E5010 停下（``run `emo new <name>` to scaffold a project here``），而不属于那里所扎根的包的入口是 E5011。先 `cd` 进包里：那个目录就是模块树，每条命令都从那里读它，于是同一个文件无论命令在哪里敲下都指同一件事。

- **中心注册表，端点可配置。** 包按 `name@version` 通过中心注册表寻址，由全局内容寻址缓存支撑、跨项目共享——没有每项目的依赖副本。项目拉取所用的端点按序取自：`EMO_REGISTRY` 环境变量、manifest 的可选 `registry` 字段，最后是随编译器附带的标准库内置注册表。该字段只接受 `http(s)` URL——纳入版本控制的 manifest 必须命名一台每台机器都能以同样方式抵达的端点，所以文件系统注册表（协议的裸文件布局所导出到的目录）只经 `EMO_REGISTRY` 使用，留给测试与离线开发。HTTP 注册表服务带 scope 的（`owner/name`）包；顶层短名属于标准库，永远从内置副本解析——即使配置了远程注册表。被 yank 的版本不参与新的解析，但保持可下载，所以既有的 `package.lock` 仍能安装。每次拉取都把内容摘要与 lockfile 核对（全新解析时则与注册表自己公布的校验和核对）——不匹配就是错误，绝不静默替换。
- **限定作用域的包名。** 第三方包在 scope 前缀下命名，归属显式，抢注无立足之地；scope 前缀成为模块路径前缀。owner 和短名各段都是一个小写标识符：1–64 个字符，字母开头，后接字母、数字或 `_`。短名就是 `require` 绑定的名字，所以规则就是标识符字母表本身；各段不含横线，这让发布归档的单横线名（`owner-name-version.emoji`）保持无歧义；而标识符永远按代码渲染（等宽、无下划线装饰），`_` 不会被埋掉。官方标准库独占顶层短名（`json.decode()`、`http.get(url)`）。
- **manifest 是 Emo 配置文件**，以受限 profile 书写（可终止、密闭、无副作用）。没有任何读取方会把它当模块遍历：依赖解析、`emo emoji publish`、`emo check` 与编辑器的诊断都按这个 profile 读它；而需要程序的命令会直接拒绝它——`emo run`、`emo build` 拿到 `package.emo` 作入口时以 66 退出，不会把它的字段当代码读。**依赖是精确版本**——开发与测试所用的版本——并且 **targets 声明包支持的编译目标**。绑定原生代码的包还在可选的 `link` 字段里声明要链接的系统库，从非默认注册表拉取的项目则在可选的 `registry` 字段里命名端点：

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]
    link = ["sqlite3"]
    registry = "https://packages.example.com"

    deps {
      "json" = "2.3.1"
      "http" = "1.4.2"
    }
  }
  ```

  `registry` 字段只在 manifest 是项目根时被读取——依赖的 manifest 是从消费方已选定的注册表抓取的，它的字段在那里被忽略。这个字段直接命名本包的注册表：`emo emoji publish` 向它上传，`emo emoji login` 在 `--registry` 与 `EMO_REGISTRY` 都未指明时也向它验证（见下文）。

- **`deps` 的键是字符串字面量**——这个块唯一的写法。包名在这里和在其它所有地方一样是数据(`name` 字段、`require`、lockfile、注册表),所以 scope 能叫什么不取决于词法:owner 是关键字(`emo`)也写得出来。包字段(`name`、`version`、`targets`、`link`、`registry`)仍是标识符绑定——一边是固定 schema 的字段,另一边是 名字→版本 的映射。

- **包可以自带原生代码。** 包目录树里的 `.c`、`.h` 文件是包的一部分——与 `.emo` 模块一同被收集、校验、发布。c 目标会把依赖包的 C 源文件编进程序，并链接其 `link` 字段声明的库，所以消费 `sqlite3` 这类原生绑定包只需 `require`——不用 `--cclib`，不用手写 shim。`link` 只接受裸库名。包的原生输入只有 c 目标兑现；其他目标在构建期拒绝这样的依赖，manifest 的 `targets` 则在解析期拒绝。

- **版本是语义化的（major.minor.patch），按最小版本选择（MVS）解析。** 当不同的包要求同一依赖的不同版本时，满足所有要求的最小版本胜出——对精确要求，取所命名的最高者。升级永远是显式操作。lockfile（`package.lock`）记录带校验和的解析结果，应纳入版本控制；`emo deps resolve` 写它，`emo deps update` 在 pin 变化后重新生成，`emo deps list` 读它——构建从不静默重写：manifest 已经走过头的 lockfile（某个 pin 写完之后被改掉或删掉）会让构建失败并指向 `emo deps resolve`。校验和是对包内收集到的源文件（`.emo`，以及可能存在的 `.c`/`.h`）的 SHA-256：按路径排序，逐文件以 `path \0 content \0` 喂入——与注册表在发布时重算的摘要是同一个算法。（注册表协议冻结前校验和是 MD5；旧编译器写出的 lockfile 删掉重新 resolve 即可。）
- **目标兼容性在解析期检查。** 不支持当前构建目标的依赖，会以清晰的错误在解析期失败，而不是编译中途。
- **发布用 `emo emoji publish`，在包根目录运行。** 命令校验 manifest（`owner/name` 形式的包名、合法的版本号），把全部收集到的源文件——`.emo` 及可能存在的 `.c`/`.h`，含子目录——加上可选的根部 `README.md` 打成确定性的 `.emoji` 归档（gzip tar，路径排序、元数据清零：同样输入永远产出同样字节），POST 到注册表。端点来自 `--registry`、`EMO_REGISTRY`、manifest 的 `registry` 字段或最近一次 `emo emoji login`；API token 来自 `--token`、`EMO_TOKEN` 或该 registry 对应的已存登录——已存 token 只会发给铸造它的那个 registry。`--dry-run` 只在本地校验与打包，打印归档名、大小、校验和与文件清单，不发请求。版本不可变：发布已存在的版本会被拒绝——在 manifest 里 bump `version`。
- **共享包生命周期是 `emo emoji`** —— 以归档格式本身命名的命令组。`emo emoji new acme/string_tools` 脚手架一个可发布的包（`owner/name` 的 manifest、以包命名的公共模块、README）；`emo emoji build` 在 manifest 声明的每个目标下编译包的入口模块——发布前的门禁；`emo emoji login` 向注册表验证账号（端点来自 `--registry`、`EMO_REGISTRY` 或 manifest 的 `registry` 字段），并存入一个 push/yank/read 的 API token（`~/.config/emo/credentials`，0600，每个 registry 一个块，过期时间随 token 一并记录——`--expires-in-days` 可限定 token 的寿命），之后发布既不需要 flag 也不需要环境变量——有终端时询问邮箱与密码（密码关闭回显读取），否则从 stdin 读入两行；token 过期后，注册表会以专用错误码拒绝，`emo emoji publish` 会提示重新 `emo emoji login`。
