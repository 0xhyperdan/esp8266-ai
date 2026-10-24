// ESP8266/ESP32 WiFi clock with weather, music, stocks, salary, and device
// administration pages.
//
// Display: 240x240 SPI ST7789 (TFT_eSPI). Pin mapping is set via build_flags
// in platformio.ini - edit those if your wiring differs.

#include <Arduino.h>
#include <WiFiManager.h>
#include <ArduinoJson.h>
#include <TFT_eSPI.h>
#if defined(ESP32)
#include <Update.h>
#else
#include <Updater.h>
#endif

#include "config.h"
#include "hardware_features.h"
#include "platform_compat.h"
#include "printer_monitor.h"
#include "img/ui_labels_zh.h"

TFT_eSPI tft = TFT_eSPI();
AIClockWebServer webServer(80);
void drawBatteryIndicator();
#include "printer_screen.h"
void fillPrinterInfo(JsonObject object);

// Shared one-row scratch buffer for the music, weather and stock binary transports.
const int SCREEN_CX = 120, SCREEN_CY = 120;
uint16_t rowBuf[SCREEN_W];

bool fileSystemReady = false;

// Display override, settable from the Mac app via POST /api/display. Weather is
// the default; music/stock are bridge-fed; salary is device-owned (it receives
// the bridge clock timestamp).
enum DisplayMode {
  MODE_MUSIC,
  MODE_STOCK,
  MODE_WEATHER,
  MODE_SALARY,
  MODE_PRINTER
};
DisplayMode displayMode = MODE_WEATHER;
DisplayMode effectiveMode();
bool wiredActive();
void drawSquareRing(float pct, uint16_t color);

// When the default weather page is active and the Mac reports audio playing,
// the screen temporarily promotes to music and returns when playback stops.
bool statusMusicPlaying = false;
unsigned long bridgeEpoch = 0;
unsigned long bridgeEpochReceivedAtMs = 0;
DisplayMode lastEffectiveMode = MODE_WEATHER;

// ---------- salary clock ----------
// Values are stored in fen/minutes so configuration is deterministic on both
// ESP8266 and ESP32. A zero monthly salary keeps the page in setup state.
struct SalaryConfig {
  long monthlyFen = 0;
  int startMin = SALARY_DEFAULT_START_MIN;
  int endMin = SALARY_DEFAULT_END_MIN;
  int lunchStartMin = SALARY_DEFAULT_LUNCH_START_MIN;
  int lunchEndMin = SALARY_DEFAULT_LUNCH_END_MIN;
};
SalaryConfig salaryConfig;
bool salaryChromeDrawn = false;
String salaryLastEarned;
String salaryLastStatus;

// ---------- music mode state ----------
const int MUSIC_COVER_W = 128;
const int MUSIC_COVER_H = 128;
// Title/artist come as a Mac-rendered bitmap strip (232x44) because the
// panel fonts are ASCII-only and CJK titles would render as blanks.
const int MUSIC_TEXT_W = 232;
const int MUSIC_TEXT_H = 44;
const int MUSIC_TEXT_X = 4, MUSIC_TEXT_Y = 150;
const unsigned long MUSIC_POLL_INTERVAL_MS = 2000;
// ---------- stock watchlist mode state ----------
// Rows come pre-formatted from the bridge (GET /stock or serial #STOCK):
// ASCII code + price/pct strings + up flag, so the firmware just paints.
const unsigned long STOCK_POLL_INTERVAL_MS = 5000;
const int MAX_STOCKS = 5;
const int STOCK_ROW_Y = 4;
struct StockRow {
  String code, price, pct;
  int up = 0; // 1 rising (red, CN convention) / -1 falling (green) / 0 flat
};
StockRow stocks[MAX_STOCKS];
int stockCount = 0;
int stockRowHeight() { return 220 / max(1, stockCount); }
int stockRowTop(int index) {
  return STOCK_ROW_Y + index * stockRowHeight() + (stockRowHeight() - 44) / 2;
}
bool stockEverLoaded = false;
bool stockDirty = false;
bool stockChromeDrawn = false;
String stockLastCode[MAX_STOCKS]; // top line (CJK name strip + code)
String stockLastVal[MAX_STOCKS];  // value line (price + pct)
int ringLastPct = -1000;
String pctText(float pct) { return pct >= 0 ? String((int)pct) + "%" : "-"; }
unsigned long lastStockPollMs = 0;
// CJK names come as bridge-rendered RGB565 strips (GET /stock/names-v2.raw, one
// 156x16 strip per row) - names_rev says when to re-fetch. -1 = not drawn.
const int STOCK_NAME_W = 156, STOCK_NAME_H = 16;
const char *STOCK_NAMES_SERIAL_FILE = "/stock_names.raw";
const char *STOCK_NAMES_SERIAL_TEMP_FILE = "/stock_names.tmp";
int stockNamesRev = -1;
int stockNamesDrawnRev = -1;
int serialStockNamesRev = -1;

String musicTitle, musicArtist, musicAlbum;
bool musicPlaying = false;
int musicElapsed = 0, musicDuration = 0;
int musicArtworkRev = -1;
int musicTextRev = -1;
bool musicHasArtwork = false;
bool musicChromeDrawn = false;
unsigned long lastMusicPollMs = 0;

// ---------- FuBoTV-style weather clock state ----------
// The Mac renders the Chinese chrome and weather artwork as one RGB565 frame.
// The device streams it row-by-row, then owns the seconds field locally so a
// full 115 KB image is only fetched when the minute or weather data changes.
const unsigned long WEATHER_POLL_INTERVAL_MS = 5000;
const int WEATHER_SECONDS_X = 211;
const int WEATHER_SECONDS_Y = 120;
const int WEATHER_SECONDS_OWNER_X = 196;
const int WEATHER_SECONDS_OWNER_Y = 101;
const int WEATHER_SECONDS_OWNER_W = 40;
const int WEATHER_SECONDS_OWNER_H = 38;
const char *WEATHER_ASTRONAUT_FILE = "/wa.bin";
const char *WEATHER_ASTRONAUT_TEMP_FILE = "/wa.tmp";
const char *WEATHER_ASTRONAUT_BACKUP_FILE = "/wa.bak";
const int WEATHER_ASTRONAUT_X = 168;
const int WEATHER_ASTRONAUT_Y = 168;
const int WEATHER_ASTRONAUT_W = 72;
const int WEATHER_ASTRONAUT_H = 72;
const int WEATHER_ASTRONAUT_FRAME_COUNT = 20;
const size_t WEATHER_ASTRONAUT_FRAME_BYTES =
    (size_t)WEATHER_ASTRONAUT_W * WEATHER_ASTRONAUT_H * 2;
const size_t WEATHER_ASTRONAUT_PACK_BYTES =
    2 + (size_t)WEATHER_ASTRONAUT_FRAME_COUNT * WEATHER_ASTRONAUT_FRAME_BYTES;
const unsigned long WEATHER_ASTRONAUT_INTERVAL_MS = 30;
const unsigned long WEATHER_ASTRONAUT_RETRY_MS = 60000;
unsigned long lastWeatherPollMs = 0;
unsigned long weatherEpoch = 0;
unsigned long weatherEpochReceivedAtMs = 0;
long weatherScreenRev = -1;
long weatherScreenDrawnRev = -1;
int weatherAstronautRevision = -1;
int weatherAstronautLoadedRevision = -1;
int weatherAstronautFrames = 0;
int weatherAstronautFrame = 0;
unsigned long lastWeatherAstronautMs = 0;
unsigned long lastWeatherAstronautDownloadMs = 0;
int weatherLastSecond = -1;
bool weatherChromeDrawn = false;
bool weatherBaseCacheValid = false;
uint32_t weatherRowFingerprints[SCREEN_H];
uint32_t updateCrc32(uint32_t crc, const uint8_t *data, size_t length);
void renderWeatherBaseRow(int row, bool forceFullRepaint);


// Bridge host is not asked for during first-time WiFi setup: the Mac/Windows
// bridge discovers the device and pairs automatically (or set via /api/bridge).
String bridgeHost;

unsigned long lastPollMs = 0;
unsigned long lastSuccessMs = 0;
bool everPolled = false;
bool mainUiShown = false;      // false while the config-portal screen is up
bool webServerStarted = false; // deferred: port 80 clashes with the portal

// ---------- backlight brightness ----------
// The panel backlight (TFT_BL, active LOW) is PWM-dimmable — the vendor's own
// firmware does the same. 0 = off, 100 = full. Persisted so it survives reboot.

int brightness = BRIGHTNESS_DEFAULT; // 0-100
bool autoRotateEnabled = true;
uint8_t screenRotation = 0;

void applyBrightness() {
  platformWriteBacklight(brightness);
}

void loadBrightness() {
  if (!LittleFS.exists(BRIGHTNESS_FILE)) return;
  File f = LittleFS.open(BRIGHTNESS_FILE, "r");
  if (!f) return;
  int v = f.readStringUntil('\n').toInt();
  f.close();
  if (v >= 0 && v <= 100) brightness = v;
}

void saveBrightness() {
  File f = LittleFS.open(BRIGHTNESS_FILE, "w");
  if (!f) return;
  f.println(brightness);
  f.close();
}

void applyExplicitBrightness(int level) {
  brightness = constrain(level, 0, 100);
  applyBrightness();
}

void loadOrientationConfig() {
  if (!LittleFS.exists(ORIENTATION_CONFIG_FILE)) return;
  File f = LittleFS.open(ORIENTATION_CONFIG_FILE, "r");
  if (!f) return;
  autoRotateEnabled = f.readStringUntil('\n').toInt() != 0;
  f.close();
}

void saveOrientationConfig() {
  if (!fileSystemReady) return;
  File f = LittleFS.open(ORIENTATION_CONFIG_FILE, "w");
  if (!f) return;
  f.println(autoRotateEnabled ? 1 : 0);
  f.close();
}

// ---------- persistence for the bridge host ----------

void loadBridgeHost() {
  if (LittleFS.exists(WIFI_CONFIG_FILE)) {
    File f = LittleFS.open(WIFI_CONFIG_FILE, "r");
    bridgeHost = f.readStringUntil('\n');
    bridgeHost.trim();
    f.close();
  }
}

void saveBridgeHost(const String &host) {
  File f = LittleFS.open(WIFI_CONFIG_FILE, "w");
  f.println(host);
  f.close();
}

// ---------- persistence for salary clock ----------

bool validSalaryConfig(const SalaryConfig &value) {
  if (value.monthlyFen < 0 || value.monthlyFen > 1000000000L) return false;
  if (value.startMin < 0 || value.endMin > 1439 || value.startMin >= value.endMin) return false;
  bool hasLunch = value.lunchStartMin != value.lunchEndMin;
  if (!hasLunch) return true;
  return value.lunchStartMin >= value.startMin &&
         value.lunchEndMin <= value.endMin &&
         value.lunchStartMin < value.lunchEndMin;
}

bool configureSalary(long monthlyFen, int startMin, int endMin,
                     int lunchStartMin, int lunchEndMin) {
  SalaryConfig next;
  next.monthlyFen = monthlyFen;
  next.startMin = startMin;
  next.endMin = endMin;
  next.lunchStartMin = lunchStartMin;
  next.lunchEndMin = lunchEndMin;
  if (!validSalaryConfig(next)) return false;
  salaryConfig = next;
  salaryChromeDrawn = false;
  salaryLastEarned = "";
  salaryLastStatus = "";
  if (fileSystemReady) {
    File f = LittleFS.open(SALARY_CONFIG_FILE, "w");
    if (f) {
      f.printf("%ld,%d,%d,%d,%d\n", salaryConfig.monthlyFen,
               salaryConfig.startMin, salaryConfig.endMin,
               salaryConfig.lunchStartMin, salaryConfig.lunchEndMin);
      f.close();
    }
  }
  return true;
}

void loadSalaryConfig() {
  if (LittleFS.exists(SALARY_CONFIG_FILE)) {
    File f = LittleFS.open(SALARY_CONFIG_FILE, "r");
    if (f) {
      SalaryConfig loaded;
      loaded.monthlyFen = f.readStringUntil(',').toInt();
      loaded.startMin = f.readStringUntil(',').toInt();
      loaded.endMin = f.readStringUntil(',').toInt();
      loaded.lunchStartMin = f.readStringUntil(',').toInt();
      loaded.lunchEndMin = f.readStringUntil('\n').toInt();
      f.close();
      if (validSalaryConfig(loaded)) salaryConfig = loaded;
    }
  }
}

// ---------- atomic binary transfer recovery ----------

void recoverAtomicTransfer(const char *binPath, const char *tempPath, const char *backupPath) {
  if (!LittleFS.exists(binPath) && LittleFS.exists(backupPath)) {
    LittleFS.rename(backupPath, binPath);
  } else {
    LittleFS.remove(backupPath);
  }
  LittleFS.remove(tempPath);
}

bool ensureFileSystem(bool formatOnFailure) {
  if (fileSystemReady) return true;
  fileSystemReady = LittleFS.begin();
  if (fileSystemReady || !formatOnFailure) return fileSystemReady;

  Serial.println("[fs] mount failed; formatting after explicit upload request");
  LittleFS.end();
  if (!LittleFS.format()) return false;
  fileSystemReady = LittleFS.begin();
  return fileSystemReady;
}

bool inspectWeatherAstronautFile(const char *path, bool applyState) {
  if (!fileSystemReady || !LittleFS.exists(path)) return false;
  File file = LittleFS.open(path, "r");
  if (!file || file.size() < 2) {
    if (file) file.close();
    return false;
  }

  const int revision = file.read();
  const int frameCount = file.read();
  const size_t expected =
      2 + (size_t)frameCount * WEATHER_ASTRONAUT_FRAME_BYTES;
  const bool valid =
      revision >= 0 && frameCount > 0 &&
      frameCount <= WEATHER_ASTRONAUT_FRAME_COUNT &&
      (size_t)file.size() == expected;
  file.close();
  if (!valid) return false;

  if (applyState) {
    weatherAstronautLoadedRevision = revision;
    weatherAstronautFrames = frameCount;
    weatherAstronautFrame = 0;
    Serial.printf("[weather] astronaut revision=%d frames=%d\n", revision, frameCount);
  }
  return true;
}

