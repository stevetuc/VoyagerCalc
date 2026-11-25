// SPDX-License-Identifier: MIT
// Copyright (c) 2026 José González Divassón
//
// LegacyMatrixEditor.swift - the HP-15C Matrix Editor on iOS 12, a UIKit port of
// App/MatrixEditorModel.swift and Views/MatrixEditorView.swift: matrix A–E, size with the free
// memory check, a real-only grid, Paste Matrix (a tab-separated range, previewed first), Copy
// (TSV), Open from Memory and Apply (DIM + values into the calculator's memory through
// Matrix15 / CalculatorMachine.writeMatrix15).
//
// The grid is made of text fields, one per cell, and is only built for up to 1024 cells: a bigger
// matrix (the 15C allows 99 × 99) is still read, pasted, copied and applied, but is not drawn.

import UIKit

final class LegacyMatrixEditorViewController: UIViewController, UITextFieldDelegate {
    private let calculator = LegacyCalculator.shared

    private let matrixControl = UISegmentedControl(items: Pool15.letters)
    private let rowsLabel = UILabel()
    private let colsLabel = UILabel()
    private let rowsStepper = UIStepper()
    private let colsStepper = UIStepper()
    private let memoryLabel = UILabel()
    private let gridScroll = UIScrollView()
    private let gridStack = UIStackView()
    private let statusLabel = UILabel()

    private var fields: [UITextField] = []
    private var cells: [String] = []
    private var rows = 0
    private var cols = 0
    private var matrix = 0
    private var image: Data?
    private var variant = 150

    private static let cellWidth: CGFloat = 84
    private static let cellHeight: CGFloat = 26
    private static let gutter: CGFloat = 34
    private static let maxDrawnCells = 1024

