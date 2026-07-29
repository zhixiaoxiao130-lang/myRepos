#!/bin/bash
# ======================================================
# DSI 屏幕 (7寸触摸屏) 配置检查脚本
# 检查 /boot/armbianEnv.txt 中的 overlay 设置
# 运行方式: ./dsi_test.sh
# ======================================================

ENV_FILE="/boot/armbianEnv.txt"
OVERLAY_NAME="recomputer-rk3588-devkit-raspi-7inch-touchscreen"

echo "========================================="
echo "  DSI 屏幕配置检查"
echo "========================================="

# 检查配置文件是否存在
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 错误：配置文件 $ENV_FILE 不存在！"
    echo "   请确认系统是否正确烧录。"
    exit 1
fi

# 提取 overlays= 行（忽略大小写和前导空格）
overlay_line=$(grep -E '^\s*overlays=' "$ENV_FILE" | head -n 1)

if [ -z "$overlay_line" ]; then
    echo "❌ 未在 $ENV_FILE 中找到 overlays= 配置。"
    echo ""
    echo "➡️  若要启用 DSI 屏幕，请执行以下操作："
    echo "   1. 编辑 $ENV_FILE"
    echo "   2. 添加或修改这一行："
    echo "      overlays=$OVERLAY_NAME"
    echo "      （如果已有其他 overlay，用空格分隔）"
    echo "   3. 保存后执行："
    echo "      sudo sync"
    echo "      sudo reboot"
    echo "   4. 重启后，DSI 屏幕应正常显示，触摸和桌面应用可正常响应。"
    echo ""
    echo "⚠️  若之后不再使用 DSI 屏幕，请将上述行注释掉（行首加 #），"
    echo "   再执行 sync 并重启即可。"
    exit 2
fi

# 检查是否包含所需的 overlay
if echo "$overlay_line" | grep -qF "$OVERLAY_NAME"; then
    echo "✅ 已配置 $OVERLAY_NAME"
    echo "   DSI 屏幕应已启用。"
    echo "   - 屏幕应正常显示桌面"
    echo "   - 触摸功能应正常工作"
    echo "   - 桌面应用可点击响应"
    echo ""
    echo "💡 如果不再使用 DSI 屏幕，请编辑 $ENV_FILE"
    echo "   将包含 '$OVERLAY_NAME' 的行注释掉（行首加 #），"
    echo "   或删除该 overlay 名称，然后执行："
    echo "      sudo sync"
    echo "      sudo reboot"
else
    echo "❌ 在 overlays 中未找到 '$OVERLAY_NAME'。"
    echo ""
    echo "➡️  若要启用 DSI 屏幕，请编辑 $ENV_FILE"
    echo "   在 overlays= 行末尾添加 '$OVERLAY_NAME'"
    echo "   （与其他 overlay 用空格分隔）"
    echo "   然后执行："
    echo "      sudo sync"
    echo "      sudo reboot"
    echo "   重启后 DSI 屏幕应可正常使用。"
    echo ""
    echo "⚠️  若不再使用 DSI 屏幕，请在上述行中将该 overlay 名称移除或注释。"
fi
