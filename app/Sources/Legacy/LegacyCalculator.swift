// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyCalculator.swift - the iOS 12 app state. The SwiftUI app's AppModel, without Combine
// (ObservableObject / @Published need iOS 13): plain closures notify the view controller, and
// every mutation happens on the main queue. The calculator logic is the same: FirmwareStore,
// StateStore, CalculatorMachine, KeyLatch and the engine thread.

import AVFoundation
import Foundation

final class LegacyCalculator {
    static let shared = LegacyCalculator()

    /// Main queue: something the face shows changed (display, pressed or latched keys, model).
    var onChange: (() -> Void)?
    /// Main queue: something to tell the user (a note, a result).
    var onMessage: ((String) -> Void)?
    /// Main queue: something went wrong.
    var onError: ((String) -> Void)?

    private(set) var snapshot = FaceSnapshot()
    private(set) var firmwareName: String?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var pressedKeys: Set<Int> = []
    private(set) var latchedKeys: Set<Int> = []
    private(set) var capabilities: FirmwareCapabilities = .all
    private(set) var images: [Int] = []
    private(set) var firmwareInfo = ""
    private(set) var firmwareChecksum: String?
    /// SHA-256 of the firmware file: the key the program notes are kept under.
    private(set) var firmwareID = ""
    /// The memory file last opened in the calculator (its program notes sit next to it).
    private(set) var memoryFileName: String?
    /// Called on the main queue once a memory file has been loaded.
    var onMemoryLoaded: ((URL) -> Void)?

    private var engine: LegacyEngine?
    private var latch = KeyLatch()
    private let firmwareStore = FirmwareStore()
    private let stateStore = StateStore()
    private var players: [AVAudioPlayer] = []
    private var nextPlayer = 0

    var model: CalculatorModel { CalculatorModel.with(id: snapshot.model) }
    var hasFirmware: Bool { isRunning }
    var canKeepMemory: Bool { capabilities.contains(.memory) }
    var canSwitchModel: Bool { images.count > 1 }

    // MARK: launch / firmware

    func launch() {
        guard engine == nil, !isStarting else { return }
        if let fw = firmwareStore.load() {
            start(fw, restoring: stateStore.load(firmwareID: SHA256Hex.of(fw.data)))
        }
    }

    /// A firmware file the user picked in the document picker.
    func firmwarePicked(_ url: URL) {
        do {
            let fw = try firmwareStore.read(url)
            let probe = VoyagerCalculator()
            try probe.loadFirmware(fw.data)                 // check before remembering
            try firmwareStore.remember(url, firmware: fw)
            start(fw, restoring: stateStore.load(firmwareID: SHA256Hex.of(fw.data)))
        } catch {
            onError?(Self.message(error))
        }
    }

