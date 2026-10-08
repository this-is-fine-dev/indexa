#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Release archives never contain the vault, local runtime, Matrix history or signing seed.
test -x matrix/qr/target/release/indexa-qr || { echo 'Missing native QR binary; run scripts/build-matrix-qr.sh first.' >&2; exit 1; }
version="${INDEXA_VERSION:-$(cat release/version.txt)}"
[[ "$version" =~ ^[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || { echo 'Invalid version' >&2; exit 1; }
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$SWIFTPM_MODULECACHE_OVERRIDE"
swift build --disable-keychain -c release
binary_dir="$(swift build --disable-keychain -c release --show-bin-path)"
framework='.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
test -d "$framework"
app='dist/Indexa.app'
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/matrix" "$app/Contents/Resources/hermes-plugin" "$app/Contents/Frameworks"
cp matrix/service.py matrix/qr_session.py matrix/native_services.py matrix/public_proxy.py "$app/Contents/Resources/matrix/"
cp matrix/qr/target/release/indexa-qr "$app/Contents/Resources/matrix/"
cp hermes-plugin/__init__.py hermes-plugin/mcp_notes.py hermes-plugin/notes.js hermes-plugin/plugin.yaml "$app/Contents/Resources/hermes-plugin/"
cp release/stack.json scripts/prepare-runtime.py scripts/connect-hermes-mcp.py "$app/Contents/Resources/"
cp "$binary_dir/Indexa" "$app/Contents/MacOS/Indexa"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
export INDEXA_BUILD_VERSION="$version"
python3 - <<'PY'
import os, pathlib, plistlib, urllib.parse, base64
version = os.environ['INDEXA_BUILD_VERSION']
feed = os.environ.get('INDEXA_UPDATE_FEED', 'https://github.com/this-is-fine-dev/indexa/releases/latest/download/appcast.xml').strip()
key_path = pathlib.Path('release/sparkle-public-key.txt')
key = key_path.read_text().strip() if key_path.exists() else ''
if key and len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit('Invalid update public key')
if feed:
    url = urllib.parse.urlsplit(feed)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('Update feed must use HTTPS without embedded credentials')
    if not key:
        raise SystemExit('Update feed requires release/sparkle-public-key.txt')
plist = dict(CFBundleName='Indexa', CFBundleDisplayName='Indexa', CFBundleIdentifier='local.fine.indexa',
    CFBundleExecutable='Indexa', CFBundlePackageType='APPL', CFBundleShortVersionString=version,
    CFBundleVersion='1' + version, LSMinimumSystemVersion='14.0', LSUIElement=True,
    NSAppleEventsUsageDescription='Indexa zapisuje i odczytuje wskazane notatki Apple Notes przez agenta Hermes po Twojej zgodzie.',
    NSCalendarsFullAccessUsageDescription='Indexa udostępnia Hermesowi istniejące kalendarze i wydarzenia. Odczyt i tworzenie wydarzeń włączasz osobno w Integracjach.',
    NSRemindersFullAccessUsageDescription='Indexa udostępnia Hermesowi istniejące listy i przypomnienia. Odczyt, tworzenie i oznaczanie jako wykonane włączasz osobno w Integracjach.',
    NSHighResolutionCapable=True, SUEnableAutomaticChecks=bool(feed), SUAutomaticallyUpdate=False,
    SUVerifyUpdateBeforeExtraction=True)
if key:
    plist['SUPublicEDKey'] = key
if feed:
    plist['SUFeedURL'] = feed
with open('dist/Indexa.app/Contents/Info.plist', 'wb') as file:
    plistlib.dump(plist, file)
PY
codesign --force --sign - "$app/Contents/Resources/matrix/indexa-qr"
codesign --force --deep --sign "${MACOS_SIGN_IDENTITY:--}" --identifier local.fine.indexa "$app"
codesign --verify --deep --strict "$app"
zip="dist/Indexa-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
printf '%s\n' "$PWD/$app" "$PWD/$zip"