void loadWeatherAstronautState() {
  recoverAtomicTransfer(
      WEATHER_ASTRONAUT_FILE,
      WEATHER_ASTRONAUT_TEMP_FILE,
      WEATHER_ASTRONAUT_BACKUP_FILE);
  weatherAstronautLoadedRevision = -1;
  weatherAstronautFrames = 0;
  inspectWeatherAstronautFile(WEATHER_ASTRONAUT_FILE, true);
}

void drawCenteredMonoLabel(const uint8_t *bits, int width, int height, int centerX, int y,
                           uint16_t color) {
  int rowBytes = (width + 7) / 8;
  int x0 = centerX - width / 2;
  uint16_t packedColor = (uint16_t)((color << 8) | (color >> 8));
  for (int row = 0; row < height; row++) {
    for (int x = 0; x < width; x++) {
      uint8_t packed = pgm_read_byte(bits + row * rowBytes + x / 8);
      rowBuf[x] = (packed & (0x80 >> (x & 7))) ? packedColor : TFT_BLACK;
    }
    tft.pushImage(x0, y + row, width, 1, rowBuf);
  }
}

// ---------- Salary clock ----------

unsigned long salaryCurrentEpoch() {
  if (bridgeEpoch == 0) return 0;
  return bridgeEpoch + (millis() - bridgeEpochReceivedAtMs) / 1000UL;
}

int salaryWeekday(unsigned long localEpoch) {
  // Unix day 0 was Thursday; return Sunday = 0 ... Saturday = 6.
  long days = (long)(localEpoch / 86400UL);
  int weekday = (int)((days + 4L) % 7L);
  return weekday < 0 ? weekday + 7 : weekday;
}

int salaryDailyWorkSeconds() {
  int total = (salaryConfig.endMin - salaryConfig.startMin) * 60;
  if (salaryConfig.lunchStartMin != salaryConfig.lunchEndMin) {
    total -= (salaryConfig.lunchEndMin - salaryConfig.lunchStartMin) * 60;
  }
  return max(1, total);
}

long salaryElapsedWorkSeconds(unsigned long localEpoch) {
  if (localEpoch == 0 || salaryWeekday(localEpoch) == 0 || salaryWeekday(localEpoch) == 6) return 0;
  long daySecond = (long)(localEpoch % 86400UL);
  long startSecond = (long)salaryConfig.startMin * 60L;
  long endSecond = (long)salaryConfig.endMin * 60L;
  long elapsed = constrain(daySecond - startSecond, 0L, endSecond - startSecond);
  if (salaryConfig.lunchStartMin != salaryConfig.lunchEndMin) {
    long lunchStart = (long)salaryConfig.lunchStartMin * 60L;
    long lunchEnd = (long)salaryConfig.lunchEndMin * 60L;
    elapsed -= constrain(daySecond - lunchStart, 0L, lunchEnd - lunchStart);
  }
  return max(0L, min(elapsed, (long)salaryDailyWorkSeconds()));
}

String salaryTimeInput(int minute) {
  char text[6];
  snprintf(text, sizeof(text), "%02d:%02d", minute / 60, minute % 60);
  return String(text);
}

int parseSalaryTime(const String &value) {
  int separator = value.indexOf(':');
  if (separator < 0) return value.toInt();
  int hour = value.substring(0, separator).toInt();
  int minute = value.substring(separator + 1).toInt();
  return hour * 60 + minute;
}

String salaryStatusText(unsigned long localEpoch) {
  if (salaryConfig.monthlyFen <= 0) return "CONFIGURE SALARY";
  if (localEpoch == 0) return "WAITING FOR CLOCK";
  int weekday = salaryWeekday(localEpoch);
  if (weekday == 0 || weekday == 6) return "WEEKEND - PAUSED";
  int dayMinute = (int)((localEpoch % 86400UL) / 60UL);
  if (dayMinute < salaryConfig.startMin) return "BEFORE WORK";
  if (dayMinute >= salaryConfig.endMin) return "WORKDAY COMPLETE";
  if (salaryConfig.lunchStartMin != salaryConfig.lunchEndMin &&
      dayMinute >= salaryConfig.lunchStartMin && dayMinute < salaryConfig.lunchEndMin) {
    return "LUNCH BREAK - PAUSED";
  }
  return "EARNING NOW";
}

double salaryRatePerSecond() {
  if (salaryConfig.monthlyFen <= 0) return 0;
  return (salaryConfig.monthlyFen / 100.0) /
         (SALARY_MONTHLY_WORKDAYS * salaryDailyWorkSeconds());
}

// Poster-style palette for the salary page: pure-black sky, gold coins and a
// gold progress bar, matching the 每秒进账 reference design.
const uint16_t SALARY_BG = 0x0000;        // TFT_BLACK sky
const uint16_t SALARY_GOLD = 0xFE69;      // #FFCF4D big number / bar fill
const uint16_t SALARY_GOLD_MID = 0xF5C7;  // #F5B93E coin face
const uint16_t SALARY_GOLD_DIM = 0xCCA3;  // #C8971F coin rim / inner ring
const uint16_t SALARY_COIN_MARK = 0x8AC2; // #8A5A14 ¥ strokes
const uint16_t SALARY_MUTED = 0x9516;     // #97A0B5 grey-blue captions
const uint16_t SALARY_TRACK = 0x29AA;     // #2C3550 bar track
const uint16_t SALARY_SPARK = 0x6AC5;     // #6B5A2A dim gold sparkle dots

String salaryLastPctLine;
int salaryLastPct = -1;

// Mono label blit with an explicit background so dynamic strips repaint
// cleanly over the black sky (drawCenteredMonoLabel always paints black).
void drawSalaryLabel(const uint8_t *bits, int width, int height, int x, int y,
                     uint16_t color, uint16_t bg) {
  const int rowBytes = (width + 7) / 8;
  const uint16_t packedColor = (uint16_t)((color << 8) | (color >> 8));
  const uint16_t packedBg = (uint16_t)((bg << 8) | (bg >> 8));
  for (int row = 0; row < height; row++) {
    const uint8_t *rowPtr = bits + row * rowBytes;
    for (int col = 0; col < width; col++) {
      uint8_t packed = pgm_read_byte(rowPtr + col / 8);
      rowBuf[col] = (packed & (0x80 >> (col & 7))) ? packedColor : packedBg;
    }
    tft.pushImage(x, y + row, width, 1, rowBuf);
  }
}

// Gold coin: dark rim, bright face, inner ring, and a thick ¥ on the big one.
void drawSalaryCoin(int cx, int cy, int r, bool withMark) {
  tft.fillCircle(cx, cy, r, SALARY_GOLD_DIM);
  tft.fillCircle(cx, cy, r - 3, SALARY_GOLD);
  if (withMark) {
    tft.drawCircle(cx, cy, (int)(r * 0.70), SALARY_GOLD_DIM);
    const uint16_t c = SALARY_COIN_MARK;
    const int half = (int)(r * 0.38), top = cy - (int)(r * 0.44);
    const int mid = cy - (int)(r * 0.10), bot = cy + (int)(r * 0.46);
    const int barHalf = (int)(r * 0.34);
    for (int o = 0; o < 2; o++) { // 2px-thick diagonals meeting at the stem
      tft.drawLine(cx - half, top + o, cx, mid + o, c);
      tft.drawLine(cx + half, top + o, cx, mid + o, c);
      tft.drawLine(cx - 1 + o, mid, cx - 1 + o, bot, c); // stem
    }
    tft.fillRect(cx - barHalf, cy + (int)(r * 0.08), barHalf * 2, 2, c);
    tft.fillRect(cx - barHalf, cy + (int)(r * 0.26), barHalf * 2, 2, c);
  }
}

void drawSalaryChrome() {
  tft.fillScreen(SALARY_BG);
  ringLastPct = -1000;
  tft.setTextDatum(TL_DATUM);

  // dim sparkle dots scattered around the bands the dynamic strips never touch
  const int16_t sparks[][2] = {{14, 20},  {52, 6},   {190, 8},  {226, 26},
                               {8, 92},   {232, 96}, {6, 162},  {234, 166},
                               {118, 236}, {64, 234}, {178, 234}};
  for (auto &xy : sparks) tft.fillRect(xy[0], xy[1], 2, 2, SALARY_SPARK);

  // small floating coins; kept clear of every dynamic strip's worst case
  drawSalaryCoin(24, 58, 8, false);
  drawSalaryCoin(214, 52, 6, false);
  drawSalaryCoin(10, 122, 6, false);
  drawSalaryCoin(230, 130, 5, false);
  drawSalaryCoin(26, 224, 7, false);
  drawSalaryCoin(213, 222, 8, false);

  // hero coin + title
  drawSalaryCoin(SCREEN_CX, 64, 30, true);
  drawSalaryLabel(salary_title_bits, SALARY_TITLE_W, SALARY_TITLE_H,
                  SCREEN_CX - SALARY_TITLE_W / 2, 8, TFT_WHITE, SALARY_BG);

  // rate caption (static per config): 每秒 +0.0142 元
  const String rateAscii = salaryConfig.monthlyFen > 0
                               ? "+" + String(salaryRatePerSecond(), 4)
                               : "--";
  const bool withYuan = salaryConfig.monthlyFen > 0;
  const int gap = 5;
  int lineW = 0;
  if (withYuan) lineW += SALARY_RATE_PREFIX_W + gap;
  lineW += tft.textWidth(rateAscii, 2);
  if (withYuan) lineW += gap + SALARY_YUAN_W;
  const int rx = SCREEN_CX - lineW / 2;
  tft.fillRect(rx - 4, 149, lineW + 8, 20, SALARY_BG);
  int cx1 = rx;
  if (withYuan) {
    drawSalaryLabel(salary_rate_prefix_bits, SALARY_RATE_PREFIX_W,
                    SALARY_RATE_PREFIX_H, cx1, 150, SALARY_MUTED, SALARY_BG);
    cx1 += SALARY_RATE_PREFIX_W + gap;
  }
  tft.setTextColor(SALARY_MUTED, SALARY_BG);
  tft.drawString(rateAscii, cx1, 151, 2);
  if (withYuan) {
    drawSalaryLabel(salary_yuan_bits, SALARY_YUAN_W, SALARY_YUAN_H,
                    cx1 + tft.textWidth(rateAscii, 2) + gap, 150, SALARY_MUTED,
                    SALARY_BG);
  }

  // bar track; the gold fill is repainted whenever the percent moves
  tft.fillRoundRect(28, 174, 184, 8, 4, SALARY_TRACK);

  salaryChromeDrawn = true;
  salaryLastEarned = "";
  salaryLastStatus = "";
  salaryLastPctLine = "";
  salaryLastPct = -1;
}

void drawSalaryScreen() {
  const unsigned long utcEpoch = salaryCurrentEpoch();
  const unsigned long localEpoch = utcEpoch == 0 ? 0 : utcEpoch + 8UL * 3600UL;
  const long earnedSeconds = salaryElapsedWorkSeconds(localEpoch);
  const double rate = salaryRatePerSecond();
  const double earned = rate * earnedSeconds;
  const String earnedText = salaryConfig.monthlyFen > 0 ? String(earned, 2) : "--";
  const String status = salaryStatusText(localEpoch);

  if (!salaryChromeDrawn) drawSalaryChrome();

  if (earnedText != salaryLastEarned) {
    salaryLastEarned = earnedText;
    tft.fillRect(18, 94, 204, 54, SALARY_BG);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(SALARY_GOLD, SALARY_BG);
    const int numW = tft.textWidth(earnedText, 6);
    const int x0 = SCREEN_CX - (numW + 5 + SALARY_YUAN_W) / 2;
    tft.drawString(earnedText, x0, 97, 6);
    if (salaryConfig.monthlyFen > 0) {
      drawSalaryLabel(salary_yuan_bits, SALARY_YUAN_W, SALARY_YUAN_H,
                      x0 + numW + 5, 112, SALARY_GOLD, SALARY_BG);
    }
  }

  const float progress = salaryDailyWorkSeconds() > 0
      ? 100.0f * earnedSeconds / salaryDailyWorkSeconds() : 0;
  const int pctInt = (int)(progress + 0.5f);
  if (pctInt != salaryLastPct) {
    salaryLastPct = pctInt;
    tft.fillRoundRect(28, 174, 184, 8, 4, SALARY_TRACK);
    int fillW = (int)(184.0f * progress / 100.0f + 0.5f);
    if (fillW > 0) tft.fillRoundRect(28, 174, max(fillW, 8), 8, 4, SALARY_GOLD);
  }

  // 已挣 NN% — hidden entirely while unconfigured or before the clock syncs
  const String pctLine =
      salaryConfig.monthlyFen > 0 && utcEpoch != 0 ? pctText(progress) : "";
  if (pctLine != salaryLastPctLine) {
    salaryLastPctLine = pctLine;
    tft.fillRect(76, 186, 88, 22, SALARY_BG);
    if (pctLine.length()) {
      const int lineW = SALARY_EARNED_PREFIX_W + 6 + tft.textWidth(pctLine, 2);
      const int x0 = SCREEN_CX - lineW / 2;
      drawSalaryLabel(salary_earned_prefix_bits, SALARY_EARNED_PREFIX_W,
                      SALARY_EARNED_PREFIX_H, x0, 188, TFT_WHITE, SALARY_BG);
      tft.setTextColor(TFT_WHITE, SALARY_BG);
      tft.drawString(pctLine, x0 + SALARY_EARNED_PREFIX_W + 6, 190, 2);
    }
  }

  if (status != salaryLastStatus) {
    salaryLastStatus = status;
    tft.fillRect(60, 212, 120, 18, SALARY_BG);
    struct SalaryStatusArt {
      const char *key;
      const uint8_t *bits;
      int width;
    };
    const SalaryStatusArt art[] = {
        {"EARNING NOW", salary_status_earning_bits, SALARY_STATUS_EARNING_W},
        {"LUNCH BREAK - PAUSED", salary_status_lunch_bits, SALARY_STATUS_LUNCH_W},
        {"WEEKEND - PAUSED", salary_status_weekend_bits, SALARY_STATUS_WEEKEND_W},
        {"BEFORE WORK", salary_status_before_bits, SALARY_STATUS_BEFORE_W},
        {"WORKDAY COMPLETE", salary_status_after_bits, SALARY_STATUS_AFTER_W},
        {"CONFIGURE SALARY", salary_status_config_bits, SALARY_STATUS_CONFIG_W},
        {"WAITING FOR CLOCK", salary_status_clock_bits, SALARY_STATUS_CLOCK_W},
    };
    const uint16_t color = status == "EARNING NOW" ? SALARY_GOLD : SALARY_MUTED;
    for (const auto &entry : art) {
      if (status == entry.key) {
        drawSalaryLabel(entry.bits, entry.width, SALARY_STATUS_EARNING_H,
                        SCREEN_CX - entry.width / 2, 213, color, SALARY_BG);
        break;
      }
    }
  }
}

