import Foundation

/// 読み込んだツールの計算式を評価する、アプリ専用の小さな評価器。
/// できるのは数の計算だけで、通信・ファイル・アプリのデータには一切触れない。NSExpression や JavaScript は使わない。
/// 式の長さ、入れ子の深さ、計算の回数に上限がある。
enum ToolExpressionError: Error, Equatable {
    case syntax(String, position: Int)
    case unknownVariable(String)
    case unknownFunction(String)
    case wrongArgumentCount(String, expected: String)
    case divisionByZero
    case notFinite
    case tooLong
    case tooDeep
    case tooManySteps

    var message: String {
        switch self {
        case .syntax(let text, let position): return "\(position + 1)文字目: \(text)"
        case .unknownVariable(let name): return "「\(name)」という入力欄はありません"
        case .unknownFunction(let name): return "「\(name)」という関数はありません"
        case .wrongArgumentCount(let name, let expected): return "\(name) の引数は \(expected) です"
        case .divisionByZero: return "0で割っています"
        case .notFinite: return "計算結果が数になりません(大きすぎる、または定義されない値)"
        case .tooLong: return "式が長すぎます(\(ToolExpression.maxLength)文字まで)"
        case .tooDeep: return "括弧や関数の入れ子が深すぎます(\(ToolExpression.maxDepth)段まで)"
        case .tooManySteps: return "計算の回数が上限(\(ToolExpression.maxSteps)回)を超えました"
        }
    }
}

struct ToolExpression: Equatable {
    static let maxLength = 500
    static let maxDepth = 32
    static let maxSteps = 5000

    indirect enum Node: Equatable {
        case number(Double)
        case variable(String)
        case unary(String, Node)
        case binary(String, Node, Node)
        case call(String, [Node])
    }

    let root: Node
    /// 式の中で使っている変数(入力欄のID)
    let variables: Set<String>

    // MARK: - 構文解析

