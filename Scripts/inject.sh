#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 把 Device/ 下锁定的三台京东系设备支持注入到 immortalwrt openwrt-25.12 源码树。
# 用法: ./Scripts/inject.sh <immortalwrt 源码目录>
#
# 注入内容:
#   1. 设备树 5 个文件 (含 nn6000 公共 dtsi)
#   2. image/ipq60xx.mk 设备定义 (4 台, 含 nn6000 v1)
#   3. base-files: 网口划分 / 无线校准提取 / eMMC 双分区升级
#   4. bootconfig.sh 双分区辅助库 (platform.sh 依赖)
#   5. ipq-wifi 无线校准包的设备注册 (校准数据本身 25.12 锁定的
#      qca-wireless e20f4c6f 已包含, 无需注入)
#   6. uci-defaults: argon 默认主题 + 青绿色配色 (开机首次启动生效),
#      并追加 CSS 让加载/保存弹窗也跟随主题色
#   7. uci-defaults: apk 源修正 (官方无 video 仓库, 注释该源防报错)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?用法: inject.sh <immortalwrt 源码目录>}"

QCOM="$SRC/target/linux/qualcommax"
BF="$QCOM/ipq60xx/base-files"
DEV="$REPO_ROOT/Device"

die() { echo "FATAL: $*" >&2; exit 1; }

