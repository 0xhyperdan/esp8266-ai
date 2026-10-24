#include "printer_monitor_parser.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const char *message) {
  if (!condition) {
    std::printf("FAIL: %s\n", message);
    ++failures;
  }
}

PrinterMonitor::Snapshot emptySnapshot() {
  PrinterMonitor::Snapshot snapshot{};
  snapshot.state[0] = '\0';
  snapshot.job[0] = '\0';
  snapshot.error[0] = '\0';
  return snapshot;
}

}  // namespace

int main() {
  using namespace PrinterMonitor;

  Snapshot snapshot = emptySnapshot();
  ParserState parser;

  const char *initialReport =
      "{\"print\":{\"gcode_state\":\"RUNNING\",\"mc_percent\":42,"
      "\"mc_remaining_time\":75,\"nozzle_temper\":220.5,"
      "\"nozzle_target_temper\":220,\"bed_temper\":55.25,"
      "\"bed_target_temper\":60,\"layer_num\":12,"
      "\"total_layer_num\":180,\"subtask_name\":\"Bracket.gcode.3mf\","
      "\"task_id\":\"123456\"}}";
  check(parseReport(initialReport, std::strlen(initialReport), snapshot, parser),
        "initial full report is accepted");
  check(std::strcmp(snapshot.state, "RUNNING") == 0, "state is parsed");
  check(std::strcmp(snapshot.job, "Bracket.gcode.3mf") == 0, "job is parsed");
  check(snapshot.progressKnown && snapshot.progress == 42, "progress is parsed");
  check(snapshot.remainingKnown && snapshot.remainingMinutes == 75,
        "remaining time is parsed");
  check(snapshot.nozzleKnown && snapshot.nozzle == 220.5f &&
            snapshot.nozzleTarget == 220.0f,
        "nozzle temperatures are parsed");
  check(snapshot.bedKnown && snapshot.bed == 55.25f &&
            snapshot.bedTarget == 60.0f,
        "bed temperatures are parsed");
  check(snapshot.layersKnown && snapshot.layer == 12 &&
            snapshot.totalLayers == 180,
        "layers are parsed");

  const char *temperatureDelta =
      "{\"print\":{\"nozzle_temper\":221.25}}";
  check(parseReport(temperatureDelta, std::strlen(temperatureDelta), snapshot,
                    parser),
        "temperature delta is accepted");
  check(snapshot.progressKnown && snapshot.progress == 42 &&
            snapshot.remainingKnown && snapshot.remainingMinutes == 75 &&
            snapshot.layersKnown && snapshot.layer == 12 &&
            snapshot.totalLayers == 180,
        "absent delta fields preserve their values");
  check(snapshot.nozzle == 221.25f, "updated delta field is applied");

  const Snapshot beforeNull = snapshot;
  const char *nullDelta = "{\"print\":{\"mc_percent\":null,\"job\":123}}";
  check(!parseReport(nullDelta, std::strlen(nullDelta), snapshot, parser),
        "a report with no valid monitored fields is rejected");
  check(snapshot.progressKnown == beforeNull.progressKnown &&
            snapshot.progress == beforeNull.progress &&
            snapshot.layer == beforeNull.layer,
        "null and invalid fields do not become false or zero");

  const char *newJob =
      "{\"print\":{\"subtask_name\":\"Gear.gcode.3mf\",\"task_id\":\"999\","
      "\"gcode_state\":\"PREPARE\"}}";
  check(parseReport(newJob, std::strlen(newJob), snapshot, parser),
        "new job report is accepted");
  check(!snapshot.progressKnown && snapshot.progress == 0 &&
            !snapshot.remainingKnown && snapshot.remainingMinutes == 0 &&
            !snapshot.layersKnown && snapshot.layer == 0 &&
            snapshot.totalLayers == 0,
        "job change clears old job counters");
  check(std::strcmp(snapshot.job, "Gear.gcode.3mf") == 0 &&
            std::strcmp(snapshot.state, "PREPARE") == 0,
        "new job identity and state are stored");
  check(snapshot.nozzleKnown && snapshot.bedKnown,
        "job change preserves non-counter temperature availability");

  const char *clamped =
      "{\"print\":{\"mc_percent\":250,\"mc_remaining_time\":20000,"
      "\"layer_num\":-7,\"total_layer_num\":99999,"
      "\"nozzle_temper\":500,\"bed_temper\":300}}";
  check(parseReport(clamped, std::strlen(clamped), snapshot, parser),
        "out-of-range report is accepted");
  check(snapshot.progress == 100 && snapshot.remainingMinutes == 10000 &&
            snapshot.layer == 0 && snapshot.totalLayers == 10000 &&
            snapshot.nozzle == 350.0f && snapshot.bed == 150.0f,
        "numeric values are clamped");

  const char *longName =
      "{\"print\":{\"subtask_name\":\""
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}";
  check(parseReport(longName, std::strlen(longName), snapshot, parser),
        "long job name is accepted");
  check(snapshot.job[sizeof(snapshot.job) - 1] == '\0',
        "long job name remains NUL terminated");

  const char *hmsReport =
      "{\"print\":{\"hms\":[{\"attr\":7,\"code\":512}]}}";
  check(!parseReport(hmsReport, std::strlen(hmsReport), snapshot, parser),
        "uninterpreted HMS alone is not fresh print telemetry");

  const char *x2d =
      "{\"print\":{\"device\":{\"extruder\":{\"state\":16,\"info\":["
      "{\"id\":0,\"temp\":14418130},{\"id\":1,\"temp\":15073485}]}}}}";
  check(parseReport(x2d, std::strlen(x2d), snapshot, parser), "X2D tools parsed");
  check(snapshot.dualNozzle && snapshot.activeNozzle == 1 && snapshot.nozzle == 205,
        "X2D packed temperatures use active left nozzle");
  check(snapshot.nozzleKnownN[0] && snapshot.nozzleN[0] == 210 &&
            snapshot.nozzleKnownN[1] && snapshot.nozzleN[1] == 205,
        "both X2D nozzle temperatures retained");
  const char *switchTool = "{\"print\":{\"device\":{\"extruder\":{\"state\":0}}}}";
  check(parseReport(switchTool, std::strlen(switchTool), snapshot, parser),
        "active-tool-only delta accepted");
  check(snapshot.nozzle == 210, "tool switch selects cached right temperature");
  const char *legacyZero = "{\"print\":{\"nozzle_temper\":0}}";
  check(!parseReport(legacyZero, std::strlen(legacyZero), snapshot, parser),
        "legacy single nozzle field does not override dual tool data");
  check(snapshot.nozzle == 210, "X2D current temperature preserved");

  const char *metadataOnly = "{\"print\":{\"task_id\":\"next-job\"}}";
  check(parseReport(metadataOnly, std::strlen(metadataOnly), snapshot, parser),
        "job identity change alone commits reset state");
  check(!snapshot.progressKnown && !snapshot.remainingKnown && !snapshot.layersKnown &&
            !snapshot.job[0] && !snapshot.state[0],
        "new task cannot inherit prior task counters, name, or terminal state");

  const char *finished = "{\"print\":{\"gcode_state\":\"FINISH\",\"mc_percent\":100}}";
  parseReport(finished, std::strlen(finished), snapshot, parser);
  const char *restart = "{\"print\":{\"gcode_state\":\"PREPARE\"}}";
  check(parseReport(restart, std::strlen(restart), snapshot, parser),
        "same local task restarting is accepted");
  check(!snapshot.progressKnown, "repeated local job does not start at 100 percent");

  char utf8[128];
  char utf8Source[140];
  memset(utf8Source, 'a', 126);
  strcpy(utf8Source + 126, "中");
  PrinterMonitor::copyText(utf8, sizeof(utf8), utf8Source);
  check(strlen(utf8) == 126, "job name truncation never splits a UTF-8 character");
  PrinterMonitor::copyText(utf8, sizeof(utf8), "\xc3(");
  check(strcmp(utf8, "?(") == 0, "malformed UTF-8 cannot break status JSON");

  const char *empty = "";
  check(!parseReport(empty, 0, snapshot, parser), "empty payload is rejected");

  if (failures == 0) std::printf("printer monitor parser tests passed\n");
  return failures == 0 ? 0 : 1;
}
