#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./create_avd.sh [avd_name] [system_image_package] [device_profile]
# Example:
#   ./create_avd.sh ipcamera_avd
#   ./create_avd.sh ipcamera_avd "system-images;android-35;google_apis;x86_64" "pixel_6"

AVD_NAME="${1:-ipcamera_avd}"
REQUESTED_PACKAGE="${2:-}"
DEVICE_PROFILE="${3:-pixel_6}"

# Auto-detect Android SDK
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [ ! -d "$ANDROID_SDK" ]; then
  echo "Error: Android SDK directory not found at '$ANDROID_SDK'."
  echo "Set ANDROID_HOME or ANDROID_SDK_ROOT to your Android SDK path."
  exit 1
fi

export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/cmdline-tools/bin:$ANDROID_SDK/emulator:$ANDROID_SDK/platform-tools:$PATH"

for cmd in avdmanager sdkmanager; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found in PATH."
    echo "Ensure Android SDK Command-line Tools are installed in $ANDROID_SDK/cmdline-tools/latest/bin"
    exit 1
  fi
done

# Auto-detect an installed system image if none was specified
detect_installed_system_image() {
  local sys_img_root="$ANDROID_SDK/system-images"
  if [ -d "$sys_img_root" ]; then
    # Look for the newest android-* directory with an installed system.img
    local found
    found="$(find "$sys_img_root" -mindepth 3 -maxdepth 3 -type f -name "source.properties" 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$found" ]; then
      local rel="${found#"$sys_img_root/"}"
      local api_dir
      local tag_dir
      local abi_dir
      api_dir="$(echo "$rel" | cut -d'/' -f1)"
      tag_dir="$(echo "$rel" | cut -d'/' -f2)"
      abi_dir="$(echo "$rel" | cut -d'/' -f3)"
      echo "system-images;${api_dir};${tag_dir};${abi_dir}"
      return 0
    fi
  fi
  return 1
}

SYS_IMG_PACKAGE="$REQUESTED_PACKAGE"
if [ -z "$SYS_IMG_PACKAGE" ]; then
  if SYS_IMG_PACKAGE="$(detect_installed_system_image)"; then
    echo "==> Found installed system image: $SYS_IMG_PACKAGE"
  else
    SYS_IMG_PACKAGE="system-images;android-35;google_apis;x86_64"
    echo "==> No local system image found. Installing $SYS_IMG_PACKAGE via sdkmanager..."
    yes | sdkmanager --licenses >/dev/null 2>&1 || true
    sdkmanager "$SYS_IMG_PACKAGE"
  fi
else
  # Ensure requested system image is installed
  IFS=';' read -r _ api tag abi <<< "$SYS_IMG_PACKAGE"
  if [ ! -d "$ANDROID_SDK/system-images/$api/$tag/$abi" ]; then
    echo "==> Installing system image $SYS_IMG_PACKAGE via sdkmanager..."
    yes | sdkmanager --licenses >/dev/null 2>&1 || true
    sdkmanager "$SYS_IMG_PACKAGE"
  fi
fi

echo "==> Creating AVD '$AVD_NAME' (device: $DEVICE_PROFILE, image: $SYS_IMG_PACKAGE)..."
echo "no" | avdmanager create avd \
  --name "$AVD_NAME" \
  --package "$SYS_IMG_PACKAGE" \
  --device "$DEVICE_PROFILE" \
  --force

CONFIG_FILE="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [ -f "$CONFIG_FILE" ]; then
  BACK_CAM="emulated"
  if [ -e /dev/video0 ]; then
    BACK_CAM="webcam0"
  fi

  echo "==> Configuring hardware properties in $CONFIG_FILE (back=$BACK_CAM, front=emulated)..."
  set_prop() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}\s*=" "$CONFIG_FILE"; then
      sed -i "s|^${key}\s*=.*|${key}=${val}|" "$CONFIG_FILE"
    else
      echo "${key}=${val}" >> "$CONFIG_FILE"
    fi
  }

  set_prop "hw.camera.back" "$BACK_CAM"
  set_prop "hw.camera.front" "emulated"
  set_prop "hw.keyboard" "yes"
  set_prop "hw.gpu.enabled" "yes"
  set_prop "hw.gpu.mode" "auto"
fi

echo "================================================================"
echo "  ✓ AVD '$AVD_NAME' created successfully!"
echo "  Run it with:"
echo "    ./run_avd.sh $AVD_NAME"
echo "================================================================"