# 在目标文件第 nth 次出现的行首锚点(含缩进)之后插入片段文件内容
insert_after_nth() {
	local anchor="$1" nth="$2" frag="$3" file="$4"
	[ -f "$file" ] || die "目标文件不存在: $file"
	grep -qF -- "$anchor" "$file" || die "$file 中找不到锚点: $anchor"
	awk -v a="$anchor" -v n="$nth" -v f="$frag" '
		{ print }
		index($0, a) == 1 && !done {
			c++
			if (c == n) {
				while ((getline line < f) > 0) print line
				close(f); done = 1
			}
		}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# 在目标文件第 nth 次出现的行首锚点(含缩进)之前插入片段文件内容
insert_before_nth() {
	local anchor="$1" nth="$2" frag="$3" file="$4"
	[ -f "$file" ] || die "目标文件不存在: $file"
	grep -qF -- "$anchor" "$file" || die "$file 中找不到锚点: $anchor"
	awk -v a="$anchor" -v n="$nth" -v f="$frag" '
		index($0, a) == 1 && !done {
			c++
			if (c == n) {
				while ((getline line < f) > 0) print line
				close(f); done = 1
			}
		}
		{ print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# 幂等保护: 只允许注入到干净的 25.12 树
if grep -rq "jdcloud,re-cs-02" "$BF/etc/board.d/02_network" 2>/dev/null; then
	die "源码树似乎已注入过, 请使用干净的上游克隆"
fi

echo "==> [1/8] 注入设备树"
for f in ipq6010-re-cs-02.dts ipq6000-re-ss-01.dts ipq6000-link.dtsi ipq6000-nn6000-v1.dts ipq6000-nn6000-v2.dts; do
	[ -f "$DEV/dts/$f" ] || die "缺少设备树文件: $f"
	cp "$DEV/dts/$f" "$QCOM/files/arch/arm64/boot/dts/qcom/$f"
done

echo "==> [2/8] 注入 eMMC 双分区辅助库并挂接 platform.sh"
[ -f "$BF/lib/upgrade/platform.sh" ] || die "找不到 platform.sh"
mkdir -p "$BF/lib/functions"
cp "$DEV/base-files/bootconfig.sh" "$BF/lib/functions/bootconfig.sh"
FRAG="$(mktemp)"
trap 'rm -f "$FRAG"' EXIT
printf '. /lib/functions/bootconfig.sh\n\n' > "$FRAG"
insert_before_nth "PART_NAME=firmware" 1 "$FRAG" "$BF/lib/upgrade/platform.sh"
sed -i "s/^RAMFS_COPY_BIN=.*/RAMFS_COPY_BIN='fw_printenv fw_setenv head seq'/" "$BF/lib/upgrade/platform.sh"

echo "==> [3/8] 注入镜像定义 (image/ipq60xx.mk)"
MK="$QCOM/image/ipq60xx.mk"
printf '\n' >> "$MK"
cat "$DEV/patches/ipq60xx.mk.append" >> "$MK"

echo "==> [4/8] 注入网口划分 (02_network)"
NET="$BF/etc/board.d/02_network"
insert_after_nth "	glinet,gl-ax1800|\\" 1 "$DEV/patches/net.ins.gl1800.after" "$NET"
insert_before_nth "	glinet,gl-axt1800)" 1 "$DEV/patches/net.ins.axt1800.before" "$NET"
insert_before_nth "	qihoo,360v6)" 1 "$DEV/patches/net.ins.360v6.before" "$NET"
# MAC 分配分支: 02_network 有两个 case (网口划分 + MAC 分配), alfa-network 锚点
# 在两者中各出现一次, 取第 2 次命中真正的 MAC 分配 case
insert_before_nth "	alfa-network,ap120c-ax)" 2 "$DEV/patches/net.ins.mac.before" "$NET"

echo "==> [5/8] 注入无线校准提取 (11-ath11k-caldata)"
CAL="$BF/etc/hotplug.d/firmware/11-ath11k-caldata"
insert_before_nth "	qihoo,360v6)" 1 "$DEV/patches/caldata.ins.360v6.before" "$CAL"
# mr7500 在 AHB 与 QCN9074 两个 case 各出现一次, 取第 2 次
insert_before_nth "	linksys,mr7500)" 2 "$DEV/patches/caldata.ins.mr7500.before" "$CAL"

echo "==> [6/8] 注入 eMMC 升级流程与无线校准包注册"
insert_before_nth "	yuncore,fap650)" 1 "$DEV/patches/platform.ins.fap650.before" "$BF/lib/upgrade/platform.sh"
IPQWIFI="$SRC/package/firmware/ipq-wifi/Makefile"
insert_after_nth "ALLWIFIBOARDS:= \\" 1 "$DEV/patches/ipqwifi.boards.after" "$IPQWIFI"
insert_before_nth '$(eval $(call generate-ipq-wifi-package,' 1 "$DEV/patches/ipqwifi.eval.before" "$IPQWIFI"

echo "==> [7/8] 注入 argon 默认主题、配色与加载弹窗样式"
UCID="$BF/etc/uci-defaults"
mkdir -p "$UCID"
cat > "$UCID/99-jdcloud-argon" <<'EOF'
# 清理旧版误建的重复配置段, 对主题原生 section 直接设值
uci -q delete argon.global
uci set argon.@global[0].primary='#009688'
# 激活 argon 为默认皮肤
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit argon
uci commit luci
EOF

# luci-base 的加载/保存弹窗用固定蓝色, 往 argon 主题 css 末尾追加覆盖规则,
# 用 var(--primary) 跟随主题色 (网页里换色时弹窗同步变化)。
# 主题源码位于 luci feed 克隆中, 用 find 定位 css, 不依赖固定目录层级
CSS_SNIP='
/* [jdcloud] loading/confirm follow theme color */
.spinning::before,
.spinning::after {
	border-color: rgba(0, 150, 136, 0.25) !important;
	border-top-color: var(--primary, #009688) !important;
}
.modal .alert-message {
	color: var(--primary, #009688);
}
'
for f in $(find "$SRC/feeds/luci/themes/luci-theme-argon" -type f -name '*.css' 2>/dev/null); do
	printf '%s\n' "$CSS_SNIP" >> "$f"
done

echo "==> [8/8] 注入 apk 源修正 (uci-defaults)"
cat > "$UCID/99-jdcloud-apk" <<'EOF'
# ImmortalWrt 官方包仓库不含 video feed, 注释该源避免 apk 报错; 需要时去掉行首 # 即可
sed -i 's|^https.*/video/packages.adb.*|#&|' /etc/apk/repositories
EOF

echo "==> 注入完成, 自检:"
ok=1
check() { grep -qF -- "$2" "$1" || { echo "  缺失: $2 (@$1)"; ok=0; }; }
check "$MK" 'define Device/jdcloud_re-cs-02'
check "$MK" 'define Device/link_nn6000-v2'
check "$NET" 'jdcloud,re-cs-02|\'
check "$NET" 'link,nn6000-v1|\'
check "$NET" 'jdcloud,re-ss-01|\'
check "$NET" 'lan_mac=$(mmc_get_mac_binary 0:ART 6)'
# MAC 分支必须位于 MAC 分配 case 内 (分支体内有 mmc_get_mac_binary),
# 若误插到网口划分 case 会导致网口划分缺失、刷机后无法获取 IP
sed -n '/^[[:space:]]*jdcloud,re-ss-01)[[:space:]]*$/,/^[[:space:]]*;;[[:space:]]*$/p' "$NET" | grep -q 'mmc_get_mac_binary' \
	|| { echo "  错误: MAC 分支位置异常 (不在 MAC 分配 case 内)"; ok=0; }
check "$CAL" 'jdcloud,re-cs-02)'
check "$CAL" 'caldata_extract_mmc "0:ART" 0x26800 0x20000'
check "$CAL" 'link,nn6000-v2)'
check "$BF/lib/upgrade/platform.sh" 'emmc_do_upgrade "$1"'
check "$BF/lib/upgrade/platform.sh" '. /lib/functions/bootconfig.sh'
check "$IPQWIFI" 'jdcloud_re-cs-02'
check "$IPQWIFI" 'link_nn6000'
check "$BF/etc/uci-defaults/99-jdcloud-argon" "luci-static/argon"
check "$BF/etc/uci-defaults/99-jdcloud-argon" 'argon.@global[0].primary'
check "$BF/etc/uci-defaults/99-jdcloud-argon" '#009688'
check "$BF/etc/uci-defaults/99-jdcloud-argon" 'delete argon.global'
check "$BF/etc/uci-defaults/99-jdcloud-apk" 'video/packages.adb'
grep -rq --include='*.css' 'jdcloud' "$SRC/feeds/luci/themes/luci-theme-argon" 2>/dev/null \
	|| { echo "  缺失: 弹窗样式注入 (feeds/luci css)"; ok=0; }
ls "$QCOM/files/arch/arm64/boot/dts/qcom/" | grep -q ipq6010-re-cs-02.dts || { echo "  缺失: 设备树"; ok=0; }
bash -n "$BF/lib/upgrade/platform.sh" || { echo "  platform.sh 语法错误"; ok=0; }
sh -n "$NET" || { echo "  02_network 语法错误"; ok=0; }
sh -n "$CAL" || { echo "  11-ath11k-caldata 语法错误"; ok=0; }

[ "$ok" = 1 ] && echo "==> 全部注入项校验通过" || { echo "==> 注入校验失败" >&2; exit 1; }