void drawSquareRing(float pct, uint16_t color) {
  const int margin = 4;
  const int thickness = 2;
  const int side = SCREEN_W - margin * 2;
  int remaining = (int)(side * 4L * constrain(pct, 0.0f, 100.0f) / 100.0f);
  tft.fillRect(margin, margin, side, thickness, color);
  remaining -= side;
  if (remaining <= 0) return;
  int segment = min(remaining, side);
  tft.fillRect(SCREEN_W - margin - thickness, margin, thickness, segment, color);
  remaining -= side;
  if (remaining <= 0) return;
  segment = min(remaining, side);
  tft.fillRect(SCREEN_W - margin - segment, SCREEN_H - margin - thickness, segment, thickness, color);
  remaining -= side;
  if (remaining <= 0) return;
  segment = min(remaining, side);
  tft.fillRect(margin, SCREEN_H - margin - segment, thickness, segment, color);
}

void drawBatteryIndicator() {
  const HardwareFeatures::BatteryState &battery = HardwareFeatures::battery();
  const int areaX = 174, areaY = 18, areaW = 54, areaH = 15;
  tft.fillRect(areaX, areaY, areaW, areaH, TFT_BLACK);
  if (!battery.supported || !battery.present) return;

  const uint16_t color = battery.charging ? TFT_CYAN
                         : battery.level <= 15 ? TFT_RED
                                               : TFT_LIGHTGREY;
  tft.setTextDatum(TR_DATUM);
  tft.setTextColor(color, TFT_BLACK);
  tft.drawString(String(battery.level) + "%", 203, areaY + 3, 1);

  const int batteryX = 208, batteryY = areaY + 2, batteryW = 17, batteryH = 10;
  tft.drawRect(batteryX, batteryY, batteryW, batteryH, color);
  tft.fillRect(batteryX + batteryW, batteryY + 3, 2, 4, color);
  const int fillWidth = max(1, (batteryW - 4) * battery.level / 100);
  tft.fillRect(batteryX + 2, batteryY + 2, fillWidth, batteryH - 4, color);
}

void applyScreenRotation(uint8_t rotation) {
  rotation &= 3;
  if (rotation == screenRotation) return;
  screenRotation = rotation;
  tft.setRotation(screenRotation);
  tft.fillScreen(TFT_BLACK);
  musicChromeDrawn = false;
  stockChromeDrawn = false;
  stockDirty = true;
  stockNamesDrawnRev = -1;
  weatherChromeDrawn = false;
  weatherScreenDrawnRev = -1;
  weatherLastSecond = -1;
  if (!mainUiShown) return;
  DisplayMode mode = effectiveMode();
  if (mode == MODE_MUSIC) {
    lastMusicPollMs = 0;
  } else if (mode == MODE_STOCK) {
    lastStockPollMs = 0;
  } else if (mode == MODE_WEATHER) {
    lastWeatherPollMs = 0;
  } else if (mode == MODE_SALARY) {
    salaryChromeDrawn = false;
    drawSalaryScreen();
  }
  Serial.printf("[hardware] screen rotation=%u\n", screenRotation);
}

// pushImage() colors must be pre-byte-swapped (this firmware never enables
// setSwapBytes). Natural RGB565 -> wire order:
inline uint16_t swap565(uint16_t c) { return (uint16_t)((c << 8) | (c >> 8)); }

String timeText(int sec) {
  if (sec < 0) sec = 0;
  char buf[12];
  snprintf(buf, sizeof(buf), "%d:%02d", sec / 60, sec % 60);
  return String(buf);
}

String fitText(String s, int maxPx, int font) {
  if (tft.textWidth(s, font) <= maxPx) return s;
  while (s.length() > 0 && tft.textWidth(s + "...", font) > maxPx) {
    s.remove(s.length() - 1);
  }
  return s + "...";
}

void drawMusicCoverPlaceholder() {
  const int x = (SCREEN_W - MUSIC_COVER_W) / 2;
  const int y = 14;
  tft.fillRect(x, y, MUSIC_COVER_W, MUSIC_COVER_H, TFT_DARKGREY);
  tft.drawRect(x, y, MUSIC_COVER_W, MUSIC_COVER_H, TFT_DARKGREY);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(TFT_LIGHTGREY, TFT_DARKGREY);
  tft.drawString("No Art", SCREEN_CX, y + MUSIC_COVER_H / 2, 2);
}

bool drawMusicCoverFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0 || !musicHasArtwork) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music/cover.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  const int x = (SCREEN_W - MUSIC_COVER_W) / 2;
  const int y = 14;
  const size_t rowBytes = (size_t)MUSIC_COVER_W * 2;
  bool ok = true;
  for (int r = 0; r < MUSIC_COVER_H; r++) {
    int got = stream->readBytes((uint8_t *)rowBuf, rowBytes);
    if (got != (int)rowBytes) {
      ok = false;
      break;
    }
    tft.pushImage(x, y + r, MUSIC_COVER_W, 1, rowBuf);
    yield();
  }
  http.end();
  return ok;
}

// Streams the Mac-rendered 232x44 title/artist strip and blits it row by
// row — the only way to get CJK on screen without shipping a font.
bool drawMusicTextFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music/text.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  const size_t rowBytes = (size_t)MUSIC_TEXT_W * 2;
  bool ok = true;
  for (int r = 0; r < MUSIC_TEXT_H; r++) {
    int got = stream->readBytes((uint8_t *)rowBuf, rowBytes);
    if (got != (int)rowBytes) {
      ok = false;
      break;
    }
    tft.pushImage(MUSIC_TEXT_X, MUSIC_TEXT_Y + r, MUSIC_TEXT_W, 1, rowBuf);
    yield();
  }
  http.end();
  return ok;
}

// ASCII-only fallback if the strip fetch fails (CJK will stay blank, but at
// least latin titles show something).
void drawMusicTextFallback() {
  tft.fillRect(MUSIC_TEXT_X, MUSIC_TEXT_Y, MUSIC_TEXT_W, MUSIC_TEXT_H, TFT_BLACK);
  tft.setTextDatum(TC_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  String title = musicTitle.length() ? musicTitle : "No Music";
  tft.drawString(fitText(title, 216, 2), SCREEN_CX, MUSIC_TEXT_Y + 4, 2);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString(fitText(musicArtist, 216, 2), SCREEN_CX, MUSIC_TEXT_Y + 24, 2);
}

// Regions repaint independently: cover / text strip only when their rev
// changes, progress bar + time on every poll (partial fill, no flicker
// elsewhere).
void drawMusicScreen(bool coverChanged, bool textChanged) {
  if (!musicChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    coverChanged = true;
    textChanged = true;
    musicChromeDrawn = true;
  }
  if (coverChanged) {
    if (!drawMusicCoverFromBridge()) drawMusicCoverPlaceholder();
  }
  if (textChanged) {
    if (!drawMusicTextFromBridge()) drawMusicTextFallback();
  }

  const int bx = 20, by = 204, bw = 200, bh = 8;
  tft.fillRect(0, by - 2, SCREEN_W, SCREEN_H - by + 2, TFT_BLACK);
  tft.fillRect(bx, by, bw, bh, TFT_DARKGREY);
  float progress = musicDuration > 0 ? (float)musicElapsed / (float)musicDuration : 0;
  if (progress < 0) progress = 0;
  if (progress > 1) progress = 1;
  uint16_t color = musicPlaying ? TFT_GREEN : TFT_LIGHTGREY;
  tft.fillRect(bx, by, (int)(bw * progress), bh, color);
  tft.setTextDatum(TC_DATUM);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString(timeText(musicElapsed) + " / " + timeText(musicDuration), SCREEN_CX, 220, 1);
}

void pollMusic() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/music";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) {
    JsonDocument doc;
    if (!deserializeJson(doc, http.getString())) {
      musicTitle = doc["title"] | "";
      musicArtist = doc["artist"] | "";
      musicAlbum = doc["album"] | "";
      musicPlaying = doc["playing"] | false;
      statusMusicPlaying = musicPlaying; // fast stop-detection while music shows
      musicElapsed = doc["elapsed"] | 0;
      musicDuration = doc["duration"] | 0;
      musicHasArtwork = doc["has_artwork"] | false;
      int rev = doc["artwork_rev"] | -1;
      bool coverChanged = rev != musicArtworkRev;
      musicArtworkRev = rev;
      int tRev = doc["text_rev"] | -1;
      bool textChanged = tRev != musicTextRev;
      musicTextRev = tRev;
      drawMusicScreen(coverChanged, textChanged);
    }
  }
  http.end();
}

// ---------- FuBoTV-style weather clock screen ----------

unsigned long weatherCurrentEpoch() {
  if (weatherEpoch == 0) return 0;
  return weatherEpoch + (millis() - weatherEpochReceivedAtMs) / 1000UL;
}

void drawWeatherSeconds(bool force = false) {
  const unsigned long epoch = weatherCurrentEpoch();
  if (epoch == 0) return;
  const int second = epoch % 60UL;
  if (!force && second == weatherLastSecond) return;
  weatherLastSecond = second;

  char value[3] = {};
  snprintf(value, sizeof(value), "%02d", second);
  tft.fillRect(196, 101, 40, 38, TFT_BLACK);
  tft.setTextDatum(MR_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString(value, WEATHER_SECONDS_X + 23, WEATHER_SECONDS_Y, 4);
}

void drawWeatherAstronautFrame(int frameIndex) {
  if (!fileSystemReady || weatherAstronautFrames <= 0) return;
  frameIndex %= weatherAstronautFrames;
  if (frameIndex < 0) frameIndex += weatherAstronautFrames;

  File file = LittleFS.open(WEATHER_ASTRONAUT_FILE, "r");
  if (!file) return;
  const size_t rowBytes = (size_t)WEATHER_ASTRONAUT_W * 2;
  const size_t frameOffset =
      2 + (size_t)frameIndex * WEATHER_ASTRONAUT_FRAME_BYTES;
  if (!file.seek(frameOffset)) {
    file.close();
    return;
  }

  for (int row = 0; row < WEATHER_ASTRONAUT_H; ++row) {
    if (file.read((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) break;
    tft.pushImage(
        WEATHER_ASTRONAUT_X,
        WEATHER_ASTRONAUT_Y + row,
        WEATHER_ASTRONAUT_W,
        1,
        rowBuf);
    if ((row & 0x0F) == 0x0F) yield();
  }
  file.close();
}

bool installWeatherAstronautPack() {
  if (!inspectWeatherAstronautFile(WEATHER_ASTRONAUT_TEMP_FILE, false)) {
    LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
    return false;
  }

  LittleFS.remove(WEATHER_ASTRONAUT_BACKUP_FILE);
  const bool hadCurrent = LittleFS.exists(WEATHER_ASTRONAUT_FILE);
  if (hadCurrent &&
      !LittleFS.rename(WEATHER_ASTRONAUT_FILE, WEATHER_ASTRONAUT_BACKUP_FILE)) {
    LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
    return false;
  }
  if (!LittleFS.rename(WEATHER_ASTRONAUT_TEMP_FILE, WEATHER_ASTRONAUT_FILE)) {
    if (hadCurrent) {
      LittleFS.rename(WEATHER_ASTRONAUT_BACKUP_FILE, WEATHER_ASTRONAUT_FILE);
    }
    return false;
  }
  if (!inspectWeatherAstronautFile(WEATHER_ASTRONAUT_FILE, true)) {
    LittleFS.remove(WEATHER_ASTRONAUT_FILE);
    if (hadCurrent) {
      LittleFS.rename(WEATHER_ASTRONAUT_BACKUP_FILE, WEATHER_ASTRONAUT_FILE);
      inspectWeatherAstronautFile(WEATHER_ASTRONAUT_FILE, true);
    }
    return false;
  }
  LittleFS.remove(WEATHER_ASTRONAUT_BACKUP_FILE);
  return true;
}

bool downloadWeatherAstronautPack() {
  if (!fileSystemReady || WiFi.status() != WL_CONNECTED ||
      bridgeHost.length() == 0) {
    return false;
  }
  lastWeatherAstronautDownloadMs = millis();

  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/weather/astronaut.raw";
  http.setTimeout(15000);
  if (!http.begin(client, url)) return false;
  const int code = http.GET();
  const int contentLength = http.getSize();
  if (code != HTTP_CODE_OK ||
      contentLength != (int)WEATHER_ASTRONAUT_PACK_BYTES) {
    http.end();
    return false;
  }

  LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
  File file = LittleFS.open(WEATHER_ASTRONAUT_TEMP_FILE, "w");
  if (!file) {
    http.end();
    return false;
  }

  WiFiClient *stream = http.getStreamPtr();
  size_t received = 0;
  bool ok = true;
  while (received < WEATHER_ASTRONAUT_PACK_BYTES) {
    const size_t remaining = WEATHER_ASTRONAUT_PACK_BYTES - received;
    const size_t chunk = min(remaining, sizeof(rowBuf));
    const size_t read = stream->readBytes((uint8_t *)rowBuf, chunk);
    if (read == 0 || file.write((uint8_t *)rowBuf, read) != read) {
      ok = false;
      break;
    }
    received += read;
    yield();
  }
  file.close();
  http.end();

  if (!ok || received != WEATHER_ASTRONAUT_PACK_BYTES) {
    LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
    return false;
  }
  if (!installWeatherAstronautPack()) return false;

  Serial.printf(
      "[weather] downloaded astronaut pack revision=%d frames=%d bytes=%u\n",
      weatherAstronautLoadedRevision,
      weatherAstronautFrames,
      (unsigned int)received);
  return true;
}

bool drawWeatherFrameFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/weather/screen.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  const int code = http.GET();
  if (code != HTTP_CODE_OK ||
      (http.getSize() >= 0 && http.getSize() != SCREEN_W * SCREEN_H * 2)) {
    http.end();
    return false;
  }

  WiFiClient *stream = http.getStreamPtr();
  const size_t rowBytes = (size_t)SCREEN_W * 2;
  bool ok = true;
  for (int row = 0; row < SCREEN_H; ++row) {
    if (stream->readBytes((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) {
      ok = false;
      break;
    }
    renderWeatherBaseRow(row, !weatherChromeDrawn);
    yield();
  }
  http.end();
  // A short read may have replaced some panel rows.  Keep the previous
  // fingerprint cache out of use until a successful transfer repaints in full.
  if (!ok) {
    weatherChromeDrawn = false;
    return false;
  }

  weatherChromeDrawn = true;
  weatherScreenDrawnRev = weatherScreenRev;
  weatherBaseCacheValid = true;
  weatherLastSecond = -1;
  drawWeatherSeconds(true);
  drawWeatherAstronautFrame(weatherAstronautFrame);
  if (HardwareFeatures::battery().present) drawBatteryIndicator();
  return true;
}

void drawWeatherFallback() {
  if (weatherChromeDrawn) return;
  weatherBaseCacheValid = false;
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("Weather clock", SCREEN_CX, 102, 4);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString("Connect Wi-Fi bridge", SCREEN_CX, 132, 2);
  weatherChromeDrawn = true;
}

bool handleWeatherPayload(const String &payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) return false;
  const unsigned long epoch = doc["epoch"] | 0UL;
  const long rev = doc["screen_rev"] | -1L;
  if (epoch == 0 || rev < 0) return false;
  weatherEpoch = epoch;
  weatherEpochReceivedAtMs = millis();
  weatherScreenRev = rev;
  weatherAstronautRevision = doc["astronaut_rev"] | -1;
  return true;
}

#if defined(ARDUINO_ARCH_ESP8266) && !AICLOCK_WIRED_ONLY
unsigned long lastPrinterPollMs = 0;
void pollPrinterBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(750);
  if (!http.begin(client, "http://" + bridgeHost + "/printer")) return;
  const int code = http.GET();
  const int length = http.getSize();
  // Require bounded Content-Length; never allocate from an untrusted body size.
  if (code == HTTP_CODE_OK && length > 0 && length <= 2048) {
    static char payload[2049];
    auto *stream = http.getStreamPtr();
    stream->setTimeout(750);
    if (stream->readBytes(payload, length) == static_cast<size_t>(length))
      PrinterMonitor::ingestBridge(payload, length);
  }
  http.end();
}
#endif

void pollWeather() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) {
    drawWeatherFallback();
    return;
  }
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/weather";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  const int code = http.GET();
  const bool parsed = code == HTTP_CODE_OK && handleWeatherPayload(http.getString());
  http.end();
  if (parsed &&
      weatherAstronautRevision >= 0 &&
      weatherAstronautLoadedRevision != weatherAstronautRevision &&
      (lastWeatherAstronautDownloadMs == 0 ||
       millis() - lastWeatherAstronautDownloadMs >= WEATHER_ASTRONAUT_RETRY_MS)) {
    downloadWeatherAstronautPack();
  }
  if (parsed && (!weatherChromeDrawn || weatherScreenDrawnRev != weatherScreenRev)) {
    if (!drawWeatherFrameFromBridge()) drawWeatherFallback();
  }
}

