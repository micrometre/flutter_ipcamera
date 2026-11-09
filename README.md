# IP Camera

A Flutter application that turns your mobile device (or Android emulator) into a network IP camera. It captures frames from the camera and streams them over a local or public network using the MJPEG (Motion JPEG) standard, making it accessible from any modern web browser without additional client software.

## Features

- **Full-Screen Camera Preview:** Displays the live camera feed edge-to-edge, adjusting dynamically for both portrait and landscape orientations.
- **Embedded MJPEG HTTP Server:** Hosts an `x-mixed-replace` multipart stream (`/stream`) and a web viewer UI (`/`) directly from the device via a local `dart:io` HTTP server on port `8080`.
- **Browser Snapshot Capture:** Includes a **Take Snapshot** button in the web interface to download a JPEG capture directly from the live stream.
- **Network Interface Detection:** Automatically discovers your device's Wi-Fi interface (`wlan0` on Android, `en0` on iOS) to present the correct local IP.
- **Public IP Discovery:** Fetches your device's public IP address via `api.ipify.org` for external network access (requires router port forwarding).
- **Client Monitoring:** Displays the real-time count of connected viewer clients in the UI.
- **Laptop Webcam Passthrough on AVD:** Automatically selects the back/external camera (`webcam0` on Android Emulator) so you can test the full streaming pipeline using your computer's physical webcam.

## Getting Started

### Prerequisites

- Flutter SDK installed (`>=3.0.0`)
- A physical Android/iOS device **or** the Android SDK (`adb`, `emulator`, `avdmanager`, `sdkmanager`) for testing on an Android Virtual Device (AVD).

### Running on a Physical Device

1. Clone or navigate to the repository.
2. Get the dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app on your connected device:
   ```bash
   flutter run
   ```

### Testing on an Android Emulator (AVD)

Helper scripts are included to create and launch an Android Virtual Device configured with your laptop's webcam (`/dev/video0` as `webcam0`) and automatic ADB port forwarding:

1. **Create an AVD (optional if you already have one):**
   ```bash
   # Creates 'ipcamera_avd' (pixel_6 profile, Android 35 x86_64) configured with webcam0
   ./create_avd.sh

   # Or specify a custom AVD name, system image, and device profile:
   ./create_avd.sh my_avd "system-images;android-35;google_apis;x86_64" "pixel_6"
   ```

2. **Boot the AVD and run the app:**
   ```bash
   # Boots the first available AVD (or creates 'ipcamera_avd' if none exist),
   # attaches your laptop webcam (webcam0), forwards port 8080, and runs the app:
   ./run_avd.sh

   # Or target a specific AVD:
   ./run_avd.sh ipcamera_avd

   # Restart an already-running emulator to apply webcam settings:
   ./run_avd.sh --restart
   ```

3. **View the stream from the emulator:**
   - Because `run_avd.sh` runs `adb forward tcp:8080 tcp:8080`, tap **Start Streaming** in the emulator and open [http://localhost:8080](http://localhost:8080) in your computer's browser.

### Usage on a Physical Phone

1. Launch the app on your phone.
2. The UI will display two addresses in the overlay:
   - **Local IP:** e.g., `http://192.168.1.50:8080 (Local)`
   - **Public IP:** e.g., `http://203.0.113.45:8080 (Public)`
3. Tap the **Start Streaming** button.
4. Open a web browser on your computer (must be connected to the same Wi-Fi network for Local IP access).
5. Enter the Local IP address displayed on your phone into the browser's address bar.
6. You will see the live camera feed streaming directly to your browser and can click **Take Snapshot** to save a frame as a JPEG.

> **Note on Public IP Access:** If you want to access the camera over the internet using the Public IP, you must configure your home router to forward port `8080` to your phone's local Wi-Fi IP address.

## CI/CD & Releases

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs automatically on pushes and pull requests to `main`/`master` and on `v*` tags:

1. **Validate Configs & Scripts:** Checks shell script syntax (`run_avd.sh`, `create_avd.sh`), `pubspec.yaml`, and `AndroidManifest.xml`.
2. **Flutter Format & Analyze:** Sets up Java 17 and Flutter (`stable`), then runs `flutter analyze` and `flutter test`.
3. **Build & Release Android APK:** Builds `app-release.apk`, uploads it as a workflow artifact, and publishes `ip_camera_<version>_release.apk` to **GitHub Releases**.

## Permissions Required

The application automatically requests the following permissions upon installation:
- **Camera:** Required to capture image frames.
- **Microphone:** Included in standard iOS camera setup (though audio streaming is currently disabled in this version).
- **Internet:** Required to bind the local HTTP server and fetch the public IP.
