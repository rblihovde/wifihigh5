import Foundation

/// The one place a CSV text field is written.
///
/// There used to be two escapers, and only one of them defended against formula
/// injection. A spreadsheet reading a CSV removes the quoting first and then
/// evaluates any cell that starts like a formula, so quoting on its own
/// protects nothing: a Bonjour name of `=HYPERLINK(...)` would travel into the
/// export and run when the file was opened. Every exported string comes here.
///
/// Numbers must not. Prefixing a reading of −62 would turn it into text and
/// make the column useless for anyone analysing the file.
enum CSVEncoder {

    /// Leading characters that make a spreadsheet treat a cell as a formula, or
    /// run the cell on into a formula, including the full-width forms some
    /// locales accept. Compared as scalars: Swift reads "\r\n" as a single
    /// character, which a character comparison would miss.
    private static let formulaLeads: Set<Unicode.Scalar> = [
        "=", "+", "-", "@", "\t", "\r", "\n",
        "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"
    ]

    static func field(_ input: String) -> String {
        var value = input
        if let first = value.unicodeScalars.first, formulaLeads.contains(first) {
            value = "'" + value
        }
        let needsQuoting = value.unicodeScalars.contains {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
