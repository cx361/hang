# hang

**hang** ist eine location-basierte Social-App, die dir zeigt, wann deine Freunde in deiner Nähe sind – mit voller Kontrolle über deine Privatsphäre.

## 🌟 Features

### 📍 Radar & Location Tracking
- **H3-basiertes Geospatial System**: Nutzt Uber's H3 (Resolution 9) für präzise, privacy-freundliche Standorterfassung
- **19-Zellen kRing**: Erkennt Freunde in einem 2-Ring-Radius um deine Position
- **Hexagon-Visualisierung**: Dynamische Anzeige deines Standort-Sektors mit animierter Glow-Wave
- **Echtzeit-Updates**: Background Location Tracking mit 150m Distanzfilter
- **Location Age**: Zeigt an, wie aktuell die Standorte deiner Freunde sind (<10min, <30min, <1h, <2h, etc.)

### 👥 Freundschaftssystem
- **Handle-basierte Suche**: Finde Freunde über ihren eindeutigen @handle
- **Friend Requests**: Sende, akzeptiere oder lehne Freundschaftsanfragen ab
- **Status-Badges**: Visuelles Feedback für Freundschaftsstatus (Freund, Anfrage gesendet/erhalten)
- **Drei Tabs**: Übersichtliche Trennung von Suche, Anfragen und Freundesliste

### 🕵️ Inkognito-Modus
- **Zeitbasierte Unsichtbarkeit**: Wähle zwischen 30min, 1h, 2h, 6h, 24h oder unbegrenzt
- **Automatische Ablauf-Erkennung**: Timer prüft jede Minute und deaktiviert Inkognito automatisch
- **Live Countdown**: Zeigt verbleibende Zeit in Stunden und Minuten
- **Radar-Deaktivierung**: Keine Freunde-Erkennung während Inkognito aktiv
- **Lila UI-Indikator**: Banner, Hexagon-Center und Button-Styling

### 🛡️ Safe Zones
- **Kartenbasierte Auswahl**: Wähle mehrere H3-Felder auf einer interaktiven Karte
- **Multi-Select**: Tippe Felder an um sie hinzuzufügen/zu entfernen
- **Automatische Erkennung**: App prüft bei jedem Location-Update, ob du in einer Safe Zone bist
- **Radar-Schutz**: Du bist unsichtbar für Freunde, wenn du in einer deiner Safe Zones bist
- **Cyan/Mint UI-Indikator**: Banner, Hexagon-Center und Button-Styling

### 🎨 Moderne UI
- **Dark Theme**: Schwarzer Hintergrund mit Orange/Lila/Cyan Akzenten
- **Bottom Navigation**: Drei Hauptbereiche (Radar, Friends, Settings)
- **Animationen**: Glow Wave mit BlendMode.plus für sanfte Lichteffekte
- **Responsive Design**: Optimiert für iOS und Android

## 🏗️ Technische Architektur

### Frontend (Flutter/Dart)
- **Flutter SDK**: Cross-platform mobile framework
- **h3_flutter**: H3 Geospatial Indexing (Resolution 9, 19-cell kRing)
- **flutter_background_geolocation**: Background Location Tracking
- **flutter_map**: Interactive map display (CartoDB Voyager tiles)
- **latlong2**: Coordinate handling
- **supabase_flutter**: Backend client library
- **flutter_dotenv**: Environment configuration

### Backend (Supabase)

#### Datenbank-Schema

**`profiles` (extends auth.users)**
```sql
- id: UUID (FK to auth.users, Primary Key)
- handle: VARCHAR (UNIQUE, NOT NULL) -- @username
- last_h3_index_res9: VARCHAR -- Aktueller H3-Standort (Hex-String)
- is_in_safe_zone: BOOLEAN (DEFAULT false)
- is_incognito: BOOLEAN (DEFAULT false)
- incognito_until: TIMESTAMP WITH TIME ZONE (NULL = unbegrenzt)
- updated_at: TIMESTAMP WITH TIME ZONE (AUTO)
```

**`friendships`**
```sql
- id: UUID (Primary Key)
- requester_id: UUID (FK to profiles)
- addressee_id: UUID (FK to profiles)
- status: VARCHAR ('pending', 'accepted', 'rejected')
- created_at: TIMESTAMP WITH TIME ZONE
- UNIQUE(requester_id, addressee_id)
```

**`safe_zones`**
```sql
- id: UUID (Primary Key)
- user_id: UUID (FK to profiles)
- name: VARCHAR -- Zone-Name
- h3_index_res9: VARCHAR -- Komma-separierte H3-Indices
- created_at: TIMESTAMP WITH TIME ZONE
```

