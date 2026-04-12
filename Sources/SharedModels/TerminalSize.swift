public struct TerminalSize: Sendable, Equatable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) throws {
        guard columns > 0 else {
            throw SemanticDeveloperError.invalidTerminalSize(columns: columns, rows: rows)
        }

        guard rows > 0 else {
            throw SemanticDeveloperError.invalidTerminalSize(columns: columns, rows: rows)
        }

        self.columns = columns
        self.rows = rows
    }
}
