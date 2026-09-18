#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APP="$BUILD/NetSplit.app"
MACOS="$APP/Contents/MacOS"
SDK="$(xcrun --show-sdk-path)"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCH="$(uname -m)"
BUNDLE_ID="com.weiyuhang.netsplit"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
DISPLAY_NAME="网卡分流"
# 产物文件名必须是 ASCII：GitHub 创建 Release 资产时会剥掉非 ASCII 字符，
# 用中文名传上去会变成 "-0.4.0.dmg"。只有文件名受这个限制，
# App 装出来的名字和安装器里给用户看的文案都照旧用 DISPLAY_NAME。
ARTIFACT_NAME="NetSplit"
ICON_SRC="$ROOT/Resources/icon-1024.png"
ICNS="$BUILD/AppIcon.icns"

make_icns() {
  [[ -f "$ICON_SRC" ]] || { echo "missing $ICON_SRC" >&2; return 1; }
  local setdir="$BUILD/AppIcon.iconset"
  rm -rf "$setdir" "$ICNS"
  mkdir -p "$setdir"
  local size name
  for spec in \
    "16 icon_16x16" \
    "32 icon_16x16@2x" \
    "32 icon_32x32" \
    "64 icon_32x32@2x" \
    "128 icon_128x128" \
    "256 icon_128x128@2x" \
    "256 icon_256x256" \
    "512 icon_256x256@2x" \
    "512 icon_512x512" \
    "1024 icon_512x512@2x"
  do
    set -- $spec
    sips -z "$1" "$1" "$ICON_SRC" --out "$setdir/${2}.png" >/dev/null
  done
  iconutil -c icns "$setdir" -o "$ICNS"
  rm -rf "$setdir"
}

set_file_icon() {
  local icon="$1" target="$2"
  local helper="$BUILD/SetIcon"
  if [[ ! -x "$helper" ]]; then
    swiftc -O -framework AppKit -o "$helper" "$ROOT/packaging/SetIcon.swift"
  fi
  "$helper" "$icon" "$target"
}

# 每次构建都从空的 build/ 开始。
#
# 否则上一轮产物会留在目录里：换了版本号时旧的 dmg/pkg 不会被覆盖，
# `dist` 结尾的 ls 会把陈货一起列出来，Release 工作流的 *.dmg / *.pkg
# 通配也可能把旧版本一起传上去。
#
# 必须在 build_app 之前调用：build_pkg / build_dmg 里都有
# `[[ -d "$APP" ]] || build_app`，先清会把刚编译好的 app 删掉。
clean_build() {
  [[ "$BUILD" == "$ROOT/build" ]] || {
    echo "clean_build: 拒绝删除预期之外的路径 $BUILD" >&2
    return 1
  }
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
}

