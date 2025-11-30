#include <Wire.h>
#include <U8g2lib.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define OLED_ADDR 0x3C
#define SDA_PIN 4
#define SCL_PIN 5

U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(
  U8G2_R0, U8X8_PIN_NONE, SCL_PIN, SDA_PIN
);

// ====== ШРИФТ (МЕЛКИЙ С КИРИЛЛИЦЕЙ) ======
#define FONT_NAME u8g2_font_6x12_t_cyrillic
const int FONT_W = 6;
const int FONT_H = 12;

// -------- ТЕКСТ СУФЛЁРА --------
String teleText =
  "Привет! Это тест русского текста. "
  "Шрифт мелкий как раньше, скролл плавный. "
  "Команды: p play/pause, d вниз, u вверх, + быстрее, - медленнее.";

// Буфер приёма нового текста
String rxBuffer = "";
volatile bool receivingText = false;
volatile bool newTextReady  = false;

const int MAX_TEXT_LEN = 60000;

// -------- ЗОНА ТЕКСТА: КВАДРАТ 64x64 В ЦЕНТРЕ --------
const int TEXT_W = 64;
const int TEXT_H = 64;

// Центрируем по горизонтали, по вертикали высота равна экрану
const int TEXT_X0 = (128 - TEXT_W) / 2; // (128-64)/2 = 32
const int TEXT_Y0 = (64  - TEXT_H) / 2; // (64-64)/2 = 0

// Сколько символов в строке по ширине квадрата
const int COLS = TEXT_W / FONT_W; // 64/6 = 10 символов

// Плотность строк
const int lineStep = 10;                 // межстрочный шаг
const int VISIBLE_LINES = TEXT_H / lineStep; // 6 строк

int posByte = 0;       // позиция верхней строки в UTF-8 БАЙТАХ
int pixelOffset = 0;   // 0..lineStep-1

// -------- СКРОЛЛ --------
bool isScrolling = false;
int direction = 1;
unsigned long scrollInterval = 80;
unsigned long lastScrollTime = 0;

// -------- BLE --------
static const char* SERVICE_UUID        = "12345678-1234-1234-1234-1234567890ab";
static const char* CHARACTERISTIC_UUID = "abcd1234-5678-90ab-cdef-1234567890ab";

volatile char lastCmd = 0;

// ================= UTF-8 helpers =================
bool isUtf8LeadByte(uint8_t b) { return (b & 0xC0) != 0x80; }

int utf8Next(const String& s, int i) {
  int n = s.length();
  if (i >= n) return n;
  i++;
  while (i < n && !isUtf8LeadByte((uint8_t)s[i])) i++;
  return i;
}

int utf8Prev(const String& s, int i) {
  if (i <= 0) return 0;
  i--;
  while (i > 0 && !isUtf8LeadByte((uint8_t)s[i])) i--;
  return i;
}

int utf8SkipForward(const String& s, int i, int k) {
  int n = s.length();
  int idx = i;
  for (int t = 0; t < k && idx < n; t++) idx = utf8Next(s, idx);
  return idx;
}

// ================= Render =================
void drawFrame() {
  u8g2.clearBuffer();
  u8g2.setFont(FONT_NAME);
  u8g2.setFontPosTop();

  // Клип только в центре: квадрат 64x64
  u8g2.setClipWindow(TEXT_X0, TEXT_Y0, TEXT_X0 + TEXT_W - 1, TEXT_Y0 + TEXT_H - 1);

  int textLen = teleText.length();
  int basePos = posByte;

  for (int line = 0; line <= VISIBLE_LINES; ++line) {
    int yLocal = (line * lineStep) - pixelOffset; // координата внутри квадрата
    if (yLocal < -lineStep || yLocal > (TEXT_H - 1)) continue;

    int cpStart = utf8SkipForward(teleText, basePos, line * COLS);
    if (cpStart >= textLen) continue;

    int cpEnd = utf8SkipForward(teleText, cpStart, COLS);
    if (cpEnd > textLen) cpEnd = textLen;

    String lineStr = teleText.substring(cpStart, cpEnd);

    // Рисуем с учётом смещения квадрата
    u8g2.drawUTF8(TEXT_X0, TEXT_Y0 + yLocal, lineStr.c_str());
  }

  u8g2.setMaxClipWindow();
  u8g2.sendBuffer();
}

