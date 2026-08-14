# sing-box-Module

面向 Magisk、KernelSU 与 APatch 的 sing-box 单核心模块。模块脚本位于安装目录，用户数据、核心二进制和运行状态位于 `/data/adb/sing-box_module`。

## 运行架构

运行时按职责分为三层：

- `scripts/lib.sh`：解析用户配置和运行时路径，维护服务 PID 与规则状态。
- `scripts/sing-box.service`：负责核心进程的 `start|stop|restart|status` 生命周期，并先执行 `sing-box check`。
- `scripts/subscription.sh`：维护订阅索引和当前完整配置。
- `scripts/config-builder.sh` 与 `scripts/tproxy.sh`：前者生成 `config/run/config.json`，后者生成规则副本并调用 AndroidTProxyShell。

每个本地或远程订阅都是完整 sing-box 配置。服务从当前选中项生成 `config/run/config.json`；`redirect` 或 `tproxy` 模式会额外注入 `sb-module-*` 入站，源配置不会被修改。`tproxy.conf` 的运行时副本会在黑名单模式合并自动绕过包名和用户列表，并强制与模块代理模式一致；白名单模式只代理 `PROXY_APPS_LIST` 中的应用。

核心启动并通过存活检查后才会加载透明代理规则；规则加载失败会停止刚启动的核心，避免服务显示运行但流量未被接管。网络接口变化时，模块会重建本机地址的旁路规则以避免回环；这部分规则使用独立链，并在启动前、停止和卸载时清理。停止或卸载时会优先清理规则，再依据模块自己的 PID 文件停止核心，不会通过全局 `pidof sing-box` 影响其他实例。

## 配置

- 模块配置：`/data/adb/sing-box_module/scripts/sing-box.config`
- 透明代理配置：`/data/adb/sing-box_module/scripts/tproxy.conf`
- 订阅索引：`/data/adb/sing-box_module/scripts/subscription.json`
- 完整配置：`/data/adb/sing-box_module/config/local/` 与 `/data/adb/sing-box_module/config/remote/`
- 模式入站：`/data/adb/sing-box_module/config/inbounds/`；同名用户 JSON 优先于 `tpl/` 中的模板，并追加到完整配置的 `inbounds` 数组末尾；两处均不存在同名文件时不插入入站
- 派生运行配置：`/data/adb/sing-box_module/config/run/`
- 日志与 PID：`/data/adb/sing-box_module/run/`

常用命令：

```sh
su -c 'sh /data/adb/modules/sing-box_module/scripts/sing-box.service status'
su -c 'sh /data/adb/modules/sing-box_module/scripts/sing-box.service restart'
```

## 致谢

本项目参考甚至复制了以下项目的代码，特此鸣谢
- https://github.com/CHIZI-0618/box4magisk
- https://github.com/CHIZI-0618/AndroidTProxyShell
