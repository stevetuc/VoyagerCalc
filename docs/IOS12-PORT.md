# VoyagerCalc on iOS 12 (iPad Air, 1st generation): feasibility and port plan

Audit of `Divasson2/VoyagerCalc` at `9fe4d28` (0.7.5), written 2026-11-25.

Target device: **iPad Air (1st generation, A7, arm64)**. Apple's last release for it is
**iOS 12.5.7** (2023) and **12.5.8** (Jan 2026). There is no iOS 12.7; 12.5.x is the ceiling.
All references to "iOS 12" below mean 12.5.7 / 12.5.8.

---

## 1. Verdict

**No. The app will not run as is, and this is not a deployment-target setting change.**

Three independent blockers, any one of which is fatal:

| # | Blocker | Evidence |
|---|---|---|
| 1 | Project targets iOS 17.0 | `app/project.yml` (`deploymentTarget: iOS "17.0"`), `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (×2) in `app/VoyagerCalc.xcodeproj/project.pbxproj` |
| 2 | The whole UI is SwiftUI, which **requires iOS 13 or later** | 21 of 33 files under `app/Sources` import SwiftUI; `app/Sources/Views/*` is 2,648 lines of SwiftUI |
| 3 | No shipping Xcode can build for iOS 12 | Xcode 15.4 is the last with an iOS 12 deployment target (iOS 12–17.5). **Xcode 16 and later start at iOS 15**, and Xcode 26 supports iOS 15–26 only |

Blocker 2 is structural: `SwiftUI.framework` does not exist on an iOS 12 system, so a SwiftUI
view hierarchy cannot be instantiated there at all. Lowering the deployment target would only
turn the build into "SwiftUI is only available in iOS 13.0 or newer" errors.

Blocker 3 means that even a UIKit port has to be built with **Xcode 15.4 on macOS Sonoma 14.x**.
Xcode 15.4 will not run on macOS Sequoia 15 or Tahoe 26, so a Sonoma volume, VM, or an older Mac
is required. Xcode 15.4 ships iOS 15–17.5 simulators only, so **there is no iOS 12 simulator**:
every test run is on the physical iPad.

Also worth knowing: since 2026 the App Store rejects uploads whose deployment target is below
iOS 13. An iOS 12 build is therefore a **sideload / personal-install** artifact (Apple ID
provisioning, 7-day profile with a free account, 1 year with a paid one), never an App Store
release.

### What is *good* news

The expensive part of this project is portable and needs no work:

| Layer | Lines | Status on iOS 12 |
|---|---|---|
| `core/` (C11 Cortex-M4 + SAM4L emulator, `optables.h` included) | ~5,077 | **Builds as is.** Plain C11, arm64, no OS services. |
| `app/Sources/Models/` (12C / 15C / 16C faces as data, key zones, photo geometry) | 933 | **Reusable.** `import Foundation` only. |
| `app/Sources/Core/` (C wrapper, machine, engine, inspector, matrix, PDF writer, TrueType subsetter, SHA-256, Manz parser) | 4,041 | **Reusable.** Foundation only; the PDF writer is hand-rolled (`PDFWriter.swift`, "no PDFKit / CoreText"), so it does not need iOS 13+ PDF APIs. |

So roughly **9,000 of the 14,200 Swift/C lines survive untouched**. The port is a UI-layer
rewrite, not a rewrite of the calculator.

---

## 2. Full incompatibility inventory

`app/Sources`, grouped by the API that blocks it. "Uses" counts are grep hits.

### Framework-level (cannot be fixed by availability checks in an iOS 12 binary)

| API | Availability | Uses | Consequence |
|---|---|---|---|
| `SwiftUI` | iOS 13 | 21 files | Whole view layer replaced with UIKit |
| `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject` (Combine) | iOS 13 | 69 | `AppModel` (925 lines), `MatrixEditorModel`, `ProgramDocModel` need a non-Combine observation mechanism |
| `async` / `await` / `Task` / `Task.sleep` / `MainActor.assumeIsolated` | iOS 13 (concurrency back-deployment) | 47 | Replace with `DispatchQueue` / `Thread` / `Timer`. The engine is already thread-based, so this is mostly mechanical. |
| `UniformTypeIdentifiers` / `UTType` | iOS 14 | 5 files (`MemoryFile`, `ManzProgramFile`, `AppModel`, `MainViews`, `ProgramDocModel`) | Replace with UTI strings (`public.data`, custom `com.…` identifiers already declared in `Resources/iOS/Info.plist`) |
| SwiftUI `@AppStorage` | iOS 14 | 8 | `UserDefaults` directly |
| SwiftUI `.fileImporter`, `fileExporter`, `ShareLink` | iOS 14 / 16 | `MainViews`, `AppModel` | `UIDocumentPickerViewController` (iOS 11+) + `UIActivityViewController` |
| SwiftUI `Menu` | iOS 14 | `MainViews` | `UIAlertController` action sheet / `UIBarButtonItem` menu |
| `@Environment(\.dismiss)` | iOS 15 | 3 | `dismiss(animated:)` |
| `@FocusState` | iOS 15 | `MatrixEditorView` | `becomeFirstResponder()` |
| SwiftUI `Grid` | iOS 16 | `MatrixEditorView` | `UICollectionView` / manual frames |
| `.onChange(of:_:_:)` (two-parameter closure) | iOS 17 | 6 | moot (views replaced); one-parameter form on iOS 12 if kept |
| `ContentUnavailableView` | iOS 17 | 2 | plain `UILabel` + image |
| `UILaunchScreen` Info.plist key | iOS 14 | `Resources/iOS/Info.plist` | iOS 12 needs `UILaunchStoryboardName` or launch images, otherwise the app letterboxes at 320×480 |
| `UIApplicationSceneManifest` | iOS 13 | same file | remove; use `AppDelegate` + `window` for iOS 12 (scene API must be optional) |
| SF Symbols in `Image(systemName:)` | iOS 13 | several | bundle PNG/PDF assets, or draw |

### macOS-only code (exclude from the iOS 12 target, not a blocker)

`import AppKit` in 10 files, `import IOKit` in `USBHIDTransport.swift` (USB HID programming
transport), `WindowFit.swift` / `WindowChrome.swift` (NSWindow sizing and chrome),
`.windowResizability` / `.defaultSize` / `CommandGroup` in `VoyagerCalcApp.swift`.
None of this has an iOS 12 equivalent; the legacy target simply omits it.

### Fine on iOS 12 (checked, no action)

`AVAudioPlayer` (`App/KeyClick.swift`), `FileManager` Application Support storage
(`FirmwareStore`), `UIActivityViewController`, `UIDocumentPickerViewController`,
CoreGraphics, Foundation `Codable`, `DispatchQueue`, `Thread`, `PDFWriter`, `TrueTypeFont`.

---

## 3. Recommended architecture

**Add a second app target; do not modify the existing SwiftUI app.**

```
VoyagerCalc (existing)     macOS 14 / iOS 17   SwiftUI + Combine   unchanged
VoyagerCalc-iOS12 (new)    iOS 12.0, iPad only UIKit only          new, ~3,500 lines
     ├── reuses core/src, Sources/Models, Sources/Core
     └── new Sources/Legacy/ (AppDelegate, view controllers, views)
```

Why a separate target rather than `if #available(iOS 13, *)` in one binary:

* A single binary would need `@available(iOS 13.0, *)` on every SwiftUI type, every
  `@Published`, and every call site — that is a much larger, more fragile diff than a new
  target, and it makes upstream merges painful in both directions.
* The legacy target can drop the inspector, matrix editor, program documentation and PDF
  export initially, then add them back screen by screen, without touching the modern app.
* `project.yml` and `app/tools/genproj.py` both generate the project, so the target is added
  in the generator, and the checked-in `.xcodeproj` stays reproducible.

### UIKit mapping, screen by screen

The photo-face data already exists as measured rectangles (`PhotoFaceGeometry.swift`,
`KeyZones.swift`), so the photo face ports cleanly:

| Modern | Legacy (iOS 12) |
|---|---|
| `PhotoFaceView` (image + hit zones + pressed state) | `UIViewController` with `UIImageView` + `UIView` per key zone from `PhotoFaceGeometry`; press = `transform` + `alpha` in `touchesBegan/Moved/Ended`; `UILongPressGestureRecognizer` for latch |
| `LCDView` (Core Graphics drawing) | `UIView` + `draw(_:)`, same drawing code (segments/annunciators), `setNeedsDisplay()` on state change |
| `CalculatorView` / `KeyView` (drawn face) | `UIButton` grid or `CALayer` keys, one reusable `KeyButton: UIButton` |
| `MainViews` menu | `UIAlertController(.actionSheet)` from a toolbar button |
| `WelcomeView` / `ProgramInfoView` | `UIAlertController` or a plain modal `UIViewController` |
| `InspectorView` (registers, program list, context menus) | `UITableViewController` sections; `UIMenuController` / action sheet for line operations |
| `MatrixEditorView` | `UICollectionView` of `UITextField` cells |
| `HardwareKeyboard` (`UIKeyCommand`) | unchanged in spirit: `UIKeyCommand` exists on iOS 12; register on the view controller's `keyCommands` |
| `MemoryFile` / `ManzProgramFile` (FileDocument + UTType) | `UIDocument` subclass + `UIDocumentPickerViewController(forOpeningContentTypes:)` → `init(documentTypes:in:)` with UTI strings |
| Program documentation PDF | keep `PDFWriter`; share via `UIActivityViewController` |

### Model layer without Combine

`AppModel` and `MatrixEditorModel` keep their logic but lose `ObservableObject`/`@Published`:

```swift
// Sources/Legacy/LegacyModel.swift
final class ChangeBroadcaster {
    private var observers: [UUID: () -> Void] = [:]
    func observe(_ body: @escaping () -> Void) -> UUID { … }
    func send() { observers.values.forEach { $0() } }
}
// var display: String { didSet { changes.send() } }
```

View controllers subscribe in `viewWillAppear` and unsubscribe in `viewWillDisappear`. This is
the standard pre-Combine pattern and it also removes the `@MainActor` assumptions: every
mutation happens on the main queue explicitly.

`CalculatorEngine` (own thread, real-time stepping) needs only its `Task.sleep` and
`MainActor.assumeIsolated` calls turned into `Thread.sleep` / `DispatchQueue.main.async`.

---

## 4. Plan and effort

| Phase | Work | Result | Estimate |
|---|---|---|---|
| 0 | `project.yml` + `genproj.py`: add `VoyagerCalc-iOS12` (iOS 12.0, `TARGETED_DEVICE_FAMILY = 2`), legacy `Info.plist` (no scene manifest, launch storyboard), `Sources/Legacy` group | Empty app boots on the iPad | 0.5 day |
| 1 | Legacy plumbing: `AppDelegate`, firmware picker (`UIDocumentPicker`), `FirmwareStore` port, `UserDefaults`, key-click sound | Chooses firmware, no UI yet | 1 day |
| 2 | LCD + photo face + keys + touch handling + `HardwareKeyRouter` | **Working calculator**, photo face | 2–3 days |
| 3 | Drawn face fallback, ON/OFF, model switch, memory save/load, About | Feature-complete calculator | 2 days |
| 4 | Inspector (registers, program listing) | Parity with the main use case | 3–4 days |
| 5 | Matrix editor, program notes, PDF export, 15C program import | Full parity | 4–6 days |

* **Calculator-only MVP (phases 0–3): ~2,000–2,500 lines of new UIKit, about one week.**
* **Full parity (0–5): ~3,500–4,500 lines, about three weeks** of focused work.

These are estimates for one developer who knows the codebase; the C core, models and PDF
writer are reused, so they carry no port risk.

---

## 5. Risks

1. **Performance on an A7.** Real-speed mode emulates a 48 MHz Cortex-M4. The A7 has ample
   headroom in principle, but `CalculatorEngine`'s timing was tuned on a Mac. Expect to
   measure and possibly widen the real-time step budget on the iPad. Turbo (25×) will be
   unreachable; keep the real-speed mode as the default and do not promise turbo.
2. **No iOS 12 simulator.** Xcode 15.4 simulators start at iOS 15. All testing is on the
   device, over cable, with device support for iOS 12 in Xcode 15.4.
3. **Toolchain lock-in.** Xcode 15.4 needs macOS Sonoma 14.x. On a Sequoia/Tahoe Mac this
   means a second volume or a VM. The modern app can keep building with Xcode 26 in parallel;
   only the legacy target is pinned to the old toolchain.
4. **Signing.** Free Apple ID: 7-day profiles, 3 apps. Paid: 1-year profiles. Installing on a
   device that tops out at iOS 12.5.7 works with both.
5. **App Store: not possible.** Uploads must target iOS 13+ as of 2026. This is a personal
   build.
6. **Upstream drift.** A separate target keeps `git merge upstream/main` clean, but every new
   feature in the SwiftUI app has to be re-implemented in the legacy target if you want it
   there. Freeze the legacy target at a feature set.
7. **The iPad's iOS version.** If the device is on 12.5.7 it can go to 12.5.8 (certificate
   refresh, Jan 2026). Neither adds any API, so it makes no difference to this port.

---

## 6. What is in this branch

The `VoyagerCalc-iOS12` target is in the project, and phases 0–3 are implemented in
`app/Sources/Legacy/` (UIKit, no SwiftUI, no Combine, no Swift concurrency):

| File | What |
|---|---|
| `AppDelegate.swift` | iOS 12 application (no scene manifest), saves the memory when the app goes to the background |
| `LegacyEngine.swift` | the engine thread: same 10 ms real-time loop as `CalculatorEngine`, with `Thread`/`NSLock`/`DispatchSemaphore` instead of `Task`/`@MainActor` |
| `LegacyCalculator.swift` | firmware, boot, keys, `KeyLatch`, memory files, model switch, key click |
| `CalculatorFaceView.swift` | the drawn face (body, bezel, band, gold legends with brackets, keys with their blue legends), touch tracking and the 0.8 s latch |
| `LCDCanvasView.swift` | the display: seven-segment digits, points, commas and annunciators, drawn with Core Graphics |
| `LegacyDrawing.swift` | colours, gradients and shrink-to-fit text |
| `CalculatorViewController.swift` | the screen: menu (action sheet), `UIDocumentPicker` firmware and memory files, share sheet for memory, iPad hardware keyboard |

Reused unchanged: `core/src` (C), `Sources/Models`, and every `Sources/Core` file except
`CalculatorEngine.swift` (which is replaced by `LegacyEngine.swift`), plus `App/FirmwareStore.swift`.

Not ported yet (phases 4–5): the Registers & Program inspector, the 15C matrix editor, program notes
and the documentation PDF. `LegacyCalculator.canKeepMemory` already gates the memory UI on the
firmware's capabilities, so HP's original 12C firmware behaves as in the SwiftUI app.

### Build it

1. Xcode 15.4 on macOS Sonoma 14.x (Xcode 16 and later cannot target iOS 12).
2. `python3 app/tools/genproj.py` if the project file needs regenerating after adding files
   (it is generated; `app/project.yml` is the same project for XcodeGen).
3. Scheme **VoyagerCalc-iOS12**, your iPad Air, ⌘R. Set your team under *Signing & Capabilities*.
4. First launch: **Choose Firmware File…** and pick your own `.bin`.

### Not verified

Nothing here was compiled: this was written without a Mac or an Xcode toolchain, so the Swift has
been checked by reading it against the APIs it calls, not by a build. The first ⌘B in Xcode 15.4 is
the real check, and a few things are likely to need small fixes there (unknown-argument order,
a missed availability annotation). The generator output, the property list, the launch storyboard and
the absence of iOS 13+ APIs in `Sources/Legacy` were checked mechanically.

## 7. Git plan

* Work on a branch off `9fe4d28`, e.g. `ios12-port`, with this document as the first commit.
* If a real fork is wanted (a separate repository under another account or an organisation),
  it needs GitHub authorisation; a repository cannot be forked into the account that already
  owns it, so for `Divasson2/VoyagerCalc` itself a branch is the correct mechanism.
