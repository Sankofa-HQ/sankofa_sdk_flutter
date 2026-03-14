# Sankofa Flutter SDK

Official Flutter SDK for Sankofa Analytics.

## Features

*   **Offline Support**: Events are queued locally if the network is unavailable.
*   **Auto-Flush**: Events are automatically sent in the background.
*   **Device Context**: Automatically captures OS, version, and device model.
*   **Session Replay**: Wireframe and screenshot-based replay capture for supported platforms.

## Installation

```yaml
dependencies:
  sankofa_flutter:
    path: ../sdk/sankofa_flutter
```

Pass `endpoint` as either:

* A server base URL such as `http://localhost:8080`
* An API base URL such as `http://localhost:8080/api/v1`
* The full ingest URL `http://localhost:8080/api/v1/track`

## Usage

### 1. Initialize

Initialize the SDK in your `main.dart` before `runApp`.

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Sankofa.instance.init(
    apiKey: 'sk_live_12345',
    endpoint: 'http://localhost:8080', // Sankofa Engine base URL
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

## Replay Integration

Wrap your app with `SankofaReplayBoundary` and register `SankofaNavigatorObserver` to capture route and interaction metadata for replays.

```dart
MaterialApp(
  navigatorObservers: [SankofaNavigatorObserver()],
  home: SankofaReplayBoundary(
    child: MyScreen(),
  ),
);
```
