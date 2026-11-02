#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TASK_ROOT/outputs/NodeGuard.app/Contents/Info.plist")"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/work/package-$TASK_VERSION.XXXXXX")"
trap 'rm -rf -- "$TASK_STAGE"' EXIT
TASK_ARCH="$(uname -m)"
mkdir -p "$TASK_STAGE/dmg" "$TASK_STAGE/source/NodeGuard"
ditto "$TASK_ROOT/outputs/NodeGuard.app" "$TASK_STAGE/dmg/NodeGuard.app"
ln -s /Applications "$TASK_STAGE/dmg/Applications"
cp "$TASK_ROOT/LICENSE" "$TASK_STAGE/dmg/LICENSE"
cat > "$TASK_STAGE/dmg/拖动安装说明.txt" <<'EOF'
将 NodeGuard.app 拖到旁边的 Applications 文件夹即可安装。

若已运行旧版，请先退出旧版，再从“应用程序”打开节点哨兵。
关闭窗口后仍可从 Dock 图标或菜单栏重新打开。

默认自动测试当前订阅全部前置节点，每轮结束后间隔 6 小时。
低负载稳定 15 秒后串行测试，忽略后台心跳和零星请求；持续大流量时让行，稍后继续。
新版修复 Claude 内置浏览器访问普通网站误触发强退；锁定当前出口 IP，保留 Claude 服务保护。
关闭或重启程序后续测未完成队列；换网与唤醒后重新验证出口。

自动切换和 Claude 强制退出仍保留原有开关，不会随安装自动开启。
严格保护确认出口变化立即处理；暂时无法验证默认复验最多 12 秒后退出，可在未武装时调整。
系统通知需 macOS 授权；新版修复前台静默，自检会显示点击反馈和通知中心回执。
EOF
for name in Package.swift README.md CHANGELOG.md CONTRIBUTING.md LICENSE AGENTS.md .gitignore Sources Tests Vendor scripts docs; do
    ditto "$TASK_ROOT/$name" "$TASK_STAGE/source/NodeGuard/$name"
done
hdiutil create -volname "节点哨兵 NodeGuard" -srcfolder "$TASK_STAGE/dmg" -format UDZO -ov "$TASK_ROOT/outputs/NodeGuard-$TASK_VERSION-macOS-$TASK_ARCH.dmg"
ditto -c -k --sequesterRsrc --keepParent "$TASK_STAGE/source/NodeGuard" "$TASK_ROOT/outputs/NodeGuard-source-$TASK_VERSION.zip"
cp "$TASK_ROOT/README.md" "$TASK_ROOT/outputs/使用说明.md"
cp "$TASK_ROOT/docs/PROJECT.md" "$TASK_ROOT/outputs/项目方案.md"
cd "$TASK_ROOT/outputs"
shasum -a 256 "NodeGuard-$TASK_VERSION-macOS-$TASK_ARCH.dmg" "NodeGuard-source-$TASK_VERSION.zip" > SHA256SUMS.txt
