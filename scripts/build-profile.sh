#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  build-profile.sh — dipanggil dari workflow GitHub Actions (build-flutter.yml)
#  Menggantikan baris `flutter build apk ...` lama.
#
#  Input (env):
#    BUILD_TYPE : debug | release      (payload.buildType)
#    PERF_MODE  : fast  | low          (payload.perfMode) — hanya untuk engine flutter
#    ENGINE     : flutter | native     (payload.engine)  native = project Android Gradle
#    PROJECT_DIR: folder yang berisi pubspec.yaml (default: .)
#
#  fast = build tercepat  -> hanya arm64-v8a (HP modern), gradle parallel+cache
#  low  = support HP lama -> armeabi-v7a + arm64-v8a, jalan di device low-end
#
#  Output: APK ada di build/app/outputs/flutter-apk/ ; path ditulis ke
#          $GITHUB_OUTPUT sebagai `apk_path`.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

ENGINE="${ENGINE:-flutter}"
case "$ENGINE" in flutter|native) ;; *) ENGINE=flutter ;; esac
BUILD_TYPE="${BUILD_TYPE:-release}"
PERF_MODE="${PERF_MODE:-fast}"
PROJECT_DIR="${PROJECT_DIR:-.}"

case "$BUILD_TYPE" in debug|release) ;; *) BUILD_TYPE=release ;; esac
case "$PERF_MODE"  in fast|low)      ;; *) PERF_MODE=fast ;; esac

echo "▶ Build profile: type=$BUILD_TYPE perf=$PERF_MODE"

# ── Gradle tuning di level USER (~/.gradle/gradle.properties) ──────────────
# Level user tidak ditimpa project, dan tidak mengubah isi project user.
GRADLE_HOME_DIR="${GRADLE_USER_HOME:-$HOME/.gradle}"
mkdir -p "$GRADLE_HOME_DIR"
GP="$GRADLE_HOME_DIR/gradle.properties"
{
  echo "org.gradle.daemon=true"
  echo "org.gradle.parallel=true"
  echo "org.gradle.caching=true"
  echo "org.gradle.workers.max=4"
  echo "org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+UseParallelGC -Dfile.encoding=UTF-8"
  echo "kotlin.incremental=true"
  echo "kotlin.daemon.jvmargs=-Xmx2g"
} > "$GP"


# ═══ ENGINE NATIVE (Android Gradle: gradlew assemble<Type>) ═══════════════════
if [ "$ENGINE" = "native" ]; then
  echo "▶ Engine NATIVE (Gradle) type=$BUILD_TYPE"
  cd "$PROJECT_DIR"
  # cari root project (folder yang memuat settings.gradle / settings.gradle.kts)
  SETTINGS="$(find . -maxdepth 3 \( -name 'settings.gradle' -o -name 'settings.gradle.kts' \) -not -path '*/node_modules/*' | head -n1 || true)"
  if [ -z "$SETTINGS" ]; then
    echo "✖ settings.gradle tidak ditemukan. Pastikan ZIP berisi project Android (settings.gradle + folder app/)." >&2
    exit 1
  fi
  cd "$(dirname "$SETTINGS")"
  ROOT_DIR="$(pwd)"

  # lisensi & platform Android SDK (runner GitHub sudah punya SDK; ini hanya jaga-jaga)
  if [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
    CSDK="$(grep -RhoE 'compileSdk(Version)?[ =]+[0-9]+' --include=*.gradle --include=*.kts . 2>/dev/null | grep -oE '[0-9]+$' | sort -nr | head -1 || true)"
    if [ -n "$CSDK" ] && [ ! -d "$ANDROID_HOME/platforms/android-$CSDK" ]; then
      yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platforms;android-$CSDK" >/dev/null 2>&1 || true
    fi
  fi

  GR="./gradlew"
  if [ -f ./gradlew ]; then chmod +x ./gradlew; else GR="gradle"; echo "⚠ gradlew tidak ada, memakai gradle bawaan runner"; fi
  [ "$BUILD_TYPE" = "debug" ] && TASK="assembleDebug" || TASK="assembleRelease"

  run_gradle() { $GR --no-daemon --stacktrace --warning-mode=summary "$TASK"; }
  if ! run_gradle; then
    echo "⚠ Gradle gagal, mencoba ulang sekali dengan state bersih..." >&2
    $GR --stop >/dev/null 2>&1 || true
    rm -rf ~/.gradle/daemon 2>/dev/null || true
    run_gradle
  fi

  # cari APK hasil build (utamakan sesuai tipe)
  PAT="*release*.apk"; [ "$BUILD_TYPE" = "debug" ] && PAT="*debug*.apk"
  FOUND="$(find . -path '*/outputs/apk/*' -name "$PAT" -not -name '*unsigned*' | head -n1 || true)"
  [ -z "$FOUND" ] && FOUND="$(find . -path '*/outputs/apk/*' -name '*.apk' | head -n1 || true)"
  if [ -z "$FOUND" ]; then
    echo "✖ APK tidak ditemukan setelah build Gradle." >&2
    exit 1
  fi
  # samakan lokasi dengan engine Flutter agar langkah upload artifact di workflow tidak perlu diubah
  mkdir -p build/app/outputs/flutter-apk
  cp "$FOUND" "build/app/outputs/flutter-apk/app-$BUILD_TYPE.apk"
  APK="build/app/outputs/flutter-apk/app-$BUILD_TYPE.apk"
  echo "✔ APK: $APK ($(du -h "$APK" | cut -f1))"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "apk_path=$ROOT_DIR/$APK" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── Flag flutter per mode ──────────────────────────────────────────────────
# PENTING: ABI WAJIB lewat flag CLI. Flutter selalu mengirim -Ptarget-platform
# sendiri, jadi mengisi target-platform di gradle.properties project tidak
# akan berpengaruh.
if [ "$PERF_MODE" = "low" ]; then
  PLATFORMS="android-arm,android-arm64"
else
  PLATFORMS="android-arm64"
fi

cd "$PROJECT_DIR"
flutter pub get

FLAGS=(--"$BUILD_TYPE" --target-platform "$PLATFORMS" --no-pub)
if [ "$PERF_MODE" = "fast" ]; then
  FLAGS+=(--no-tree-shake-icons)   # lewati langkah tree-shake icon (hemat waktu)
fi

echo "▶ flutter build apk ${FLAGS[*]}"
if ! flutter build apk "${FLAGS[@]}"; then
  # Stabilitas: 1x retry dengan state bersih (daemon/cache Gradle yang macet sering jadi penyebab gagal acak)
  echo "⚠ Build gagal, mencoba ulang sekali dengan state bersih..." >&2
  (cd android 2>/dev/null && ./gradlew --stop >/dev/null 2>&1) || true
  rm -rf ~/.gradle/daemon 2>/dev/null || true
  flutter clean >/dev/null 2>&1 || true
  flutter pub get
  flutter build apk "${FLAGS[@]}"
fi

APK="$(ls -1 build/app/outputs/flutter-apk/app-*.apk 2>/dev/null | head -n1 || true)"
if [ -z "$APK" ]; then
  echo "✖ APK tidak ditemukan di build/app/outputs/flutter-apk/" >&2
  exit 1
fi
echo "✔ APK: $APK ($(du -h "$APK" | cut -f1))"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "apk_path=$PROJECT_DIR/$APK" >> "$GITHUB_OUTPUT"
