# 验证范围

当前源码为 Lightpaw 4.4.0（build 25），实际开发与验收环境为 Apple Silicon macOS。原始实机记录含本机路径与配置身份，仅留在开发机器，不随仓库上传。

## 已有证据

- 4.4.0 原生构建、安装副本自检、签名与构建产物一致性检查通过。
- 配置编辑器 227 项、待办队列 74 项、队列与真实原子文件写入集成 37 项、插件清单 48 项检查通过。配置写入使用隔离的临时夹具。
- 实际界面验证了逐项预约、撤销、筛选、刷新，以及退出并重开 Lightpaw 后恢复待办。测试结束后撤销全部预约，实际 Codex 配置保持不变。
- 先前版本实际验证了清理勾选及取消、测试缓存移到废纸篓和取回、测试应用卸载、Homebrew 测试 cask 更新、复杂卸载 hooks 与管理员密码窗口。4.4.0 没有改动这些底层流程，也没有重做全部破坏性测试。
- 菜单栏面板外部点击收起由本机用户实际操作确认；字符猫眨眼和摆尾曾通过实机截图检查。

4.4.0 开发机应用约 4.68 MB。收起窗口且无待办的约 42 秒短样本中，平均 CPU 约 0.44%（单核口径），物理内存中位约 83.58 MiB、采样峰值约 133.95 MiB。CPU 依据 Mach 时钟比例换算。短样本不是长期上限，也不是其他机器上的性能承诺。

## 可复现入口

构建后运行监测核心和界面协议自检：

```sh
./build.sh
./dist/Lightpaw.app/Contents/MacOS/CodexMemoryWatch --self-test
```

进程桥测试只运行临时夹具，不调用真实清理、优化或卸载：

```sh
mkdir -p .build/module-cache
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  Sources/MoleGuardian.c -o .build/MoleGuardian
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
  Sources/MoleBridge.swift Tests/MoleBridgeTests.swift -o .build/MoleBridgeTests
.build/MoleBridgeTests "$PWD/.build/MoleGuardian"
```

其余测试按服务划分在 `Tests/` 中；测试夹具中的密钥标记、配方与应用身份均为合成数据。部分测试另提供显式选择的本机只读盘点模式，不能把盘点输出作为通用测试数据提交。

后台工具集成测试默认只使用临时配置：

```sh
mkdir -p .build/module-cache
xcrun clang -O2 -mmacosx-version-min=13.0 -c Sources/Monitor.c -o .build/Monitor.o
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
  -import-objc-header Sources/Monitor.h \
  Sources/MonitorCore.swift Sources/Models/CodexTools.swift \
  Sources/Models/ToolChangeQueue.swift Tests/ToolManagementIntegrationTests.swift \
  .build/Monitor.o -framework AppKit -lproc -o .build/ToolManagementIntegrationTests
.build/ToolManagementIntegrationTests
```

历史 37 项集成检查中，34 项使用临时夹具，3 项是本机只读兼容性检查。上传版本将后者改为显式参数 `--local-compatibility`，默认不读取真实 Codex 配置。该参数要求运行中的 Codex 和兼容的本地配置，只适合有意执行本机验收时使用。

## 尚未证明的范围

- 没有通过关闭正在进行的 Codex 会话，验证实际用户配置在退出后的自动应用。该分支由同一原子写入器连接隔离配置的集成测试覆盖。
- 未验收任意 Homebrew cask 脚本、全量系统维护、Intel Mac 或 Windows。
- 未证明长时间无内存泄漏，也未证明 Codex 自动退出的根因已经修复。
- 当前签名仅用于本机开发与运行，不等于公证分发。
