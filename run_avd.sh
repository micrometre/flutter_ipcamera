#!/usr/bin/env bash
set -euo pipefail

# Navigate to project root
cd "$(dirname "$0")"

# Auto-detect Android SDK and Flutter SDK paths if not already in PATH
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [ -d "$ANDROID_SDK" ]; then
  export PATH="$ANDROID_SDK/emulator:$ANDROID_SDK/platform-tools:$PATH"
fi

if ! command -v flutter >/dev/null 2>&1; then
  if [ -d "$HOME/snap/flutter/common/flutter/bin" ]; then
    export PATH="$HOME/snap/flutter/common/flutter/bin:$PATH"
  elif [ -d "/snap/bin" ]; then
    export PATH="/snap/bin:$PATH"
  fi
fi

# Verify required tools
for cmd in adb emulator flutter; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found in PATH."
    echo "Make sure Flutter and the Android SDK (emulator & platform-tools) are installed and in your PATH."
    exit 1
  fi
done

# Optional --restart flag to reboot running emulator with webcam0 enabled
RESTART_AVD=false
AVD_ARG=""
for arg in "$@"; do
  if [ "$arg" = "--restart" ]; then
    RESTART_AVD=true
  else
    AVD_ARG="$arg"
  fi
done

# Enable laptop webcam (webcam0) for back camera and emulated for front camera
# (A single physical /dev/video0 cannot be claimed by both front and back simultaneously,
# which otherwise causes Android CameraX CameraValidator to fail.)
enable_avd_webcam_config() {
  local avd_name="$1"
  local back_mode="$2"
  local config_file="$HOME/.android/avd/${avd_name}.avd/config.ini"
  if [ -f "$config_file" ]; then
    echo "==> Configuring $avd_name camera (back=$back_mode, front=emulated)..."
    sed -i "s/^hw\.camera\.back\s*=.*/hw.camera.back=$back_mode/" "$config_file"
    sed -i "s/^hw\.camera\.front\s*=.*/hw.camera.front=emulated/" "$config_file"
    grep -q '^hw\.camera\.back=' "$config_file" || echo "hw.camera.back=$back_mode" >> "$config_file"
    grep -q '^hw\.camera\.front=' "$config_file" || echo "hw.camera.front=emulated" >> "$config_file"
  fi
}

get_running_device() {
  adb devices | awk 'NR>1 && ($2=="device" || $2=="offline") {print $1; exit}'
}

DEVICE_ID="$(get_running_device)"

if [ "$RESTART_AVD" = true ] && [ -n "$DEVICE_ID" ]; then
  echo "==> Stopping running emulator ($DEVICE_ID) to apply webcam settings..."
  adb -s "$DEVICE_ID" emu kill >/dev/null 2>&1 || true
  sleep 3
  DEVICE_ID=""
fi

if [ -z "$DEVICE_ID" ]; then
  AVD_NAME="$AVD_ARG"
  if [ -z "$AVD_NAME" ]; then
    AVD_NAME="$(emulator -list-avds | head -n 1)"
  fi

  if [ -z "$AVD_NAME" ]; then
    echo "==> No Android Virtual Devices (AVDs) found. Creating 'ipcamera_avd'..."
    ./create_avd.sh ipcamera_avd
    AVD_NAME="ipcamera_avd"
  fi

  # Use webcam0 if a host webcam (/dev/video0) exists, otherwise fall back to emulated
  CAMERA_MODE="emulated"
  if [ -e /dev/video0 ]; then
    CAMERA_MODE="webcam0"
    echo "==> Detected laptop webcam (/dev/video0) -> using '$CAMERA_MODE' for back camera"
  else
    echo "==> No /dev/video0 detected -> falling back to '$CAMERA_MODE' virtual camera"
  fi

  enable_avd_webcam_config "$AVD_NAME" "$CAMERA_MODE"

  echo "==> Launching AVD: $AVD_NAME (back: $CAMERA_MODE, front: emulated)..."
  emulator -avd "$AVD_NAME" \
    -camera-back "$CAMERA_MODE" \
    -camera-front emulated \
    >/dev/null 2>&1 &

  sleep 2
else
  echo "==> Found running/booting device: $DEVICE_ID"
  # Also update the first AVD's config.ini for future boots
  FIRST_AVD="$(emulator -list-avds | head -n 1)"
  if [ -n "$FIRST_AVD" ]; then
    CAMERA_MODE="emulated"
    [ -e /dev/video0 ] && CAMERA_MODE="webcam0"
    enable_avd_webcam_config "$FIRST_AVD" "$CAMERA_MODE"
  fi
fi

echo "==> Waiting for ADB device to be online..."
adb wait-for-device

echo "==> Waiting for Android system boot to complete..."
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  sleep 2
done

DEVICE_ID="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
echo "==> Emulator $DEVICE_ID is online and ready!"

# Forward port 8080 from host to device so http://localhost:8080 works on your machine
echo "==> Forwarding host port 8080 -> device port 8080..."
adb -s "$DEVICE_ID" forward tcp:8080 tcp:8080

# Pre-grant camera permission if the app is already installed
adb -s "$DEVICE_ID" shell pm grant com.example.flutter_camera android.permission.CAMERA >/dev/null 2>&1 || true

echo "================================================================"
echo "  Stream will be accessible on your computer at:"
echo "  http://localhost:8080"
echo "================================================================"

# Run the Flutter app on the emulator
echo "==> Running Flutter app on $DEVICE_ID..."
flutter run -d "$DEVICE_ID"
