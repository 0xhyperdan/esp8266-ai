#pragma once

#include "printer_monitor.h"

// Status is public like /api/info. Credential mutation uses the existing OTA
// authentication plus a non-simple header, preventing cross-origin form posts.
inline void fillPrinterInfo(JsonObject object) {
  const auto state = PrinterMonitor::snapshot();
  object["supported"] = state.supported;
#if defined(ESP32)
  object["source"] = "native";
  object["native"] = true;
#else
  object["source"] = "bridge";
  object["native"] = false;
#endif
  if (!state.supported) return;
  object["configured"] = state.configured;
  object["enabled"] = state.enabled;
  object["connected"] = state.connected;
  object["stale"] = state.stale;
  PrinterMonitor::writeSnapshotText(object, state);
  object["dual_nozzle"] = state.dualNozzle;
  object["active_nozzle"] = state.activeNozzle;
  if (state.nozzleKnownN[1]) object["nozzle_left_c"] = state.nozzleN[1];
  if (state.nozzleKnownN[0]) object["nozzle_right_c"] = state.nozzleN[0];
  if (state.progressKnown) object["progress"] = state.progress;
  if (state.remainingKnown) object["remaining_min"] = state.remainingMinutes;
  if (state.layersKnown) {
    object["layer"] = state.layer;
    object["total_layers"] = state.totalLayers;
  }
  if (state.nozzleKnown) {
    object["nozzle_c"] = state.nozzle;
  }
  if (state.bedKnown) {
    object["bed_c"] = state.bed;
  }
}

const char PRINTER_SETUP_PAGE[] PROGMEM = R"HTML(
<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>拓竹打印机设置</title>
<style>body{font:16px system-ui;max-width:520px;margin:30px auto;padding:16px}label{display:block;margin:18px 0}input:not([type=checkbox]){display:block;box-sizing:border-box;width:100%;padding:10px;margin-top:8px}button{padding:10px 18px;margin:8px}#result{white-space:pre-wrap}</style>
<h1>拓竹打印机 · LAN Direct</h1>
<p>仅监控状态，不控制打印。配置保存在此 ESP32-S3，关闭电脑后仍可使用。</p>
<p>请仅在可信局域网配置：此管理页使用 HTTP；打印机连接使用 TLS，但拓竹 LAN 自签名证书无法验证身份。</p>
<form id="settings">
<label><input id="enabled" type="checkbox" checked> 开启打印机监控（关闭后断开连接）</label>
<label>打印机局域网 IPv4<input id="host" required maxlength="15" placeholder="192.168.2.100"></label>
<label>打印机序列号<input id="serial" required maxlength="32" autocomplete="off"></label>
<label>LAN Access Code<input id="code" type="password" maxlength="64" autocomplete="new-password" placeholder="已配置时留空表示保留"></label>
<label><input id="trust" type="checkbox"> 我信任此局域网，允许连接打印机的自签名 TLS 证书</label>
<button>保存并显示打印机</button><button id="forget" type="button">清除打印机配置</button></form>
<p id="result" role="status"></p><p><a href="/">返回设备管理</a></p>
<script>
const el=id=>document.getElementById(id);let saving=false;
async function send(body){
 if(saving)return;saving=true;el('result').textContent='正在保存…';
 try{const response=await fetch('/api/printer',{method:'POST',headers:{'Content-Type':'application/json','X-AIClock-Config':'1'},body:JSON.stringify(body)});const message=await response.text();if(!response.ok)throw Error(message);el('result').textContent=body.action==='forget'?'已清除':'已保存';el('code').value='';if(body.action==='forget'){el('host').value='';el('serial').value='';el('enabled').checked=true;el('trust').checked=false;}}
 catch(error){el('result').textContent=error.message;}finally{saving=false;}
}
el('settings').onsubmit=event=>{event.preventDefault();send({enabled:el('enabled').checked,host:el('host').value.trim(),serial:el('serial').value.trim(),access_code:el('code').value,allow_self_signed:el('trust').checked});};
el('forget').onclick=()=>{if(confirm('清除此设备保存的打印机访问码和连接配置？'))send({action:'forget'});};
fetch('/api/printer/config').then(response=>{if(!response.ok)throw Error('无法读取设置');return response.json();}).then(config=>{el('host').value=config.host||'';el('serial').value=config.serial||'';el('enabled').checked=config.host&&config.serial?Boolean(config.enabled):true;el('trust').checked=config.allow_self_signed;}).catch(error=>el('result').textContent=error.message);
</script></html>
)HTML";

