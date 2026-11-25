// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// CalculatorViewController.swift - the iOS 12 screen: the drawn calculator filling the window, a menu
// button, the firmware picker (UIDocumentPicker, iOS 11+), memory files through the share sheet, and
// the iPad hardware keyboard. It replaces the SwiftUI MainViews menu and the Files importer.
//
// The menu also opens the Registers & Program inspector, the 15C matrix editor and the program
// notes (Program Info, the documentation PDF and the listing as text). See docs/IOS12-PORT.md.

import UIKit

final class CalculatorViewController: UIViewController, UIDocumentPickerDelegate {
    private enum PickerPurpose { case firmware, memory, notes }

    private let calculator = LegacyCalculator.shared
    private let face = CalculatorFaceView(frame: .zero)
    private let menuButton = UIButton(type: .system)
    private let emptyView = UIView(frame: .zero)
    private let emptyTitle = UILabel(frame: .zero)
    private let emptyText = UILabel(frame: .zero)
    private let chooseButton = UIButton(type: .system)
    private let footer = UILabel(frame: .zero)
    private var pickerPurpose: PickerPurpose = .firmware

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(rgb: 0x241E1A)

        face.onPress = { [weak self] code, part in self?.calculator.press(code, part: part) }
        face.onRelease = { [weak self] code in self?.calculator.release(code) }
        face.onLatch = { [weak self] code in self?.calculator.holdBecameLatch(code) }
        view.addSubview(face)

