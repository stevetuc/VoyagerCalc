// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyInspector.swift - the iOS 12 Registers & Program inspector, a UIKit port of
// Views/InspectorView.swift. The header shows the model, its modes, the flags and the program
// line; the table below holds the stack, the 15C memory pool and matrices, the storage registers
// and the program listing. It is read-only: a snapshot comes from the engine thread
// (Inspector.inspect) twice a second while the panel is on screen and changes nothing.
//
// Taps work like the Mac's context menus: a register opens RCL / STO / STO+ / x-swap as keyed
// commands, a program line opens GTO nnn and its step comment (part of the program notes).

import UIKit

enum LegacyInspectorPane: Int {
    case both, registers, program
}

/// Menlo for the numbers and the listing (the iOS 12 build cannot use monospacedSystemFont).
enum LegacyFont {
    static func mono(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Menlo-Bold" : "Menlo", size: size)
            ?? UIFont(name: "Courier", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
    static func monoItalic(_ size: CGFloat) -> UIFont {
        UIFont(name: "Menlo-Italic", size: size) ?? mono(size)
    }
}

/// The panel colours: the calculator's own dark brown, so the sheet does not glare next to it.
enum LegacyPanelColors {
    static let panel = UIColor(rgb: 0x241E1A)
    static let header = UIColor(rgb: 0x2E2723)
    static let ink = UIColor(rgb: 0xEDE6DE)
    static let dim = UIColor(rgb: 0xA79C92)
    static let gold = UIColor(rgb: 0xE3A63A)
    static let blue = UIColor(rgb: 0x5DA9E8)
    static let running = UIColor(rgb: 0x4CBF6B)
    static let band = UIColor(rgb: 0x33513B)
    static let bandRunning = UIColor(rgb: 0x3F6B4A)
    static let bad = UIColor(rgb: 0xE07A5F)
}

// MARK: - table pieces

private struct InspectorRow {
    var name = ""
    var value = NSAttributedString()
    var current = false
    /// The program step a tap opens (nil for anything else).
    var programLine: Int?
    /// The register a tap opens.
    var register: String?
    /// What "Copy" puts on the clipboard, if anything.
    var copy = ""
}

private struct InspectorSection {
    var title = ""
    var rows: [InspectorRow] = []
}

private final class InspectorCell: UITableViewCell {
    static let id = "legacyInspectorRow"
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = UIColor(white: 1, alpha: 0.08)
        selectedBackgroundView = selected

        nameLabel.font = LegacyFont.mono(11)
        nameLabel.textColor = LegacyPanelColors.dim
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = LegacyFont.mono(12)
        valueLabel.textColor = LegacyPanelColors.ink
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.55
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)
        contentView.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 58),
            valueLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func show(_ row: InspectorRow, running: Bool) {
        nameLabel.text = row.name
        valueLabel.attributedText = row.value
        contentView.backgroundColor = row.current
            ? (running ? LegacyPanelColors.bandRunning : LegacyPanelColors.band)
            : .clear
    }
}

private final class InspectorHeader: UITableViewHeaderFooterView {
    static let id = "legacyInspectorHeader"
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentView.backgroundColor = LegacyPanelColors.header
        label.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = LegacyPanelColors.dim
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func show(_ title: String) { label.text = title.uppercased() }
}

// MARK: - the panel

