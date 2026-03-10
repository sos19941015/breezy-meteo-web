# Breezy Meteo Web

A Flutter Web weather app inspired by the Breezy Weather visual style, powered by Open-Meteo APIs.

## Features
- GPS locate + IP fallback locate
- City search (Nominatim) and reverse geocoding
- Favorite cities (local storage)
- Current weather summary
- Hourly forecast
- Daily forecast
- Life index cards (AQI, humidity, cloud cover, visibility, pressure, sun, moon, UV)
- Dynamic weather effects (rain/snow/thunder/fog/etc.)
- Material 3 themed UI with mobile-style centered layout

## Tech Stack
- Flutter Web
- Open-Meteo Forecast API
- Open-Meteo Air Quality API
- Nominatim (search/reverse geocoding)
- `geolocator`, `http`, `shared_preferences`

## Run Locally
```powershell
flutter pub get
flutter run -d chrome
```

## Build Web
```powershell
flutter build web
```

## Serve Build Locally
```powershell
python -m http.server 5310 --bind 0.0.0.0 --directory build/web
```
Then open:
- Desktop: `http://localhost:5310/`
- Phone (same Wi-Fi): `http://<your-lan-ip>:5310/`

## Deploy to GitHub Pages
From project root:

```powershell
flutter build web --base-href /breezy-meteo-web/
```

Then publish `build/web` to your Pages source branch (for example `gh-pages`), or via GitHub Actions.

If using `gh-pages` branch manually:
1. Create/switch to `gh-pages`
2. Copy contents of `build/web` to branch root
3. Commit and push
4. In GitHub repo settings, set Pages source to `gh-pages` branch root

## Project Structure
- App entry: `lib/main.dart`
