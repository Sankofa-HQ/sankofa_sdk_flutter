# Sankofa Flutter SDK

Official Flutter SDK for Sankofa Analytics.

## Features

*   **Offline Support**: Events are queued locally if the network is unavailable.
*   **Auto-Flush**: Events are automatically sent in the background.
*   **Device Context**: Automatically captures OS, version, and device model.

## Installation

```yaml
dependencies:
  sankofa_flutter:
    path: ../sdk/sankofa_flutter
```

## Usage

### 1. Initialize

Initialize the SDK in your `main.dart` before `runApp`.

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Sankofa.instance.init(
    apiKey: 'sk_live_12345',
    endpoint: 'http://localhost:8080/v1/track', // Connect to your Engine
    debug: true,
  );
  
  runApp(MyApp());
}
```

### 2. Identify User

```dart
Sankofa.instance.identify('user_123');
```

### 3. Track Events

```dart
await Sankofa.instance.track('button_clicked', {
  'bg_color': 'blue',
  'screen': 'home',
});
```
