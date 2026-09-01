import QtQuick
import "."

// Service entry point (manifest kinds: ["service"]). Instantiating this item
// forces the NowahService singleton alive so refresh and pairing timers keep
// running even when no Nowah bar widget is placed on any bar.
Item {
  // The shell may inject plugin settings here; forward them if it does.
  property var settings: null
  onSettingsChanged: if (settings) NowahService.configure(settings)

  readonly property var service: NowahService
}
