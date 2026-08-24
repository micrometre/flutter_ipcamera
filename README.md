# Flutter IP Webcam

A Flutter application that turns your mobile device into a network IP camera. It captures frames from your phone's camera and streams them over a local or public network using the MJPEG (Motion JPEG) standard, making it accessible from any modern web browser without additional client software.

## Features

- **Full-Screen Camera Preview:** Displays the live camera feed edge-to-edge, adjusting dynamically for both portrait and landscape orientations.
- **Embedded MJPEG HTTP Server:** Hosts an `x-mixed-replace` multipart stream directly from the device via a local `dart:io` HTTP server.
- **Network Interface Detection:** Automatically discovers your device's Wi-Fi interface (`wlan0` on Android, `en0` on iOS) to present the correct local IP.
- **Public IP Discovery:** Fetches your device's public IP address via `api.ipify.org` for external network access (requires router port forwarding).
- **Client Monitoring:** Displays the real-time count of connected viewer clients in the UI.

## Getting Started

### Prerequisites

- Flutter SDK installed (`>=3.0.0`)
- A physical Android or iOS device (emulators may lack camera support or have network bridging complexities).

### Installation

1. Clone or navigate to the repository.
2. Get the dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app on your physical device:
   ```bash
   flutter run
   ```

### Usage

1. Launch the app on your phone.
2. The UI will display two addresses in the overlay:
   - **Local IP:** e.g., `http://192.168.1.50:8080 (Local)`
   - **Public IP:** e.g., `http://203.0.113.45:8080 (Public)`
3. Tap the **Start Streaming** button.
4. Open a web browser on your computer (must be connected to the same Wi-Fi network for Local IP access).
5. Enter the Local IP address displayed on your phone into the browser's address bar.
6. You will see the live camera feed streaming directly to your browser!

> **Note on Public IP Access:** If you want to access the camera over the internet using the Public IP, you must configure your home router to forward port `8080` to your phone's local Wi-Fi IP address.

## Permissions Required

The application automatically requests the following permissions upon installation:
- **Camera:** Required to capture image frames.
- **Microphone:** Included in standard iOS camera setup (though audio streaming is currently disabled in this version).
- **Internet:** Required to bind the local HTTP server and fetch the public IP.