build_app() {
  rm -rf "$APP"
  mkdir -p "$MACOS" "$APP/Contents/Resources"
  make_icns

  swiftc -parse-as-library -O \
    -target "${ARCH}-apple-macos${MIN_OS}" \
    -sdk "$SDK" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Network \
    -framework ServiceManagement \
    -o "$MACOS/NetSplit" \
    "$SRC"/*.swift

  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
  echo -n "APPL????" > "$APP/Contents/PkgInfo"
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

  if command -v codesign >/dev/null; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
  fi

  echo "built $APP"
}

# pkgbuild 在较新的 macOS 上会因 com.apple.provenance 打出
# "write: Permission denied"，包仍然能写成，过滤掉即可。
run_quiet() {
  local log
  log="$(mktemp)"
  if ! "$@" >"$log" 2>&1; then
    grep -vE '^(write: Permission denied$|\[.*completed\] ?)' "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  grep -vE '^(write: Permission denied$|\[.*completed\] ?)' "$log" || true
  rm -f "$log"
}

build_pkg() {
  [[ -d "$APP" ]] || build_app

  local payload="$BUILD/pkgroot"
  local scripts="$BUILD/pkgscripts"
  local component="$BUILD/${ARTIFACT_NAME}-component.pkg"
  local dist="$BUILD/distribution.xml"
  local pkg="$BUILD/${ARTIFACT_NAME}-${VERSION}.pkg"

  rm -rf "$payload" "$scripts" "$component" "$pkg"
  mkdir -p "$payload" "$scripts"
  ditto "$APP" "$payload/${DISPLAY_NAME}.app"
  cp "$ROOT/packaging/preinstall" "$ROOT/packaging/postinstall" "$scripts/"
  chmod 755 "$scripts/preinstall" "$scripts/postinstall"

  run_quiet pkgbuild \
    --root "$payload" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location /Applications \
    --min-os-version "$MIN_OS" \
    --scripts "$scripts" \
    "$component"

  cat >"$dist" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${DISPLAY_NAME}</title>
    <organization>com.weiyuhang</organization>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <pkg-ref id="${BUNDLE_ID}"/>
    <choices-outline>
        <line choice="default">
            <line choice="${BUNDLE_ID}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${BUNDLE_ID}" visible="false">
        <pkg-ref id="${BUNDLE_ID}"/>
    </choice>
    <pkg-ref id="${BUNDLE_ID}" version="${VERSION}" onConclusion="none">${ARTIFACT_NAME}-component.pkg</pkg-ref>
    <os-version min="${MIN_OS}"/>
</installer-gui-script>
EOF

  cat >"$BUILD/welcome.html" <<EOF
<!DOCTYPE html>
<html lang="zh-Hans">
<head><meta charset="utf-8"></head>
<body style="font-family:-apple-system;font-size:13px;line-height:1.5">
<p>将「${DISPLAY_NAME}」安装到「应用程序」文件夹。</p>
<p>安装后菜单栏会出现网线 / Wi-Fi 图标，用于在 Wi-Fi 上网和网线内网之间切换。</p>
<p>切换服务顺序时需要输入本机密码。</p>
</body>
</html>
EOF

  run_quiet productbuild \
    --distribution "$dist" \
    --package-path "$BUILD" \
    --resources "$BUILD" \
    "$pkg"

  rm -f "$component"
  echo "pkg  $pkg"
}

build_dmg() {
  [[ -d "$APP" ]] || build_app

  local stage="$BUILD/dmg"
  local dmg="$BUILD/${ARTIFACT_NAME}-${VERSION}.dmg"

  rm -rf "$stage" "$dmg"
  mkdir -p "$stage"
  make_icns
  ditto "$APP" "$stage/${DISPLAY_NAME}.app"
  ln -s /Applications "$stage/Applications"
  cp "$ICNS" "$stage/.VolumeIcon.icns"
  if command -v SetFile >/dev/null; then
    SetFile -c icnC "$stage/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$stage" 2>/dev/null || true
  fi

  # 只看 `diskutil image` 是否存在不够：较老的系统有这个子命令，
  # 但 create from 还不认 --volumeName，会直接报错退出。要探到参数级。
  local diskutil_help=""
  diskutil_help="$(diskutil image create from --help 2>&1 || true)"
  if grep -q -- '--volumeName' <<<"$diskutil_help"; then
    run_quiet diskutil image create from \
      --format UDZO \
      --volumeName "$DISPLAY_NAME" \
      "$stage" \
      "$dmg"
  else
    run_quiet hdiutil create \
      -volname "$DISPLAY_NAME" \
      -srcfolder "$stage" \
      -ov \
      -format UDZO \
      "$dmg"
  fi

  set_file_icon "$ICON_SRC" "$dmg" || true
  echo "dmg  $dmg"
}

cmd="${1:-build}"
case "$cmd" in
  build|"")
    clean_build
    build_app
    ;;
  open)
    clean_build
    build_app
    pkill -x NetSplit 2>/dev/null || true
    open "$APP"
    ;;
  install)
    clean_build
    build_app
    DEST="/Applications/${DISPLAY_NAME}.app"
    pkill -x NetSplit 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "installed $DEST"
    open "$DEST"
    ;;
  pkg)
    clean_build
    build_app
    build_pkg
    ;;
  dmg)
    clean_build
    build_app
    build_dmg
    ;;
  dist)
    clean_build
    build_app
    build_pkg
    build_dmg
    ls -lh "$BUILD"/*.pkg "$BUILD"/*.dmg
    ;;
  *)
    cat <<'EOF'
用法: build.sh [build|open|install|pkg|dmg|dist]

  build    只编译 .app
  open     编译并运行
  install  编译并拷到 /Applications
  pkg      生成安装包 .pkg（装到「应用程序」）
  dmg      生成磁盘映像 .dmg（拖到 Applications）
  dist     同时打 pkg 和 dmg

每个命令都会先清空 build/，再从干净的目录开始编译。
EOF
    exit 2
    ;;
esac
