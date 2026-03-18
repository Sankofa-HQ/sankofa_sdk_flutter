# Sankofa Flutter SDK 🚀

[![Pub Version](https://img.shields.io/pub/v/sankofa_flutter?logo=dart&logoColor=white)](https://pub.dev/packages/sankofa_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official Flutter SDK for [Sankofa Analytics](https://sankofa.dev). Capture every event, resolve user identities, and experience high-fidelity session replays with a single, lightweight package.

---

## ✨ Features

- **Event Tracking**: Send custom events with arbitrary properties and automatic device metadata.
- **Identity Management**: Seamlessly link anonymous users to permanent customer profiles.
- **Session Replay**: 
  - **Wireframe Mode**: Ultra-low bandwidth, high-fidelity UI reconstruction.
  - **Screenshot Mode**: Pixel-perfect visual capture for complex UI debugging.
  - **Auto-masking**: Sensitive data protection via `SankofaMask`.
- **Deep Link Attribution**: Automatically captures UTM parameters from incoming links.
- **Offline Reliability**: Robust local queueing with background auto-flushing.
- **Privacy First**: Choose what to track and what to mask.

---

## 🚀 Quick Start

### 1. Install
Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  sankofa_flutter: ^0.0.1
```

### 2. Initialize
Initialize the SDK in your `main` function before `runApp`.

```dart
import 'package:sankofa_flutter/sankofa_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Sankofa.instance.init(
    apiKey: 'YOUR_PROJECT_API_KEY',
    endpoint: 'https://api.sankofa.dev', // Or your self-hosted instance
    debug: true, // Enable logging for development
  );

  runApp(const MyApp());
}
```

---

## 🛠 Usage Guide

### Event Tracking
Track any user action with a simple method call.

```dart
Sankofa.instance.track('completed_purchase', {
  'item_name': 'Vintage Camera',
  'price': 120.50,
  'currency': 'USD',
});
```

### Identity & Profiles
Identify your users to merge their anonymous history into a single profile.

```dart
// Link anonymous data to a specific user ID
Sankof.instance.identify('user_99');

// Set user attributes
Sankofa.instance.setPerson(
  name: 'Jane Doe',
  email: 'jane@example.com',
  properties: {
    'membership': 'Gold',
  },
);
```

### Session Replay
To enable session replay, wrap your root widget and add the navigator observer.

```dart
MaterialApp(
  navigatorObservers: [SankofaNavigatorObserver()],
  home: const SankofaReplayBoundary(
    child: MyHomePage(),
  ),
);
```

#### Privacy Masking
Hide sensitive UI elements from replays using the `SankofaMask` widget.

```dart
SankofaMask(
  child: TextField(
    controller: _passwordController,
    obscureText: true,
  ),
);
```

---

## 🏗 Modular Architecture (For Contributors)

The Sankofa Flutter SDK is built with a modular, highly-testable architecture:

- **`SankofaClient`**: The primary orchestrator handling initialization and public API dispatching.
- **`QueueManager`**: Manages the persistent local database and background flushing logic.
- **`IdentityManager`**: Handles anonymous ID generation and user state persistence.
- **`SessionManager`**: Manages session rotation and inactivity timeouts.
- **`ReplaySystem`**: A decoupled component consisting of:
    - `Recorder`: Captures UI blueprints or screenshots.
    - `Uploader`: Handles gzip-compressed chunk uploads.
    - `Widgets`: Provides the `SankofaReplayBoundary` and navigation observers.

### Local Development

1. Clone the repo: `git clone https://github.com/saytoonz/Sankofa`
2. Navigate to SDK: `cd sdk/sankofa_flutter`
3. Run tests: `flutter test`
4. Run example app: `cd example && flutter run`

---

## 📑 Documentation

For full API references and integration guides, visit our [Documentation Portal](https://docs.sankofa.dev).

---

## 🛡 License

Distributed under the MIT License. See `LICENSE` for more information.