// ---------- stock watchlist screen ----------

bool handleStockPayload(const String &payload) {
  JsonDocument doc;
  if (deserializeJson(doc, payload)) return false;
  JsonArray arr = doc["stocks"];
  if (arr.isNull()) return false;
  int previousCount = stockCount;
  stockCount = 0;
  for (JsonObject s : arr) {
    if (stockCount >= MAX_STOCKS) break;
    stocks[stockCount].code = s["code"] | "";
    stocks[stockCount].price = s["price"] | "";
    stocks[stockCount].pct = s["pct"] | "";
    stocks[stockCount].up = s["up"] | 0;
    stockCount++;
  }
  stockNamesRev = doc["names_rev"] | -1;
  if (previousCount != stockCount) stockChromeDrawn = false;
  stockEverLoaded = true;
  stockDirty = true;
  return true;
}

// Streams the Mac-rendered name strips and blits one per row on the left side
// of the top line. Wired-only mode has no HTTP: codes still show on the right.
bool drawStockNamesFromSerialCache() {
  if (!fileSystemReady || serialStockNamesRev != stockNamesRev ||
      !LittleFS.exists(STOCK_NAMES_SERIAL_FILE)) {
    return false;
  }
  File file = LittleFS.open(STOCK_NAMES_SERIAL_FILE, "r");
  if (!file) return false;
  uint8_t cnt = 0;
  if (file.read(&cnt, 1) != 1 || cnt > MAX_STOCKS) {
    file.close();
    return false;
  }
  const size_t rowBytes = (size_t)STOCK_NAME_W * 2;
  bool ok = true;
  for (int i = 0; i < cnt && ok; i++) {
    int y0 = stockRowTop(i);
    for (int r = 0; r < STOCK_NAME_H; r++) {
      if (file.read((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) {
        ok = false;
        break;
      }
      if (i < stockCount) tft.pushImage(14, y0 + r, STOCK_NAME_W, 1, rowBuf);
      yield();
    }
  }
  file.close();
  return ok;
}

bool drawStockNamesFromBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return false;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/stock/names-v2.raw";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) {
    http.end();
    return false;
  }
  WiFiClient *stream = http.getStreamPtr();
  uint8_t cnt = 0;
  if (stream->readBytes(&cnt, 1) != 1) {
    http.end();
    return false;
  }
  const size_t rowBytes = (size_t)STOCK_NAME_W * 2;
  bool ok = true;
  for (int i = 0; i < cnt && ok; i++) {
    int y0 = stockRowTop(i);
    for (int r = 0; r < STOCK_NAME_H; r++) {
      if (stream->readBytes((uint8_t *)rowBuf, rowBytes) != (int)rowBytes) {
        ok = false;
        break;
      }
      if (i < stockCount) tft.pushImage(14, y0 + r, STOCK_NAME_W, 1, rowBuf);
      yield();
    }
  }
  http.end();
  return ok;
}

bool drawStockNames() {
  if (drawStockNamesFromSerialCache()) return true;
  return drawStockNamesFromBridge();
}

void pollStock() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/stock";
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) return;
  int code = http.GET();
  if (code == HTTP_CODE_OK) handleStockPayload(http.getString());
  http.end();
}

// 54px per row: grey name on the top left, code on the top right, big font-4
// price (white) on the left, and change% on the right - red rising / green
// falling (CN convention).
// Rows repaint only when their text changes, same trick as everywhere else.
void drawStockScreen() {
  if (!stockChromeDrawn) {
    tft.fillScreen(TFT_BLACK);
    stockChromeDrawn = true;
    for (int i = 0; i < MAX_STOCKS; i++) {
      stockLastCode[i] = "\x01"; // force repaint
      stockLastVal[i] = "\x01";
    }
    stockNamesDrawnRev = -1;
    drawCenteredMonoLabel(stock_label_bits, STOCK_LABEL_W, STOCK_LABEL_H, SCREEN_CX, 225,
                          0x7BEF);
  }
  stockDirty = false;

  if (stockCount == 0) {
    if (stockLastCode[0] != "") {
      for (int i = 0; i < MAX_STOCKS; i++) {
        stockLastCode[i] = "";
        stockLastVal[i] = "";
      }
      tft.fillRect(0, 0, SCREEN_W, 226, TFT_BLACK);
      tft.setTextDatum(TC_DATUM);
      tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
      tft.drawString(stockEverLoaded ? "No stocks configured" : "Waiting for bridge...", SCREEN_CX, 100, 2);
      if (stockEverLoaded) tft.drawString("Mac menu: Set watchlist", SCREEN_CX, 124, 2);
    }
    return;
  }

  for (int i = 0; i < stockCount; i++) {
    int y0 = stockRowTop(i);
    bool has = i < stockCount;
    // top line (name strip + code) and value line refresh independently, so
    // a price tick never wipes the name bitmap
    String codeKey = has ? stocks[i].code : "";
    if (codeKey != stockLastCode[i]) {
      stockLastCode[i] = codeKey;
      tft.fillRect(0, y0, SCREEN_W, 17, TFT_BLACK);
      stockNamesDrawnRev = -1; // strip area wiped: re-fetch names
      if (has) {
        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(0x7BEF, TFT_BLACK);
        tft.drawString(stocks[i].code, 226, y0, 2);
      }
    }
    String valKey = has ? stocks[i].price + "|" + stocks[i].pct + "|" + String(stocks[i].up) : "";
    if (valKey != stockLastVal[i]) {
      stockLastVal[i] = valKey;
      tft.fillRect(0, y0 + 18, SCREEN_W, 26, TFT_BLACK);
      if (has) {
        tft.setTextDatum(TL_DATUM);
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
        tft.drawString(stocks[i].price, 14, y0 + 18, 4);
        uint16_t pc = stocks[i].up > 0 ? TFT_RED : (stocks[i].up < 0 ? TFT_GREEN : TFT_LIGHTGREY);
        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(pc, TFT_BLACK);
        tft.drawString(stocks[i].pct, 226, y0 + 18, 4);
      }
    }
  }

  // CJK name strips, re-fetched when the watchlist (names_rev) changes
  if (stockNamesRev >= 0 && stockNamesDrawnRev != stockNamesRev) {
    if (drawStockNames()) stockNamesDrawnRev = stockNamesRev;
  }
}

// ---------- WiFi / bridge polling ----------

WiFiManager wifiManager; // global: the config portal now runs non-blocking in loop()

void configModeCallback(WiFiManager *wm) {
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("WiFi setup needed", 8, 32, 2);
  tft.drawString("Connect phone to AP:", 8, 62, 2);
  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString(WIFI_PORTAL_AP_NAME, 8, 87, 2);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("then open 192.168.4.1", 8, 117, 2);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.drawString("Or: plug into the computer", 8, 155, 2);
  tft.drawString("via USB - no WiFi needed", 8, 178, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("Firmware v" FW_VERSION, 8, 215, 2);
}

// Non-blocking: with saved credentials this still waits ~10s for the join,
// but a missing/failed WiFi no longer traps boot in the portal - the portal
// keeps running from loop() while the USB serial link can take over the
// screen (wired mode for APs with client isolation).
void setupWiFi() {
  wifiManager.setAPCallback(configModeCallback);
  wifiManager.setConfigPortalBlocking(false);

  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("Connecting WiFi...", 8, 100, 2);

  Serial.println("[wifi] starting WiFiManager autoConnect (non-blocking portal)...");
  bool ok = wifiManager.autoConnect(WIFI_PORTAL_AP_NAME);
  Serial.printf("[wifi] autoConnect result=%d ssid=%s ip=%s\n", ok, WiFi.SSID().c_str(),
                WiFi.localIP().toString().c_str());
  Serial.printf("[wifi] bridge host = '%s'\n", bridgeHost.c_str());
}

void setupWiredOnly() {
  platformDisableWiFi();
  delay(1);

  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("USB mode", 8, 62, 4);
  tft.drawString("Waiting for AIClockBridge", 8, 104, 2);
  tft.setTextColor(TFT_CYAN, TFT_BLACK);
  tft.drawString("Connect this device to Mac", 8, 132, 2);
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString("Firmware v" FW_VERSION, 8, 215, 2);
  Serial.println("[usb] wired-only mode, WiFi disabled");
}

bool parseStatusJson(const String &payload) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return false;

  if (!doc["music_playing"].is<bool>()) return false;
  const bool musicPlaying = doc["music_playing"].as<bool>();
  const unsigned long timestamp = doc["ts"] | 0UL;
  if (timestamp == 0) return false;

  statusMusicPlaying = musicPlaying;
  bridgeEpoch = timestamp;
  bridgeEpochReceivedAtMs = millis();
  return true;
}

// The mode actually rendered. While weather is selected, currently-playing
// audio promotes to music; every pinned page keeps its own renderer.
DisplayMode effectiveMode() {
  if (displayMode == MODE_WEATHER && statusMusicPlaying &&
      (wiredActive() || WiFi.status() == WL_CONNECTED)) {
    return MODE_MUSIC;
  }
  return displayMode;
}

void pollBridge() {
  if (WiFi.status() != WL_CONNECTED || bridgeHost.length() == 0) {
    Serial.printf("[bridge] skip poll: wifi=%d host='%s'\n",
                  WiFi.status() == WL_CONNECTED, bridgeHost.c_str());
    return;
  }

  WiFiClient client;
  HTTPClient http;
  String url = "http://" + bridgeHost + BRIDGE_DEFAULT_PATH;
  http.setTimeout(BRIDGE_HTTP_TIMEOUT_MS);
  if (!http.begin(client, url)) {
    Serial.println("[bridge] http.begin() failed");
    return;
  }

  int code = http.GET();
  Serial.printf("[bridge] GET %s -> %d\n", url.c_str(), code);
  if (code == HTTP_CODE_OK) {
    String payload = http.getString();
    if (parseStatusJson(payload)) {
      lastSuccessMs = millis();
      everPolled = true;
      Serial.printf("[bridge] heartbeat music=%d\n", statusMusicPlaying ? 1 : 0);
    } else {
      Serial.println("[bridge] invalid status envelope");
    }
  }
  http.end();
}

// ---------- wired (USB serial) bridge link ----------
// Fallback for WiFi networks with client isolation (device can't reach the
// bridge over LAN) - or for skipping WiFi setup entirely: when the clock is
// plugged into the computer over USB, the bridge pushes the same /status
// payloads down the CH340 serial line as newline-terminated frames:
//   bridge -> device:  #HELLO   #STATUS {json}   #CMD {json}
//   device -> bridge:  #DEVICE {"name":"aiclock","fw":"x.y.z"}
// Everything else the device prints (logs) is ignored by the bridge.
unsigned long lastSerialFrameMs = 0;
bool wiredEverLinked = false;
char serialLine[2059]; // 2 KiB printer snapshot plus prefix and terminator
size_t serialLineLen = 0;