    init(_ source: String) throws {
        guard source.count <= Self.maxLength else { throw ToolExpressionError.tooLong }
        var parser = Parser(characters: Array(source))
        root = try parser.parseAll()
        variables = parser.variables
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(String)
        case end
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var depth = 0
        var variables = Set<String>()
        private var current: Token = .end
        private var currentPosition = 0

        init(characters: [Character]) {
            self.characters = characters
        }

        mutating func parseAll() throws -> Node {
            try advance()
            let node = try parseOr()
            guard current == .end else { throw ToolExpressionError.syntax("ここで式が終わるはずです", position: currentPosition) }
            return node
        }

        private mutating func advance() throws {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            currentPosition = index
            guard index < characters.count else {
                current = .end
                return
            }
            let character = characters[index]
            if character.isNumber || character == "." {
                var text = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    text.append(characters[index])
                    index += 1
                }
                guard let value = Double(text) else { throw ToolExpressionError.syntax("数として読めません: \(text)", position: currentPosition) }
                current = .number(value)
                return
            }
            if character.isLetter || character == "_" {
                var text = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    text.append(characters[index])
                    index += 1
                }
                current = .identifier(text)
                return
            }
            let two = index + 1 < characters.count ? String([character, characters[index + 1]]) : ""
            if ["<=", ">=", "==", "!=", "&&", "||"].contains(two) {
                index += 2
                current = .symbol(two)
                return
            }
            if "+-*/%^(),<>!".contains(character) {
                index += 1
                current = .symbol(String(character))
                return
            }
            throw ToolExpressionError.syntax("使えない文字です: \(character)", position: currentPosition)
        }

        private func isSymbol(_ text: String) -> Bool { current == .symbol(text) }

        private mutating func binaryLevel(_ operators: [String], _ next: (inout Parser) throws -> Node) throws -> Node {
            var left = try next(&self)
            while case .symbol(let symbol) = current, operators.contains(symbol) {
                try advance()
                let right = try next(&self)
                left = .binary(symbol, left, right)
            }
            return left
        }

        private mutating func parseOr() throws -> Node { try binaryLevel(["||"]) { try $0.parseAnd() } }
        private mutating func parseAnd() throws -> Node { try binaryLevel(["&&"]) { try $0.parseComparison() } }
        private mutating func parseComparison() throws -> Node { try binaryLevel(["<", "<=", ">", ">=", "==", "!="]) { try $0.parseSum() } }
        private mutating func parseSum() throws -> Node { try binaryLevel(["+", "-"]) { try $0.parseProduct() } }
        private mutating func parseProduct() throws -> Node { try binaryLevel(["*", "/", "%"]) { try $0.parseUnary() } }

        private mutating func parseUnary() throws -> Node {
            if isSymbol("-") || isSymbol("!") || isSymbol("+") {
                guard case .symbol(let symbol) = current else { return .number(0) }
                try advance()
                depth += 1
                defer { depth -= 1 }
                guard depth <= ToolExpression.maxDepth else { throw ToolExpressionError.tooDeep }
                let operand = try parseUnary()
                return symbol == "+" ? operand : .unary(symbol, operand)
            }
            return try parsePower()
        }

        /// べき乗は右結合(2^3^2 = 2^9)
        private mutating func parsePower() throws -> Node {
            let base = try parsePrimary()
            if isSymbol("^") {
                try advance()
                depth += 1
                defer { depth -= 1 }
                guard depth <= ToolExpression.maxDepth else { throw ToolExpressionError.tooDeep }
                let exponent = try parseUnary()
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func parsePrimary() throws -> Node {
            depth += 1
            defer { depth -= 1 }
            guard depth <= ToolExpression.maxDepth else { throw ToolExpressionError.tooDeep }
            switch current {
            case .number(let value):
                try advance()
                return .number(value)
            case .identifier(let name):
                try advance()
                if isSymbol("(") {
                    try advance()
                    var arguments: [Node] = []
                    if !isSymbol(")") {
                        arguments.append(try parseOr())
                        while isSymbol(",") {
                            try advance()
                            arguments.append(try parseOr())
                        }
                    }
                    guard isSymbol(")") else { throw ToolExpressionError.syntax("「)」が足りません", position: currentPosition) }
                    try advance()
                    return .call(name, arguments)
                }
                if name == "pi" { return .number(Double.pi) }
                variables.insert(name)
                return .variable(name)
            case .symbol("("):
                try advance()
                let node = try parseOr()
                guard isSymbol(")") else { throw ToolExpressionError.syntax("「)」が足りません", position: currentPosition) }
                try advance()
                return node
            case .end:
                throw ToolExpressionError.syntax("式が途中で終わっています", position: currentPosition)
            default:
                throw ToolExpressionError.syntax("ここには数、入力欄の名前、「(」のどれかが必要です", position: currentPosition)
            }
        }
    }

    // MARK: - 評価

    /// 使える関数と、引数の数
    static let functions: [String: ClosedRange<Int>] = [
        "abs": 1...1, "sqrt": 1...1, "floor": 1...1, "ceil": 1...1, "round": 1...2, "trunc": 1...1,
        "min": 1...8, "max": 1...8, "pow": 2...2, "mod": 2...2, "exp": 1...1, "ln": 1...1, "log10": 1...1,
        "sin": 1...1, "cos": 1...1, "tan": 1...1, "if": 3...3, "days": 2...2, "clamp": 3...3,
    ]

    /// 式の中の変数と関数が正しいかを、計算する前に調べる
    func check(knownVariables: Set<String>) throws {
        for name in variables.sorted() where !knownVariables.contains(name) { throw ToolExpressionError.unknownVariable(name) }
        try Self.checkCalls(root)
    }

    private static func checkCalls(_ node: Node) throws {
        switch node {
        case .number, .variable: return
        case .unary(_, let operand): try checkCalls(operand)
        case .binary(_, let left, let right):
            try checkCalls(left)
            try checkCalls(right)
        case .call(let name, let arguments):
            guard let range = functions[name] else { throw ToolExpressionError.unknownFunction(name) }
            guard range.contains(arguments.count) else {
                let expected = range.lowerBound == range.upperBound ? "\(range.lowerBound)個" : "\(range.lowerBound)〜\(range.upperBound)個"
                throw ToolExpressionError.wrongArgumentCount(name, expected: expected)
            }
            for argument in arguments { try checkCalls(argument) }
        }
    }

    /// 日付は「1970年1月1日からの日数」の数として渡す。真偽は 1 と 0。
    /// stepLimit は計算の回数の上限(テスト用に小さくできる)
    func evaluate(_ values: [String: Double], stepLimit: Int = ToolExpression.maxSteps) throws -> Double {
        var steps = 0
        let result = try Self.evaluate(root, values, &steps, stepLimit)
        guard result.isFinite else { throw ToolExpressionError.notFinite }
        return result
    }

    private static func evaluate(_ node: Node, _ values: [String: Double], _ steps: inout Int, _ limit: Int) throws -> Double {
        steps += 1
        guard steps <= limit else { throw ToolExpressionError.tooManySteps }
        switch node {
        case .number(let value):
            return value
        case .variable(let name):
            guard let value = values[name] else { throw ToolExpressionError.unknownVariable(name) }
            return value
        case .unary(let symbol, let operand):
            let value = try evaluate(operand, values, &steps, limit)
            return symbol == "!" ? (value == 0 ? 1 : 0) : -value
        case .binary(let symbol, let leftNode, let rightNode):
            let left = try evaluate(leftNode, values, &steps, limit)
            // && と || は、左だけで決まるなら右を計算しない
            if symbol == "&&", left == 0 { return 0 }
            if symbol == "||", left != 0 { return 1 }
            let right = try evaluate(rightNode, values, &steps, limit)
            switch symbol {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/":
                guard right != 0 else { throw ToolExpressionError.divisionByZero }
                return left / right
            case "%":
                guard right != 0 else { throw ToolExpressionError.divisionByZero }
                return left.truncatingRemainder(dividingBy: right)
            case "^": return pow(left, right)
            case "<": return left < right ? 1 : 0
            case "<=": return left <= right ? 1 : 0
            case ">": return left > right ? 1 : 0
            case ">=": return left >= right ? 1 : 0
            case "==": return left == right ? 1 : 0
            case "!=": return left != right ? 1 : 0
            case "&&", "||": return right != 0 ? 1 : 0
            default: throw ToolExpressionError.syntax("使えない演算子です: \(symbol)", position: 0)
            }
        case .call(let name, let argumentNodes):
            if name == "if" {
                guard argumentNodes.count == 3 else { throw ToolExpressionError.wrongArgumentCount(name, expected: "3個") }
                // 条件に合うほうだけを計算する
                let condition = try evaluate(argumentNodes[0], values, &steps, limit)
                return try evaluate(condition != 0 ? argumentNodes[1] : argumentNodes[2], values, &steps, limit)
            }
            guard let range = functions[name] else { throw ToolExpressionError.unknownFunction(name) }
            guard range.contains(argumentNodes.count) else { throw ToolExpressionError.wrongArgumentCount(name, expected: "\(range.lowerBound)〜\(range.upperBound)個") }
            let a = try argumentNodes.map { try evaluate($0, values, &steps, limit) }
            switch name {
            case "abs": return abs(a[0])
            case "sqrt": return a[0].squareRoot()
            case "floor": return a[0].rounded(.down)
            case "ceil": return a[0].rounded(.up)
            case "trunc": return a[0].rounded(.towardZero)
            case "round":
                let digits = a.count > 1 ? min(max(a[1].rounded(), -12), 12) : 0
                let scale = pow(10, digits)
                return (a[0] * scale).rounded(.toNearestOrAwayFromZero) / scale
            case "min": return a.min() ?? 0
            case "max": return a.max() ?? 0
            case "pow": return pow(a[0], a[1])
            case "mod":
                guard a[1] != 0 else { throw ToolExpressionError.divisionByZero }
                return a[0].truncatingRemainder(dividingBy: a[1])
            case "exp": return exp(a[0])
            case "ln": return log(a[0])
            case "log10": return log10(a[0])
            case "sin": return sin(a[0] * .pi / 180)
            case "cos": return cos(a[0] * .pi / 180)
            case "tan": return tan(a[0] * .pi / 180)
            case "days": return a[1] - a[0]
            case "clamp": return min(max(a[0], a[1]), a[2])
            default: throw ToolExpressionError.unknownFunction(name)
            }
        }
    }
}