inline bool printerConfigurationAuthorized() {
#if AICLOCK_OTA_AVAILABLE
  return authenticateOtaRequest();
#else
  webServer.send(403, "text/plain", "Authenticated configuration is unavailable.");
  return false;
#endif
}

inline void registerPrinterRoutes() {
#if defined(ESP32)
  const char *headers[] = {"Authorization", "X-AIClock-Config"};
  webServer.collectHeaders(headers, 2);
  webServer.on("/printer", HTTP_GET, []() {
    if (!PrinterMonitor::snapshot().supported) {
      webServer.send(404, "text/plain", "Printer monitoring requires ESP32-S3.");
      return;
    }
    if (printerConfigurationAuthorized())
      webServer.send_P(200, "text/html; charset=utf-8", PRINTER_SETUP_PAGE);
  });
  webServer.on("/api/printer", HTTP_GET, []() {
    JsonDocument document;
    fillPrinterInfo(document.to<JsonObject>());
    String response;
    serializeJson(document, response);
    webServer.send(200, "application/json", response);
  });
  webServer.on("/api/printer/config", HTTP_GET, []() {
    if (!printerConfigurationAuthorized()) return;
    const auto config = PrinterMonitor::configuration();
    JsonDocument document;
    document["host"] = config.host;
    document["serial"] = config.serial;
    document["enabled"] = config.enabled;
    document["allow_self_signed"] = config.allowSelfSigned;
    // Never send credentials back, even to the authenticated configuration UI.
    String response;
    serializeJson(document, response);
    webServer.sendHeader("Cache-Control", "no-store");
    webServer.send(200, "application/json", response);
  });
  webServer.on("/api/printer", HTTP_POST, []() {
    if (!PrinterMonitor::snapshot().supported) {
      webServer.send(400, "text/plain", "Printer monitoring requires ESP32-S3.");
      return;
    }
    if (!printerConfigurationAuthorized()) return;
    if (webServer.header("X-AIClock-Config") != "1") {
      webServer.send(403, "text/plain", "Missing configuration request header.");
      return;
    }
    const String body = webServer.arg("plain");
    JsonDocument document;
    if (body.length() > 1024 || deserializeJson(document, body)) {
      webServer.send(400, "text/plain", "Invalid configuration.");
      return;
    }
    if (document["action"] == "forget") {
      String error;
      if (!PrinterMonitor::clear(error)) {
        webServer.send(500, "text/plain", error);
        return;
      }
      webServer.send(200, "text/plain", "ok");
      return;
    }
    if (!document["enabled"].is<bool>() ||
        !document["allow_self_signed"].is<bool>() ||
        !document["host"].is<const char *>() ||
        !document["serial"].is<const char *>() ||
        !document["access_code"].is<const char *>()) {
      webServer.send(400, "text/plain", "Missing configuration fields.");
      return;
    }
    auto config = PrinterMonitor::configuration();
    const String host = document["host"].as<String>();
    const String serial = document["serial"].as<String>();
    const String code = document["access_code"].as<String>();
    if (host.length() >= sizeof(config.host) ||
        serial.length() >= sizeof(config.serial) ||
        code.length() >= sizeof(config.accessCode) ||
        host.length() != strlen(host.c_str()) ||
        serial.length() != strlen(serial.c_str()) ||
        code.length() != strlen(code.c_str())) {
      webServer.send(400, "text/plain", "Configuration field too long.");
      return;
    }
    if (!code.length() && (host != config.host || serial != config.serial)) {
      webServer.send(400, "text/plain", "Enter the access code when changing printers.");
      return;
    }
    config.enabled = document["enabled"].as<bool>();
    config.allowSelfSigned = document["allow_self_signed"].as<bool>();
    strlcpy(config.host, host.c_str(), sizeof(config.host));
    strlcpy(config.serial, serial.c_str(), sizeof(config.serial));
    if (code.length()) strlcpy(config.accessCode, code.c_str(), sizeof(config.accessCode));
    String error;
    if (!PrinterMonitor::configure(config, error)) {
      webServer.send(400, "text/plain", error);
      return;
    }
    if (config.enabled) displayMode = MODE_PRINTER;
    webServer.send(200, "text/plain", "ok");
  });
#endif
}