const size_t SERIAL_TRANSFER_CHUNK_BYTES = 768;
const size_t SERIAL_STOCK_NAMES_MAX_BYTES =
    1 + (size_t)MAX_STOCKS * STOCK_NAME_W * STOCK_NAME_H * 2;
uint8_t serialTransferChunk[SERIAL_TRANSFER_CHUNK_BYTES];
File serialStockNamesFile;
bool serialStockNamesActive = false;
size_t serialStockNamesExpectedSize = 0;
size_t serialStockNamesReceived = 0;
uint32_t serialStockNamesExpectedCrc = 0;
uint32_t serialStockNamesRunningCrc = 0xFFFFFFFFUL;
unsigned long serialStockNamesNextSequence = 0;
int serialStockNamesPendingRev = -1;

enum SerialWeatherAssetKind {
  SERIAL_WEATHER_NONE,
  SERIAL_WEATHER_SCREEN,
  SERIAL_WEATHER_ASTRONAUT,
};
enum SerialRLEState {
  SERIAL_RLE_CONTROL,
  SERIAL_RLE_RUN_HIGH,
  SERIAL_RLE_RUN_LOW,
  SERIAL_RLE_LITERAL_HIGH,
  SERIAL_RLE_LITERAL_LOW,
};
const size_t SERIAL_WEATHER_ASSET_MAX_BYTES = 256 * 1024;
bool serialWeatherAssetActive = false;
unsigned long serialWeatherLastProgressMs = 0;
unsigned long lastWeatherScreenRequestMs = 0;
SerialWeatherAssetKind serialWeatherAssetKind = SERIAL_WEATHER_NONE;
size_t serialWeatherExpectedSize = 0;
size_t serialWeatherReceived = 0;
size_t serialWeatherDecodedExpected = 0;
size_t serialWeatherDecoded = 0;
uint32_t serialWeatherExpectedCrc = 0;
uint32_t serialWeatherRunningCrc = 0xFFFFFFFFUL;
unsigned long serialWeatherNextSequence = 0;
long serialWeatherPendingRev = -1;
int serialWeatherPendingFrames = 0;
SerialRLEState serialWeatherRLEState = SERIAL_RLE_CONTROL;
int serialWeatherRLERemaining = 0;
uint8_t serialWeatherRLEHigh = 0;
size_t serialWeatherScreenPixels = 0;
size_t serialWeatherFileBufferBytes = 0;
uint8_t *serialWeatherEncodedBuffer = nullptr;
size_t serialWeatherEncodedCapacity = 0;
File serialWeatherFile;

void sendSerialDeviceInfo();

bool wiredActive() { return wiredEverLinked && (millis() - lastSerialFrameMs) < 15000UL; }

// First data over either transport replaces the boot/portal screen.
void showMainUiIfNeeded() {
  if (mainUiShown) return;
  mainUiShown = true;
  displayMode = MODE_WEATHER;
  const auto printer = PrinterMonitor::snapshot();
  if (printer.supported && printer.configured && printer.enabled)
    displayMode = MODE_PRINTER;
  lastEffectiveMode = displayMode;
  weatherChromeDrawn = false;
  weatherScreenDrawnRev = -1;
  weatherLastSecond = -1;
  lastWeatherPollMs = 0;
  tft.fillScreen(TFT_BLACK);
}

void clearSerialStockNamesUpload(bool removeFile) {
  if (serialStockNamesFile) serialStockNamesFile.close();
  if (removeFile && fileSystemReady) LittleFS.remove(STOCK_NAMES_SERIAL_TEMP_FILE);
  serialStockNamesActive = false;
  serialStockNamesExpectedSize = 0;
  serialStockNamesReceived = 0;
  serialStockNamesExpectedCrc = 0;
  serialStockNamesRunningCrc = 0xFFFFFFFFUL;
  serialStockNamesNextSequence = 0;
  serialStockNamesPendingRev = -1;
}

void clearSerialWeatherAssetUpload(bool removeTemporaryFile) {
  if (serialWeatherEncodedBuffer) {
    free(serialWeatherEncodedBuffer);
    serialWeatherEncodedBuffer = nullptr;
  }
  serialWeatherEncodedCapacity = 0;
  if (serialWeatherFile) serialWeatherFile.close();
  if (removeTemporaryFile && fileSystemReady &&
      serialWeatherAssetKind == SERIAL_WEATHER_ASTRONAUT) {
    LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
  }
  serialWeatherAssetActive = false;
  serialWeatherLastProgressMs = 0;
  serialWeatherAssetKind = SERIAL_WEATHER_NONE;
  serialWeatherExpectedSize = 0;
  serialWeatherReceived = 0;
  serialWeatherDecodedExpected = 0;
  serialWeatherDecoded = 0;
  serialWeatherExpectedCrc = 0;
  serialWeatherRunningCrc = 0xFFFFFFFFUL;
  serialWeatherNextSequence = 0;
  serialWeatherPendingRev = -1;
  serialWeatherPendingFrames = 0;
  serialWeatherRLEState = SERIAL_RLE_CONTROL;
  serialWeatherRLERemaining = 0;
  serialWeatherRLEHigh = 0;
  serialWeatherScreenPixels = 0;
  serialWeatherFileBufferBytes = 0;
}

uint32_t updateCrc32(uint32_t crc, const uint8_t *data, size_t length) {
  while (length--) {
    crc ^= *data++;
    for (uint8_t bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320UL : 0);
    }
  }
  return crc;
}

// The bridge frame is a base layer.  Seconds and the file-backed astronaut are
// owned by the firmware, so a row update must never blit through either rect.
// Row CRCs give a 960-byte change cache without retaining a full framebuffer.
void renderWeatherBaseRow(int row, bool forceFullRepaint) {
  if (row < 0 || row >= SCREEN_H) return;

  const uint32_t fingerprint = ~updateCrc32(
      0xFFFFFFFFUL,
      (const uint8_t *)rowBuf,
      (size_t)SCREEN_W * sizeof(uint16_t));
  if (!forceFullRepaint && weatherChromeDrawn && weatherBaseCacheValid &&
      fingerprint == weatherRowFingerprints[row]) {
    return;
  }
  weatherRowFingerprints[row] = fingerprint;

  const bool secondsRow = row >= WEATHER_SECONDS_OWNER_Y &&
                          row < WEATHER_SECONDS_OWNER_Y + WEATHER_SECONDS_OWNER_H;
  const bool astronautRow = weatherAstronautFrames > 0 &&
                            row >= WEATHER_ASTRONAUT_Y &&
                            row < WEATHER_ASTRONAUT_Y + WEATHER_ASTRONAUT_H;
  if (secondsRow) {
    tft.pushImage(0, row, WEATHER_SECONDS_OWNER_X, 1, rowBuf);
    tft.pushImage(
        WEATHER_SECONDS_OWNER_X + WEATHER_SECONDS_OWNER_W,
        row,
        SCREEN_W - WEATHER_SECONDS_OWNER_X - WEATHER_SECONDS_OWNER_W,
        1,
        rowBuf + WEATHER_SECONDS_OWNER_X + WEATHER_SECONDS_OWNER_W);
  } else if (astronautRow) {
    tft.pushImage(0, row, WEATHER_ASTRONAUT_X, 1, rowBuf);
  } else {
    tft.pushImage(0, row, SCREEN_W, 1, rowBuf);
  }
}

int base64Value(char ch) {
  if (ch >= 'A' && ch <= 'Z') return ch - 'A';
  if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
  if (ch >= '0' && ch <= '9') return ch - '0' + 52;
  if (ch == '+') return 62;
  if (ch == '/') return 63;
  return -1;
}

bool decodeBase64Chunk(const char *input, size_t length, uint8_t *output, size_t capacity,
                       size_t &outputLength) {
  outputLength = 0;
  if (length == 0 || length % 4 != 0) return false;
  for (size_t i = 0; i < length; i += 4) {
    int a = base64Value(input[i]);
    int b = base64Value(input[i + 1]);
    int c = input[i + 2] == '=' ? -2 : base64Value(input[i + 2]);
    int d = input[i + 3] == '=' ? -2 : base64Value(input[i + 3]);
    if (a < 0 || b < 0 || c == -1 || d == -1 || (c == -2 && d != -2) ||
        ((c == -2 || d == -2) && i + 4 != length)) {
      return false;
    }

    size_t bytes = c == -2 ? 1 : (d == -2 ? 2 : 3);
    if (outputLength + bytes > capacity) return false;
    uint32_t value = ((uint32_t)a << 18) | ((uint32_t)b << 12);
    if (c >= 0) value |= (uint32_t)c << 6;
    if (d >= 0) value |= (uint32_t)d;
    output[outputLength++] = (uint8_t)(value >> 16);
    if (bytes > 1) output[outputLength++] = (uint8_t)(value >> 8);
    if (bytes > 2) output[outputLength++] = (uint8_t)value;
  }
  return true;
}

bool flushSerialWeatherFileBuffer() {
  if (serialWeatherFileBufferBytes == 0) return true;
  if (!serialWeatherFile ||
      serialWeatherFile.write((uint8_t *)rowBuf, serialWeatherFileBufferBytes) !=
          serialWeatherFileBufferBytes) {
    return false;
  }
  serialWeatherFileBufferBytes = 0;
  return true;
}

bool emitSerialWeatherPixel(uint8_t high, uint8_t low, bool renderScreenRows) {
  if (serialWeatherDecoded + 2 > serialWeatherDecodedExpected) return false;
  if (serialWeatherAssetKind == SERIAL_WEATHER_SCREEN) {
    const size_t column = serialWeatherScreenPixels % SCREEN_W;
    rowBuf[column] = ((uint16_t)low << 8) | high;
    serialWeatherScreenPixels++;
    if (renderScreenRows && column + 1 == SCREEN_W) {
      renderWeatherBaseRow(
          serialWeatherScreenPixels / SCREEN_W - 1, !weatherChromeDrawn);
    }
  } else if (serialWeatherAssetKind == SERIAL_WEATHER_ASTRONAUT) {
    uint8_t *output = (uint8_t *)rowBuf;
    if (serialWeatherFileBufferBytes + 2 > sizeof(rowBuf) &&
        !flushSerialWeatherFileBuffer()) {
      return false;
    }
    output[serialWeatherFileBufferBytes++] = high;
    output[serialWeatherFileBufferBytes++] = low;
  } else {
    return false;
  }
  serialWeatherDecoded += 2;
  return true;
}

bool decodeSerialWeatherRLE565(
    const uint8_t *data, size_t length, bool renderScreenRows = false) {
  for (size_t index = 0; index < length; ++index) {
    const uint8_t value = data[index];
    switch (serialWeatherRLEState) {
      case SERIAL_RLE_CONTROL:
        serialWeatherRLERemaining = (value & 0x7F) + 1;
        serialWeatherRLEState =
            (value & 0x80) ? SERIAL_RLE_RUN_HIGH : SERIAL_RLE_LITERAL_HIGH;
        break;
      case SERIAL_RLE_RUN_HIGH:
        serialWeatherRLEHigh = value;
        serialWeatherRLEState = SERIAL_RLE_RUN_LOW;
        break;
      case SERIAL_RLE_RUN_LOW:
        while (serialWeatherRLERemaining-- > 0) {
          if (!emitSerialWeatherPixel(
                  serialWeatherRLEHigh, value, renderScreenRows)) {
            return false;
          }
        }
        serialWeatherRLEState = SERIAL_RLE_CONTROL;
        break;
      case SERIAL_RLE_LITERAL_HIGH:
        serialWeatherRLEHigh = value;
        serialWeatherRLEState = SERIAL_RLE_LITERAL_LOW;
        break;
      case SERIAL_RLE_LITERAL_LOW:
        if (!emitSerialWeatherPixel(
                serialWeatherRLEHigh, value, renderScreenRows)) {
          return false;
        }
        serialWeatherRLERemaining--;
        serialWeatherRLEState = serialWeatherRLERemaining == 0
            ? SERIAL_RLE_CONTROL
            : SERIAL_RLE_LITERAL_HIGH;
        break;
    }
  }
  return true;
}

void handleSerialStockNamesBegin(const char *payload) {
  if (serialStockNamesActive || serialWeatherAssetActive) {
    Serial.println("#STOCK_NAMES_ERR busy");
    return;
  }

  JsonDocument doc;
  if (deserializeJson(doc, payload)) {
    Serial.println("#STOCK_NAMES_ERR invalid_metadata");
    return;
  }
  unsigned long size = doc["size"].as<unsigned long>();
  uint32_t crc = doc["crc32"].as<uint32_t>();
  int revision = doc["revision"] | -1;
  if (size <= 1 || size > SERIAL_STOCK_NAMES_MAX_BYTES || revision < 0) {
    Serial.println("#STOCK_NAMES_ERR invalid_metadata");
    return;
  }
  if (!ensureFileSystem(true)) {
    Serial.println("#STOCK_NAMES_ERR filesystem_unavailable");
    return;
  }

  LittleFS.remove(STOCK_NAMES_SERIAL_TEMP_FILE);
  serialStockNamesFile = LittleFS.open(STOCK_NAMES_SERIAL_TEMP_FILE, "w");
  if (!serialStockNamesFile) {
    Serial.println("#STOCK_NAMES_ERR file_open_failed");
    return;
  }
  serialStockNamesActive = true;
  serialStockNamesExpectedSize = size;
  serialStockNamesReceived = 0;
  serialStockNamesExpectedCrc = crc;
  serialStockNamesRunningCrc = 0xFFFFFFFFUL;
  serialStockNamesNextSequence = 0;
  serialStockNamesPendingRev = revision;
  Serial.println("#STOCK_NAMES_READY");
}

