#!/usr/bin/env bash
# Builds the private MOQOM core modules as static, library-evolution
# XCFrameworks, zips them, and prints the SwiftPM checksums.
#
#   Scripts/build-xcframeworks.sh                  # all platforms
#   PLATFORMS="macos ios ios-sim" Scripts/build-xcframeworks.sh
#
# Inputs (environment):
#   MOQOM_CORE_SRC  Checkout of the private core sources. Default: ../moqom-swift.
#                   Read only: the sources are copied into a staging package and
#                   built there, so nothing is written into the checkout.
#   OUT             Where the .xcframework.zip files and checksums.txt go.
#                   Default: ./build/xcframeworks
#   WORK            Scratch space (staging package + DerivedData), deleted on
#                   exit unless KEEP_WORK=1. Default: a fresh mktemp directory.
#   PLATFORMS       Space-separated subset of:
#                   macos ios ios-sim xros xros-sim tvos tvos-sim
#   MODULES         Default: "MoqomCore MoqomWire MoqomKit MoqomLoopback"
#   KEEP_DOCS=1     Ship .swiftdoc files (Quick Help). Off by default: the
#                   private sources' documentation comments are internal.
#   KEEP_SYMBOLS=1  Keep unstripped static libraries in $OUT/symbols for crash
#                   symbolication. They must never be published.
#   CODESIGN_IDENTITY  If set, each .xcframework is signed with it before zipping.
#   SKIP_UNAVAILABLE=1 Skip, with a warning, platforms whose Xcode platform
#                   component is not installed, instead of failing. Never set
#                   this for a release: the XCFramework would silently lack them.
#
# Output: one static XCFramework per module. Each framework holds the module's
# own object code only, so linking all four never duplicates a symbol, and its
# Swift module as .swiftinterface files only (no binary .swiftmodule, no
# .private/.package interface, no .swiftsourceinfo).

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MOQOM_CORE_SRC="${MOQOM_CORE_SRC:-$HERE/../moqom-swift}"
OUT="${OUT:-$HERE/build/xcframeworks}"
PLATFORMS="${PLATFORMS:-macos ios ios-sim xros xros-sim tvos tvos-sim}"
MODULES="${MODULES:-MoqomCore MoqomWire MoqomKit MoqomLoopback}"
VERSION="${VERSION:-0.0.0}"

if [[ ! -d "$MOQOM_CORE_SRC/Sources/MoqomKit" ]]; then
    echo "error: private core sources not found at $MOQOM_CORE_SRC (set MOQOM_CORE_SRC)" >&2
    exit 1
fi

if [[ -z "${WORK:-}" ]]; then
    WORK="$(mktemp -d -t moqom-xcf)"
fi
cleanup() {
    if [[ "${KEEP_WORK:-0}" != 1 ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

STAGE="$WORK/moqom-swift-core"
DERIVED="$WORK/DerivedData"
FRAMEWORKS="$WORK/frameworks"
mkdir -p "$STAGE/Sources" "$FRAMEWORKS" "$OUT"

# Snapshot rather than symlink: other work in the checkout must not change the
# sources halfway through a seven-platform build.
rsync -a --delete --exclude '.DS_Store' --exclude MoqomMLVC \
    "$MOQOM_CORE_SRC/Sources/" "$STAGE/Sources/"

# The public shell ships MoqomGalleryView as source (Sources/MoqomUI), so the
# binary leaves it out; two public types of that name would be ambiguous.
cat > "$STAGE/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MoqomSwiftCore",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "MoqomCore", targets: ["MoqomCore"]),
        .library(name: "MoqomWire", targets: ["MoqomWire"]),
        .library(name: "MoqomKit", targets: ["MoqomKit"]),
        .library(name: "MoqomLoopback", targets: ["MoqomLoopback"]),
    ],
    targets: [
        .target(name: "MoqomCore", swiftSettings: strict),
        .target(name: "MoqomWire", dependencies: ["MoqomCore"], swiftSettings: strict),
        .target(
            name: "MoqomKit",
            dependencies: ["MoqomCore", "MoqomWire"],
            exclude: ["Subscribe/MoqomGalleryView.swift"],
            swiftSettings: strict
        ),
        .target(
            name: "MoqomLoopback",
            dependencies: ["MoqomCore", "MoqomKit"],
            swiftSettings: strict
        ),
    ]
)
EOF

# platform key -> xcodebuild destination | products directory suffix | plist platform | min OS
destination() {
    case "$1" in
        macos)    echo "generic/platform=macOS" ;;
        ios)      echo "generic/platform=iOS" ;;
        ios-sim)  echo "generic/platform=iOS Simulator" ;;
        xros)     echo "generic/platform=visionOS" ;;
        xros-sim) echo "generic/platform=visionOS Simulator" ;;
        tvos)     echo "generic/platform=tvOS" ;;
        tvos-sim) echo "generic/platform=tvOS Simulator" ;;
        *) echo "unknown platform $1" >&2; return 1 ;;
    esac
}
products_dir() {
    case "$1" in
        macos)    echo "Release" ;;
        ios)      echo "Release-iphoneos" ;;
        ios-sim)  echo "Release-iphonesimulator" ;;
        xros)     echo "Release-xros" ;;
        xros-sim) echo "Release-xrsimulator" ;;
        tvos)     echo "Release-appletvos" ;;
        tvos-sim) echo "Release-appletvsimulator" ;;
    esac
}
bundle_platform() {
    case "$1" in
        macos)    echo "MacOSX" ;;
        ios)      echo "iPhoneOS" ;;
        ios-sim)  echo "iPhoneSimulator" ;;
        xros)     echo "XROS" ;;
        xros-sim) echo "XRSimulator" ;;
        tvos)     echo "AppleTVOS" ;;
        tvos-sim) echo "AppleTVSimulator" ;;
    esac
}

