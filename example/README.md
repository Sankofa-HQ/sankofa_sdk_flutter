# Sankofa Flutter Event Tester

A comprehensive demonstration and debugging app for the **Sankofa Flutter SDK**. This project serves as a "Sandbox" where you can test event ingestion, user identification, and high-fidelity session replays in real-time.

---

## ✨ Features

- **Dynamic Initialization**: Configure your engine URL and API key directly within the app—no hardcoding required.
- **Interactive Event Tracking**: Send custom events with arbitrary properties and see them reflected in your Sankofa dashboard instantly.
- **Identity Resolution**: Test `identify()` and `setPerson()` flows to merge anonymous data with customer profiles.
- **Session Replay (Wireframe Mode)**: Experience low-bandwidth, high-fidelity session recording. The app is pre-configured with a `SankofaReplayBoundary` to demonstrate privacy masking.
- **Automatic Lifecycle Tracking**: Automatically captures app background/foreground transitions and screen views via `SankofaNavigatorObserver`.
- **User Journey Simulation**: A "one-tap" button to simulate a complete e-commerce funnel (Page View -> View Item -> Add to Cart -> Checkout).

---

## 🚀 Getting Started

### 1. Prerequisites
- **Flutter SDK** (Stable channel)
- **Sankofa Engine** (Running locally or in the cloud)

### 2. Setup
Clone the repository and fetch dependencies:
```bash
flutter pub get
```

### 3. Run the App
```bash
flutter run
```

---

## 🔌 Connection Guide

When the app launches, you will see a **Setup Screen**. 

- **Engine URL**: 
  - Use `http://10.0.2.2:8080` for **Android Emulators**.
  - Use `http://localhost:8080` for **iOS Simulators** or **Web**.
  - Use your production domain (e.g., `https://api.sankofa.dev`) if testing against a live server.
- **API Key**: Enter your Project API Key (found in your Sankofa Project Settings).
- **Environment**: If you use a key starting with `sk_test_`, ensure your Sankofa Dashboard is toggled to **"Test Data"** mode to see the events.

---

## 📂 Key Code References

- **SDK Initialization**: See `_SetupScreenState._connect()` in `lib/main.dart`.
- **Custom Tracking**: See `_EventTesterScreenState._sendCustomEvent()`.
- **UI Masking**: Look for `SankofaMask` usage around the API Key field to see how sensitive data is hidden from session replays.
- **Navigation**: Check the `navigatorObservers` property in `MyApp` to see how automated screen tracking is enabled.

---

## 🛡 License

This project is licensed under the MIT License.
