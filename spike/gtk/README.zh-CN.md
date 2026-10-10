# Linux GTK spike(可行性验证)

第二个 GUI 可行性验证。macOS 那一轮问的是"原生 GUI 到底够不够得着";这一轮的问题更尖锐:macOS 的 shim 是被 Objective-C 逼出来的(头文件、按签名 cast msgSend、ARC 跳板)——**绑定层里多少是本质的、多少是偶然的?** GTK 4 是纯 C,直呼路径可以被实测。

## 运行

```sh
./docker-e2e.sh      # 任何有 Docker 的机器:在 Linux 容器里编译、
                     # 链接、运行(ubuntu:24.04 + Xvfb),自驱测试
                     # 点击真实按钮并打印结果
./build.sh           # 在装了 GTK 4 的机器上
EMO_GUI_AUTOTEST=1 ./gtk-spike
```

除 macOS 那轮已落地的编译器改动(Void foreign 返回、`emo_defs.h`、内容寻址 cclib 缓存)外,本轮零编译器改动。

## 答案:shim 从 192 行缩到约 100 行,直呼层出现了

- **直呼 `foreign def`,零 shim**——`gtk_init`、`gtk_window_new`、`gtk_window_set_title`、`gtk_window_set_default_size`、`gtk_fixed_new`/`gtk_fixed_put`、`gtk_button_new_with_label`、`gtk_label_new`、`gtk_label_set_text`、`gtk_button_get_label`、`gtk_window_set_child`、`gtk_window_present`,加上 GLib 的 `g_main_loop_new`/`g_main_loop_run`:十三个调用从 Emo 直接发出。控件指针走指针长度的 Int64;字符串双向走 `const char *`。
- **shim 只剩三件事**:(1) 信号处理器——`g_signal_connect` 收函数指针,Emo 造不出来,处理器 extern `main__on_click`,并把 GObject 自己的 `user_data` 当作每连接句柄传过去(正是接口+userdata 回调设计预期的那个槽位);(2) C `int` **返回值**——32 位返回让寄存器高半无定义,所以 `gtk_widget_get_width` 包了一层加宽包装(参数安全,返回不安全——这是 `docs/numeric-width.md` 里 `Int32` 条目的第一个具体实证);(3) 自驱测试。
- **常规路径零结构体**——GTK4 把返回结构体的 getter(GTK3 的 `gtk_widget_get_allocation`)迁移成标量函数后,整个 demo 没有编组过任何 struct。
- **回调与 macOS 完全同构**——状态走回调签名(计数进、新计数出),句柄走 `user_data`。

## 发现

1. **macOS 绑定层约三分之二是偶然的。** ObjC 逼出了创建器、msgSend 词汇表和 ARC 跳板;对着 C 的 GTK,它们全部变成 Emo 直呼。本质剩下的只有函数指针回调、非 64 位返回和变参——恰好是语言路线图已经挂账的清单。
2. **GTK 4 把经典主循环从库里移除了。** 4.14(Ubuntu 24.04)实测:`gtk_main`/`gtk_main_quit` 既不在头文件里、也不被 `libgtk-4` 导出,只有 `gtk_init` 幸存。主循环是 GLib 的——Emo 直呼 `g_main_loop_new`/`g_main_loop_run`,退出由 shim 负责。
3. **直呼 extern 和库自身的头文件不能共存于同一编译单元。** `emo_defs.h` 声明所有 foreign 符号的 FFI 视图(Int64 句柄);gtk.h 为同一批符号声明类型化原型——两者同时 include,cc 直接拒绝重声明。macOS spike 没遇到是因为它的词汇表 shim 不声明任何 AppKit 符号;直呼架构的 shim 只能手写那一个 Emo 回调的 extern,放弃对它的编译期签名检查。出一个不含 foreign 声明的 defs 变体即可恢复检查。
4. **`int` 返回的 getter 是静默腐蚀隐患。** 声明成 `Int64` 能编译能链接,然后高半返回垃圾。今天没有任何警告;可选出路是 shim 包装(本 spike)、`Int32` foreign 类型(numeric-width 排期)、或对疑似窄返回的 lint。
5. **C `double` 参数是同一个陷阱、更锋利的刃。** GTK 4.12 把 `GtkFixed` 的坐标改成了 double;首轮构建声明成 `Int64`,编译、链接、然后画出垃圾——整型实参走 x 寄存器,被调方从 v 寄存器读,是**寄存器类别都错了**的读取,链接器看不见、cc 看不见(跨 TU)、checker 也看不见。把参数如实声明成 `Float64`(FFI 表本就支持)则零 shim 直接成立;陷阱只存在于声明说谎的时候。抓到它的是截图管线(Xvfb + `xwd`),只回读文本和宽度的自驱测试抓不到。
6. **`int64_t` 在 Linux 是 `long`,在 macOS 是 `long long`。** shim 初版把与 defs 对齐的函数定义成 `long long`——macOS 上恰好正确,容器里第一遍构建就被 cc 对着 `emo_defs.h` 拒绝。头文件契约在首次接触时就抓到了真实的可移植性 bug。
7. **`GtkFixed` 坐标原点在左上**(AppKit 在左下)——布局数字不可跨工具包移植;它们应该按工具包留在 Emo 层,spike 正是这么放的。
8. **pkg-config 旗标经 `--cclib` 原样透传**——`--cclib="$(pkg-config --libs gtk4)"` 是一个以 `-` 开头的值,shell 替 cc 拆词;内容寻址缓存覆盖它。

## 状态

仅为 spike——容器镜像(`emo-gtk-build`,由 `Dockerfile` 构建)是本机私有的。`emo` 二进制默认 `../../_build/default/src/emo_cli/emo.exe`,可用 `EMO=...` 覆盖。
