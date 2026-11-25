// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyProgramNotes.swift - program documentation on iOS 12: a UIKit port of AppModel's notes
// (ProgramDocModel.swift) and of Views/ProgramInfoView.swift. The notes are the title, author,
// description, notes per label / register / flag and the comments per step. They follow the
// program when lines are inserted or deleted (ProgramDocument.rematch), are kept per firmware in
// UserDefaults, are found next to an opened memory file (".voyagerdoc") and are written to a
// ".voyagerdoc" file through the share sheet.
//
// The documentation PDF and the listing as text use Core's ProgramDocumentPDF and plainText(), so
// the iPad writes the same document the Mac app does.

import UIKit

final class LegacyProgramNotes {
    static let shared = LegacyProgramNotes()

    private(set) var doc = ProgramDocument()
    private(set) var memoryFileName: String?

    var onError: ((String) -> Void)?

    private var loadedFor = "\u{0}"
    private var lastProgramKeys: [String] = []
    private var pendingSidecar: ProgramDocument?
    private var candidateName: String?

    private var calculator: LegacyCalculator { .shared }

    private var defaultsKey: String {
        "programDoc." + (calculator.firmwareID.isEmpty ? "none" : String(calculator.firmwareID.prefix(16)))
    }

    // MARK: keeping them

    /// Pick up the notes of the firmware that is running now (called from the screen's refresh).
    func syncFirmware() {
        guard calculator.hasFirmware, loadedFor != calculator.firmwareID else { return }
        loadedFor = calculator.firmwareID
        lastProgramKeys = []
        doc = ProgramDocument()
        memoryFileName = calculator.memoryFileName
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? ProgramDocument.decode(data) {
            doc = stored
        }
    }

