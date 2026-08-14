# sing-box-Module

面向 Magisk、KernelSU 与 APatch 的 sing-box 单核心模块。模块脚本位于安装目录，用户数据、核心二进制和运行状态位于 `/data/adb/sing-box_module`。

## 运行架构

运行时按职责分为三层：

- `scripts/lib.sh`：解析用户配置和运行时路径，维护服务 PID 与规则状态。
- `scripts/sing-box.service`：负责核心进程的 `start|stop|restart|status` 生命周期，并先执行 `sing-box check`。
- `scripts/subscription.sh`：维护订阅索引和当前完整配置。
- `scripts/config-builder.sh` 与 `scripts/tproxy.sh`：前者生成 `config/run/config.json`，后者生成规则副本并调用 AndroidTProxyShell。

每个本地或远程订阅都是完整 sing-box 配置。服务从当前选中项生成 `config/run/config.json`；模式入站会追加到 `inbounds` 数组末尾，源配置不会被修改。`redirect` 或 `tproxy` 模式会生成 AndroidTProxyShell 的运行时副本，并强制与模块代理模式一致。

分应用代理由 `sing-box.config` 中三个配置项控制：`app_proxy_enable`、`app_proxy_mode`（`whitelist` 或 `blacklist`）和 `auto_proxy_apps_enable`。白名单仅代理 `proxy_apps_list`，黑名单仅绕过 `bypass_apps_list`。自动生成默认关闭；开启后模块会在每次启动时获取当前 Android 用户的已安装包名，并和 v2rayNG 名单求交集。该来源并不适合作为通用规则，建议仅在白名单模式使用。

自动或手动分流会生成互斥的代理与绕过集合：`redirect`/`tproxy` 只写入 ATP 实际读取的一侧名单；`tun` 和 `ebpf` 入站在白名单模式仅写入 `include_package`，在黑名单模式仅写入 `exclude_package`。当前按 Android 单用户处理，不生成 `userId:package` 条目。`force_proxy_app.txt` 总是强制代理，`force_bypass_app.txt` 总是强制绕过；两者不受以上三个开关影响。自定义入站的 `include_package`、`exclude_package` 在运行时由最终集合接管；不支持这两个字段的入站不会被改写。

手动修改当前配置、模块设置或当前模式入站时，模块不会自动重启。`config.inotify` 会记录待重启状态，管理器的 [执行] 菜单会显示警告；从该菜单切换配置或更新当前远程订阅后，菜单会主动重启服务。

核心启动并通过存活检查后才会加载透明代理规则；规则加载失败会停止刚启动的核心，避免服务显示运行但流量未被接管。网络接口变化时，模块会重建本机地址的旁路规则以避免回环；这部分规则使用独立链，并在启动前、停止和卸载时清理。停止或卸载时会优先清理规则，再依据模块自己的 PID 文件停止核心，不会通过全局 `pidof sing-box` 影响其他实例。

ColorOS 16 与 RedMagic OS 会在系统启动 60 秒后被检查；模块会移除 `fw_INPUT`、`fw_OUTPUT`、`fw_OUTPUT_oplus_dns`、`zte_fw_gms` 中拦截流量的 `REJECT`/`DROP` 规则，使 Google Play 商店和 Google Play 服务能够联网。该操作也可从管理器 [执行] 菜单手动运行，日志位于 `/data/adb/sing-box_module/run/google-firewall-fixer.log`。

## 配置

- 模块配置：`/data/adb/sing-box_module/scripts/sing-box.config`
- 透明代理配置：`/data/adb/sing-box_module/scripts/tproxy.conf`
- 强制代理应用：`/data/adb/sing-box_module/scripts/force_proxy_app.txt`，每行一个包名
- 强制白名单：`/data/adb/sing-box_module/scripts/force_bypass_app.txt`，每行一个包名
- 自动代理应用名单：`/data/adb/sing-box_module/config/proxy_package_name`；构建时下载，也可从管理器 [执行] -> 配置管理手动更新
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
- https://github.com/CHIZI-0618/ColorOS-Google-Firewall-Fixer
- https://github.com/2dust/v2rayNG（`proxy_package_name`，GPL-3.0）

## LICENSE

[AGPL-3.0](LICENSE)
