#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# 基于 VIKINGYFY/immortalwrt (NSS 平台源码) 的差异化注入。
# 三台京东系设备 (RE-CS-02 / RE-SS-01 / NN6000 v1+v2) 已由该源码树原生支持,
# 本脚本只叠加我们独有的修正:
#   1. 网口 MAC 原厂化 (上游缺少 MAC 分配, 缺失则每次开机随机生成)
#   2. argon 默认主题 + 青绿配色 (#009688) + 加载/保存弹窗跟随主题色
#   3. apk 源修正 (官方包仓库无 video feed, 注释该源避免 apk 报错)
# 用法: ./Scripts/inject.sh <源码目录>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?用法: inject.sh <源码目录>}"

QCOM="$SRC/target/linux/qualcommax"
BF="$QCOM/ipq60xx/base-files"
DEV="$REPO_ROOT/Device"

die() { echo "FATAL: $*" >&2; exit 1; }

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

# 幂等保护: 我们的特征文件已存在说明注入过
if [ -e "$BF/etc/uci-defaults/99-jdcloud-argon" ]; then
	die "源码树似乎已注入过, 请使用干净的上游克隆"
fi

# 基线自检: 确认源码树确实原生支持三台设备 (上游结构变化时在此拦下)
IMK="$QCOM/image/ipq60xx.mk"
IPQWIFI="$SRC/package/firmware/ipq-wifi/Makefile"
grep -q "define Device/jdcloud_re-cs-02" "$IMK" || die "源码树缺少 jdcloud_re-cs-02 定义"
grep -q "define Device/jdcloud_re-ss-01" "$IMK" || die "源码树缺少 jdcloud_re-ss-01 定义"
grep -q "link_nn6000" "$IPQWIFI" || die "源码树缺少 link_nn6000 BDF 注册"

echo "==> [1/3] 注入网口 MAC 原厂化 (02_network 的 MAC 分配 case)"
NET="$BF/etc/board.d/02_network"
# 02_network 有两个 case (网口划分 + MAC 分配), alfa 锚点各出现一次,
# 取第 2 次命中 MAC 分配 case; 若误插网口划分 case 会导致接口定义缺失
insert_before_nth "	alfa-network,ap120c-ax)" 2 "$DEV/patches/net.ins.mac.before" "$NET"

echo "==> [2/3] 注入 argon 默认主题、配色与加载弹窗样式"
UCID="$BF/etc/uci-defaults"
mkdir -p "$UCID"
cat > "$UCID/99-jdcloud-argon" <<'EOF'
# 清理可能存在的重复配置段, 对主题原生 section 直接设值
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
/* [jdcloud] notice/apply dialog follow theme color */
.alert-message.notice,
.modal.notice {
	background-color: var(--primary, #009688) !important;
	color: #fff !important;
}
'
for f in $(find "$SRC/feeds/luci/themes/luci-theme-argon" -type f -name '*.css' 2>/dev/null); do
	printf '%s\n' "$CSS_SNIP" >> "$f"
done

echo "==> [3/3] 注入 apk 源修正 (uci-defaults)"
cat > "$UCID/99-jdcloud-apk" <<'EOF'
# ImmortalWrt 官方包仓库不含 video feed, 注释该源避免 apk 报错;
# 需要时去掉行首 # 即可。兼容 repositories 与 repositories.d 两种布局
for f in /etc/apk/repositories /etc/apk/repositories.d/*; do
	[ -f "$f" ] && sed -i 's|^https.*/video/packages.adb.*|#&|' "$f"
done
EOF

echo "==> 注入完成, 自检:"
ok=1
check() { grep -qF -- "$2" "$1" || { echo "  缺失: $2 (@$1)"; ok=0; }; }
check "$NET" 'lan_mac=$(mmc_get_mac_binary 0:ART 6)'
# MAC 分支必须位于 MAC 分配 case 内 (分支体内有 mmc_get_mac_binary),
# 若误插到网口划分 case 会导致网口划分缺失、刷机后无法获取 IP
sed -n '/^[[:space:]]*jdcloud,re-ss-01)[[:space:]]*$/,/^[[:space:]]*;;[[:space:]]*$/p' "$NET" | grep -q 'mmc_get_mac_binary' \
	|| { echo "  错误: MAC 分支位置异常 (不在 MAC 分配 case 内)"; ok=0; }
check "$BF/etc/uci-defaults/99-jdcloud-argon" "luci-static/argon"
check "$BF/etc/uci-defaults/99-jdcloud-argon" 'argon.@global[0].primary'
check "$BF/etc/uci-defaults/99-jdcloud-argon" '#009688'
check "$BF/etc/uci-defaults/99-jdcloud-apk" 'video/packages.adb'
grep -rq --include='*.css' 'jdcloud' "$SRC/feeds/luci/themes/luci-theme-argon" 2>/dev/null \
	|| { echo "  缺失: 弹窗样式注入 (feeds/luci css)"; ok=0; }

[ "$ok" = 1 ] && echo "==> 全部注入项校验通过" || { echo "==> 注入校验失败" >&2; exit 1; }