#### Row Level Security (RLS)
Alle Tabellen nutzen RLS mit `auth.uid()` Checks für maximale Datensicherheit.

### Ablauf: Friend Detection

1. **Location Update** (jeder 150m oder manuell)
2. **H3 Conversion**: GPS → H3 Cell (Resolution 9)
3. **kRing Calculation**: gridDisk(cell, 2) → 19 Zellen
4. **Safe Zone Check**: Prüfe ob eigener Standort in einer Safe Zone
5. **Privacy Check**: Prüfe Inkognito-Status (mit UTC-Zeit)
6. **DB Update**: Schreibe `last_h3_index_res9`, `is_in_safe_zone`, `updated_at`
7. **Friend Query**: 
   - Lade akzeptierte Freundschaften (bidirektional)
   - Filtere nach `last_h3_index_res9 IN kRing`
   - Filtere nach `is_in_safe_zone = false`
   - Filtere Inkognito-User client-side (UTC-Zeit)
8. **UI Update**: Zeige nearby friends mit Hexagon + Glow Wave

### Wichtige Implementierungs-Details

#### H3 Center Cell
- **Index 9** in der 19-Zellen-Liste ist **immer** die Zentral-Zelle
- gridDisk(cell, 2) generiert einen 2-Ring mit der cell in der Mitte

#### UTC DateTime
- Alle Zeitvergleiche nutzen `.toUtc()` für konsistente Zeitzonen
- Verhindert Inkognito-Timer-Bugs durch Timezone-Konfusion

#### Location Updates
- **iOS Simulator**: getCurrentPosition() für sofortigen initialen Standort
- **Background Tracking**: DESIRED_ACCURACY_HIGH, distanceFilter 150m
- **Debug Mode**: Verbose logging für Entwicklung

## 🚀 Setup & Installation

### Voraussetzungen
- Flutter SDK (>=3.0.0)
- Dart SDK
- iOS Development: Xcode, CocoaPods
- Android Development: Android Studio, SDK
- Supabase Account

### 1. Repository klonen
```bash
git clone https://github.com/yourusername/hang.git
cd hang
```

### 2. Dependencies installieren
```bash
flutter pub get
```

### 3. Supabase Setup