final class LegacyInspectorViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let calculator = LegacyCalculator.shared
    private let notes = LegacyProgramNotes.shared

    private let table = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let paneControl = UISegmentedControl(items: ["Both", "Registers", "Program"])
    private let zeroStack = UIStackView()

    private var snapshot: InspectorSnapshot?
    private var sections: [InspectorSection] = []
    private var timer: Timer?
    private var lastLine = -1
    private var running = false

    /// Remembered between launches, like the Mac's inspectorPane / inspectorHideZeros.
    private var pane: LegacyInspectorPane {
        get { LegacyInspectorPane(rawValue: UserDefaults.standard.integer(forKey: "inspectorPane")) ?? .both }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "inspectorPane") }
    }
    private var hideZeros: Bool {
        get { UserDefaults.standard.bool(forKey: "inspectorHideZeros") }
        set { UserDefaults.standard.set(newValue, forKey: "inspectorHideZeros") }
    }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Registers & Program"
        view.backgroundColor = LegacyPanelColors.panel
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(dismissSelf))

        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = LegacyPanelColors.ink
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        detailLabel.font = LegacyFont.mono(11)
        detailLabel.textColor = LegacyPanelColors.dim
        detailLabel.numberOfLines = 2
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.7

        paneControl.selectedSegmentIndex = pane.rawValue
        paneControl.tintColor = LegacyPanelColors.gold
        paneControl.addTarget(self, action: #selector(paneChanged), for: .valueChanged)

        let zeroLabel = UILabel()
        zeroLabel.text = "Non-zero"
        zeroLabel.font = UIFont.systemFont(ofSize: 11)
        zeroLabel.textColor = LegacyPanelColors.dim
        let zeroSwitch = UISwitch()
        zeroSwitch.isOn = hideZeros
        zeroSwitch.onTintColor = LegacyPanelColors.gold
        zeroSwitch.addTarget(self, action: #selector(zerosChanged(_:)), for: .valueChanged)
        zeroStack.addArrangedSubview(zeroLabel)
        zeroStack.addArrangedSubview(zeroSwitch)
        zeroStack.axis = .horizontal
        zeroStack.spacing = 6
        zeroStack.alignment = .center

        let controls = UIStackView(arrangedSubviews: [paneControl, zeroStack])
        controls.axis = .horizontal
        controls.spacing = 12
        controls.alignment = .center
        controls.distribution = .fill

        let header = UIStackView(arrangedSubviews: [titleLabel, detailLabel, controls])
        header.axis = .vertical
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = LegacyPanelColors.panel
        table.separatorStyle = .none
        table.rowHeight = 22
        table.sectionHeaderHeight = 24
        table.indicatorStyle = .white
        table.tableFooterView = UIView(frame: .zero)
        table.register(InspectorCell.self, forCellReuseIdentifier: InspectorCell.id)
        table.register(InspectorHeader.self, forHeaderFooterViewReuseIdentifier: InspectorHeader.id)
        table.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(table)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
        zeroStack.isHidden = pane == .program
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastLine = -1
        refresh()
        startTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    @objc private func dismissSelf() { dismiss(animated: true) }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: reading the calculator

    /// Ask the engine thread for a snapshot; the program listing only when it is shown.
    func refresh() {
        guard isViewLoaded else { return }
        calculator.inspect(includeProgram: pane != .registers) { [weak self] s in self?.apply(s) }
    }

    private func apply(_ s: InspectorSnapshot?) {
        snapshot = s
        guard let s = s else {
            titleLabel.text = "Nothing to inspect"
            titleLabel.textColor = LegacyPanelColors.ink
            detailLabel.text = calculator.hasFirmware
                ? "The calculator is switching models, or its firmware keeps its registers in a layout this panel cannot read."
                : "Choose a firmware file first."
            sections = []
            table.reloadData()
            return
        }
        notes.programChanged(s)
        running = s.running
        showHeader(s)
        sections = buildSections(s)
        table.reloadData()
        scrollToProgramLine(s)
    }

    private func showHeader(_ s: InspectorSnapshot) {
        let modelName = s.model == 15 && s.variant == 152 ? "HP-15C (15.2)" : "HP-\(s.model)C"
        var tags: [String] = []
        if s.extendedMemory { tags.append("ext. memory") }
        if s.isComplex { tags.append("Complex") }
        if s.running { tags.append("RUNNING") } else if s.programMode { tags.append("PRGM") }
        titleLabel.text = modelName + (tags.isEmpty ? "" : "  ·  " + tags.joined(separator: "  ·  "))
        titleLabel.textColor = s.running ? LegacyPanelColors.running
            : s.programMode ? LegacyPanelColors.gold
            : LegacyPanelColors.ink

        var parts: [String] = []
        if !s.modeSummary.isEmpty { parts.append(s.modeSummary) }
        if s.model != 12 {
            let flags = s.setFlags.map { flagName($0, model: s.model) }.joined(separator: " ")
            parts.append("flags " + (s.setFlags.isEmpty ? "–" : flags))
        }
        if s.hasProgram {
            parts.append(String(format: s.model == 12 ? "line %02d / %02d" : "line %03d / %03d", s.line, s.lines))
        }
        detailLabel.text = parts.joined(separator: "   ")
    }

    private func flagName(_ n: Int, model: Int) -> String {
        if model == 16 && n == 4 { return "4(C)" }
        if model == 16 && n == 5 { return "5(G)" }
        if model == 15 && n == 8 { return "8(C)" }
        return "\(n)"
    }

    // MARK: sections

    private func buildSections(_ s: InspectorSnapshot) -> [InspectorSection] {
        var out: [InspectorSection] = []
        if pane != .program {
            let stack = stackShown(s).map { registerRow(s, $0) }
            out.append(InspectorSection(title: s.model == 12 ? "Stack and financial registers" : "Stack",
                                        rows: stack))
            if let pool = s.pool {
                var memory: [InspectorRow] = [valueRow("g MEM", pool.gmem, dim: "  pool \(pool.size) + R0, R1",
                                                       copy: pool.gmem)]
                for m in s.matrices {
                    let text = m.isEmpty ? "0 × 0" : "\(m.rows) × \(m.cols)"
                    memory.append(valueRow("Matrix " + m.letter, text,
                                           dim: m.isResult ? "  (RESULT)" : "",
                                           copy: m.isEmpty ? "" : m.tsv))
                }
                out.append(InspectorSection(title: "Memory", rows: memory))
            }
            let registers = hideZeros ? s.registers.filter { $0.stored != 0 } : s.registers
            var rows = registers.map { registerRow(s, $0) }
            if rows.isEmpty { rows = [valueRow("", "All registers are zero.", dim: "", copy: "")] }
            out.append(InspectorSection(title: "Storage registers (\(s.registerCount))", rows: rows))
        }
        if pane != .registers, s.hasProgram {
            out.append(InspectorSection(title: "Program (\(s.lines) lines)", rows: programRows(s)))
        }
        return out
    }

    /// Stack top-to-bottom as users think of it: I, LAST X, T, Z, Y, X, then the 12C financial registers.
    private func stackShown(_ s: InspectorSnapshot) -> [RegisterValue] {
        let order = ["I", "LAST X", "T", "Z", "Y", "X"]
        return order.compactMap { name in s.stack.first { $0.name == name } }
            + s.stack.filter { !order.contains($0.name) }
    }

    private func registerRow(_ s: InspectorSnapshot, _ v: RegisterValue) -> InspectorRow {
        if let descriptor = s.descriptorText(v) {
            return valueRow(v.name, descriptor, dim: "", copy: descriptor, register: v.name)
        }
        if let imaginary = s.imaginary(of: v.name) {
            let negative = imaginary.text.hasPrefix("-") || imaginary.text.hasPrefix("−")
            let part = negative ? String(imaginary.text.dropFirst()) : imaginary.text
            let text = "\(v.text) \(negative ? "−" : "+") \(part)i"
            return valueRow(v.name, text, dim: "", copy: text, register: v.name)
        }
        var text = v.text
        if v.isInteger && s.base == 2 && text.count > 8 {
            var grouped = ""
            for (i, ch) in text.reversed().enumerated() {
                if i > 0 && i % 4 == 0 { grouped.append(" ") }
                grouped.append(ch)
            }
            text = String(grouped.reversed())
        }
        var suffix = ""
        if v.isInteger {
            switch s.base {
            case 16: suffix = " h"
            case 8: suffix = " o"
            case 2: suffix = " b"
            default: suffix = " d"
            }
        }
        return valueRow(v.name, text, dim: suffix, copy: v.isInteger ? v.decimal : v.text, register: v.name)
    }

    private func programRows(_ s: InspectorSnapshot) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        let zero = s.model == 12 ? "00" : "000"
        rows.append(InspectorRow(name: zero + "-", value: NSAttributedString(), current: s.line == 0,
                                 programLine: 0, register: nil, copy: ""))
        for p in s.program {
            let text = NSMutableAttributedString(string: p.keys, attributes: [
                .font: LegacyFont.mono(12), .foregroundColor: LegacyPanelColors.ink,
            ])
            if !p.mnemonic.isEmpty {
                text.append(NSAttributedString(string: "  ", attributes: [
                    .font: LegacyFont.mono(12), .foregroundColor: LegacyPanelColors.ink,
                ]))
                if !p.prefix.isEmpty {
                    text.append(NSAttributedString(string: p.prefix + " ", attributes: [
                        .font: LegacyFont.mono(12, bold: true),
                        .foregroundColor: p.prefix == "f" ? LegacyPanelColors.gold : LegacyPanelColors.blue,
                    ]))
                }
                text.append(NSAttributedString(string: p.mnemonic, attributes: [
                    .font: LegacyFont.mono(12), .foregroundColor: LegacyPanelColors.ink,
                ]))
            }
            if let comment = notes.comment(at: p.line), !comment.isEmpty {
                text.append(NSAttributedString(string: "   " + comment, attributes: [
                    .font: LegacyFont.monoItalic(11), .foregroundColor: LegacyPanelColors.dim,
                ]))
            }
            rows.append(InspectorRow(name: p.number(model: s.model) + "-", value: text,
                                     current: p.line == s.line, programLine: p.line, register: nil,
                                     copy: p.screenView(model: s.model)))
        }
        return rows
    }

    private func valueRow(_ name: String, _ text: String, dim: String, copy: String,
                          register: String? = nil) -> InspectorRow {
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: LegacyFont.mono(12), .foregroundColor: LegacyPanelColors.ink,
        ])
        if !dim.isEmpty {
            value.append(NSAttributedString(string: dim, attributes: [
                .font: LegacyFont.mono(11), .foregroundColor: LegacyPanelColors.dim,
            ]))
        }
        return InspectorRow(name: name, value: value, current: false, programLine: nil,
                            register: register, copy: copy)
    }

    private func scrollToProgramLine(_ s: InspectorSnapshot) {
        guard pane != .registers, s.hasProgram, s.line != lastLine else { return }
        lastLine = s.line
        guard let section = sections.firstIndex(where: { $0.rows.first?.programLine != nil }) else { return }
        let row = min(max(0, s.line), sections[section].rows.count - 1)
        table.scrollToRow(at: IndexPath(row: row, section: section), at: .middle, animated: true)
    }

    // MARK: table

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: InspectorHeader.id) as? InspectorHeader
        view?.show(sections[section].title)
        return view
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 24 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: InspectorCell.id, for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        (cell as? InspectorCell)?.show(row, running: running)
        cell.selectionStyle = row.programLine == nil && row.register == nil ? .none : .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if let line = row.programLine { programTapped(line, row: row) }
        else if let register = row.register { registerTapped(register, row: row) }
    }

    // MARK: taps

    private func programTapped(_ line: Int, row: InspectorRow) {
        guard let s = snapshot else { return }
        let sheet = UIAlertController(title: stepName(line, model: s.model), message: nil, preferredStyle: .actionSheet)
        let gto = CalcActions.gto(s, line: line)
        if gto.enabled {
            sheet.addAction(UIAlertAction(title: gto.title, style: .default) { [weak self] _ in
                self?.calculator.performKeys(gto.keys)
                self?.refreshSoon()
            })
        }
        sheet.addAction(UIAlertAction(title: (notes.comment(at: line) == nil ? "Add" : "Edit") + " Comment…",
                                      style: .default) { [weak self] _ in self?.editComment(line) })
        if !row.copy.isEmpty {
            sheet.addAction(UIAlertAction(title: "Copy \(row.copy)", style: .default) { _ in
                UIPasteboard.general.string = row.copy
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func registerTapped(_ name: String, row: InspectorRow) {
        guard let s = snapshot else { return }
        let sheet = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        if !row.copy.isEmpty {
            sheet.addAction(UIAlertAction(title: "Copy \(row.copy)", style: .default) { _ in
                UIPasteboard.general.string = row.copy
            })
        }
        for action in CalcActions.registerMenu(s, name: name) where action.enabled {
            sheet.addAction(UIAlertAction(title: action.title, style: .default) { [weak self] _ in
                self?.calculator.performKeys(action.keys)
                self?.refreshSoon()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func editComment(_ line: Int) {
        guard let s = snapshot else { return }
        let alert = UIAlertController(title: "Comment for " + stepName(line, model: s.model),
                                      message: "Shown in the listing and in the exported documentation. It stays with this step when lines are inserted or deleted.",
                                      preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.notes.comment(at: line) ?? ""
            field.placeholder = "Comment"
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.notes.setComment(alert.textFields?.first?.text ?? "", at: line, lines: s.program)
            self.refresh()
        })
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.notes.setComment("", at: line, lines: s.program)
            self.refresh()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func stepName(_ line: Int, model: Int) -> String {
        "step " + String(format: model == 12 ? "%02d" : "%03d", line)
    }

    /// Let the engine apply the keyed command before reading the calculator again.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refresh() }
    }

    private func anchor(_ controller: UIAlertController) {
        controller.popoverPresentationController?.sourceView = table
        controller.popoverPresentationController?.sourceRect = CGRect(x: table.bounds.midX, y: table.bounds.midY,
                                                                     width: 1, height: 1)
        controller.popoverPresentationController?.permittedArrowDirections = []
    }

    // MARK: controls

    @objc private func paneChanged() {
        pane = LegacyInspectorPane(rawValue: paneControl.selectedSegmentIndex) ?? .both
        zeroStack.isHidden = pane == .program
        lastLine = -1
        refresh()
    }

    @objc private func zerosChanged(_ sender: UISwitch) {
        hideZeros = sender.isOn
        refresh()
    }
}
