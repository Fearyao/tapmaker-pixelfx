#!/bin/sh
# 把 tap-pixelfx 装进一个 TapMaker / UrhoX 工程：拷到 <工程>/scripts/ 即可。
#
#   ./install.sh /path/to/your-project
#
# 只拷运行期需要的内容（不含仓库自带的 CI / git 配置 / 临时产物）。
# 唯一的依赖是工程里已有的 scripts/urhox-libs/（Maker 工程默认自带）。
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${1:?用法: ./install.sh <工程根目录>}

if [ ! -d "$DEST/scripts" ]; then
    echo "错误：$DEST/scripts 不存在，看起来不是 UrhoX/Maker 工程根目录" >&2
    exit 1
fi
if [ ! -d "$DEST/scripts/urhox-libs" ]; then
    echo "警告：$DEST/scripts/urhox-libs 不存在；tap-pixelfx 需要 urhox-libs/UI 才能渲染" >&2
fi

TARGET="$DEST/scripts/tap-pixelfx"
rm -rf "$TARGET"
mkdir -p "$TARGET"

# 白名单拷贝：仓库根上的 .git / .github / .gitignore / install.sh 不属于运行期内容
for item in init.lua core effects runtime atlas dev \
            README.md PORTING.md VERSION LICENSE NOTICE.md; do
    [ -e "$HERE/$item" ] || continue
    cp -R "$HERE/$item" "$TARGET/"
done

echo "已安装到 $TARGET"
echo "用法：local Pixelfx = require(\"tap-pixelfx\")"
