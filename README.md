# pear_messaging

A new Flutter project.

## Getting Started

# Pear Messaging - Secure Local Chat Application

A Flutter mobile application for Android and iOS with local storage, biometric authentication, and real-time messaging using Socket.IO.

## 🚀 Features

- **No Sign-up/Sign-in Required**: Device-based user identity
- **Biometric Authentication**: Face ID, Touch ID, or device PIN on app launch
- **Local Storage**: All messages stored securely on device
- **Real-time Messaging**: Socket-based communication
- **Material 3 Design**: Modern and clean UI
- **Clean Architecture**: Well-structured codebase with separation of concerns
- **State Management**: Using GetX for reactive state management

## 📱 Screens

1. **Splash Screen**: Initial app launch with biometric authentication
2. **Onboarding**: First-time user introduction (3 slides)
3. **Chat List**: Display all conversations with search functionality
4. **Chat Screen**: Real-time messaging interface
5. **Profile**: Device ID display and app settings

## 🛠️ Tech Stack

- **Framework**: Flutter (Dart)
- **State Management**: GetX
- **Local Storage**: Hive
- **Authentication**: local_auth package
- **Networking**: Socket.IO Client
- **UI Components**: Material 3

## 📋 Prerequisites

- Flutter SDK (^3.5.4)
- Dart SDK
- Android Studio / Xcode
- A device with biometric capabilities (for testing)

## 🔧 Installation

1. **Clone the repository**

   ```bash
   cd pear_messaging
   ```

2. **Install dependencies**

   ```bash
   flutter pub get
   ```

3. **Generate Hive adapters** (Optional - for persistent storage)

   ```bash
   flutter pub add build_runner --dev
   flutter pub add hive_generator --dev
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

4. **Configure Socket Server**
   - Update the server URL in `/lib/core/services/socket_service.dart`
   - Default: `http://localhost:3000`

## 🏃 Running the App

### Android

```bash
flutter run
```

### iOS

```bash
cd ios
pod install
cd ..
flutter run
```

## 📱 Platform Configuration

### Android

- Minimum SDK: 21
- Target SDK: Latest
- Permissions added:
  - `USE_BIOMETRIC`
  - `USE_FINGERPRINT`
  - `INTERNET`

### iOS

- Minimum iOS: 11.0
- Info.plist configured with:
  - `NSFaceIDUsageDescription`
  - `NSCameraUsageDescription`

## 🏗️ Project Structure

```
lib/
├── main.dart                 # App entry point
├── app.dart                  # App configuration
├── core/                     # Core functionality
│   ├── constants/           # App constants
│   ├── services/            # Services (auth, socket, storage)
│   ├── theme/               # App theme
│   ├── utils/               # Utility functions
│   └── widgets/             # Reusable widgets
├── features/                 # Feature modules
│   ├── splash/              # Splash screen
│   ├── onboarding/          # Onboarding flow
│   ├── chat_list/           # Chat list screen
│   ├── chat/                # Chat conversation
│   └── profile/             # Profile screen
├── routes/                   # Navigation routes
└── storage/                  # Data models and storage
    ├── models/              # Data entities
    └── adapters/            # Hive adapters
```

## 🔐 Security Features

- **Biometric Authentication**: Required on every app launch
- **Local Storage Only**: No cloud storage of messages
- **Device-based Identity**: No personal information required
- **Encrypted Storage**: Using Hive for secure local storage

## 🚧 TODO / Known Issues

- [ ] Implement actual Socket.IO server
- [ ] Add message encryption
- [ ] Implement push notifications (placeholder)
- [ ] Add message retry mechanism for offline mode
- [ ] Generate Hive adapters for production use
- [ ] Add unit and widget tests
- [ ] Implement message search within chats
- [ ] Add media sharing capabilities

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is for demonstration purposes.

## 🆘 Troubleshooting

### Biometric Authentication Not Working

- Ensure your device has biometric capabilities enabled
- Check that the app has necessary permissions
- For iOS simulator, use Features > Face ID/Touch ID

### Socket Connection Issues

- Verify the server URL in `socket_service.dart`
- Ensure the Socket.IO server is running
- Check network connectivity

### Build Errors

- Run `flutter clean`
- Delete `pubspec.lock` and run `flutter pub get`
- For iOS: Delete `Podfile.lock` and run `pod install`

## 📞 Support

For issues and questions, please create an issue in the repository.