void handleSerialStockNamesChunk(char *payload) {
  if (!serialStockNamesActive) {
    Serial.println("#STOCK_NAMES_ERR no_upload");
    return;
  }
  char *separator = strchr(payload, ' ');
  if (!separator) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR invalid_chunk");
    return;
  }
  *separator = 0;
  char *end = nullptr;
  unsigned long sequence = strtoul(payload, &end, 10);
  if (!end || *end || sequence != serialStockNamesNextSequence) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR sequence_mismatch");
    return;
  }

  size_t decodedLength = 0;
  const char *encoded = separator + 1;
  if (!decodeBase64Chunk(encoded, strlen(encoded), serialTransferChunk,
                         sizeof(serialTransferChunk),
                         decodedLength) ||
      serialStockNamesReceived + decodedLength > serialStockNamesExpectedSize) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR invalid_chunk_data");
    return;
  }
  if (serialStockNamesFile.write(serialTransferChunk, decodedLength) != decodedLength) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR file_write_failed");
    return;
  }
  serialStockNamesRunningCrc =
      updateCrc32(serialStockNamesRunningCrc, serialTransferChunk, decodedLength);
  serialStockNamesReceived += decodedLength;
  serialStockNamesNextSequence++;
  Serial.printf("#STOCK_NAMES_ACK %lu\n", sequence);
  yield();
}

void handleSerialStockNamesEnd() {
  if (!serialStockNamesActive) {
    Serial.println("#STOCK_NAMES_ERR no_upload");
    return;
  }
  if (serialStockNamesFile) {
    serialStockNamesFile.flush();
    serialStockNamesFile.close();
  }
  if (serialStockNamesReceived != serialStockNamesExpectedSize) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR size_mismatch");
    return;
  }
  if ((~serialStockNamesRunningCrc) != serialStockNamesExpectedCrc) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR crc_mismatch");
    return;
  }

  File uploaded = LittleFS.open(STOCK_NAMES_SERIAL_TEMP_FILE, "r");
  uint8_t count = 0;
  const bool validHeader = uploaded && uploaded.read(&count, 1) == 1 &&
      count > 0 && count <= MAX_STOCKS;
  const size_t expectedSize =
      validHeader ? 1 + (size_t)count * STOCK_NAME_W * STOCK_NAME_H * 2 : 0;
  const bool validSize = validHeader && uploaded.size() == expectedSize;
  if (uploaded) uploaded.close();
  if (!validSize) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR invalid_payload");
    return;
  }

  int revision = serialStockNamesPendingRev;
  LittleFS.remove(STOCK_NAMES_SERIAL_FILE);
  if (!LittleFS.rename(STOCK_NAMES_SERIAL_TEMP_FILE, STOCK_NAMES_SERIAL_FILE)) {
    clearSerialStockNamesUpload(true);
    Serial.println("#STOCK_NAMES_ERR file_commit_failed");
    return;
  }
  clearSerialStockNamesUpload(false);
  serialStockNamesRev = revision;
  stockNamesDrawnRev = -1;
  stockDirty = true;
  Serial.println("#STOCK_NAMES_DONE");
}

void handleSerialWeatherAssetBegin(const char *payload) {
  if (serialStockNamesActive || serialWeatherAssetActive) {
    Serial.println("#WEATHER_ASSET_ERR busy");
    return;
  }

  JsonDocument doc;
  if (deserializeJson(doc, payload)) {
    Serial.println("#WEATHER_ASSET_ERR invalid_metadata");
    return;
  }
  const char *kindValue = doc["kind"] | "";
  const char *encoding = doc["encoding"] | "";
  const unsigned long size = doc["size"].as<unsigned long>();
  const unsigned long decodedSize = doc["decoded_size"].as<unsigned long>();
  const uint32_t crc = doc["crc32"].as<uint32_t>();
  const long revision = doc["revision"] | -1L;
  const int frames = doc["frames"] | 0;
  const SerialWeatherAssetKind kind = !strcmp(kindValue, "screen")
      ? SERIAL_WEATHER_SCREEN
      : (!strcmp(kindValue, "astronaut") ? SERIAL_WEATHER_ASTRONAUT
                                           : SERIAL_WEATHER_NONE);
  if (kind == SERIAL_WEATHER_NONE || strcmp(encoding, "rle565") ||
      size == 0 || size > SERIAL_WEATHER_ASSET_MAX_BYTES || revision < 0) {
    Serial.println("#WEATHER_ASSET_ERR invalid_metadata");
    return;
  }
  if (kind == SERIAL_WEATHER_SCREEN &&
      (decodedSize != (unsigned long)SCREEN_W * SCREEN_H * 2 ||
       effectiveMode() != MODE_WEATHER)) {
    Serial.println("#WEATHER_ASSET_ERR invalid_screen");
    return;
  }
  if (kind == SERIAL_WEATHER_ASTRONAUT &&
      (revision > 255 || frames <= 0 || frames > WEATHER_ASTRONAUT_FRAME_COUNT ||
       decodedSize != 2 + (unsigned long)frames * WEATHER_ASTRONAUT_FRAME_BYTES)) {
    Serial.println("#WEATHER_ASSET_ERR invalid_astronaut");
    return;
  }

  if (kind == SERIAL_WEATHER_SCREEN) {
    serialWeatherEncodedBuffer = (uint8_t *)malloc(size);
    if (!serialWeatherEncodedBuffer) {
      Serial.println("#WEATHER_ASSET_ERR buffer_alloc_failed");
      return;
    }
    serialWeatherEncodedCapacity = size;
  } else if (kind == SERIAL_WEATHER_ASTRONAUT) {
    if (!ensureFileSystem(true)) {
      Serial.println("#WEATHER_ASSET_ERR filesystem_unavailable");
      return;
    }
    LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
    serialWeatherFile = LittleFS.open(WEATHER_ASTRONAUT_TEMP_FILE, "w");
    uint8_t header[2] = {(uint8_t)revision, (uint8_t)frames};
    if (!serialWeatherFile || serialWeatherFile.write(header, sizeof(header)) != sizeof(header)) {
      if (serialWeatherFile) serialWeatherFile.close();
      LittleFS.remove(WEATHER_ASTRONAUT_TEMP_FILE);
      Serial.println("#WEATHER_ASSET_ERR file_open_failed");
      return;
    }
  }

  serialWeatherAssetActive = true;
  serialWeatherLastProgressMs = millis();
  serialWeatherAssetKind = kind;
  serialWeatherExpectedSize = size;
  serialWeatherReceived = 0;
  serialWeatherDecodedExpected =
      kind == SERIAL_WEATHER_ASTRONAUT ? decodedSize - 2 : decodedSize;
  serialWeatherDecoded = 0;
  serialWeatherExpectedCrc = crc;
  serialWeatherRunningCrc = 0xFFFFFFFFUL;
  serialWeatherNextSequence = 0;
  serialWeatherPendingRev = revision;
  serialWeatherPendingFrames = frames;
  serialWeatherRLEState = SERIAL_RLE_CONTROL;
  serialWeatherRLERemaining = 0;
  serialWeatherScreenPixels = 0;
  serialWeatherFileBufferBytes = 0;
  Serial.println("#WEATHER_ASSET_READY");
}

void handleSerialWeatherAssetChunk(char *payload) {
  if (!serialWeatherAssetActive) {
    Serial.println("#WEATHER_ASSET_ERR no_upload");
    return;
  }
  char *separator = strchr(payload, ' ');
  if (!separator) {
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR invalid_chunk");
    return;
  }
  *separator = 0;
  char *end = nullptr;
  const unsigned long sequence = strtoul(payload, &end, 10);
  if (!end || *end || sequence != serialWeatherNextSequence) {
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR sequence_mismatch");
    return;
  }

  size_t decodedLength = 0;
  const char *encoded = separator + 1;
  if (!decodeBase64Chunk(encoded, strlen(encoded), serialTransferChunk,
                         sizeof(serialTransferChunk), decodedLength) ||
      serialWeatherReceived + decodedLength > serialWeatherExpectedSize) {
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR invalid_chunk_data");
    return;
  }
  serialWeatherRunningCrc =
      updateCrc32(serialWeatherRunningCrc, serialTransferChunk, decodedLength);
  serialWeatherReceived += decodedLength;
  if (serialWeatherAssetKind == SERIAL_WEATHER_SCREEN) {
    if (!serialWeatherEncodedBuffer ||
        serialWeatherReceived > serialWeatherEncodedCapacity) {
      clearSerialWeatherAssetUpload(true);
      Serial.println("#WEATHER_ASSET_ERR buffer_overflow");
      return;
    }
    memcpy(serialWeatherEncodedBuffer + serialWeatherReceived - decodedLength,
           serialTransferChunk, decodedLength);
  } else if (!decodeSerialWeatherRLE565(serialTransferChunk, decodedLength)) {
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR decode_failed");
    return;
  }
  serialWeatherNextSequence++;
  serialWeatherLastProgressMs = millis();
  Serial.printf("#WEATHER_ASSET_ACK %lu\n", sequence);
  yield();
}

void handleSerialWeatherAssetEnd() {
  if (!serialWeatherAssetActive) {
    Serial.println("#WEATHER_ASSET_ERR no_upload");
    return;
  }
  const SerialWeatherAssetKind kind = serialWeatherAssetKind;
  const long revision = serialWeatherPendingRev;
  if (kind == SERIAL_WEATHER_SCREEN) {
    // Decode once without painting.  CRC and RLE validation must both pass
    // before any row can affect either the panel or the fingerprint cache.
    serialWeatherRLEState = SERIAL_RLE_CONTROL;
    serialWeatherRLERemaining = 0;
    serialWeatherDecoded = 0;
    serialWeatherScreenPixels = 0;
    if (!serialWeatherEncodedBuffer ||
        !decodeSerialWeatherRLE565(
            serialWeatherEncodedBuffer, serialWeatherReceived, false)) {
      clearSerialWeatherAssetUpload(true);
      Serial.println("#WEATHER_ASSET_ERR decode_failed");
      return;
    }
  }
  const bool transferValid =
      serialWeatherReceived == serialWeatherExpectedSize &&
      (~serialWeatherRunningCrc) == serialWeatherExpectedCrc &&
      serialWeatherRLEState == SERIAL_RLE_CONTROL &&
      serialWeatherDecoded == serialWeatherDecodedExpected;
  if (!transferValid ||
      (kind == SERIAL_WEATHER_SCREEN &&
       (serialWeatherScreenPixels != (size_t)SCREEN_W * SCREEN_H ||
        effectiveMode() != MODE_WEATHER))) {
    Serial.printf(
        "[weather] asset validation failed kind=%d received=%u/%u crc=%08lx/%08lx "
        "state=%d decoded=%u/%u pixels=%u mode=%d\n",
        (int)kind,
        (unsigned int)serialWeatherReceived,
        (unsigned int)serialWeatherExpectedSize,
        (unsigned long)(~serialWeatherRunningCrc),
        (unsigned long)serialWeatherExpectedCrc,
        (int)serialWeatherRLEState,
        (unsigned int)serialWeatherDecoded,
        (unsigned int)serialWeatherDecodedExpected,
        (unsigned int)serialWeatherScreenPixels,
        (int)effectiveMode());
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR validation_failed");
    return;
  }

  if (kind == SERIAL_WEATHER_ASTRONAUT) {
    if (!flushSerialWeatherFileBuffer()) {
      clearSerialWeatherAssetUpload(true);
      Serial.println("#WEATHER_ASSET_ERR file_write_failed");
      return;
    }
    if (serialWeatherFile) {
      serialWeatherFile.flush();
      serialWeatherFile.close();
    }
    if (!installWeatherAstronautPack() || weatherAstronautLoadedRevision != revision) {
      clearSerialWeatherAssetUpload(true);
      Serial.println("#WEATHER_ASSET_ERR install_failed");
      return;
    }
    weatherAstronautRevision = revision;
  } else {
    serialWeatherRLEState = SERIAL_RLE_CONTROL;
    serialWeatherRLERemaining = 0;
    serialWeatherDecoded = 0;
    serialWeatherScreenPixels = 0;
    if (!decodeSerialWeatherRLE565(
            serialWeatherEncodedBuffer, serialWeatherReceived, true)) {
      clearSerialWeatherAssetUpload(true);
      weatherChromeDrawn = false;
      Serial.println("#WEATHER_ASSET_ERR decode_failed");
      return;
    }
    weatherScreenRev = revision;
    weatherScreenDrawnRev = revision;
    weatherChromeDrawn = true;
    weatherBaseCacheValid = true;
    weatherLastSecond = -1;
    drawWeatherSeconds(true);
    drawWeatherAstronautFrame(weatherAstronautFrame);
    if (HardwareFeatures::battery().present) drawBatteryIndicator();
  }

  clearSerialWeatherAssetUpload(false);
  Serial.println("#WEATHER_ASSET_DONE");
}