    private var letter: String { Pool15.letters[max(0, min(4, matrix))] }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Matrix Editor"
        view.backgroundColor = LegacyPanelColors.panel
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(dismissSelf))

        matrixControl.selectedSegmentIndex = matrix
        matrixControl.tintColor = LegacyPanelColors.gold
        matrixControl.addTarget(self, action: #selector(matrixChanged), for: .valueChanged)

        for label in [rowsLabel, colsLabel] {
            label.font = LegacyFont.mono(12)
            label.textColor = LegacyPanelColors.ink
        }
        rowsLabel.text = "3"
        colsLabel.text = "3"
        for stepper in [rowsStepper, colsStepper] {
            stepper.minimumValue = 0
            stepper.maximumValue = Double(Matrix15.maxSide)
            stepper.stepValue = 1
            stepper.tintColor = LegacyPanelColors.gold
        }
        rowsStepper.value = 3
        colsStepper.value = 3
        rowsStepper.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        colsStepper.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)

        let top = UIStackView(arrangedSubviews: [matrixControl, sizeStack()])
        top.axis = .horizontal
        top.spacing = 14
        top.alignment = .center

        memoryLabel.font = LegacyFont.mono(11)
        memoryLabel.textColor = LegacyPanelColors.dim
        memoryLabel.numberOfLines = 3

        gridScroll.backgroundColor = LegacyPanelColors.header
        gridScroll.layer.cornerRadius = 6
        gridScroll.alwaysBounceHorizontal = true
        gridScroll.alwaysBounceVertical = true
        gridStack.axis = .vertical
        gridStack.spacing = 0
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        gridScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The grid is wider and taller than the visible frame: pin the content to the content guide.
        NSLayoutConstraint.activate([
            gridStack.topAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.topAnchor, constant: 4),
            gridStack.leadingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            gridStack.trailingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.trailingAnchor, constant: -4),
            gridStack.bottomAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.bottomAnchor, constant: -4),
        ])

        statusLabel.font = UIFont.systemFont(ofSize: 12)
        statusLabel.textColor = LegacyPanelColors.dim
        statusLabel.numberOfLines = 0

        let paste = actionButton("Paste Matrix…", #selector(pasteMatrix))
        let copy = actionButton("Copy", #selector(copyMatrix))
        let open = actionButton("Open from Memory", #selector(reloadFromMemory))
        let apply = actionButton("Apply", #selector(applyNow))
        let buttons = UIStackView(arrangedSubviews: [paste, copy, open, apply])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let page = UIStackView(arrangedSubviews: [top, memoryLabel, gridScroll, statusLabel, buttons])
        page.axis = .vertical
        page.spacing = 10
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            page.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            page.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
            page.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
        rebuildGrid()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if image == nil { reloadFromMemory() }
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // MARK: pieces

    private func sizeStack() -> UIView {
        func pair(_ label: UILabel, _ stepper: UIStepper) -> UIStackView {
            let row = UIStackView(arrangedSubviews: [label, stepper])
            row.axis = .horizontal
            row.spacing = 4
            row.alignment = .center
            return row
        }
        let row = UIStackView(arrangedSubviews: [pair(rowsLabel, rowsStepper), pair(colsLabel, colsStepper)])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        return row
    }

    private func actionButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(LegacyPanelColors.gold, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.text = text
        statusLabel.textColor = error ? LegacyPanelColors.bad : LegacyPanelColors.dim
    }

    // MARK: memory

    @objc private func reloadFromMemory() {
        setStatus("Reading the calculator's memory…", error: false)
        calculator.fetchMemory { [weak self] data, variant in
            guard let self = self else { return }
            self.variant = variant
            guard let data = data, let stored = Matrix15.read(data, variant: variant, matrix: self.matrix) else {
                self.setStatus("The calculator's memory could not be read (is it running as an HP-15C?).", error: true)
                return
            }
            self.image = data
            self.fill(rows: stored.rows, cols: stored.cols, cells: stored.raw.map(Matrix15.cellText))
            if stored.rows * stored.cols > 0 {
                self.setStatus("Matrix \(self.letter) (\(stored.rows) × \(stored.cols)) from the calculator's memory.", error: false)
            } else {
                self.setStatus("Matrix \(self.letter) is not dimensioned (0 × 0). Set rows and columns, type or paste the values, then Apply.", error: false)
            }
        }
    }

    /// Rows and columns from the steppers: cells keep their row and column, new ones are empty (= 0).
    private func setSize(rows r: Int, cols c: Int) {
        let r = max(0, min(Matrix15.maxSide, r))
        let c = max(0, min(Matrix15.maxSide, c))
        var out = [String](repeating: "", count: r * c)
        for i in 0..<min(r, rows) {
            for j in 0..<min(c, cols) { out[i * c + j] = cell(i, j) }
        }
        fill(rows: r, cols: c, cells: out)
    }

    private func fill(rows r: Int, cols c: Int, cells t: [String]) {
        rows = r
        cols = c
        cells = t
        rowsStepper.value = Double(r)
        colsStepper.value = Double(c)
        rebuildGrid()
        updateMemory()
    }

    private func cell(_ r: Int, _ c: Int) -> String {
        let i = r * cols + c
        return i >= 0 && i < cells.count ? cells[i] : ""
    }

    private func updateMemory() {
        rowsLabel.text = "Rows \(rows)"
        colsLabel.text = "Cols \(cols)"
        guard let image = image else { memoryLabel.text = ""; return }
        let room = Matrix15.room(image, variant: variant, matrix: matrix)
        let need = rows * cols
        if need <= room {
            memoryLabel.text = "\(rows) × \(cols) = \(need) registers; matrix \(letter) can have up to \(room) here."
            memoryLabel.textColor = LegacyPanelColors.dim
        } else {
            memoryLabel.text = "\(rows) × \(cols) = \(need) registers does not fit: only \(room) are free for matrix \(letter) (the calculator would show Error 10)."
            memoryLabel.textColor = LegacyPanelColors.bad
        }
    }

    // MARK: the grid

    private func rebuildGrid() {
        for view in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        fields = []
        guard rows > 0, cols > 0 else {
            gridStack.addArrangedSubview(messageRow("Matrix \(letter) is 0 × 0: nothing to show. Raise rows and columns, or paste a range."))
            return
        }
        guard rows * cols <= Self.maxDrawnCells else {
            gridStack.addArrangedSubview(messageRow("This \(rows) × \(cols) matrix has \(rows * cols) cells: too many to draw here. Paste, Copy and Apply still work."))
            return
        }

        var header: [UIView] = [spacer(Self.gutter)]
        for c in 0..<cols { header.append(headerLabel("\(c + 1)")) }
        gridStack.addArrangedSubview(row(header))

        for r in 0..<rows {
            var views: [UIView] = [headerLabel("\(r + 1)")]
            for c in 0..<cols { views.append(cellField(r, c)) }
            gridStack.addArrangedSubview(row(views))
        }
    }

    private func messageRow(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = LegacyPanelColors.dim
        label.numberOfLines = 0
        return label
    }

    private func spacer(_ width: CGFloat) -> UIView {
        let view = UIView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func headerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = LegacyFont.mono(10)
        label.textColor = LegacyPanelColors.dim
        label.textAlignment = .center
        label.widthAnchor.constraint(equalToConstant: Self.cellWidth).isActive = true
        label.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return label
    }

    private func row(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = 0
        row.alignment = .center
        return row
    }

    private func cellField(_ r: Int, _ c: Int) -> UITextField {
        let i = r * cols + c
        let field = UITextField()
        field.text = i < cells.count ? cells[i] : ""
        field.font = LegacyFont.mono(12)
        field.textColor = LegacyPanelColors.ink
        field.tintColor = LegacyPanelColors.gold
        field.textAlignment = .right
        field.borderStyle = .none
        field.backgroundColor = good(cells.count > i ? cells[i] : "") ? UIColor(white: 1, alpha: 0.05) : UIColor(rgb: 0x5A2A25)
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .next
        field.delegate = self
        field.tag = i
        field.addTarget(self, action: #selector(cellChanged(_:)), for: .editingChanged)
        field.widthAnchor.constraint(equalToConstant: Self.cellWidth - 2).isActive = true
        field.heightAnchor.constraint(equalToConstant: Self.cellHeight).isActive = true
        fields.append(field)
        return field
    }

    private func good(_ text: String) -> Bool { Matrix15.value(text) != nil }

    @objc private func cellChanged(_ sender: UITextField) {
        guard sender.tag >= 0, sender.tag < cells.count else { return }
        cells[sender.tag] = sender.text ?? ""
        sender.backgroundColor = good(sender.text ?? "") ? UIColor(white: 1, alpha: 0.05) : UIColor(rgb: 0x5A2A25)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Return moves down a row, then to the top of the next column, like a spreadsheet.
        var next = textField.tag + cols
        if next >= rows * cols { next = (textField.tag % max(1, cols)) + 1 }
        if next < fields.count { fields[next].becomeFirstResponder() }
        else { textField.resignFirstResponder() }
        return false
    }

    // MARK: actions

    @objc private func matrixChanged() {
        matrix = max(0, min(4, matrixControl.selectedSegmentIndex))
        reloadFromMemory()
    }

    @objc private func sizeChanged() {
        setSize(rows: Int(rowsStepper.value), cols: Int(colsStepper.value))
    }

    @objc private func copyMatrix() {
        let tsv = (0..<rows).map { r in
            (0..<cols).map { c -> String in
                let text = cell(r, c)
                return Matrix15.value(text).map(Matrix15.cellText) ?? text
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        UIPasteboard.general.string = tsv
        setStatus("Copied \(rows) × \(cols) cells (tab-separated): paste them into a spreadsheet.", error: false)
    }

    @objc private func pasteMatrix() {
        let table = Matrix15.parseTable(UIPasteboard.general.string ?? "")
        guard table.ok else {
            setStatus(table.error.isEmpty ? "The clipboard holds no cells." : table.error, error: true)
            return
        }
        let bad = Matrix15.badCells(table)
        var message = "\(table.rows) rows × \(table.cols) columns from the clipboard, for matrix \(letter)."
        if table.ragged { message += "\nThe rows have different lengths: the missing cells become 0." }
        if let image = image {
            let available = Matrix15.room(image, variant: variant, matrix: matrix)
            let need = table.rows * table.cols
            if available >= 0 && need > available {
                message += "\n\(need) registers needed, only \(available) free for this matrix: Apply will refuse it until it is smaller."
            }
        }
        if !bad.isEmpty {
            message += "\n\(bad.count) cell(s) are not real numbers (marked red): "
                + bad.prefix(4).joined(separator: "; ") + (bad.count > 4 ? " …" : "")
        }
        let alert = UIAlertController(title: "Paste Matrix", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Fill the Grid", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.fill(rows: table.rows, cols: table.cols, cells: table.cells)
            let count = bad.count
            self.setStatus("Pasted \(table.rows) × \(table.cols) cells into the grid"
                           + (count == 0 ? "" : " (\(count) to fix, marked red)")
                           + ". Apply puts them into matrix \(self.letter).", error: count > 0)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func applyNow() {
        guard image != nil else {
            setStatus("Open the matrix from the calculator's memory first.", error: true)
            return
        }
        var raw: [UInt64] = []
        raw.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                switch Matrix15.parseCell(cell(r, c)) {
                case .success(let value):
                    raw.append(value)
                case .failure(let error):
                    setStatus("Row \(r + 1), column \(c + 1): “\(cell(r, c))” is \(error.text). Use numbers like 1.5, 1,5 or 2E-3.", error: true)
                    return
                }
            }
        }
        setStatus("Writing…", error: false)
        calculator.writeMatrix(matrix, rows: rows, cols: cols, raw: raw) { [weak self] failure in
            guard let self = self else { return }
            if let failure = failure {
                self.setStatus(failure, error: true)
                return
            }
            let letter = self.letter, rows = self.rows, cols = self.cols
            self.reloadFromMemory()
            self.setStatus(rows * cols > 0
                ? "Matrix \(letter) (\(rows) × \(cols)) is now in the calculator's memory."
                : "Matrix \(letter) was set to 0 × 0 (its registers are free again).", error: false)
        }
    }
}
