SA3AR APP - NEW UI (light dashboard style)

1. Copy into your Flutter project (replace existing files):
     lib/main.dart   lib/core.dart   lib/live.dart   test/price_engine_test.dart
   Keep your own pubspec.yaml and run:
     flutter pub add http html shared_preferences webview_flutter url_launcher
2. Windows: turn on Developer Mode (start ms-settings:developers) so plugins can link.
3. Check:  flutter analyze     Run:  flutter run -d emulator-5554
4. Screens: Welcome/Login -> Search -> Compare & fees -> Alerts (+ Sources tab for live data status).
5. screenshots/ has renders of the 4 screens (illustrative). Replace them with real emulator
   screenshots in the presentation once the app runs.


NEW: product photos + Amazon EG / Noon EG
- Photos come from the store listings; if a product has none, the app looks one up on Amazon EG / Noon EG (only accepted when the titles match).
- Type 3+ letters in Search and tap 'Search' to search Amazon EG and Noon EG for anything.
- Both sites often block automated requests. If the Sources tab shows 'no data' for them, send me the text shown there.
