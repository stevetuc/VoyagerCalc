// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyEngine.swift - the iOS 12 build of the engine runner. Same loop as CalculatorEngine, but
// with no Swift concurrency: async/await, Task and @MainActor need iOS 13, so this uses a Thread,
// a lock, a semaphore, and sends its callbacks to the main queue.

import Foundation

/// What the face needs to draw (the iOS 12 build has no inspector, so this is the whole snapshot).
struct FaceSnapshot {
    var lcd: LCDState = .blank
    var model: Int = 16
    var variant: Int = 160
    var simMs: Int = 0
    init() {}
}

final class LegacyEngine {
    enum Command {
        case press(Int)
        /// A gold / blue legend click: shift (unless pending), then the key held down.
        case pressShifted(shift: Int, code: Int)
        case release(Int)
        case releaseAll
        /// Release keys `afterMs` of calculator time from now (the end of a latched chord).
        case releaseLater([Int], afterMs: Int)
        case switchModel(Int, (Result<Int, Error>) -> Void)
        case chord(KeyChord)
        case chordWithON([Int])
        case loadMemory(Data, (Error?) -> Void)
        case saveState((Result<SavedState, Error>) -> Void)
        /// Run a closure on the engine thread with the machine (for blocking saves etc.).
        case perform((CalculatorMachine) -> Void)
        case stop
    }

    /// Called on the main queue whenever the display or the active model changes.
    var onSnapshot: ((FaceSnapshot) -> Void)?
    /// Called on the main queue if the emulated chip stops with an error.
    var onFault: ((String) -> Void)?

    private let machine: CalculatorMachine
    private let lock = NSLock()
    private var queue: [Command] = []
    private var thread: Thread?
    private var running = false
    private var last = FaceSnapshot()
    private let wake = DispatchSemaphore(value: 0)

    /// Takes a machine that already has firmware and has booted.
    init(machine: CalculatorMachine) {
        self.machine = machine
    }

    func start() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "VoyagerCalc engine (iOS 12)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func send(_ c: Command) {
        lock.lock(); queue.append(c); lock.unlock()
        wake.signal()
    }

    func stop() { send(.stop) }

    /// Run `body` on the engine thread and wait for it (at most `timeout` seconds).
    /// Do not call it from the engine thread. Returns nil on timeout or if not running.
    func performAndWait<T>(timeout: Double = 3, _ body: @escaping (CalculatorMachine) -> T) -> T? {
        guard thread != nil, running else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: T?
        send(.perform { m in result = body(m); done.signal() })
        return done.wait(timeout: .now() + timeout) == .success ? result : nil
    }

    private func takeCommands() -> [Command] {
        lock.lock(); defer { lock.unlock() }
        let q = queue; queue = []; return q
    }

    /// Run on the main queue.
    private func onMain(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    private func apply(_ c: Command) -> Bool {
        do {
            switch c {
            case .press(let k): machine.press(k)
            case .pressShifted(let sh, let k): try machine.pressShifted(sh, k)
            case .release(let k): machine.release(k)
            case .releaseAll: machine.releaseAll()
            case .releaseLater(let ks, let ms): machine.release(ks, afterMs: ms)
            case .switchModel(let v, let done):
                let r = Result { try machine.switchModel(to: v); return machine.variant }
                publish()                                   // the face follows the new model now
                onMain { done(r) }
            case .chord(let c): try machine.perform(c); publish()
            case .chordWithON(let keys): try machine.chordWithON(keys)
            case .loadMemory(let d, let done):
                do { try machine.putMemory(d); onMain { done(nil) } }
                catch { onMain { done(error) } }
            case .saveState(let done):
                let r = Result { try machine.savedState() }
                onMain { done(r) }
            case .perform(let body): body(machine)
            case .stop: return false
            }
        } catch {
            report(error)
        }
        return true
    }

    private func report(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        onMain { [weak self] in self?.onFault?(msg) }
    }

    private func publish() {
        var s = FaceSnapshot()
        s.lcd = machine.calc.lcd()
        s.model = machine.model
        s.variant = machine.variant
        s.simMs = machine.simMs
        if s.lcd != last.lcd || s.model != last.model || s.variant != last.variant {
            last = s
            onMain { [weak self] in self?.onSnapshot?(s) }
        }
    }

    private func loop() {
        let tick: UInt64 = 10_000_000                      // 10 ms in ns
        var next = DispatchTime.now().uptimeNanoseconds
        var failed = false
        publish()
        while running {
            for c in takeCommands() where !apply(c) { running = false }
            if !running { break }
            if failed { _ = wake.wait(timeout: .now() + .milliseconds(200)); continue }
            do {
                let now = DispatchTime.now().uptimeNanoseconds
                if now < next {
                    // wait for the next 10 ms slot; a command wakes us early to apply it
                    _ = wake.wait(timeout: DispatchTime(uptimeNanoseconds: next))
                    continue
                }
                if now - next > 250_000_000 { next = now }   // fell behind (e.g. iPad asleep): no catch-up race
                try machine.run(ms: 10)
                next += tick
            } catch {
                failed = true
                report(error)
            }
            publish()
        }
        machine.releaseAll()
    }
}