    private func start(_ fw: StoredFirmware, restoring saved: SavedState?) {
        stopEngine()
        isStarting = true
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let machine = CalculatorMachine()
            var outcome: Result<String?, Error>
            do {
                try machine.loadFirmware(fw.data)
                let note = try machine.boot(restoring: saved)
                outcome = .success(note)
            } catch {
                outcome = .failure(error)
            }
            let family = machine.family
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isStarting = false
                switch outcome {
                case .failure(let e):
                    self.onError?(Self.message(e))
                    self.onChange?()
                case .success(let note):
                    if let note = note { self.onMessage?(note) }
                    self.attach(machine, firmwareName: fw.name)
                    if family == .stock { self.onMessage?(Self.stockLimits) }
                }
            }
        }
    }

    private func attach(_ machine: CalculatorMachine, firmwareName: String) {
        stopEngine()
        self.firmwareName = firmwareName
        firmwareID = machine.firmwareID
        memoryFileName = nil
        firmwareInfo = machine.calc.firmwareInfo
        firmwareChecksum = machine.calc.firmwareChecksum
        capabilities = machine.capabilities
        images = machine.images
        snapshot.model = machine.model
        snapshot.variant = machine.variant
        snapshot.lcd = machine.calc.lcd()

        let e = LegacyEngine(machine: machine)
        e.onSnapshot = { [weak self] s in
            guard let self = self else { return }
            self.snapshot = s
            self.onChange?()
        }
        e.onFault = { [weak self] msg in self?.onError?(msg) }
        engine = e
        e.start()
        isRunning = true
        onChange?()
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        isRunning = false
        pressedKeys = []
        latchedKeys = []
        latch = KeyLatch()
    }

    /// Turn the calculator off and keep its memory for the next launch (blocking, short).
    func saveState() {
        guard let e = engine, canKeepMemory else { return }
        if let saved = e.performAndWait(timeout: 3, { m in try? m.savedState(turnBackOn: false) }) {
            if let s = saved { stateStore.save(s) }
        }
    }

    func resumeAfterBackground() {
        guard let e = engine else { return }
        e.send(.perform { m in _ = try? m.powerOn() })
    }

    // MARK: keys

    /// A press on one part of a key: its gold legend = f then the key, its blue legend = g then
    /// the key, the cap = the key (CalculatorMachine.pressShifted replaces a pending shift).
    func press(_ code: Int, part: KeyPart = .face) {
        guard engine != nil else { return }
        clickSound()
        if let k = model.key(code: code), let shift = k.shift(for: part) {
            apply(latch.unlatchAll())
            pressedKeys.insert(shown(code))
            engine?.send(.pressShifted(shift: shift, code: code))
            onChange?()
            return
        }
        apply(latch.press(code))
        onChange?()
    }

    func release(_ code: Int) {
        apply(latch.release(code))
        onChange?()
    }

    /// A long press: the key the finger holds stays down when it lifts.
    func holdBecameLatch(_ code: Int) {
        apply(latch.holdBecameLatch(code))
        onChange?()
    }

    func releaseLatchedKeys() {
        apply(latch.unlatchAll())
        onChange?()
    }

    private func shown(_ code: Int) -> Int { code == 35 ? 25 : code }

    private func apply(_ actions: [KeyLatch.Action]) {
        for a in actions {
            switch a {
            case .press(let k):
                pressedKeys.insert(shown(k)); engine?.send(.press(k))
            case .release(let k):
                pressedKeys.remove(shown(k)); engine?.send(.release(k))
            case .releaseLater(let ks):
                for k in ks { pressedKeys.remove(shown(k)) }
                engine?.send(.releaseLater(ks, afterMs: KeyLatch.releaseDelayMs))
            }
        }
        latchedKeys = Set(latch.latched.map(shown))
    }

    // MARK: menu actions

    func togglePower() {
        guard let e = engine else { return }
        clickSound()
        e.send(.press(CalculatorMachine.keyON))
        e.send(.release(CalculatorMachine.keyON))
    }

    func perform(_ chord: KeyChord) {
        guard let e = engine else { return }
        apply(latch.unlatchAll())
        e.send(.chord(chord))
        onChange?()
    }

    func resetCalculator() {
        guard engine != nil else { return }
        stateStore.clear()
        memoryFileName = nil
        perform(.memoryReset)
        onMessage?("Calculator reset (ON + −). It starts from a cleared memory.")
    }

    func switchModel(to variant: Int) {
        guard let e = engine else { return }
        apply(latch.unlatchAll())
        onMessage?("Switching to the \(CalculatorMachine.variantName(variant))…")
        e.send(.switchModel(variant) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success:
                self.onMessage?("Running as the \(CalculatorMachine.variantName(self.snapshot.variant)).")
            case .failure(let error):
                self.onError?(Self.message(error))
            }
            self.onChange?()
        })
    }

    // MARK: memory

    /// The 2 KB memory image, for the share sheet. The calculator is turned off for the copy.
    func memoryImage() -> Data? {
        guard let e = engine else { return nil }
        guard canKeepMemory else {
            onError?("HP's original firmware keeps its memory in a different layout than the CE firmware, so memory files are not available with it.")
            return nil
        }
        if let data = e.performAndWait(timeout: 5, { m in try? m.memory(turnBackOn: true) }) {
            if let d = data { return d }
        }
        onError?("The calculator did not answer in time; try again.")
        return nil
    }

    func loadMemory(_ url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let e = engine else { return }
            e.send(.loadMemory(data) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.onError?(Self.message(error))
                } else {
                    self.memoryFileName = url.lastPathComponent
                    self.onMessage?("Memory loaded from \(url.lastPathComponent).")
                    self.onMemoryLoaded?(url)
                }
            })
        } catch {
            onError?(Self.message(error))
        }
    }

    /// The name a memory file is saved under (not the one that was opened: that is `memoryFileName`).
    func suggestedMemoryFileName() -> String {
        let base = firmwareName.map { ($0 as NSString).deletingPathExtension } ?? "Calculator memory"
        return base + "." + model.fileExtension
    }

    // MARK: inspector / matrix editor

    /// Read the registers and, when asked, the program on the engine thread. The snapshot comes
    /// back on the main queue; nil when there is nothing to read (no firmware, or a model switch).
    func inspect(includeProgram: Bool = true, _ done: @escaping (InspectorSnapshot?) -> Void) {
        guard let e = engine else { return done(nil) }
        e.send(.inspect(includeProgram, done))
    }

    /// Key a command the inspector offers (RCL, STO, GTO nnn…) exactly as the calculator would get it.
    func performKeys(_ keys: [Int]) {
        guard let e = engine, !keys.isEmpty else { return }
        apply(latch.unlatchAll())
        e.send(.perform { machine in _ = try? machine.perform(keys: keys) })
    }

    /// The 2 KB memory image and the running 15C variant, without blocking the main queue.
    func fetchMemory(_ done: @escaping (Data?, Int) -> Void) {
        guard let e = engine else { return done(nil, snapshot.variant) }
        e.send(.perform { machine in
            let data = try? machine.memory(turnBackOn: true)
            let variant = machine.variant
            DispatchQueue.main.async { done(data, variant) }
        })
    }

    /// DIM a matrix and write its values into the calculator's memory (the Matrix Editor's Apply).
    func writeMatrix(_ m: Int, rows: Int, cols: Int, raw: [UInt64], _ done: @escaping (String?) -> Void) {
        guard let e = engine else { return done("The calculator is not running.") }
        e.send(.perform { machine in
            var failure: String?
            do { try machine.writeMatrix15(m, rows: rows, cols: cols, raw: raw) }
            catch { failure = Self.message(error) }
            DispatchQueue.main.async { done(failure) }
        })
    }

    // MARK: key click

    private func clickSound() {
        guard UserDefaults.standard.bool(forKey: "keyClickSound") else { return }
        if players.isEmpty {
            let wav = KeyClickSound.wav()
            players = (0..<4).compactMap { _ in try? AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue) }
            for p in players { p.volume = 0.8; p.prepareToPlay() }
        }
        guard !players.isEmpty else { return }
        let p = players[nextPlayer % players.count]; nextPlayer += 1
        p.currentTime = 0
        p.play()
    }

    // MARK: text

    static func message(_ error: Error) -> String {
        if let l = error as? LocalizedError, let d = l.errorDescription { return d }
        return error.localizedDescription
    }

    /// Why a CE-only feature is not available with HP's original firmware.
    static let stockLimits = "HP's original 12C firmware runs the keyboard and display only. These need the CE firmware's memory layout and are not available with it: memory files, keeping the calculator's memory between launches and the model switch."
}