void handleSerialFrame(char *line) {
  lastSerialFrameMs = millis();
  wiredEverLinked = true;
  if (!strncmp(line, "#HELLO", 6) || !strcmp(line, "#INFO")) {
    sendSerialDeviceInfo();
    return;
  }
  if (!strncmp(line, "#STOCK_NAMES_BEGIN ", 19)) {
    handleSerialStockNamesBegin(line + 19);
    return;
  }
  if (!strncmp(line, "#STOCK_NAMES_CHUNK ", 19)) {
    handleSerialStockNamesChunk(line + 19);
    return;
  }
  if (!strcmp(line, "#STOCK_NAMES_END")) {
    handleSerialStockNamesEnd();
    return;
  }
  if (!strncmp(line, "#WEATHER_ASSET_BEGIN ", 21)) {
    handleSerialWeatherAssetBegin(line + 21);
    return;
  }
  if (!strncmp(line, "#WEATHER_ASSET_CHUNK ", 21)) {
    handleSerialWeatherAssetChunk(line + 21);
    return;
  }
  if (!strcmp(line, "#WEATHER_ASSET_END")) {
    handleSerialWeatherAssetEnd();
    return;
  }
  if (!strncmp(line, "#STATUS ", 8)) {
    if (parseStatusJson(String(line + 8))) {
      lastSuccessMs = millis();
      everPolled = true;
      showMainUiIfNeeded();
      Serial.println("#ACK status");
    }
    return;
  }
  if (!strncmp(line, "#STOCK ", 7)) {
    handleStockPayload(String(line + 7));
    return;
  }
  if (!strncmp(line, "#WEATHER ", 9)) {
    handleWeatherPayload(String(line + 9));
    return;
  }
  if (!strncmp(line, "#PRINTER ", 9)) {
    PrinterMonitor::ingestBridge(line + 9, strlen(line + 9));
    return;
  }
  if (!strncmp(line, "#CMD ", 5)) {
    JsonDocument doc;
    if (deserializeJson(doc, line + 5)) return;
    if (doc["brightness"].is<int>()) {
      applyExplicitBrightness(doc["brightness"].as<int>());
#if !AICLOCK_WIRED_ONLY
      saveBrightness();
#endif
    }
    if (doc["auto_rotate"].is<bool>() && HardwareFeatures::imuAvailable()) {
      autoRotateEnabled = doc["auto_rotate"].as<bool>();
      saveOrientationConfig();
      Serial.printf("#ACK auto_rotate %d\n", autoRotateEnabled);
    }
    const char *mode = doc["display"] | (const char *)nullptr;
    if (mode) {
      String m(mode);
      // Legacy Agent modes no longer have a renderer; migrate them to weather.
      if (m == "auto" || m == "home" || m == "usage" || m == "info" ||
          m == "claude" || m == "codex" || m == "net" || m == "pomodoro") {
        displayMode = MODE_WEATHER;
      }
      else if (m == "music") displayMode = MODE_MUSIC;
      else if (m == "stock") displayMode = MODE_STOCK;
      else if (m == "weather") displayMode = MODE_WEATHER;
      else if (m == "salary") displayMode = MODE_SALARY;
      else if (m == "printer" && PrinterMonitor::snapshot().supported)
        displayMode = MODE_PRINTER;
      // the effectiveMode transition handler in loop() repaints the chrome
    }
    JsonObject salary = doc["salary"];
    if (!salary.isNull()) {
      long monthlyFen = salary["monthly_fen"] | -1L;
      int startMin = salary["start_min"] | -1;
      int endMin = salary["end_min"] | -1;
      int lunchStartMin = salary["lunch_start_min"] | -1;
      int lunchEndMin = salary["lunch_end_min"] | -1;
      if (!configureSalary(monthlyFen, startMin, endMin, lunchStartMin, lunchEndMin)) {
        Serial.println("#ACK salary error");
      } else {
        displayMode = MODE_SALARY;
        Serial.println("#ACK salary");
      }
    }
    return;
  }
}

// Drains the UART, splitting on newlines; frames start with '#', everything
// else (line noise, echoes) is dropped.
void pumpSerial() {
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (serialLineLen > 0 && serialLine[0] == '#') {
        serialLine[serialLineLen] = 0;
        handleSerialFrame(serialLine);
      }
      serialLineLen = 0;
    } else if (serialLineLen < sizeof(serialLine) - 1) {
      serialLine[serialLineLen++] = ch;
    } else {
      serialLineLen = 0; // oversized line: drop it
    }
  }
}

// ---------- web admin ----------

String htmlEscape(const String &s) {
  String out = s;
  out.replace("&", "&amp;");
  out.replace("<", "&lt;");
  out.replace(">", "&gt;");
  out.replace("\"", "&quot;");
  return out;
}

void handleRoot() {
  String age = everPolled ? String((millis() - lastSuccessMs) / 1000) + "s ago" : "never";
  String html;
  html.reserve(4608);
  html += "<!DOCTYPE html><html><head><meta charset='utf-8'>";
  html += "<meta name='viewport' content='width=device-width, initial-scale=1'>";
  html += "<title>AI Clock 设置</title>";
  html += "<style>body{font-family:-apple-system,sans-serif;max-width:480px;margin:24px "
          "auto;padding:0 16px;color:#222} h1{font-size:20px} label{display:block;margin-top:16px;font-weight:600}"
          "input{width:100%;box-sizing:border-box;padding:8px;font-size:16px;margin-top:4px}"
          "button{margin-top:16px;padding:10px 20px;font-size:16px;background:#2563eb;color:#fff;"
          "border:none;border-radius:6px}"
          "table{margin-top:20px;border-collapse:collapse;width:100%}"
          "td{padding:4px 8px;border-bottom:1px solid #eee;font-size:14px}"
          ".dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}"
          "</style></head><body>";
  html += "<h1>AI Clock 设置</h1>";
#if defined(ESP32)
  if (PrinterMonitor::snapshot().supported)
    html += "<p><a href='/printer'>拓竹打印机设置（LAN Direct）</a></p>";
#endif

  html += "<form method='POST' action='/save'>";
  html += "<label>Bridge host (ip:port)</label>";
  html += "<input name='bridge' value='" + htmlEscape(bridgeHost) + "' placeholder='192.168.1.181:8765'>";
  html += "<button type='submit'>保存</button>";
  html += "</form>";

  // Backlight brightness slider: applies live on release (PWM, persisted).
  html += "<h2 style='font-size:16px;margin-top:28px'>屏幕亮度</h2>";
  html += "<input type='range' min='0' max='100' value='" + String(brightness) + "' id='bri' "
          "oninput=\"document.getElementById('briv').textContent=this.value+'%'\" "
          "onchange=\"fetch('/api/brightness',{method:'POST',headers:{'Content-Type':"
          "'application/x-www-form-urlencoded'},body:'level='+this.value})\">";
  html += "<div style='font-size:13px;color:#555'>当前：<span id='briv'>" + String(brightness) +
          "%</span>（0 = 熄屏，设置立即生效并记住）</div>";

  html += "<h2 style='font-size:16px;margin-top:28px'>薪资时钟</h2>";
  html += "<p style='font-size:13px;color:#555'>按中国标准月工作日 21.75 天计算，午休不计薪。保存后立即切换到薪资页面。</p>";
  html += "<form method='POST' action='/api/salary'>";
  html += "<input type='hidden' name='return' value='1'>";
  html += "<label>月薪（元）</label><input type='number' step='0.01' min='0' max='10000000' name='monthly_yuan' value='" +
          String(salaryConfig.monthlyFen / 100.0, 2) + "'>";
  html += "<label>上班时间</label><input type='time' name='start_min' value='" +
          salaryTimeInput(salaryConfig.startMin) + "'>";
  html += "<label>下班时间</label><input type='time' name='end_min' value='" +
          salaryTimeInput(salaryConfig.endMin) + "'>";
  html += "<label>午休开始</label><input type='time' name='lunch_start_min' value='" +
          salaryTimeInput(salaryConfig.lunchStartMin) + "'>";
  html += "<label>午休结束</label><input type='time' name='lunch_end_min' value='" +
          salaryTimeInput(salaryConfig.lunchEndMin) + "'>";
  html += "<button type='submit'>保存薪资设置</button></form>";

  html += "<table>";
  html += "<tr><td>WiFi SSID</td><td>" + htmlEscape(WiFi.SSID()) + "</td></tr>";
  html += "<tr><td>设备 IP</td><td>" + WiFi.localIP().toString() + "</td></tr>";
  html += "<tr><td>上次桥接更新</td><td>" + age + "</td></tr>";
  html += "</table>";

#if AICLOCK_OTA_AVAILABLE
  html += "<h2 style='font-size:16px;margin-top:28px'>Firmware update</h2>";
  html += "<p><a href='/update'>Open password-protected update page</a></p>";
#endif

  html += "<form method='POST' action='/reset-wifi' onsubmit=\"return confirm('清除 WiFi "
          "设置并重启？设备会开启配网热点。');\">";
  html += "<button type='submit' style='background:#dc2626'>重置 WiFi</button>";
  html += "</form>";

  html += "</body></html>";
  webServer.send(200, "text/html", html);
}

void handleSave() {
  String newHost = webServer.arg("bridge");
  newHost.trim();
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[web] bridge host updated to '%s'\n", bridgeHost.c_str());
  webServer.sendHeader("Location", "/");
  webServer.send(303);
}

// ---------- JSON API for the Mac app ----------

const char *displayModeName(DisplayMode m) {
  if (m == MODE_PRINTER) return "printer";
  if (m == MODE_MUSIC) return "music";
  if (m == MODE_STOCK) return "stock";
  if (m == MODE_WEATHER) return "weather";
  if (m == MODE_SALARY) return "salary";
  return "weather";
}

void fillDeviceInfo(JsonDocument &doc) {
  fillPrinterInfo(doc["printer"].to<JsonObject>());
  doc["name"] = "aiclock";
  doc["board"] = AICLOCK_BOARD_ID;
  doc["transport"] = AICLOCK_WIRED_ONLY ? "usb" : "hybrid";
  doc["ip"] = WiFi.localIP().toString();
  doc["ssid"] = WiFi.SSID();
  doc["bridge"] = bridgeHost;
  doc["mode"] = displayModeName(displayMode);           // configured mode
  doc["effective"] = displayModeName(effectiveMode());   // what's on screen now
  doc["music_playing"] = statusMusicPlaying;
  doc["showing"] = displayModeName(effectiveMode());
  doc["last_update_s"] = everPolled ? (long)((millis() - lastSuccessMs) / 1000) : -1;
  doc["brightness"] = brightness;
  doc["wired"] = wiredActive(); // true = data currently arrives over USB serial
  doc["fw"] = FW_VERSION;
  doc["ota"] = (bool)AICLOCK_OTA_AVAILABLE;
  doc["reset_reason"] = platformResetReason();
  doc["free_heap"] = ESP.getFreeHeap();
  doc["max_free_block"] = platformMaxFreeBlockSize();
  JsonObject weatherAnimation = doc["weather_animation"].to<JsonObject>();
  weatherAnimation["revision"] = weatherAstronautLoadedRevision;
  weatherAnimation["frames"] = weatherAstronautFrames;
  JsonObject orientation = doc["orientation"].to<JsonObject>();
  orientation["supported"] = HardwareFeatures::imuAvailable();
  orientation["auto"] = autoRotateEnabled;
  orientation["rotation"] = screenRotation;
  const HardwareFeatures::BatteryState &batteryState = HardwareFeatures::battery();
  JsonObject battery = doc["battery"].to<JsonObject>();
  battery["supported"] = batteryState.supported;
  battery["present"] = batteryState.present;
  battery["charging"] = batteryState.charging;
  battery["level"] = batteryState.level;
  battery["voltage_mv"] = batteryState.voltageMv;
  const unsigned long salaryUtcEpoch = salaryCurrentEpoch();
  const unsigned long salaryLocalEpoch = salaryUtcEpoch == 0
      ? 0 : salaryUtcEpoch + 8UL * 3600UL;
  const long salaryElapsed = salaryElapsedWorkSeconds(salaryLocalEpoch);
  JsonObject salary = doc["salary"].to<JsonObject>();
  salary["monthly_fen"] = salaryConfig.monthlyFen;
  salary["start_min"] = salaryConfig.startMin;
  salary["end_min"] = salaryConfig.endMin;
  salary["lunch_start_min"] = salaryConfig.lunchStartMin;
  salary["lunch_end_min"] = salaryConfig.lunchEndMin;
  salary["elapsed_s"] = salaryElapsed;
  salary["daily_work_s"] = salaryDailyWorkSeconds();
  salary["earned_yuan"] = salaryRatePerSecond() * salaryElapsed;
  salary["rate_yuan_per_second"] = salaryRatePerSecond();
  salary["status"] = salaryStatusText(salaryLocalEpoch);
  salary["weekday"] = salaryLocalEpoch == 0 ? -1 : salaryWeekday(salaryLocalEpoch);
}

void sendSerialDeviceInfo() {
  JsonDocument doc;
  fillDeviceInfo(doc);
  Serial.print("#DEVICE ");
  serializeJson(doc, Serial);
  Serial.println();
}

void handleApiInfo() {
  JsonDocument doc;
  fillDeviceInfo(doc);
  String out;
  serializeJson(doc, out);
  webServer.send(200, "application/json", out);
}

void handleApiDisplay() {
  String mode = webServer.arg("mode");
  if (mode == "auto" || mode == "home" || mode == "usage" || mode == "info" ||
      mode == "claude" || mode == "codex" || mode == "net" || mode == "pomodoro") {
    displayMode = MODE_WEATHER;
  }
  else if (mode == "music") displayMode = MODE_MUSIC;
  else if (mode == "stock") displayMode = MODE_STOCK;
  else if (mode == "weather") displayMode = MODE_WEATHER;
  else if (mode == "salary") displayMode = MODE_SALARY;
  else if (mode == "printer" && PrinterMonitor::snapshot().supported)
    displayMode = MODE_PRINTER;
  else {
    webServer.send(
        400, "text/plain",
        "mode must be weather|music|stock|salary|printer");
    return;
  }
  Serial.printf("[api] display mode = %s\n", mode.c_str());
  if (displayMode == MODE_MUSIC) {
    musicChromeDrawn = false;
    lastMusicPollMs = 0; // poll + draw on the next loop tick
  } else if (displayMode == MODE_STOCK) {
    stockChromeDrawn = false;
    lastStockPollMs = 0; // poll + draw on the next loop tick
  } else if (displayMode == MODE_WEATHER) {
    weatherChromeDrawn = false;
    weatherScreenDrawnRev = -1;
    weatherLastSecond = -1;
    weatherAstronautFrame = 0;
    lastWeatherAstronautMs = 0;
    lastWeatherPollMs = 0;
  } else if (displayMode == MODE_SALARY) {
    salaryChromeDrawn = false;
  }
  webServer.send(200, "text/plain", "ok");
}

void handleApiSalary() {
  String monthlyArg = webServer.arg("monthly_yuan");
  String startArg = webServer.arg("start_min");
  String endArg = webServer.arg("end_min");
  String lunchStartArg = webServer.arg("lunch_start_min");
  String lunchEndArg = webServer.arg("lunch_end_min");
  if (monthlyArg.length() == 0 || startArg.length() == 0 || endArg.length() == 0 ||
      lunchStartArg.length() == 0 || lunchEndArg.length() == 0) {
    webServer.send(400, "text/plain", "monthly_yuan and all time fields are required");
    return;
  }
  const float monthlyYuan = monthlyArg.toFloat();
  const long monthlyFen = monthlyYuan <= 0 ? 0 : (long)(monthlyYuan * 100.0f + 0.5f);
  if (!configureSalary(monthlyFen, parseSalaryTime(startArg), parseSalaryTime(endArg),
                       parseSalaryTime(lunchStartArg), parseSalaryTime(lunchEndArg))) {
    webServer.send(400, "text/plain", "invalid salary or schedule (salary 0-10000000, times within workday)");
    return;
  }
  displayMode = MODE_SALARY;
  salaryChromeDrawn = false;
  if (webServer.hasArg("return")) {
    webServer.sendHeader("Location", "/");
    webServer.send(303);
  } else {
    webServer.send(200, "text/plain", "ok");
  }
}

