#include "printer_monitor_recovery.h"
#include <cstdio>
#include <map>
#include <string>

namespace {
struct FakeFS {
  std::map<std::string, std::string> files;
  std::string failRemove;
  std::string failRename;
  bool exists(const char *path) { return files.count(path) != 0; }
  bool remove(const char *path) {
    if (failRemove == path) return false;
    return files.erase(path) != 0;
  }
  bool rename(const char *from, const char *to) {
    if (failRename == from || !exists(from) || exists(to)) return false;
    files[to] = files[from];
    files.erase(from);
    return true;
  }
};
int failures = 0;
void check(bool condition, const char *message) {
  if (!condition) { ++failures; std::printf("FAIL: %s\n", message); }
}
}

int main() {
  using namespace PrinterMonitor;
  const ConfigPaths paths{"main", "tmp", "bak"};
  FakeFS fs;
  fs.files = {{"main", "authoritative"}, {"tmp", "partial secret"}, {"bak", "old secret"}};
  check(recoverPrimary(fs, paths) && cleanJournal(fs, paths),
        "valid primary cleans both credential-bearing orphan artifacts");
  check(fs.files.size() == 1 && fs.files["main"] == "authoritative", "primary is preserved");

  fs.files = {{"bak", "old"}, {"tmp", "candidate"}};
  check(recoverPrimary(fs, paths) && cleanJournal(fs, paths), "rename crash recovers old primary");
  check(fs.files["main"] == "old" && fs.files.size() == 1, "uncommitted candidate discarded");

  fs.files = {{"main", "old secret"}, {"tmp", "empty configuration"}};
  fs.failRemove = "bak";
  check(!commitConfigSave(fs, paths), "clear cannot succeed if backup removal fails");
  check(fs.exists("bak") && fs.files["main"] == "empty configuration", "cleanup failure remains visible");
  check(!prepareConfigSave(fs, paths), "failed cleanup prevents another success acknowledgement");
  fs.failRemove.clear();
  check(cleanJournal(fs, paths) && !fs.exists("bak"), "cleanup retry removes old credentials");

  fs.files = {{"main", "old"}, {"tmp", "new"}};
  fs.failRename = "main";
  check(!commitConfigSave(fs, paths) && fs.files["main"] == "old", "first rename failure preserves old primary");
  fs.failRename = "tmp";
  fs.files["tmp"] = "new";
  check(!commitConfigSave(fs, paths) && fs.files["main"] == "old", "commit rename failure rolls back old primary");
  fs.failRename.clear();

  fs.files = {{"bak", "only valid copy"}, {"tmp", "incomplete"}};
  fs.failRename = "bak";
  check(!prepareConfigSave(fs, paths) && fs.exists("bak"), "failed recovery never discards only valid backup");
  fs.failRename.clear();
  check(prepareConfigSave(fs, paths) && fs.files["main"] == "only valid copy", "recovery can retry deterministically");

  fs.files = {{"main", "old"}, {"tmp", "partial"}};
  fs.failRemove = "tmp";
  check(!cleanJournal(fs, paths), "temporary credential removal failure is propagated");
  fs.failRemove.clear();
  check(cleanJournal(fs, paths), "temporary cleanup can retry");

  StatusRequestSchedule schedule;
  check(schedule.due(0), "initial status request is due");
  schedule.record(0, false);
  check(!schedule.published && !schedule.due(4999), "failed publish does not count as success or busy-loop");
  check(schedule.due(5000), "failed publish retries after backoff, not a minute");
  schedule.record(5000, true);
  check(!schedule.due(64999) && schedule.due(65000), "successful snapshot requests rate-limited to a minute");
  schedule.record(65000, false);
  check(schedule.lastSuccess == 5000 && schedule.due(70000), "failed periodic request preserves success timestamp");
  check(nextFailure(255) == 4 && nextFailure(4) == 4, "failure count saturates instead of wrapping");
  check(reconnectDelayMs(0) == 5000 && reconnectDelayMs(4) == 60000 &&
        reconnectDelayMs(255) == 60000, "backoff stays bounded after long outages");
  if (!failures) std::printf("printer recovery failure-injection tests passed\n");
  return failures ? 1 : 0;
}