        menuButton.setTitle("⋯", for: .normal)
        menuButton.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .semibold)
        menuButton.setTitleColor(.white, for: .normal)
        menuButton.backgroundColor = UIColor(white: 0, alpha: 0.28)
        menuButton.layer.cornerRadius = 22
        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        view.addSubview(menuButton)

        footer.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        footer.textColor = UIColor(rgb: 0xE3A63A, alpha: 0.75)
        footer.textAlignment = .left
        view.addSubview(footer)

        buildEmptyState()
        view.addSubview(emptyView)

        calculator.onChange = { [weak self] in self?.refresh() }
        calculator.onMessage = { [weak self] text in self?.alert("VoyagerCalc", text) }
        calculator.onError = { [weak self] text in self?.alert("VoyagerCalc", text) }
        calculator.onMemoryLoaded = { [weak self] _ in
            LegacyProgramNotes.shared.memoryLoaded()
            self?.refresh()
        }
        LegacyProgramNotes.shared.onError = { [weak self] text in self?.alert("VoyagerCalc", text) }

        calculator.launch()
        refresh()
    }

    private func buildEmptyState() {
        emptyView.backgroundColor = UIColor(rgb: 0x241E1A)
        emptyTitle.text = "VoyagerCalc"
        emptyTitle.font = UIFont.systemFont(ofSize: 34, weight: .bold)
        emptyTitle.textColor = .white
        emptyTitle.textAlignment = .center
        emptyView.addSubview(emptyTitle)

        emptyText.text = "This app runs your own HP-12C / 15C / 16C Collector's Edition firmware on an emulated calculator chip. It contains no firmware and no HP artwork.\n\nChoose your firmware file (.bin) to start. The app remembers it."
        emptyText.font = UIFont.systemFont(ofSize: 15)
        emptyText.textColor = UIColor(white: 0.8, alpha: 1)
        emptyText.numberOfLines = 0
        emptyText.textAlignment = .center
        emptyView.addSubview(emptyText)

        chooseButton.setTitle("Choose Firmware File…", for: .normal)
        chooseButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        chooseButton.setTitleColor(.black, for: .normal)
        chooseButton.backgroundColor = UIColor(rgb: 0xE3A63A)
        chooseButton.layer.cornerRadius = 10
        chooseButton.addTarget(self, action: #selector(chooseFirmware), for: .touchUpInside)
        emptyView.addSubview(chooseButton)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        face.frame = view.bounds
        let safe = view.safeAreaInsets
        menuButton.frame = CGRect(x: size.width - safe.right - 56, y: safe.top + 8, width: 44, height: 44)
        footer.frame = CGRect(x: safe.left + 16, y: size.height - safe.bottom - 22,
                              width: size.width - safe.left - safe.right - 90, height: 16)
        emptyView.frame = view.bounds
        let contentWidth = min(560, size.width - 80)
        let left = (size.width - contentWidth) / 2
        emptyTitle.frame = CGRect(x: left, y: size.height * 0.30, width: contentWidth, height: 44)
        emptyText.frame = CGRect(x: left, y: emptyTitle.frame.maxY + 12, width: contentWidth, height: 150)
        chooseButton.frame = CGRect(x: left + contentWidth / 2 - 130, y: emptyText.frame.maxY + 20, width: 260, height: 50)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: display

    private func refresh() {
        LegacyProgramNotes.shared.syncFirmware()
        let model = calculator.model
        if face.model.id != model.id { face.model = model }
        face.pressed = calculator.pressedKeys
        face.latched = calculator.latchedKeys
        face.lcdView.lcd = calculator.snapshot.lcd

        let ready = calculator.hasFirmware
        face.isHidden = !ready
        menuButton.isHidden = !ready
        footer.isHidden = !ready
        emptyView.isHidden = ready

        if let name = calculator.firmwareName {
            var parts = [name]
            if calculator.canSwitchModel {
                parts.append("Running as the " + CalculatorMachine.variantName(calculator.snapshot.variant))
            }
            if let checksum = calculator.firmwareChecksum { parts.append("Checksum " + checksum) }
            footer.text = parts.joined(separator: "  ·  ")
        } else {
            footer.text = nil
        }
    }

    // MARK: menu

    @objc private func showMenu() {
        let title = calculator.firmwareName ?? "VoyagerCalc"
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Choose Firmware…", style: .default) { [weak self] _ in
            self?.chooseFirmware()
        })
        if calculator.hasFirmware {
            sheet.addAction(UIAlertAction(title: "ON / OFF", style: .default) { [weak self] _ in
                self?.calculator.togglePower()
            })
            sheet.addAction(UIAlertAction(title: "Service Menu (g-ENTER-ON)", style: .default) { [weak self] _ in
                self?.calculator.perform(.serviceMenu)
            })
            sheet.addAction(UIAlertAction(title: "Self-Test (ON + ×)", style: .default) { [weak self] _ in
                self?.calculator.perform(.selfTest)
            })
            if calculator.canSwitchModel {
                for variant in calculator.images {
                    sheet.addAction(UIAlertAction(title: "Run as the " + CalculatorMachine.variantName(variant),
                                                  style: .default) { [weak self] _ in
                        self?.calculator.switchModel(to: variant)
                        LegacyProgramNotes.shared.clearAll()
                    })
                }
            }
            if calculator.canKeepMemory {
                sheet.addAction(UIAlertAction(title: "Save Memory File…", style: .default) { [weak self] _ in
                    self?.saveMemory()
                })
                sheet.addAction(UIAlertAction(title: "Open Memory File…", style: .default) { [weak self] _ in
                    self?.presentPicker(.memory)
                })
            }
            if calculator.capabilities.contains(.inspect) {
                sheet.addAction(UIAlertAction(title: "Registers & Program", style: .default) { [weak self] _ in
                    self?.showInspector()
                })
                if calculator.model.id == 15 && calculator.canKeepMemory {
                    sheet.addAction(UIAlertAction(title: "Matrix Editor…", style: .default) { [weak self] _ in
                        self?.showMatrixEditor()
                    })
                }
                sheet.addAction(UIAlertAction(title: "Program Info…", style: .default) { [weak self] _ in
                    self?.showProgramInfo()
                })
                sheet.addAction(UIAlertAction(title: "Open Program Notes…", style: .default) { [weak self] _ in
                    self?.presentPicker(.notes)
                })
                sheet.addAction(UIAlertAction(title: "Save Program Notes…", style: .default) { [weak self] _ in
                    self?.saveNotes()
                })
                sheet.addAction(UIAlertAction(title: "Export Program Documentation (PDF)…", style: .default) { [weak self] _ in
                    self?.exportDocumentation(pdf: true)
                })
                sheet.addAction(UIAlertAction(title: "Export Listing as Text…", style: .default) { [weak self] _ in
                    self?.exportDocumentation(pdf: false)
                })
            } else {
                sheet.addAction(UIAlertAction(title: "Registers & Program (needs the CE firmware)", style: .default) { [weak self] _ in
                    self?.alert("Registers & Program", LegacyCalculator.stockLimits)
                })
            }
            sheet.addAction(UIAlertAction(title: "Release Latched Keys", style: .default) { [weak self] _ in
                self?.calculator.releaseLatchedKeys()
            })
            sheet.addAction(UIAlertAction(title: "Reset Calculator", style: .destructive) { [weak self] _ in
                self?.calculator.resetCalculator()
                LegacyProgramNotes.shared.clearAll()
            })
        }
        sheet.addAction(UIAlertAction(title: "About", style: .default) { [weak self] _ in self?.showAbout() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = menuButton
        sheet.popoverPresentationController?.sourceRect = menuButton.bounds
        present(sheet, animated: true)
    }

    private func showAbout() {
        let text = """
        VoyagerCalc runs your own HP-12C / 15C / 16C Collector's Edition firmware on a native emulator of \
        the calculator's ARM chip. No firmware and no HP artwork are included.

        Keys: tap a key; tap its gold legend above for f + key, its blue legend on the front for g + key.
        Hold a key for a moment to latch it down (a chord), then press Release Latched Keys.

        This is the iOS 12 build: the calculator, memory files, the model switch, Registers & Program, \
        the 15C Matrix Editor and the program documentation (notes, PDF and text) are all here. The \
        iPad writes the same documents as the Mac app.

        Not affiliated with HP Inc. MIT licence.
        """
        alert("About VoyagerCalc", text)
    }

    // MARK: files

    @objc private func chooseFirmware() { presentPicker(.firmware) }

    private func presentPicker(_ purpose: PickerPurpose) {
        pickerPurpose = purpose
        let types = purpose == .notes ? ["public.json", "public.data"] : ["public.data"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickerPurpose {
        case .firmware: calculator.firmwarePicked(url)
        case .memory:
            LegacyProgramNotes.shared.findSidecar(for: url)
            calculator.loadMemory(url)
        case .notes: notesPicked(url)
        }
    }

    private func saveMemory() {
        guard let data = calculator.memoryImage() else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(calculator.suggestedMemoryFileName())
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            alert("VoyagerCalc", "Could not write the memory file: \(error.localizedDescription)")
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = menuButton
        share.popoverPresentationController?.sourceRect = menuButton.bounds
        present(share, animated: true)
    }

    // MARK: alerts

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        if let top = presentedViewController {
            top.dismiss(animated: false) { [weak self] in self?.present(a, animated: true) }
        } else {
            present(a, animated: true)
        }
    }

    // MARK: hardware keyboard (iPad)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var out: [UIKeyCommand] = []
        var seen = Set<String>()
        func add(_ input: String, _ flags: UIKeyModifierFlags) {
            let id = input + "|" + String(flags.rawValue)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            out.append(UIKeyCommand(input: input, modifierFlags: flags, action: #selector(keyPressed(_:))))
        }
        for k in calculator.model.keys {
            for s in k.shortcuts {
                if case .char(let c) = s {
                    add(String(c).lowercased(), [])
                    let upper = String(c).uppercased()
                    if upper != String(c).lowercased() { add(upper, .shift) }
                }
            }
        }
        add("\r", [])                                   // ENTER
        add("\u{8}", [])                                // Delete = back-arrow / CLx
        add(UIKeyCommand.inputEscape, [])               // ON
        return out
    }

    @objc private func keyPressed(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        if input == "\r" { tap(CalculatorMachine.keyENTER); return }
        if input == "\u{8}" { tap(CalculatorMachine.keyBSP); return }
        if input == UIKeyCommand.inputEscape { calculator.togglePower(); return }
        guard let c = input.lowercased().first, let k = calculator.model.key(for: .char(c)) else { return }
        var part: KeyPart = .face
        if sender.modifierFlags.contains(.alternate), !k.g.isEmpty { part = .gLabel }
        if sender.modifierFlags.contains(.shift), !k.f.isEmpty { part = .fLabel }
        calculator.press(k.code, part: part)
        calculator.release(k.code)
    }

    private func tap(_ code: Int) {
        calculator.press(code)
        calculator.release(code)
    }

    // MARK: Registers & Program, the matrix editor, the program notes (phases 4–5)

    private func presentSheet(_ controller: UIViewController, width: CGFloat = 640, height: CGFloat = 700) {
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: width, height: height)
        nav.navigationBar.barStyle = .black
        nav.navigationBar.barTintColor = LegacyPanelColors.header
        nav.navigationBar.tintColor = LegacyPanelColors.gold
        nav.navigationBar.titleTextAttributes = [.foregroundColor: LegacyPanelColors.ink]
        present(nav, animated: true)
    }

    private func showInspector() {
        presentSheet(LegacyInspectorViewController(), width: 640, height: 720)
    }

    private func showMatrixEditor() {
        presentSheet(LegacyMatrixEditorViewController(), width: 720, height: 760)
    }

    private func showProgramInfo() {
        calculator.inspect(includeProgram: true) { [weak self] s in
            guard let self = self else { return }
            guard let s = s else {
                self.alert("Program Info", "The program could not be read from the calculator.")
                return
            }
            self.presentSheet(LegacyProgramInfoViewController(snapshot: s), width: 680, height: 780)
        }
    }

    private func saveNotes() {
        do {
            let data = try LegacyProgramNotes.shared.notesData()
            let name = LegacyProgramNotes.shared.baseName + "." + ProgramDocument.fileExtension
            LegacyDocumentExport.share(data, name: name, from: self, source: menuButton)
        } catch {
            alert("VoyagerCalc", "The notes could not be written: \(error.localizedDescription)")
        }
    }

    private func exportDocumentation(pdf: Bool) {
        calculator.inspect(includeProgram: true) { [weak self] s in
            guard let self = self else { return }
            guard let s = s else {
                self.alert("VoyagerCalc", "The program could not be read from the calculator.")
                return
            }
            let notes = LegacyProgramNotes.shared
            let name = notes.content(s).title + (pdf ? " documentation.pdf" : " listing.txt")
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pdf ? notes.pdfData(s) : notes.textData(s)
                DispatchQueue.main.async {
                    LegacyDocumentExport.share(data, name: name, from: self, source: self.menuButton)
                }
            }
        }
    }

    private func notesPicked(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            var document = try ProgramDocument.decode(try Data(contentsOf: url))
            calculator.inspect(includeProgram: true) { [weak self] s in
                guard let self = self else { return }
                if let s = s, s.hasProgram, !s.program.isEmpty {
                    let report = document.rematch(to: s.program)
                    if report.orphaned > 0 {
                        self.alert("Program Notes", "\(report.orphaned) comment(s) in “\(url.lastPathComponent)” no longer match a step of the program in the calculator. They are kept and listed in Program Info.")
                    }
                }
                LegacyProgramNotes.shared.replace(with: document)
            }
        } catch {
            alert("Program Notes", "“\(url.lastPathComponent)” is not a VoyagerCalc program notes file.")
        }
    }
}
