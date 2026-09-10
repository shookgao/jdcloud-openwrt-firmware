# OpenWRT-CI-MINI

为 **京东云雅典娜 (RE-CS-02)**、**京东云 (RE-SS-01)**、**连我 NN6000 v2** 三台
高通 IPQ6000 路由器定制的 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
固件云编译仓库。只编译这三台设备, 只用官方源码包, 全自动跟随上游更新。

参考并精简自 [VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)。

## 方案说明

上游使用 immortalwrt **openwrt-25.12 稳定分支** (内核 6.12, 只收 bugfix)。
这三台设备 25 年底才进入 immortalwrt 主线, 稳定分支尚未收录, 因此本仓库把
它们的设备支持文件 (设备树、固件定义、网口/校准/升级脚本) 锁定在 `Device/`
目录, 由 CI 在每次编译时自动注入到稳定分支源码树中。

- 设备树按稳定分支的内核 6.12 网络架构 (EDMA/`&dp` 写法) 重写,
  来源为 immortalwrt master (内核 6.18) 的官方设备定义
- 无线校准数据 (board-2.bin) 稳定分支锁定的官方固件库已包含, 直接复用
- 不从任何第三方 GitHub 仓库拉取插件或补丁 (原仓库最大的不稳定来源)

## 使用

1. 推送到你的 GitHub 公开仓库 (Actions 对公开仓库免费, 私有仓库时长会不够用)
2. 无需任何操作: 每天北京时间 06:00 自动检查上游, 有新提交才编译并发布 Release
3. 想立即编译: Actions → Build → Run workflow (可勾选"强制编译")

固件在 Release 页面下载, 刷机用 `*-squashfs-sysupgrade.bin` (tar 格式)。
从原厂系统刷入需先刷各机型对应的第三方 U-Boot, 教程见恩山论坛。

## 目录结构

```
.github/workflows/
  build.yml        编译流水线: 检查上游 → 注入设备 → 编译 → 发 Release
  cleanup.yml      每周清理旧 Release, 只保留最近 5 个
Config/
  DEVICES.txt      平台与设备清单 (增删编译机型改这里)
  COMMON.txt       通用软件配置 (luci 中文、USB 存储文件系统、kmod-tun 等)
Device/
  dts/             三台设备的设备树 (锁定, 基于 25.12 内核 6.12 适配)
  base-files/      bootconfig.sh (京东系 eMMC 双分区辅助库, 取自上游)
  patches/         注入到源码树的文本片段 (镜像定义、网口、校准、升级)
Scripts/
  inject.sh        注入器: 把 Device/ 全部内容打进上游源码树, 带自检
```

## 常见改动

**换插件/加配置**: 编辑 `Config/COMMON.txt`, 按 `.config` 格式加一行
`CONFIG_PACKAGE_名字=y`。**只能用官方 feeds 里存在的包名**, 可在
[固件选择器](https://firmware-selector.immortalwrt.org/) 搜包名确认。
普通软件包其实不用编进固件——刷好机后 `opkg update && opkg install` 即可;
只有内核模块 (kmod-*) 和少数依赖才建议编入。

**换上游分支**: 编辑 `.github/workflows/build.yml` 里的 `UPSTREAM_BRANCH`。

**同步设备支持**: 设备文件已锁定, 上游修复不会自动跟进。若某天上游
master 对这几台设备有 bug 修复, 对照 `Device/patches/` 里的片段手动更新,
或在 immortalwrt master 收录这些文件的下一个稳定分支发布后整体移除移植层。

## 排错

- 编译失败: 先看 Actions 日志是在"注入"还是"编译"步骤。
  注入失败说明稳定分支结构变动 (sed/awk 锚点失配), 需要更新 `Scripts/inject.sh`
  的锚点; 编译失败大概率是上游当天自身问题, 隔天重跑即可
- 上游连续多天编译失败时的兜底: 手动 Run workflow 强制重试,
  或临时把 `UPSTREAM_BRANCH` 换成上一次成功的 tag (形如 `v25.12.x`)

## 已知限制

- 京东云雅典娜的 2.5G WAN 口按稳定分支现有的 QCA8081 驱动模式 (sgmii) 编写,
  首次实测若协商不到 2.5G 速率, 欢迎反馈
- 网口 MAC 地址沿用稳定分支 eMMC 设备的默认分配方式, 与原厂 MAC 可能不同
- 首次刷入属于跨系统迁移, 刷机前务必确认设备已刷入第三方 U-Boot,
  以便刷失败时可以从 U-Boot Web 页面恢复
