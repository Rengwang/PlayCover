#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The tracked copy lives in PlayCover/Tools/Workspace; both repositories are siblings.
if [[ ! -d "$ROOT_DIR/PlayCover" || ! -d "$ROOT_DIR/PlayTools" ]]; then
  ROOT_DIR="$(cd "$ROOT_DIR/../../.." && pwd)"
fi
PLAYCOVER_DIR="$ROOT_DIR/PlayCover"
PLAYTOOLS_DIR="$ROOT_DIR/PlayTools"
PATCHES_DIR="$ROOT_DIR/patches"
BUILD_DIR="$ROOT_DIR/build"

usage() {
  cat <<'EOF'
Usage: ./sync_upstream.sh <command>

Commands:
  check            Fetch upstream for PlayTools & PlayCover and show new upstream commits vs local patches.
  export-patches   Export local patch commits as .patch files into ./patches/ (for backup or git am).
  sync             Backup current branch, export patches, and rebase local patches onto latest upstream.
  push             Force-push (with --force-with-lease) rebased branches to your GitHub fork (origin).
  build            Build PlayTools.xcframework, update PlayCover Carthage/Build, and build PlayCover.app.
  install          Verify and atomically install built PlayCover.app and PlayTools.framework.
  build-install    Run build followed by install.

Recommended upgrade flow when upstream updates:
  1. ./sync_upstream.sh check
  2. ./sync_upstream.sh sync
  3. ./sync_upstream.sh build
  4. ./sync_upstream.sh push
EOF
}

ensure_clean_tree() {
  local repo_dir="$1"
  local name="$2"
  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    echo "ERROR: $name has uncommitted changes. Please commit or stash them first:" >&2
    git -C "$repo_dir" status -s >&2
    exit 1
  fi
}

check_repo() {
  local repo_dir="$1"
  local name="$2"
  local branch="$3"
  echo "=== Checking $name ($branch) ==="
  git -C "$repo_dir" fetch upstream
  local incoming
  incoming="$(git -C "$repo_dir" log --oneline "HEAD..upstream/$branch" || true)"
  local local_patches
  local_patches="$(git -C "$repo_dir" log --oneline "upstream/$branch..HEAD" || true)"

  if [[ -z "$incoming" ]]; then
    echo "  Upstream ($branch): already up to date."
  else
    echo "  New upstream commits:"
    echo "$incoming" | sed 's/^/    /'
  fi

  echo "  Your local patch stack on top of upstream/$branch:"
  if [[ -z "$local_patches" ]]; then
    echo "    (none)"
  else
    echo "$local_patches" | sed 's/^/    /'
  fi
  echo
}