void handleApiBrightness() {
  String levelArg = webServer.arg("level");
  if (levelArg.length() == 0) {
    webServer.send(400, "text/plain", "missing level (0-100)");
    return;
  }
  int level = levelArg.toInt();
  applyExplicitBrightness(level);
  saveBrightness();
  Serial.printf("[api] brightness = %d\n", brightness);
  webServer.send(200, "text/plain", "ok");
}

void handleApiOrientation() {
  if (!HardwareFeatures::imuAvailable()) {
    webServer.send(501, "text/plain", "auto rotation is not supported by this device");
    return;
  }
  String value = webServer.arg("auto");
  value.toLowerCase();
  if (value != "1" && value != "0" && value != "true" && value != "false") {
    webServer.send(400, "text/plain", "auto must be 1|0|true|false");
    return;
  }
  autoRotateEnabled = value == "1" || value == "true";
  saveOrientationConfig();
  Serial.printf("[api] auto rotation = %d\n", autoRotateEnabled);
  webServer.send(200, "text/plain", "ok");
}

void handleApiBridge() {
  String newHost = webServer.arg("host");
  newHost.trim();
  if (newHost.length() == 0) {
    webServer.send(400, "text/plain", "missing host");
    return;
  }
  bridgeHost = newHost;
  saveBridgeHost(bridgeHost);
  Serial.printf("[api] bridge host = '%s'\n", bridgeHost.c_str());
  webServer.send(200, "text/plain", "ok");
  lastPollMs = 0; // poll the new bridge on the next loop tick
}

void handleResetWifi() {
  webServer.send(200, "text/html", "<html><body>Resetting WiFi, device will restart...</body></html>");
  delay(200);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

#if AICLOCK_OTA_AVAILABLE
bool otaAuthenticated = false;
bool otaUploadSucceeded = false;
bool otaRestartPending = false;
unsigned long otaRestartRequestedMs = 0;
String otaUploadError;

const char OTA_UPDATE_PAGE[] PROGMEM = R"HTML(
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Clock Firmware Update</title>
<style>body{font-family:-apple-system,sans-serif;max-width:480px;margin:32px auto;padding:0 16px}
input,button{display:block;margin-top:16px;font-size:16px}button{padding:10px 18px}</style>
</head><body><h1>Firmware Update</h1>
<p>Upload a firmware.bin built for this device. Device settings are preserved.</p>
<form method="POST" action="/update" enctype="multipart/form-data">
<input type="file" name="firmware" accept=".bin,application/octet-stream" required>
<button type="submit">Upload and restart</button></form></body></html>
)HTML";

bool authenticateOtaRequest() {
  if (webServer.authenticate(OTA_USERNAME, OTA_PASSWORD)) return true;
  webServer.requestAuthentication();
  return false;
}

void handleOtaUploadChunk() {
  HTTPUpload &upload = webServer.upload();
  if (upload.status == UPLOAD_FILE_START) {
    otaAuthenticated = webServer.authenticate(OTA_USERNAME, OTA_PASSWORD);
    otaUploadSucceeded = false;
    otaRestartPending = false;
    otaUploadError = "";
    if (!otaAuthenticated) return;
    if (!upload.filename.endsWith(".bin")) {
      otaUploadError = "Only .bin firmware images are accepted.";
      return;
    }
    uint32_t maxSketchSpace = (ESP.getFreeSketchSpace() - 0x1000) & 0xFFFFF000;
    if (!Update.begin(maxSketchSpace, U_FLASH)) {
      otaUploadError = platformUpdateErrorString();
      Serial.printf("[ota] begin failed: %s\n", otaUploadError.c_str());
      return;
    }
    Serial.printf("[ota] receiving %s, max=%u bytes\n", upload.filename.c_str(), maxSketchSpace);
  } else if (otaAuthenticated && upload.status == UPLOAD_FILE_WRITE && otaUploadError.length() == 0) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
      otaUploadError = platformUpdateErrorString();
      Serial.printf("[ota] write failed: %s\n", otaUploadError.c_str());
    }
  } else if (otaAuthenticated && upload.status == UPLOAD_FILE_END && otaUploadError.length() == 0) {
    otaUploadSucceeded = Update.end(true);
    if (!otaUploadSucceeded) otaUploadError = platformUpdateErrorString();
    Serial.printf("[ota] upload %s, bytes=%u\n", otaUploadSucceeded ? "complete" : "failed",
                  upload.totalSize);
  } else if (otaAuthenticated && upload.status == UPLOAD_FILE_ABORTED) {
    Update.end();
    otaUploadError = "Upload was aborted.";
  }
  yield();
}

void handleOtaUploadDone() {
  if (!otaAuthenticated) {
    webServer.requestAuthentication();
    return;
  }
  if (!otaUploadSucceeded) {
    String message = otaUploadError.length() > 0 ? otaUploadError : "Firmware update failed.";
    webServer.send(500, "text/plain", message);
    return;
  }
  webServer.sendHeader("Connection", "close");
  webServer.send(200, "text/html",
                 "<meta http-equiv='refresh' content='15;url=/'>Update complete. Restarting...");
  otaRestartPending = true;
  otaRestartRequestedMs = millis();
}
#endif

#include "printer_web.h"

void setupWebServer() {
  registerPrinterRoutes();
  webServer.on("/", HTTP_GET, handleRoot);
  webServer.on("/save", HTTP_POST, handleSave);
  webServer.on("/reset-wifi", HTTP_POST, handleResetWifi);
  webServer.on("/api/info", HTTP_GET, handleApiInfo);
  webServer.on("/api/display", HTTP_POST, handleApiDisplay);
  webServer.on("/api/salary", HTTP_POST, handleApiSalary);
  webServer.on("/api/bridge", HTTP_POST, handleApiBridge);
  webServer.on("/api/brightness", HTTP_POST, handleApiBrightness);
  webServer.on("/api/orientation", HTTP_POST, handleApiOrientation);
#if AICLOCK_OTA_AVAILABLE
  webServer.on("/update", HTTP_GET, []() {
    if (authenticateOtaRequest()) webServer.send_P(200, "text/html", OTA_UPDATE_PAGE);
  });
  webServer.on("/update", HTTP_POST, handleOtaUploadDone, handleOtaUploadChunk);
#endif
  webServer.begin();
  Serial.printf("[web] admin server listening on http://%s/\n", WiFi.localIP().toString().c_str());
}

// ---------- Arduino entry points ----------

void setup() {
  platformInitializePowerHold();
  Serial.setRxBufferSize(2048); // line frames must survive a slow draw
  Serial.begin(115200);
  fileSystemReady = platformMountFileSystemOnStartup();
  PrinterMonitor::begin(fileSystemReady);
#if !AICLOCK_WIRED_ONLY
  if (fileSystemReady) {
    loadBridgeHost();
    loadBrightness();
    loadSalaryConfig();
    loadWeatherAstronautState();
  }
#else
  if (fileSystemReady) {
    loadSalaryConfig();
    loadWeatherAstronautState();
  }
#endif
  if (fileSystemReady) loadOrientationConfig();
  HardwareFeatures::begin();

  tft.init();
  tft.setRotation(screenRotation);
  tft.fillScreen(TFT_BLACK);
  platformInitializeBacklight();
  applyBrightness();

#if AICLOCK_WIRED_ONLY
  setupWiredOnly();
#else
  setupWiFi();

  if (WiFi.status() == WL_CONNECTED) {
    setupWebServer();
    webServerStarted = true;

    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawString("WiFi connected", 8, 70, 2);
    tft.drawString("Admin page:", 8, 100, 2);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    tft.drawString("http://" + WiFi.localIP().toString(), 8, 125, 2);
    delay(3000);

    showMainUiIfNeeded();
    pollBridge();
  }
  // else: the config-portal screen stays up; either the user configures WiFi
  // (handled in loop) or serial #STATUS frames arrive and take the screen over
#endif
}

void loop() {
#if !AICLOCK_WIRED_ONLY
  wifiManager.process(); // keeps the config portal alive until WiFi is set up
#endif
  pumpSerial();          // wired (USB) bridge frames
  PrinterMonitor::poll();
  // A lost ACK or disconnected sender must not keep the weather renderer
  // suspended indefinitely. The host can retry after this state is released.
  if (serialWeatherAssetActive &&
      millis() - serialWeatherLastProgressMs >= 20000UL) {
    clearSerialWeatherAssetUpload(true);
    Serial.println("#WEATHER_ASSET_ERR timeout");
  }

#if !AICLOCK_WIRED_ONLY
  if (!webServerStarted && WiFi.status() == WL_CONNECTED) {
    // WiFi came up after boot (portal or slow AP); the portal has released
    // port 80 by now, so the admin server can bind it
    setupWebServer();
    webServerStarted = true;
    showMainUiIfNeeded();
    lastPollMs = 0; // poll the bridge right away
  }
  if (webServerStarted) {
    webServer.handleClient();
  }
#if AICLOCK_OTA_AVAILABLE
  if (otaRestartPending && millis() - otaRestartRequestedMs >= 1000) {
    Serial.println("[ota] restarting");
    ESP.restart();
  }
#endif
#endif
  const bool batteryChanged = HardwareFeatures::pollBattery();
  if (mainUiShown && autoRotateEnabled && HardwareFeatures::imuAvailable()) {
    uint8_t suggestedRotation = screenRotation;
    if (HardwareFeatures::pollSuggestedRotation(screenRotation, suggestedRotation)) {
      applyScreenRotation(suggestedRotation);
    }
  }
  if (!mainUiShown) return; // config-portal screen is up, nothing to animate
  if (batteryChanged) {
    DisplayMode batteryMode = effectiveMode();
    if (batteryMode == MODE_WEATHER || batteryMode == MODE_SALARY || batteryMode == MODE_PRINTER) {
      drawBatteryIndicator();
    }
  }

  unsigned long nowMs = millis();

  // Effective mode may differ from the configured one (weather -> music while
  // audio plays). On a transition, reset the incoming mode's chrome so it
  // repaints cleanly.
  DisplayMode eff = effectiveMode();
  if (eff != lastEffectiveMode) {
    PrinterScreen::release();
    lastEffectiveMode = eff;
    if (eff == MODE_MUSIC) {
      musicChromeDrawn = false;
      lastMusicPollMs = 0;
    } else if (eff == MODE_STOCK) {
      stockChromeDrawn = false;
      lastStockPollMs = 0;
    } else if (eff == MODE_WEATHER) {
      weatherChromeDrawn = false;
      weatherScreenDrawnRev = -1;
      weatherLastSecond = -1;
      weatherAstronautFrame = 0;
      lastWeatherAstronautMs = 0;
      lastWeatherPollMs = 0;
      // Do not leave the previous stock/music frame underneath the weather
      // page while its bridge-rendered frame is being prepared.
      tft.fillScreen(TFT_BLACK);
    } else if (eff == MODE_SALARY) {
      salaryChromeDrawn = false;
    }
  }

  if (eff == MODE_MUSIC) {
    // music now-playing mode: cover art + track metadata from the bridge
    if (nowMs - lastMusicPollMs >= MUSIC_POLL_INTERVAL_MS) {
      lastMusicPollMs = nowMs;
      pollMusic();
    }
  } else if (eff == MODE_STOCK) {
    // stock watchlist: HTTP poll unless the serial link is pushing #STOCK
    if (nowMs - lastStockPollMs >= STOCK_POLL_INTERVAL_MS) {
      lastStockPollMs = nowMs;
      if (!wiredActive()) pollStock();
    }
    if (!stockChromeDrawn || stockDirty) drawStockScreen();
  } else if (eff == MODE_WEATHER) {
    // USB weather assets reuse rowBuf while they are decoded. Keep every
    // other renderer away from that buffer until the transfer is committed.
    if (!serialWeatherAssetActive) {
      // Rotation/mode changes invalidate the panel, not the host's minute
      // revision. Explicitly request that same frame again over USB.
      if (wiredActive() && !weatherChromeDrawn &&
          nowMs - lastWeatherScreenRequestMs >= 3000UL) {
        lastWeatherScreenRequestMs = nowMs;
        Serial.println("#WEATHER_SCREEN_NEEDED");
      }
      if (!wiredActive() && nowMs - lastWeatherPollMs >= WEATHER_POLL_INTERVAL_MS) {
        lastWeatherPollMs = nowMs;
        pollWeather();
      }
      if (weatherChromeDrawn) {
        drawWeatherSeconds();
      }
      if (weatherChromeDrawn && weatherAstronautFrames > 0 &&
          nowMs - lastWeatherAstronautMs >= WEATHER_ASTRONAUT_INTERVAL_MS) {
        lastWeatherAstronautMs = nowMs;
        weatherAstronautFrame =
            (weatherAstronautFrame + 1) % weatherAstronautFrames;
        drawWeatherAstronautFrame(weatherAstronautFrame);
      }
    }
  } else if (eff == MODE_PRINTER) {
#if defined(ARDUINO_ARCH_ESP8266) && !AICLOCK_WIRED_ONLY
    if (!wiredActive() && nowMs - lastPrinterPollMs >= 2000UL) {
      lastPrinterPollMs = nowMs;
      pollPrinterBridge();
    }
#endif
    PrinterScreen::draw();
  } else if (eff == MODE_SALARY) {
    drawSalaryScreen();
  }

  // status poll continues in every mode (feeds /api/info and the web page).
  // Wired-first: while serial frames are flowing, skip HTTP polling entirely
  // (works around AP client isolation, and avoids double updates).
  if (nowMs - lastPollMs >= BRIDGE_POLL_INTERVAL_MS) {
    lastPollMs = nowMs;
#if !AICLOCK_WIRED_ONLY
    if (!wiredActive()) pollBridge();
#endif
  }
}