    func storeNow() {
        guard loadedFor != "\u{0}", let data = try? doc.encoded() else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: sidecar next to a memory file

    /// A memory file is about to be loaded: look for "<name>.voyagerdoc" next to it.
    func findSidecar(for url: URL) {
        candidateName = url.lastPathComponent
        pendingSidecar = nil
        for side in MemoryFileNames.sidecarCandidates(for: url) {
            let ok = side.startAccessingSecurityScopedResource()
            defer { if ok { side.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: side),
                  let found = try? ProgramDocument.decode(data) else { continue }
            pendingSidecar = found
            return
        }
    }

    /// The memory is in the calculator now: take its notes, if any were found.
    func memoryLoaded() {
        if let name = candidateName { memoryFileName = name }
        candidateName = nil
        lastProgramKeys = []
        if let sidecar = pendingSidecar {
            doc = sidecar
        } else if doc.isEmpty, let name = memoryFileName {
            doc.title = (name as NSString).deletingPathExtension
        }
        pendingSidecar = nil
        storeNow()
    }

    /// Notes the user opened in the document picker ("Open Program Notes…").
    func replace(with document: ProgramDocument) {
        doc = document
        lastProgramKeys = []
        storeNow()
    }

    /// A reset, a model switch or another firmware: nothing of the old program's notes is kept.
    func clearAll() {
        pendingSidecar = nil
        candidateName = nil
        memoryFileName = nil
        lastProgramKeys = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: the program changed

    /// A new listing arrived: the step comments follow their lines (ProgramDocument.rematch).
    func programChanged(_ s: InspectorSnapshot?) {
        guard let s = s, s.hasProgram, !s.program.isEmpty else { return }
        let keys = s.program.map(\.keys)
        guard keys != lastProgramKeys else { return }
        let first = lastProgramKeys.isEmpty
        lastProgramKeys = keys
        let stale = doc.comments.contains { c in s.program.first { $0.line == c.step }?.keys != c.keys }
        guard !doc.comments.isEmpty, !first || stale else { return }
        var d = doc
        d.rematch(to: s.program)
        guard d.comments != doc.comments else { return }
        doc = d
        storeNow()
    }

    // MARK: reading, for the panels

    func comment(at step: Int) -> String? { doc.comment(at: step) }
    var stepCommentCount: Int { doc.comments.filter { !$0.orphaned }.count }
    var orphanedComments: [StepComment] { doc.orphanedComments }
    var title: String { doc.title }
    var author: String { doc.author }
    var description: String { doc.description }
    var modelName: String { doc.model }
    func labelNote(_ label: String) -> String { doc.labels[label] ?? "" }
    func registerNote(_ register: String) -> RegisterNote { doc.registers[register] ?? RegisterNote() }
    func flagNote(_ flag: String) -> String { doc.flags[flag] ?? "" }

    // MARK: editing, from the Program Info sheet

    func setTitle(_ text: String) { doc.title = text; storeNow() }
    func setAuthor(_ text: String) { doc.author = text; storeNow() }
    func setDescription(_ text: String) { doc.description = text; storeNow() }
    func setLabelNote(_ text: String, for label: String) { doc.labels[label] = text; storeNow() }

    func setRegisterNote(name: String, meaning: String, for register: String) {
        doc.registers[register] = RegisterNote(name: name, meaning: meaning)
        storeNow()
    }

    func setFlagNote(_ text: String, for flag: String) { doc.flags[flag] = text; storeNow() }

    func setComment(_ text: String, at step: Int, lines: [ProgramLine]) {
        doc.setComment(text, at: step, lines: lines)
        storeNow()
    }

    func removeOrphans() {
        doc.comments.removeAll(where: \.orphaned)
        storeNow()
    }

    /// Open the notes of the program: place the comments on the listing as it is now and add an
    /// entry for every label, register and flag it uses (as File ▸ Program Info… does on the Mac).
    func prepareInfo(_ s: InspectorSnapshot) {
        let lines = s.hasProgram ? s.program : []
        doc.rematch(to: lines)
        doc.prefill(from: ProgramAnalysis(lines: lines, model: s.model))
        doc.model = ProgramDocumentInfo.modelName(variant: s.variant, model: s.model)
        if memoryFileName == nil { memoryFileName = calculator.memoryFileName }
        if doc.title.isEmpty, let name = memoryFileName {
            doc.title = (name as NSString).deletingPathExtension
        }
        storeNow()
    }

    /// Everything the PDF and the text export show.
    func content(_ s: InspectorSnapshot) -> ProgramDocumentContent {
        var d = doc
        let modelName = ProgramDocumentInfo.modelName(variant: s.variant, model: s.model)
        d.model = modelName
        let info = ProgramDocumentInfo(modelName: modelName,
                                       firmware: calculator.firmwareName ?? "",
                                       memoryFile: memoryFileName ?? calculator.memoryFileName ?? "",
                                       model: s.model)
        return ProgramDocumentContent(doc: d, info: info, lines: s.hasProgram ? s.program : [],
                                      pool: s.pool, setFlags: s.setFlags)
    }

    // MARK: files

    var baseName: String {
        if let name = memoryFileName ?? calculator.memoryFileName { return (name as NSString).deletingPathExtension }
        return doc.title.isEmpty ? "Program" : doc.title
    }

    func notesData() throws -> Data { try doc.encoded() }

    /// A4: this build has no paper picker (the Mac app's choice is a different app's setting).
    func pdfData(_ s: InspectorSnapshot) -> Data {
        ProgramDocumentPDF.render(content(s), paper: .a4, fonts: DocFontStore().load().pdfSet())
    }

    func textData(_ s: InspectorSnapshot) -> Data { Data(content(s).plainText().utf8) }
}

// MARK: - sharing files

enum LegacyDocumentExport {
    /// Write `data` to a temporary file and offer it in the share sheet (Save to Files, Mail, …).
    static func share(_ data: Data, name: String, from controller: UIViewController, source: UIView) {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(clean)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = UIAlertController(title: "VoyagerCalc",
                                          message: "Could not write \(clean): \(error.localizedDescription)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(alert, animated: true)
            return
        }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source
        share.popoverPresentationController?.sourceRect = source.bounds
        controller.present(share, animated: true)
    }
}

// MARK: - Program Info

/// A text field that knows where its text goes.
final class LegacyNoteField: UITextField {
    var apply: ((String) -> Void)?
}

final class LegacyProgramInfoViewController: UIViewController, UITextViewDelegate {
    private let notes = LegacyProgramNotes.shared
    private let calculator = LegacyCalculator.shared
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let snapshot: InspectorSnapshot

    init(snapshot: InspectorSnapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
        notes.prepareInfo(snapshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Program Info"
        view.backgroundColor = LegacyPanelColors.panel
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(dismissSelf))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        let guide = view.safeAreaLayoutGuide
        let content = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -28),
        ])
        buildForm()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // MARK: the form

    private func buildForm() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let model = snapshot.model
        let lines = snapshot.hasProgram ? snapshot.program : []
        let analysis = ProgramAnalysis(lines: lines, model: model)

        stack.addArrangedSubview(sectionTitle("Program"))
        stack.addArrangedSubview(field("Title", notes.title) { [weak self] in self?.notes.setTitle($0) })
        stack.addArrangedSubview(field("Author", notes.author) { [weak self] in self?.notes.setAuthor($0) })
        stack.addArrangedSubview(infoLine("Model", notes.modelName.isEmpty ? notes.content(snapshot).info.modelName : notes.modelName))
        stack.addArrangedSubview(infoLine("Steps", "\(lines.count)"))

        stack.addArrangedSubview(sectionTitle("Description"))
        let text = UITextView()
        text.text = notes.description
        text.font = UIFont.systemFont(ofSize: 15)
        text.textColor = LegacyPanelColors.ink
        text.backgroundColor = LegacyPanelColors.header
        text.layer.cornerRadius = 6
        text.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        text.delegate = self
        text.heightAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(caption("What the program does and how to use it. A line starting with ## is a section heading (for example ## Usage); a line starting with - is a bullet."))

        if !analysis.labels.isEmpty {
            stack.addArrangedSubview(sectionTitle(model == 12 ? "Branch targets" : "Labels"))
            for label in analysis.labels {
                let heading = label.isIndirect ? label.name
                    : (model == 12 ? "line \(label.name)" : "LBL \(label.name)")
                stack.addArrangedSubview(infoLine(heading, whereText(label)))
                stack.addArrangedSubview(field("Notes", notes.labelNote(label.name)) { [weak self] value in
                    self?.notes.setLabelNote(value, for: label.name)
                })
            }
        }

        if !analysis.registers.isEmpty {
            stack.addArrangedSubview(sectionTitle("Registers"))
            for register in analysis.registers {
                let use = register.operations.joined(separator: ", ") + " — " + steps(register.steps)
                stack.addArrangedSubview(infoLine(register.name, use))
                let note = notes.registerNote(register.name)
                stack.addArrangedSubview(field("Name", note.name) { [weak self] value in
                    let current = self?.notes.registerNote(register.name) ?? RegisterNote()
                    self?.notes.setRegisterNote(name: value, meaning: current.meaning, for: register.name)
                })
                stack.addArrangedSubview(field("Meaning", note.meaning) { [weak self] value in
                    let current = self?.notes.registerNote(register.name) ?? RegisterNote()
                    self?.notes.setRegisterNote(name: current.name, meaning: value, for: register.name)
                })
            }
        }

        if !analysis.flags.isEmpty {
            stack.addArrangedSubview(sectionTitle("Flags"))
            for flag in analysis.flags {
                stack.addArrangedSubview(infoLine("Flag \(flag.name)", flag.operations.joined(separator: ", ")))
                stack.addArrangedSubview(field("Meaning", notes.flagNote(flag.name)) { [weak self] value in
                    self?.notes.setFlagNote(value, for: flag.name)
                })
            }
        }

        stack.addArrangedSubview(sectionTitle("Comments per step"))
        stack.addArrangedSubview(caption("\(notes.stepCommentCount) step comment(s). Tap a line in Registers & Program to add or edit one."))
        let orphans = notes.orphanedComments
        if !orphans.isEmpty {
            stack.addArrangedSubview(caption("\(orphans.count) comment(s) no longer match a step of the program:"))
            for comment in orphans {
                stack.addArrangedSubview(caption("was step \(String(format: model == 12 ? "%02d" : "%03d", comment.step)) (\(comment.keys)): \(comment.text)"))
            }
            let remove = UIButton(type: .system)
            remove.setTitle("Remove Comments That No Longer Match", for: .normal)
            remove.setTitleColor(LegacyPanelColors.bad, for: .normal)
            remove.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            remove.addTarget(self, action: #selector(removeOrphans), for: .touchUpInside)
            stack.addArrangedSubview(remove)
        }

        stack.addArrangedSubview(sectionSeparator())
        for button in [actionButton("Save Program Notes…", #selector(saveNotes)),
                       actionButton("Export Program Documentation (PDF)…", #selector(exportPDF)),
                       actionButton("Export Listing as Text…", #selector(exportText))] {
            stack.addArrangedSubview(button)
        }
    }

    private func whereText(_ label: ProgramAnalysis.Label) -> String {
        let defined = label.defined.isEmpty
            ? (label.isIndirect ? "computed in I" : "not defined")
            : "at " + steps(label.defined)
        let called = label.called.isEmpty ? "not called" : "called from " + steps(label.called)
        return defined + " · " + called
    }

    private func steps(_ s: [Int]) -> String {
        let format = snapshot.model == 12 ? "%02d" : "%03d"
        let shown = s.prefix(8).map { String(format: format, $0) }.joined(separator: ", ")
        return s.count > 8 ? shown + " …" : shown
    }

    // MARK: pieces

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = LegacyPanelColors.dim
        return label
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = LegacyPanelColors.dim
        label.numberOfLines = 0
        return label
    }

    private func sectionSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.12)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func infoLine(_ name: String, _ value: String) -> UIView {
        let left = UILabel()
        left.text = name
        left.font = LegacyFont.mono(13, bold: true)
        left.textColor = LegacyPanelColors.ink
        left.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        left.setContentCompressionResistancePriority(.required, for: .horizontal)
        let right = UILabel()
        right.text = value
        right.font = UIFont.systemFont(ofSize: 12)
        right.textColor = LegacyPanelColors.dim
        right.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [left, right])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    private func field(_ label: String, _ text: String, apply: @escaping (String) -> Void) -> UIView {
        let name = UILabel()
        name.text = label
        name.font = UIFont.systemFont(ofSize: 12)
        name.textColor = LegacyPanelColors.dim
        name.widthAnchor.constraint(equalToConstant: 74).isActive = true

        let input = LegacyNoteField()
        input.text = text
        input.placeholder = label
        input.font = UIFont.systemFont(ofSize: 15)
        input.textColor = LegacyPanelColors.ink
        input.tintColor = LegacyPanelColors.gold
        input.borderStyle = .roundedRect
        input.backgroundColor = LegacyPanelColors.header
        input.autocapitalizationType = .sentences
        input.autocorrectionType = .no
        input.apply = apply
        input.addTarget(self, action: #selector(fieldChanged(_:)), for: .editingChanged)

        let row = UIStackView(arrangedSubviews: [name, input])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func actionButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(LegacyPanelColors.gold, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        button.contentHorizontalAlignment = .left
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func fieldChanged(_ sender: LegacyNoteField) {
        sender.apply?(sender.text ?? "")
    }

    func textViewDidChange(_ textView: UITextView) {
        notes.setDescription(textView.text)
    }

    // MARK: actions

    @objc private func removeOrphans() {
        notes.removeOrphans()
        buildForm()
    }

    @objc private func saveNotes() {
        do {
            let data = try notes.notesData()
            LegacyDocumentExport.share(data, name: notes.baseName + "." + ProgramDocument.fileExtension,
                                       from: self, source: view)
        } catch {
            notes.onError?("The notes could not be written: \(error.localizedDescription)")
        }
    }

    @objc private func exportPDF() {
        let notes = self.notes
        let snapshot = self.snapshot
        let name = notes.content(snapshot).title + " documentation.pdf"
        DispatchQueue.global(qos: .userInitiated).async {
            let data = notes.pdfData(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                LegacyDocumentExport.share(data, name: name, from: self, source: self.view)
            }
        }
    }

    @objc private func exportText() {
        let name = notes.content(snapshot).title + " listing.txt"
        LegacyDocumentExport.share(notes.textData(snapshot), name: name, from: self, source: view)
    }
}
