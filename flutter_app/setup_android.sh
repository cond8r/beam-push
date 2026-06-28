#!/bin/bash
# Run this once in a terminal with your VPN/proxy configured
# Scaffolds the Android platform and builds the APK

set -e

# Chinese Flutter mirrors (helps with network issues)
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

cd "$(dirname "$0")"

echo "=== Step 1: Add Android platform scaffold ==="
flutter create --org com.fangduo --platforms=android .

echo "=== Step 2: Restore custom AndroidManifest.xml ==="
# The scaffold overwrites AndroidManifest.xml — restore our version
cat > android/app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>

    <application
        android:label="Beam"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
              android:name="io.flutter.embedding.android.NormalTheme"
              android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="text/plain"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
        </activity>

        <service
            android:name="com.google.firebase.messaging.FirebaseMessagingService"
            android:exported="false">
            <intent-filter>
                <action android:name="com.google.firebase.MESSAGING_EVENT"/>
            </intent-filter>
        </service>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2"/>
    </application>
</manifest>
EOF

echo "=== Step 3: Get dependencies ==="
flutter pub get

echo ""
echo "=== NOTE: FCM / Firebase setup ==="
echo "Before building, you need google-services.json:"
echo "  1. Create project at https://console.firebase.google.com"
echo "  2. Add Android app with package: com.fangduo.beam"
echo "  3. Download google-services.json → place in android/app/"
echo "  4. Add FCM server key to VPS: BEAM_FCM_KEY=<key>"
echo ""
echo "=== Step 4: Build APK (without FCM is fine too) ==="
# Remove firebase from pubspec if no google-services.json
if [ ! -f android/app/google-services.json ]; then
  echo "No google-services.json found — removing Firebase from build..."
  sed -i '' '/firebase_core\|firebase_messaging/d' pubspec.yaml
  # Also comment out fcm_service import in main.dart
fi

flutter build apk --release
echo ""
echo "APK built at: build/app/outputs/flutter-apk/app-release.apk"
