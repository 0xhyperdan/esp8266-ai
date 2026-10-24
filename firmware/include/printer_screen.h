#pragma once

#include "printer_monitor.h"

namespace PrinterScreen {
#if defined(ESP32)
static TFT_eSprite canvas(&tft);
#else
// ESP8266 cannot afford a 115 KB full-screen sprite.
static TFT_eSPI &canvas = tft;
static PrinterMonitor::Snapshot lastSnapshot{};
static bool hasDrawn = false;
#endif
static unsigned long lastDrawMs = 0;

inline void release() {
#if defined(ESP32)
  canvas.deleteSprite();
#else
  hasDrawn = false;
#endif
  lastDrawMs = 0;
}

inline String asciiJob(const char *job) {
  String text;
  for (size_t index = 0; job[index] && index < 26; ++index) {
    const uint8_t ch = static_cast<uint8_t>(job[index]);
    if (ch < 32 || ch > 126) return "Print job";
    text += static_cast<char>(ch);
  }
  return text.length() ? text : "Printer status";
}

inline void draw(bool force = false) {
  const auto state = PrinterMonitor::snapshot();
#if defined(ESP32)
  if (!force && millis() - lastDrawMs < 1000UL) return;
  lastDrawMs = millis();
  if (!canvas.created()) {
    canvas.setColorDepth(16);
    if (!canvas.createSprite(240, 240)) {
      tft.fillScreen(TFT_BLACK);
      tft.setTextDatum(MC_DATUM);
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      tft.drawString("Printer: low memory", 120, 120, 2);
      return;
    }
  }
  canvas.fillSprite(TFT_BLACK);
#else
  const auto &old = lastSnapshot;
  const bool unchanged = old.configured == state.configured && old.enabled == state.enabled &&
      old.connected == state.connected && old.stale == state.stale &&
      old.progressKnown == state.progressKnown && old.progress == state.progress &&
      old.remainingKnown == state.remainingKnown && old.remainingMinutes == state.remainingMinutes &&
      old.layersKnown == state.layersKnown && old.layer == state.layer && old.totalLayers == state.totalLayers &&
      old.nozzleKnown == state.nozzleKnown && old.nozzle == state.nozzle &&
      old.bedKnown == state.bedKnown && old.bed == state.bed &&
      old.dualNozzle == state.dualNozzle &&
      old.nozzleKnownN[0] == state.nozzleKnownN[0] && old.nozzleKnownN[1] == state.nozzleKnownN[1] &&
      old.nozzleN[0] == state.nozzleN[0] && old.nozzleN[1] == state.nozzleN[1] &&
      !strcmp(old.state, state.state) && !strcmp(old.job, state.job) && !strcmp(old.error, state.error);
  if (!force && hasDrawn && unchanged) return;
  lastSnapshot = state;
  hasDrawn = true;
  canvas.fillScreen(TFT_BLACK);
#endif
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  canvas.setTextDatum(TL_DATUM);
  canvas.drawString("BAMBU", 12, 10, 4);
  const char *status = state.state;
  uint16_t color = TFT_GREEN;
  if (!state.configured) status = "Configure printer in app";
  else if (!state.enabled) status = "Monitoring disabled";
  else if (!state.connected) status = "Printer offline";
  else if (state.stale) status = "Data stale";
  else if (!strlen(state.state)) status = "Waiting for printer";
  if (!state.connected || state.stale || !state.enabled) color = TFT_ORANGE;
  if (!strcmp(state.state, "FAILED")) color = TFT_RED;
  if (!strcmp(state.state, "PAUSE") && state.connected && !state.stale)
    color = TFT_YELLOW;
  canvas.setTextColor(color, TFT_BLACK);
  canvas.drawString(status, 12, 40, 2);
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  canvas.drawString(asciiJob(state.job), 12, 62, 2);
  canvas.fillRoundRect(12, 90, 216, 8, 4, TFT_DARKGREY);
  if (state.progressKnown && state.progress > 0)
    canvas.fillRoundRect(12, 90, max(1, 216 * state.progress / 100), 8, 4, color);
  const String percent = state.progressKnown ? String(state.progress) + "%" : "--%";
  canvas.drawString(percent, 12, 107, 6);
  String remaining = "--";
  if (state.remainingKnown) {
    remaining = state.remainingMinutes >= 60
        ? String(state.remainingMinutes / 60) + "h " + String(state.remainingMinutes % 60) + "m"
        : String(state.remainingMinutes) + "m";
  }
  canvas.drawString("Left " + remaining, 12, 156, 2);
  const String layers = state.layersKnown
      ? String(state.layer) + "/" + String(state.totalLayers) : "--/--";
  canvas.drawString("L " + layers, 126, 156, 2);
  canvas.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  canvas.drawString("NOZZLE", 12, 186, 2);
  canvas.drawString("BED", 130, 186, 2);
  canvas.setTextColor(TFT_WHITE, TFT_BLACK);
  const String nozzle = state.nozzleKnown
      ? String((int)state.nozzle) + " C" : "--";
  const String bed = state.bedKnown
      ? String((int)state.bed) + " C" : "--";
  if (state.dualNozzle) {
    const String left = state.nozzleKnownN[1] ? String((int)state.nozzleN[1]) : "--";
    const String right = state.nozzleKnownN[0] ? String((int)state.nozzleN[0]) : "--";
    canvas.drawString("L" + left + " R" + right, 12, 208, 2);
  } else {
    canvas.drawString(nozzle, 12, 208, 4);
  }
  canvas.drawString(bed, 130, 208, 4);
#if defined(ESP32)
  canvas.pushSprite(0, 0);
#endif
  if (HardwareFeatures::battery().present) drawBatteryIndicator();
}
}  // namespace PrinterScreen