#### 3.1 Projekt erstellen
- Gehe zu [supabase.com](https://supabase.com)
- Erstelle ein neues Projekt
- Notiere `SUPABASE_URL` und `SUPABASE_ANON_KEY`

#### 3.2 Datenbank-Schema
Führe folgende SQL-Befehle in der Supabase SQL-Konsole aus:

```sql
-- Profiles Table (extends auth.users)
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  handle VARCHAR UNIQUE NOT NULL,
  last_h3_index_res9 VARCHAR,
  is_in_safe_zone BOOLEAN DEFAULT false,
  is_incognito BOOLEAN DEFAULT false,
  incognito_until TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Friendships Table
CREATE TABLE friendships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  addressee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status VARCHAR NOT NULL CHECK (status IN ('pending', 'accepted', 'rejected')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(requester_id, addressee_id)
);

-- Safe Zones Table
CREATE TABLE safe_zones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name VARCHAR NOT NULL,
  h3_index_res9 VARCHAR NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE safe_zones ENABLE ROW LEVEL SECURITY;

-- Profiles Policies
CREATE POLICY "Users can view all profiles" ON profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- Friendships Policies
CREATE POLICY "Users can view own friendships" ON friendships FOR SELECT 
  USING (auth.uid() = requester_id OR auth.uid() = addressee_id);
CREATE POLICY "Users can insert friendships" ON friendships FOR INSERT 
  WITH CHECK (auth.uid() = requester_id);
CREATE POLICY "Users can update friendships" ON friendships FOR UPDATE 
  USING (auth.uid() = requester_id OR auth.uid() = addressee_id);

-- Safe Zones Policies
CREATE POLICY "Users can view own safe zones" ON safe_zones FOR SELECT 
  USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own safe zones" ON safe_zones FOR INSERT 
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own safe zones" ON safe_zones FOR DELETE 
  USING (auth.uid() = user_id);
```

### 4. Environment Configuration

Erstelle eine `.env` Datei im Root:

```bash
cp lib/.env.example .env
```

Fülle die `.env` mit deinen Supabase-Credentials:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key-here
```

**Wichtig**: Die `.env` ist in `.gitignore` und wird nicht committed!

### 5. App starten

#### iOS
```bash
# Simulator
flutter run -d ios

# Spezifisches Gerät
flutter devices  # Liste verfügbare Geräte
flutter run -d <device-id>
```

#### Android
```bash
flutter run -d android
```

#### macOS (für Development)
```bash
flutter run -d macos
```

### 6. Troubleshooting

#### iOS Simulator zeigt keinen Standort
1. Simulator → Features → Location
2. Wähle "Custom Location" oder "City Run"
3. App nutzt `getCurrentPosition()` für sofortigen ersten Standort

#### Supabase Connection Fehler
- Prüfe `.env` Datei im Root-Verzeichnis
- Verifiziere URL und Key in Supabase Dashboard
- Check Flutter Logs: `flutter logs`

#### H3 Library Fehler
```bash
flutter clean
flutter pub get
```

## 📱 Usage

### 1. Account erstellen
- Email + Password eingeben
- Handle wählen (3-20 Zeichen, nur alphanumerisch + underscore)

### 2. Standort erlauben
- App benötigt "Always" Location Permission
- iOS: Settings → hang → Location → Always

### 3. Freunde hinzufügen
- Friends Tab → Suchen
- @handle eingeben
- "Hinzufügen" Button drücken
- Warte auf Akzeptierung

### 4. Inkognito aktivieren
- Settings → Inkognito-Modus Toggle
- Wähle Dauer
- Radar wird automatisch deaktiviert

### 5. Safe Zones erstellen
- Settings → Safe Zones → FAB Button
- Tippe auf Karte um Felder auszuwählen
- Name eingeben → Speichern

## 🧪 Development

### Debug Logging
Logs sind gefiltert für Production-readiness:
- `[dotenv]` - Environment loading
- `[supabase]` - Backend queries
- `[location]` - GPS updates
- `[radar]` - Friend detection
- `[incognito]` - Privacy mode

### Testing
```bash
# Unit Tests (TODO)
flutter test

# Integration Tests (TODO)
flutter drive --target=test_driver/app.dart
```

### Code Quality
```bash
# Analyze
flutter analyze

# Format
flutter format .
```

## 📂 Projekt-Struktur

```
lib/
├── main.dart                 # App Entry, Radar Tab, H3 Logic
├── auth_wrapper.dart         # Auth State Routing
├── auth_screen.dart          # Login/Signup UI
├── profile_setup_screen.dart # Handle Creation
├── friends_screen.dart       # Friend Management (3 Tabs)
├── settings_screen.dart      # Settings, Inkognito, Safe Zones Link
├── safe_zones_screen.dart    # Safe Zones CRUD + Map
└── glow_wave_overlay.dart    # Animated Radar Wave

assets/
└── .env.example              # Environment template

ios/                          # iOS native code
android/                      # Android native code
```

## 🔐 Privacy & Security

- **Row Level Security**: Alle Daten durch RLS geschützt
- **Keine genauen Koordinaten**: Nur H3-Indices (ca. 175m Durchmesser bei Res 9)
- **Inkognito-Modus**: Vollständige temporäre Unsichtbarkeit
- **Safe Zones**: Permanente Unsichtbarkeit an definierten Orten
- **Friend-only Visibility**: Nur akzeptierte Freunde sehen deinen Standort
- **UTC Timestamps**: Verhindert Client-side Time Manipulation

## 🎨 Design-System

### Farben
- **Primary Background**: `#000000` (Black)
- **Orange (Active)**: `#FF8800` / `#FF8A00`
- **Purple (Incognito)**: `#2D1B3D` / `Colors.deepPurple`
- **Cyan/Mint (Safe Zone)**: `#4DD0E1` / `#1A3A3D`
- **Text Primary**: `Colors.white` / `Colors.white70`
- **Text Secondary**: `Colors.grey`

### Icons
- **Radar**: `Icons.radar` (Custom)
- **Friends**: `Icons.people`
- **Settings**: `Icons.settings`
- **Incognito**: `Icons.visibility_off`
- **Safe Zone**: `Icons.shield`
- **Search**: `Icons.search`

## 🚧 Roadmap

- [ ] Push Notifications wenn Freunde in der Nähe
- [ ] Gruppe-Chats für nearby friends
- [ ] Temporary "Hang Spots" für spontane Meetups
- [ ] Friend Activity Feed
- [ ] Statistics & Heatmaps
- [ ] iOS Widget
- [ ] Android Widget

## 📄 Lizenz

[TODO: Lizenz hinzufügen]

## 👨‍💻 Contributing

[TODO: Contributing Guidelines]

## 📞 Support

Bei Fragen oder Problemen erstelle ein Issue im GitHub Repository.

---

Made with ❤️ and Flutter
