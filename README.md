# Prompter-glasses
## 1. Сборка проекта

### 1.1 Железо
- ESP32-C3 dev-board (любая совместимая, например ESP32C3 Dev Module).
- OLED SSD1306 128×64 I2C (адрес 0x3C).
- Плата зярядки IP5306

### 1.2 Софт для прошивки ESP
- Arduino IDE **или** PlatformIO (ниже инструкция для Arduino IDE).
- Установленный **ESP32 Arduino Core**.
- Библиотеки Arduino:
  - `U8g2`
  - `ESP32 BLE Arduino`
  - `Wire`

### 1.3 Софт для сборки приложения
- Flutter SDK.
- Android Studio + Android SDK.
- Телефон Android с BLE.

Flutter-зависимости (уже в `pubspec.yaml`):
- `flutter_blue_plus`
- `permission_handler`

---

## 2. Подключение

### 2.1 OLED → ESP32-C3
| OLED SSD1306 | ESP32-C3 |
|---|---|
| VCC | 3V3 |
| GND | GND |
| SDA | GPIO4 |
| SCK | GPIO5 |


## 2. Прошивка ESP32-C3 (Arduino IDE)

1. Установить Arduino IDE.
2. Установить ESP32 core:
   - **File → Preferences → Additional Boards Manager URLs**  
     добавить:
     ```
     https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
     ```
   - **Tools → Board → Boards Manager…**  
     найти `esp32` от Espressif и установить.
3. Установить библиотеки:
   - **Tools → Manage Libraries…**
   - установить `U8g2`
   - установить `ESP32 BLE Arduino`
4. Открыть скетч:
    firmware/esp32/esp32.ino
5. Выбрать плату:
- **Tools → Board → ESP32 Arduino → ESP32C3 Dev Module**  
6. Выбрать порт:
- **Tools → Port → COMx**
7. Нажать **Upload**.

## 3. Сборка и запуск Flutter-приложения

1. Убедитесь что Flutter установлен:
   ```bash
   flutter --version
   flutter doctor
2. Перейдите в папку приложения:
    cd teleprompter_remote
3. Подтяните зависимости:
    flutter pub get
4. Запустите на подключённом телефоне:
    flutter run
5. (Опционально) Соберите APK:
    flutter build apk --release

## 4. 3D модели

 - 3D модели корпуса и других компнентов лежат в папке `models`
 - В этой папке предствлены файлы с 3D моделями в 2 расширениях: .m3d и .stl