info_plist() { # module platform
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$1</string>
    <key>CFBundleIdentifier</key><string>cloud.moqom.$1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$(bundle_platform "$2")</string></array>
    <key>MinimumOSVersion</key><string>26.0</string>
</dict>
</plist>
EOF
}

# Copies only the public interface of a built module into $2.
copy_interface() { # built.swiftmodule dest.swiftmodule
    mkdir -p "$2"
    local f
    for f in "$1"/*.swiftinterface; do
        case "$f" in
            *.private.swiftinterface|*.package.swiftinterface) continue ;;
        esac
        cp "$f" "$2/"
    done
    if [[ "${KEEP_DOCS:-0}" == 1 ]]; then
        cp "$1"/*.swiftdoc "$2/" 2>/dev/null || true
    fi
}

make_framework() { # module platform products
    local module="$1" platform="$2" products="$3"
    local fw="$FRAMEWORKS/$platform/$module.framework"
    rm -rf "$fw"
    local lib="$WORK/lib/$platform/lib$module.a"
    mkdir -p "$(dirname "$lib")"
    libtool -static -no_warning_for_no_symbols -o "$lib" "$products/$module.o"
    if [[ "${KEEP_SYMBOLS:-0}" == 1 ]]; then
        mkdir -p "$OUT/symbols/$platform"
        cp "$lib" "$OUT/symbols/$platform/"
    fi
    # Debug info carries absolute build paths and source structure.
    strip -S "$lib" 2>/dev/null

    if [[ "$platform" == macos ]]; then
        local v="$fw/Versions/A"
        mkdir -p "$v/Modules" "$v/Resources"
        cp "$lib" "$v/$module"
        copy_interface "$products/$module.swiftmodule" "$v/Modules/$module.swiftmodule"
        info_plist "$module" "$platform" > "$v/Resources/Info.plist"
        ln -s A "$fw/Versions/Current"
        ln -s "Versions/Current/$module" "$fw/$module"
        ln -s Versions/Current/Modules "$fw/Modules"
        ln -s Versions/Current/Resources "$fw/Resources"
    else
        mkdir -p "$fw/Modules"
        cp "$lib" "$fw/$module"
        copy_interface "$products/$module.swiftmodule" "$fw/Modules/$module.swiftmodule"
        info_plist "$module" "$platform" > "$fw/Info.plist"
    fi
}

BUILT=""
for platform in $PLATFORMS; do
    echo "==> Building $platform"
    log="$WORK/build-$platform.log"
    if ! (cd "$STAGE" && xcodebuild build \
            -scheme MoqomSwiftCore-Package \
            -destination "$(destination "$platform")" \
            -configuration Release \
            -derivedDataPath "$DERIVED" \
            BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            ONLY_ACTIVE_ARCH=NO \
            SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
            DEBUG_INFORMATION_FORMAT=dwarf \
            COMPILER_INDEX_STORE_ENABLE=NO \
            > "$log" 2>&1); then
        if [[ "${SKIP_UNAVAILABLE:-0}" == 1 ]] && grep -q "is not installed" "$log"; then
            echo "warning: skipping $platform: its platform is not installed in Xcode" >&2
            continue
        fi
        grep -E "error:" "$log" | sort -u | head -40 >&2 || true
        echo "error: $platform build failed; log kept at $log" >&2
        KEEP_WORK=1
        exit 1
    fi
    products="$DERIVED/Build/Products/$(products_dir "$platform")"
    for module in $MODULES; do
        make_framework "$module" "$platform" "$products"
    done
    BUILT="$BUILT $platform"
    # Intermediates for one platform are not needed by the next.
    rm -rf "$DERIVED/Build/Intermediates.noindex"
done
if [[ -z "$BUILT" ]]; then
    echo "error: no platform was built" >&2
    exit 1
fi

: > "$OUT/checksums.txt"
for module in $MODULES; do
    xcf="$WORK/xcf/$module.xcframework"
    rm -rf "$xcf"
    mkdir -p "$WORK/xcf"
    args=()
    for platform in $BUILT; do
        args+=(-framework "$FRAMEWORKS/$platform/$module.framework")
    done
    xcodebuild -create-xcframework "${args[@]}" -output "$xcf" >/dev/null
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        codesign --timestamp -s "$CODESIGN_IDENTITY" "$xcf"
    fi
    zip_path="$OUT/$module.xcframework.zip"
    rm -f "$zip_path"
    (cd "$WORK/xcf" && ditto -c -k --sequesterRsrc --keepParent "$module.xcframework" "$zip_path")
    sum="$(swift package compute-checksum "$zip_path")"
    echo "$module $sum" | tee -a "$OUT/checksums.txt"
    if [[ "${LOCAL_XCFRAMEWORKS:-}" != "" ]]; then
        mkdir -p "$LOCAL_XCFRAMEWORKS"
        rm -rf "$LOCAL_XCFRAMEWORKS/$module.xcframework"
        cp -R "$xcf" "$LOCAL_XCFRAMEWORKS/"
    fi
done

echo "==> Wrote $(ls "$OUT"/*.xcframework.zip | wc -l | tr -d ' ') archives to $OUT"