export_patches_repo() {
  local repo_dir="$1"
  local name="$2"
  local branch="$3"
  local out_dir="$PATCHES_DIR/$name"
  mkdir -p "$out_dir"
  rm -f "$out_dir"/*.patch
  local count
  count="$(git -C "$repo_dir" rev-list --count "upstream/$branch..HEAD" 2>/dev/null || echo 0)"
  if [[ "$count" -gt 0 ]]; then
    git -C "$repo_dir" format-patch -o "$out_dir" "upstream/$branch..HEAD" >/dev/null
    echo "Exported $count patch(es) to $out_dir/"
  else
    echo "No local commits ahead of upstream/$branch in $name."
  fi
}

sync_repo() {
  local repo_dir="$1"
  local name="$2"
  local branch="$3"

  ensure_clean_tree "$repo_dir" "$name"
  git -C "$repo_dir" checkout "$branch"
  git -C "$repo_dir" fetch upstream

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local backup_branch="backup/pre-sync-$stamp"
  git -C "$repo_dir" branch "$backup_branch"
  echo "[$name] Created safety backup branch: $backup_branch"

  export_patches_repo "$repo_dir" "$name" "$branch"

  local incoming_count
  incoming_count="$(git -C "$repo_dir" rev-list --count "HEAD..upstream/$branch")"
  if [[ "$incoming_count" -eq 0 ]]; then
    echo "[$name] Already based on latest upstream/$branch."
    return 0
  fi

  echo "[$name] Rebasing local patches onto upstream/$branch ($incoming_count new upstream commit(s))..."
  if ! git -C "$repo_dir" rebase "upstream/$branch"; then
    cat <<EOF >&2

CONFLICT in $name during rebase onto upstream/$branch!
To resolve:
  1. cd "$repo_dir"
  2. git status   # fix conflicts in listed files
  3. git add <resolved-files>
  4. git rebase --continue
Or abort cleanly and keep previous state:
  git -C "$repo_dir" rebase --abort
Note: Backup branch '$backup_branch' and .patch files in '$PATCHES_DIR/$name' are preserved.
EOF
    exit 1
  fi
  echo "[$name] Rebase succeeded cleanly!"
}

push_repo() {
  local repo_dir="$1"
  local name="$2"
  local branch="$3"
  echo "[$name] Pushing $branch to origin (Rengwang)..."
  git -C "$repo_dir" push --force-with-lease origin "$branch"
}

framework_plugins_dir() {
  local fw="$1"
  if [ -d "$fw/Versions/A" ]; then
    echo "$fw/Versions/A/PlugIns"
  else
    echo "$fw/PlugIns"
  fi
}

# macOS 布局的 AKInterface.bundle 只允许 Contents/ 存在。根目录残留的 Info.plist 会让
# codesign --deep 报 "unsealed contents present in the bundle root"，进而使 PlayCover 的
# Sparkle 签名阶段整段失败。
install_ak_bundle() {
  local fw="$1"
  local ak_bundle="$2"
  if [ ! -d "$ak_bundle" ]; then
    echo "WARNING: AKInterface.bundle not found at $ak_bundle"
    return 0
  fi
  local plugins
  plugins="$(framework_plugins_dir "$fw")"
  mkdir -p "$plugins"
  rm -rf "$plugins/AKInterface.bundle"
  ditto "$ak_bundle" "$plugins/AKInterface.bundle"
  rm -f "$plugins/AKInterface.bundle/Info.plist"
  codesign -f -s - "$plugins/AKInterface.bundle" 2>/dev/null || true
}

ensure_xcframework_slice() {
  local xcfw="$1"
  local slice="$2"
  local fw="$3"
  if [ -d "$xcfw/$slice/PlayTools.framework" ]; then
    return 0
  fi
  # xcodebuild -create-xcframework 在本机偶尔只写出 Info.plist 而不落切片，补拷一份。
  mkdir -p "$xcfw/$slice"
  ditto "$fw" "$xcfw/$slice/PlayTools.framework"
}

build_all() {
  local pt_build="$BUILD_DIR/PlayTools"
  local pt_cat_build="$BUILD_DIR/PlayToolsCatalyst"
  local pc_build="$BUILD_DIR/PlayCover"
  local fw_ios="$pt_build/Release-iphoneos/PlayTools.framework"
  local fw_cat="$pt_cat_build/Release-maccatalyst/PlayTools.framework"
  local xcfw="$pt_build/PlayTools.xcframework"
  local carthage_xcfw="$PLAYCOVER_DIR/Carthage/Build/PlayTools.xcframework"

  echo "=== 1/4 Building PlayTools (Release / iphoneos) ==="
  # AKInterface 目标 SDKROOT=macosx（需要 AppKit），不能跟着 -scheme 一起按 iphoneos 编，
  # 所以拆成独立 target 构建，最后把 AKInterface.bundle 塞回两个切片的 PlugIns。
  FASTLANE=1 xcodebuild \
    -project "$PLAYTOOLS_DIR/PlayTools.xcodeproj" \
    -target PlayTools \
    -configuration Release \
    -sdk iphoneos \
    SYMROOT="$pt_build" \
    OBJROOT="$pt_build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    build

  echo "=== 2/4 Building AKInterface (Release / macosx) ==="
  FASTLANE=1 xcodebuild \
    -project "$PLAYTOOLS_DIR/PlayTools.xcodeproj" \
    -target AKInterface \
    -configuration Release \
    -sdk macosx \
    SYMROOT="$pt_build" \
    OBJROOT="$pt_build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    build

  echo "=== 3/4 Building PlayTools (Release / Mac Catalyst) ==="
  # 宿主 PlayCover 是 macOS App，注入的 PlayTools 必须是 catalyst 平台，否则 dyld 报
  # "incompatible platform (have 'iOS', need 'macCatalyst')"。Catalyst 目标只有走
  # -scheme + -destination 才会带上 EFFECTIVE_PLATFORM_NAME=-maccatalyst。
  FASTLANE=1 xcodebuild \
    -project "$PLAYTOOLS_DIR/PlayTools.xcodeproj" \
    -scheme PlayTools \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    SYMROOT="$pt_cat_build" \
    OBJROOT="$pt_cat_build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    build

  local ak_bundle="$pt_build/Release/AKInterface.bundle"
  install_ak_bundle "$fw_ios" "$ak_bundle"
  install_ak_bundle "$fw_cat" "$ak_bundle"

  echo "=== 4/4 Packaging PlayTools.xcframework + PlayCover.app ==="
  rm -rf "$fw_ios/Modules" "$fw_ios/Headers" "$xcfw"
  xcodebuild -create-xcframework \
    -framework "$fw_ios" \
    -framework "$fw_cat" \
    -output "$xcfw" || true

  if [ ! -f "$xcfw/Info.plist" ]; then
    echo "ERROR: failed to create $xcfw" >&2
    exit 1
  fi
  ensure_xcframework_slice "$xcfw" "ios-arm64" "$fw_ios"
  ensure_xcframework_slice "$xcfw" "ios-arm64-maccatalyst" "$fw_cat"

  mkdir -p "$(dirname "$carthage_xcfw")"
  rm -rf "$carthage_xcfw"
  ditto "$xcfw" "$carthage_xcfw"

  rm -rf "$pc_build/Release/PlayCover.app"
  FASTLANE=1 xcodebuild \
    -project "$PLAYCOVER_DIR/PlayCover.xcodeproj" \
    -scheme PlayCover \
    -configuration Release \
    SYMROOT="$pc_build" \
    OBJROOT="$pc_build" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build

  # 导出真机 IPA 需要 iOS 切片：随 App 资源携带一份，避免把 Catalyst 库塞进 iOS 包。
  local app_resources="$pc_build/Release/PlayCover.app/Contents/Resources"
  mkdir -p "$app_resources"
  rm -rf "$app_resources/PlayTools-iOS.framework"
  ditto "$fw_ios" "$app_resources/PlayTools-iOS.framework"
  codesign -f -s - "$app_resources/PlayTools-iOS.framework" 2>/dev/null || true

  local app_fw="$pc_build/Release/PlayCover.app/Contents/Frameworks/PlayTools.framework"
  local app_fw_a="$app_fw/Versions/A"

  if [ -d "$app_fw_a" ]; then
    rm -f "$app_fw_a/ProxyShield.dylib" "$app_fw/ProxyShield.dylib" \
      "$app_fw_a/GKLDShield.dylib" "$app_fw/GKLDShield.dylib"
    codesign -f -s - "$app_fw"
  fi

  local signing_identity="${PLAYCOVER_SIGNING_IDENTITY:-}"
  local signing_config="${XDG_CONFIG_HOME:-$HOME/.config}/playcover/local-signing-identity"
  if [[ -z "$signing_identity" && -f "$signing_config" ]]; then
    signing_identity="$(cat "$signing_config")"
    if [[ -z "$signing_identity" ]]; then
      echo "ERROR: No signing identity in $signing_config" >&2
      return 1
    fi
  fi
  # Only the host reads the KeyCover password. Sign it after sealing its nested frameworks.
  codesign --force --sign "${signing_identity:--}" --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags,runtime "$pc_build/Release/PlayCover.app"
  codesign --verify --deep --strict "$pc_build/Release/PlayCover.app"

  echo
  echo "Build succeeded:"
  echo "  PlayTools.xcframework -> $carthage_xcfw (ios-arm64 + ios-arm64-maccatalyst)"
  echo "  PlayCover.app         -> $pc_build/Release/PlayCover.app"
}

atomic_replace_bundle() {
  local src="$1"
  local dest="$2"
  local staging="${dest}.staging.$$"
  local backup="${dest}.backup.$$"

  rm -rf "$staging" "$backup"
  mkdir -p "$(dirname "$dest")"
  ditto "$src" "$staging"
  if ! codesign --verify --deep --strict "$staging"; then
    rm -rf "$staging"
    echo "ERROR: codesign verification failed for $src" >&2
    exit 1
  fi

  if [ -e "$dest" ]; then
    mv "$dest" "$backup"
  fi
  if ! mv "$staging" "$dest"; then
    if [ -e "$backup" ]; then
      mv "$backup" "$dest" || true
    fi
    rm -rf "$staging"
    echo "ERROR: failed to move $staging into $dest" >&2
    exit 1
  fi
  rm -rf "$backup"
}

install_app() {
  local built_app="$BUILD_DIR/PlayCover/Release/PlayCover.app"
  local target_app="/Applications/PlayCover.app"
  local target_fw="$HOME/Library/Frameworks/PlayTools.framework"

  if [ ! -d "$built_app" ]; then
    echo "ERROR: built app not found at $built_app. Run './sync_upstream.sh build' first." >&2
    exit 1
  fi

  echo "=== Installing PlayCover.app + PlayTools.framework ==="
  osascript -e 'tell application "PlayCover" to quit' 2>/dev/null || true
  pkill -x PlayCover 2>/dev/null || true
  sleep 1

  atomic_replace_bundle "$built_app" "$target_app"
  atomic_replace_bundle "$target_app/Contents/Frameworks/PlayTools.framework" "$target_fw"

  codesign --verify --deep --strict "$target_app"
  codesign --verify --deep --strict "$target_fw"

  echo "Installed and verified:"
  ls -la "$target_app/Contents/Frameworks/PlayTools.framework/Versions/A/PlayTools" \
         "$target_fw/Versions/A/PlayTools"
}

cmd="${1:-}"
case "$cmd" in
  check)
    check_repo "$PLAYTOOLS_DIR" "PlayTools" "master"
    check_repo "$PLAYCOVER_DIR" "PlayCover" "develop"
    ;;
  export-patches)
    export_patches_repo "$PLAYTOOLS_DIR" "PlayTools" "master"
    export_patches_repo "$PLAYCOVER_DIR" "PlayCover" "develop"
    ;;
  sync)
    sync_repo "$PLAYTOOLS_DIR" "PlayTools" "master"
    sync_repo "$PLAYCOVER_DIR" "PlayCover" "develop"
    ;;
  push)
    push_repo "$PLAYTOOLS_DIR" "PlayTools" "master"
    push_repo "$PLAYCOVER_DIR" "PlayCover" "develop"
    ;;
  build)
    build_all
    ;;
  install)
    install_app
    ;;
  build-install)
    build_all
    install_app
    ;;
  *)
    usage
    exit 1
    ;;
esac