// ================= Step one line (when paused) =================
void stepOneLine(int dir) {
  int textLen = teleText.length();

  if (dir > 0) {
    int nextPos = utf8SkipForward(teleText, posByte, COLS);
    int tailCheck = utf8SkipForward(teleText, nextPos, (VISIBLE_LINES + 1) * COLS);
    if (tailCheck < textLen) posByte = nextPos;
  } else {
    for (int k = 0; k < COLS && posByte > 0; k++) {
      posByte = utf8Prev(teleText, posByte);
    }
  }

  pixelOffset = 0;
  drawFrame();
}

// ================= Commands =================
void handleCmd(char cmd) {
  if (cmd == 'p' || cmd == 'P') {
    isScrolling = !isScrolling;
    return;
  }

  if (cmd == 'd' || cmd == 'D') {
    if (!isScrolling) stepOneLine(+1);
    else direction = +1;
    return;
  }


  if (cmd == 'u' || cmd == 'U') {
    if (!isScrolling) stepOneLine(-1);
    else direction = -1;
    return;
  }

  if (cmd == '+') { if (scrollInterval > 20)   scrollInterval -= 10; }
  if (cmd == '-') { if (scrollInterval < 1000) scrollInterval += 10; }
}

// ================= Scroll =================
void updateScroll() {
  if (!isScrolling) return;

  unsigned long now = millis();
  if (now - lastScrollTime < scrollInterval) return;
  lastScrollTime = now;

  int textLen = teleText.length();
  pixelOffset++;

  if (pixelOffset >= lineStep) {
    pixelOffset = 0;

    if (direction > 0) {
      int nextPos = utf8SkipForward(teleText, posByte, COLS);
      int tailCheck = utf8SkipForward(teleText, nextPos, (VISIBLE_LINES + 1) * COLS);
      if (tailCheck < textLen) posByte = nextPos;
      else isScrolling = false;
    } else {
      for (int k = 0; k < COLS && posByte > 0; k++) {
        posByte = utf8Prev(teleText, posByte);
      }
      if (posByte == 0) isScrolling = false;
    }
  }

  drawFrame();
}

// ================= BLE callback =================
class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    String raw = pChar->getValue();
    if (raw.length() == 0) return;

    String cmdCheck = raw;
    cmdCheck.replace("\r", "");
    cmdCheck.replace("\n", "");
    cmdCheck.trim();

    if (cmdCheck == "TSTART") {
      rxBuffer = "";
      receivingText = true;
      return;
    }

    if (receivingText) {
      if (rxBuffer.length() < MAX_TEXT_LEN) {
        rxBuffer += raw;
      }

      int tendPos = rxBuffer.indexOf("TEND");
      if (tendPos >= 0) {
        rxBuffer = rxBuffer.substring(0, tendPos);
        receivingText = false;
        if (rxBuffer.length() > 0) newTextReady = true;
      }
      return;
    }

    if (cmdCheck == "TEND") return;

    if (cmdCheck.length() == 1) {
      lastCmd = cmdCheck[0];
    }
  }
};

void setupBLE() {
  BLEDevice::init("Teleprompter-C3");
  BLEServer* server = BLEDevice::createServer();
  BLEService* service = server->createService(SERVICE_UUID);

  BLECharacteristic* ch = service->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  ch->setCallbacks(new CmdCallbacks());
  ch->addDescriptor(new BLE2902());

  service->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();
}

void setup() {
  Serial.begin(115200);
  Wire.begin(SDA_PIN, SCL_PIN);

  u8g2.begin();
  u8g2.enableUTF8Print();
  u8g2.setFont(FONT_NAME);

  rxBuffer.reserve(MAX_TEXT_LEN);
  teleText.reserve(MAX_TEXT_LEN);

  drawFrame();
  setupBLE();
}

void loop() {
  if (newTextReady) {
    newTextReady = false;

    teleText = rxBuffer;
    rxBuffer = "";

    posByte = 0;
    pixelOffset = 0;
    isScrolling = false;
    drawFrame();
  }

  if (lastCmd) {
    char cmd = lastCmd;
    lastCmd = 0;
    handleCmd(cmd);
  }

  updateScroll();
}
