import Foundation

// MARK: - C Language Interpreter (subset)
// Interprets a practical subset of C for educational snippets.

public struct CInterpreterResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    public let durationMs: Int
    public let steps: Int
}

public enum CInterpreterError: Error {
    case timeout
    case memoryLimit
    case parseError(String)
    case runtimeError(String)
}

public final class CInterpreter {
    public var maxSteps: Int = 500_000
    public var maxHeap: Int = 2 * 1024 * 1024
    public var maxOutput: Int = 64 * 1024

    public init() {}

    public func run(_ source: String) -> CInterpreterResult {
        let start = Date()
        var stdout = ""
        var stderr = ""
        var steps = 0
        var exitCode = 0
        let lexer = Lexer(source: source)
        let parser = Parser(lexer: lexer)
        do {
            let program = try parser.parseProgram()
            let vm = VM(interpreter: self) { stdout += $0 }
            try vm.execute(program)
            steps = vm.steps
        } catch let err as CInterpreterError {
            switch err {
            case .timeout: stderr = "Error: timed out (limit \(maxSteps) steps)"
            case .memoryLimit: stderr = "Error: memory exceeded (\(maxHeap) bytes)"
            case .parseError(let m): stderr = "Parse error: \(m)"
            case .runtimeError(let m): stderr = "Runtime error: \(m)"
            }

// MARK: - Lexer

extension CInterpreter {
    final class Lexer {
        let src: [Character]
        var pos = 0
        var line = 1
        var tokens: [Token] = []

        enum Token {
            case intLit(Int), charLit(Int), strLit(String)
            case ident(String), keyword(String), op(String), eof
        }

        init(source: String) {
            src = Array(source)
            tokenize()
        }

        private func tokenize() {
            while pos < src.count {
                let c = src[pos]
                if c.isWhitespace { if c == "\n" { line += 1 }; pos += 1; continue }
                if c == "/" && peek(1) == "/" {
                    while pos < src.count && src[pos] != "\n" { pos += 1 }
                    continue
                }
                if c == "/" && peek(1) == "*" {
                    pos += 2
                    while pos < src.count, !(src[pos] == "*" && peek(1) == "/") {
                        if src[pos] == "\n" { line += 1 }; pos += 1
                    }
                    pos += 2; continue
                }
                if c == "\"" {
                    pos += 1
                    var s = ""
                    while pos < src.count && src[pos] != "\"" {
                        if src[pos] == "\\" && pos + 1 < src.count {
                            pos += 1
                            switch src[pos] {
                            case "n": s += "\n"
                            case "t": s += "\t"
                            case "r": s += "\r"
                            case "\\": s += "\\"
                            case "\"": s += "\""
                            case "0": s += "\0"
                            default: s += String(src[pos])
                            }
                        } else { s += String(src[pos]) }
                        pos += 1
                    }
                    if pos < src.count { pos += 1 }
                    tokens.append(.strLit(s)); continue
                }
                if c == "'" {
                    pos += 1
                    var v = 0
                    if pos < src.count && src[pos] == "\\" {
                        pos += 1
                        if pos < src.count {
                            switch src[pos] {
                            case "n": v = 10
                            case "t": v = 9
                            case "r": v = 13
                            case "0": v = 0
                            default: v = Int(src[pos].asciiValue ?? 0)
                            }
                            pos += 1
                        }
                    } else if pos < src.count {
                        v = Int(src[pos].asciiValue ?? 0); pos += 1
                    }
                    if pos < src.count && src[pos] == "'" { pos += 1 }
                    tokens.append(.charLit(v)); continue
                }
                if c.isNumber {
                    var n = 0
                    if c == "0", peek(1) == "x" || peek(1) == "X" {
                        pos += 2
                        while pos < src.count, src[pos].isHexDigit {
                            n = n * 16 + Int(String(src[pos]), radix: 16)!
                            pos += 1
                        }
                    } else {
                        while pos < src.count, src[pos].isNumber {
                            n = n * 10 + Int(src[pos].wholeNumberValue ?? 0)
                            pos += 1
                        }
                    }
                    tokens.append(.intLit(n)); continue
                }
                if c.isLetter || c == "_" {
                    var id = ""
                    while pos < src.count, (src[pos].isLetter || src[pos].isNumber || src[pos] == "_") {
                        id += String(src[pos]); pos += 1
                    }
                    let kw = ["int","char","void","return","if","else","while","for","do","break","continue","struct","typedef","sizeof"]
                    if kw.contains(id) { tokens.append(.keyword(id)) }
                    else { tokens.append(.ident(id)) }
                    continue
                }
                let ops = ["<<=",">>=","...","==","!=","<=",">=","&&","||","<<",">>",
                           "++","--","+=","-=","*=","/=","->","+","-","*","/","%","<",">",
                           "!","&","|","^","~","=","(",")","{","}","[","]",";",",",".","?",":", "@"]
                var matched = false
                for op in ops {
                    let opChars = Array(op)
                    if pos + opChars.count <= src.count {
                        var ok = true
                        for i in 0..<opChars.count {
                            if src[pos + i] != opChars[i] { ok = false; break }
                        }
                        if ok { tokens.append(.op(op)); pos += opChars.count; matched = true; break }
                    }
                }
                if matched { continue }
                pos += 1
            }
            tokens.append(.eof)
        }

        private func peek(_ o: Int) -> Character { (pos + o < src.count) ? src[pos + o] : "\0" }

// MARK: - AST

extension CInterpreter {
    indirect enum Expr {
        case intLit(Int), strLit(String), ident(String)
        case unary(String, Expr), binary(String, Expr, Expr)
        case call(String, [Expr]), addr(Expr), deref(Expr)
        case index(Expr, Expr), assign(String, Expr, Expr)
        case cast(String, Expr), sizeof(String)
    }
    enum Stmt {
        case expr(Expr), decl(String, String, Expr?)
        case block([Stmt]), `if`(Expr, Stmt, Stmt?), `while`(Expr, Stmt)
        case `for`(Stmt?, Expr?, Expr?, Stmt), `do`(Stmt, Expr)
        case `return`(Expr?), `break`, `continue`
    }
    struct Function {
        let name: String
        let params: [(String, String)]
        let body: Stmt
    }
}

// MARK: - Parser

extension CInterpreter {
    final class Parser {
        let lexer: Lexer
        var functions: [Function] = []
        var globals: [(String, String, Expr?)] = []

        init(lexer: Lexer) { self.lexer = lexer }

        func parseProgram() throws -> [Function] {
            while true {
                if case .eof = lexer.current() { break }
                try parseTopLevel()
            }
            return functions
        }

        private func parseTopLevel() throws {
            let retType = try parseType()
            guard case .ident(let name) = lexer.current() else {
                throw CInterpreterError.parseError("expected identifier at line \(lexer.curLine())")
            }
            lexer.advance()
            if case .op(let o) = lexer.current(), o == "(" {
                try parseFunctionBody(retType: retType, name: name); return
            }
            if case .op(let o) = lexer.current(), o == "=" {
                lexer.advance()
                let initExpr = try tryParseExpr()
                globals.append((retType, name, initExpr))
            } else {
                globals.append((retType, name, nil))
            }
            try lexer.expectOp(";")
        }

        private func parseFunctionBody(retType: String, name: String) throws {
            try lexer.expectOp("(")
            var params: [(String, String)] = []
            if case .op(let o) = lexer.current(), o != ")" {
                repeat {
                    let pt = try parseType()
                    var pn = "__p\(params.count)"
                    if case .ident(let n) = lexer.current() { lexer.advance(); pn = n }
                    params.append((pt, pn))
                } while matchOp(",")
            }
            try lexer.expectOp(")")
            let body = try parseBlock()
            _ = retType
            functions.append(Function(name: name, params: params, body: body))

extension CInterpreter.Parser {
    fileprivate func parseStmt() throws -> Stmt {
        if case .keyword(let k) = lexer.current() {
            switch k {
            case "if":
                lexer.advance(); try lexer.expectOp("(")
                let cond = try tryParseExpr(); try lexer.expectOp(")")
                let thenS = try parseStmt()
                var elseS: Stmt? = nil
                if case .keyword(let k2) = lexer.current(), k2 == "else" { lexer.advance(); elseS = try parseStmt() }
                return .if(cond, thenS, elseS)
            case "while":
                lexer.advance(); try lexer.expectOp("(")
                let cond = try tryParseExpr(); try lexer.expectOp(")")
                return .while(cond, try parseStmt())
            case "for":
                lexer.advance(); try lexer.expectOp("(")
                let ini: Stmt? = isStmtStart() ? try parseStmt() : ({ try lexer.expectOp(";"); return nil }() as Stmt?)
                let co: Expr? = (case .op(let o) = lexer.current(), o != ";") ? try tryParseExpr() : nil
                try lexer.expectOp(";")
                let st: Expr? = (case .op(let o) = lexer.current(), o != ")") ? try tryParseExpr() : nil
                try lexer.expectOp(")")
                _ = ini; _ = st
                return .for(ini, co, st, try parseStmt())
            case "do":
                lexer.advance()
                let body = try parseStmt()
                try lexer.expectKeyword("while"); try lexer.expectOp("(")
                let cond = try tryParseExpr(); try lexer.expectOp(")"); try lexer.expectOp(";")
                return .do(body, cond)
            case "return":
                lexer.advance()
                var e: Expr? = nil
                if case .op(let o) = lexer.current(), o != ";" { e = try tryParseExpr() }
                try lexer.expectOp(";")
                return .return(e)
            case "break": lexer.advance(); try lexer.expectOp(";"); return .break
            case "continue": lexer.advance(); try lexer.expectOp(";"); return .continue
            case "int", "char", "void": return try parseDecl()
            default: break
            }
        }
        if isDeclStart() { return try parseDecl() }
        let e = try tryParseExpr(); try lexer.expectOp(";"); return .expr(e)
    }

    fileprivate func parseDecl() throws -> Stmt {
        let t = try parseType()
        var name = "__v"
        if case .ident(let n) = lexer.current() { lexer.advance(); name = n }
        var init: Expr? = nil
        if case .op(let o) = lexer.current(), o == "=" { lexer.advance(); init = try tryParseExpr() }
        try lexer.expectOp(";")
        return .decl(t, name, init)
    }

    fileprivate func isStmtStart() -> Bool {
        switch lexer.current() {
        case .keyword(let k): return ["int","char","void","if","while","for","do","return","break","continue"].contains(k)
        case .op(let o): return o == "{"
        default: return true
        }
    }

extension CInterpreter.Parser {
    fileprivate func tryParseExpr() throws -> Expr { try parseAssign() }

    fileprivate func parseAssign() throws -> Expr {
        let lhs = try parseTernary()
        if case .op(let o) = lexer.current(), ["=","+=","-=","*=","/="].contains(o) {
            lexer.advance(); return .assign(o, lhs, try parseAssign())
        }
        return lhs
    }

    fileprivate func parseTernary() throws -> Expr {
        let cond = try parseOr()
        if case .op(let o) = lexer.current(), o == "?" {
            lexer.advance()
            let a = try tryParseExpr(); try lexer.expectOp(":"); let b = try parseTernary()
            return .binary("?", cond, .binary(":", a, b))
        }
        return cond
    }

    fileprivate func parseOr()  throws -> Expr { bin(parseAnd, ["||"]) }
    fileprivate func parseAnd() throws -> Expr { bin(parseBitOr, ["&&"]) }
    fileprivate func parseBitOr() throws -> Expr { bin(parseXor, ["|"]) }
    fileprivate func parseXor() throws -> Expr { bin(parseBitAnd, ["^"]) }
    fileprivate func parseBitAnd() throws -> Expr { bin(parseEq, ["&"]) }

    fileprivate func parseEq() throws -> Expr {
        var l = try parseComp()
        while case .op(let o) = lexer.current(), ["==","!="].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseComp())
        }
        return l
    }

    fileprivate func parseComp() throws -> Expr {
        var l = try parseShift()
        while case .op(let o) = lexer.current(), ["<",">","<=",">="].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseShift())
        }
        return l
    }

    fileprivate func parseShift() throws -> Expr {
        var l = try parseAdd()
        while case .op(let o) = lexer.current(), ["<<",">>"].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseAdd())
        }
        return l
    }

    fileprivate func parseAdd() throws -> Expr {
        var l = try parseMul()
        while case .op(let o) = lexer.current(), ["+","-"].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseMul())
        }
        return l
    }

    fileprivate func parseMul() throws -> Expr {
        var l = try parseUnary()
        while case .op(let o) = lexer.current(), ["*","/","%"].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseUnary())
        }
        return l
    }

    fileprivate func parseUnary() throws -> Expr {
        if case .op(let o) = lexer.current(), ["!","~","-","&","*","++","--"].contains(o) {
            lexer.advance(); return .unary(o, try parseUnary())
        }
        if case .keyword(let k) = lexer.current(), k == "sizeof" {
            lexer.advance(); return .sizeof(try parseType())
        }
        return try parsePostfix()
    }

    fileprivate func parsePostfix() throws -> Expr {
        var e = try parsePrimary()

// MARK: - Virtual Machine

extension CInterpreter {
    final class VM {
        let interpreter: CInterpreter
        let output: (String) -> Void
        var steps = 0
        var heap: [UInt8]
        var heapUsed = 0
        var functions: [Function] = []
        var globals: [(String, String, Expr?)] = []
        var vars: [[String: Int]] = [[:]]
        var returnValue: Int? = nil
        var breaking = false, continuing = false

        init(interpreter: CInterpreter, output: @escaping (String) -> Void) {
            self.interpreter = interpreter
            self.output = output
            self.heap = Array(repeating: 0, count: interpreter.maxHeap)
        }

        func execute(_ program: [Function]) throws {
            functions = program
            for (t, n, ie) in globals {
                let v = try ie.map { try eval($0) } ?? 0
                vars[0][n] = v; _ = t
            }
            guard let main = program.first(where: { $0.name == "main" }) else {
                throw CInterpreterError.runtimeError("no main() function found")
            }
            try call(main, [])
        }

        private func checkSteps() throws {
            steps += 1
            if steps > interpreter.maxSteps { throw CInterpreterError.timeout }
        }

        private func get(_ n: String) -> Int {
            for i in stride(from: vars.count - 1, through: 0, by: -1) {
                if let v = vars[i][n] { return v }
            }
            return 0
        }
        private func set(_ n: String, _ v: Int) {
            for i in stride(from: vars.count - 1, through: 0, by: -1) {
                if vars[i][n] != nil { vars[i][n] = v; return }
            }
            vars[vars.count - 1][n] = v
        }

        private func call(_ fn: Function, _ args: [Int]) throws {
            var frame: [String: Int] = [:]
            for (i, p) in fn.params.enumerated() { frame[p.1] = i < args.count ? args[i] : 0 }
            vars.append(frame)
            try exec(fn.body)
            vars.removeLast()
        }

        private func exec(_ s: Stmt) throws {
            checkSteps()
            if returnValue != nil || breaking || continuing { return }
            switch s {
            case .expr(let e): _ = try eval(e)
            case .decl(let t, let n, let ini):
                let v = try ini.map { try eval($0) } ?? 0
                set(n, v); _ = t
            case .block(let ss):
                for s in ss { try exec(s); if returnValue != nil || breaking || continuing { break } }
            case .if(let c, let t, let e):
                if try eval(c) != 0 { try exec(t) } else if let e = e { try exec(e) }
            case .while(let c, let b):
                while try eval(c) != 0 { breaking = false; try exec(b); if returnValue != nil { break }; if breaking { breaking = false; break }; if continuing { continuing = false } }
            case .for(let i, let c, let st, let b):
                if let i = i { try exec(i) }

extension CInterpreter.VM {
    private func eval(_ e: Expr) throws -> Int {
        checkSteps()
        switch e {
        case .intLit(let v): return v
        case .strLit(let s):
            let p = heapUsed; let bytes = Array(s.utf8)
            for b in bytes { heap[heapUsed] = b; heapUsed += 1 }
            heap[heapUsed] = 0; heapUsed += 1; return p
        case .ident(let n): return get(n)
        case .unary(let op, let e):
            let v = try eval(e)
            switch op {
            case "!": return v == 0 ? 1 : 0
            case "~": return ~v
            case "-": return -v
            case "*": return (v >= 0 && v < heapUsed) ? Int(heap[v]) : 0
            case "&": return v
            case "++": return v + 1
            case "--": return v - 1
            default: return v
            }
        case .binary(let op, let l, let r):
            let a = try eval(l), b = try eval(r)
            switch op {
            case "+": return a + b; case "-": return a - b; case "*": return a * b
            case "/": return b != 0 ? a / b : 0; case "%": return b != 0 ? a % b : 0
            case "<": return a < b ? 1 : 0; case ">": return a > b ? 1 : 0
            case "<=": return a <= b ? 1 : 0; case ">=": return a >= b ? 1 : 0
            case "==": return a == b ? 1 : 0; case "!=": return a != b ? 1 : 0
            case "&&": return (a != 0 && b != 0) ? 1 : 0; case "||": return (a != 0 || b != 0) ? 1 : 0
            case "&": return a & b; case "|": return a | b; case "^": return a ^ b
            case "<<": return a << b; case ">>": return a >> b
            case "?": return a; case ":": return b
            default: return 0
            }
        case .call(let name, let args):
            let a = try args.map { try eval($0) }
            return try callFunc(name, a)
        case .addr(let e): return try eval(e)
        case .deref(let e):
            let p = try eval(e); return (p >= 0 && p < heapUsed) ? Int(heap[p]) : 0
        case .index(let arr, let idx):
            let b = try eval(arr), i = try eval(idx)
            let p = b + i; return (p >= 0 && p < heapUsed) ? Int(heap[p]) : 0
        case .assign(let op, let lhs, let rhs):
            let rv = try eval(rhs)
            if case .ident(let n) = lhs {
                var c = get(n)
                switch op {
                case "=": c = rv; case "+=": c += rv; case "-=": c -= rv
                case "*=": c *= rv; case "/=": c = rv != 0 ? c / rv : 0
                default: c = rv
                }
                set(n, c); return c
            }
            return rv
        case .cast(_, let e): return try eval(e)
        case .sizeof(let t):
            if t.contains("*") { return 8 }
            if t == "int" { return 4 }
            if t == "char" { return 1 }
            return 4
        }
    }


extension CInterpreter.VM {
    private func callFunc(_ name: String, _ args: [Int]) throws -> Int {
        switch name {
        case "printf": return try printf(args)
        case "malloc": return try malloc(args)
        case "free": return 0
        case "strlen":
            let p = args.first ?? 0; var l = 0; var i = p
            while i >= 0 && i < heapUsed && heap[i] != 0 { l += 1; i += 1 }; return l
        case "strcpy":
            guard args.count >= 2 else { return 0 }
            let d = args[0], s = args[1]; var i = 0; var p = s
            while p >= 0 && p < heapUsed && heap[p] != 0 && d + i >= 0 && d + i < heapUsed {
                heap[d + i] = heap[p]; p += 1; i += 1
            }
            if d + i >= 0 && d + i < heapUsed { heap[d + i] = 0 }
            return d
        case "strcmp":
            guard args.count >= 2 else { return 0 }
            let s1 = getString(args[0]), s2 = getString(args[1])
            return s1 == s2 ? 0 : (s1 < s2 ? -1 : 1)
        case "memset":
            guard args.count >= 3 else { return 0 }
            let d = args[0], v = UInt8(args[1] & 0xFF), n = args[2]
            for i in 0..<n { if d + i >= 0 && d + i < heapUsed { heap[d + i] = v } }
            return d
        case "memcpy":
            guard args.count >= 3 else { return 0 }
            let d = args[0], s = args[1], n = args[2]
            for i in 0..<n {
                if s + i >= 0 && s + i < heapUsed && d + i >= 0 && d + i < heapUsed {
                    heap[d + i] = heap[s + i]
                }
            }
            return d
        case "atoi": return Int(getString(args.first ?? 0).trimmingCharacters(in: .whitespaces)) ?? 0
        case "putchar":
            if let c = args.first { output(String(UnicodeScalar(UInt8(c & 0xFF)))) }
            return args.first ?? 0
        case "abs": return args.first.map { abs($0) } ?? 0
        case "getchar": return 0
        default:
            if let fn = functions.first(where: { $0.name == name }) {
                try call(fn, args); return returnValue ?? 0
            }
            return 0
        }
    }

    private func printf(_ args: [Int]) throws -> Int {
        guard !args.isEmpty else { return 0 }
        let fmt = getString(args[0])
        var out = "", ai = 1, i = 0
        let ch = Array(fmt)
        while i < ch.count {
            if ch[i] == "%", i + 1 < ch.count {
                i += 1
                switch ch[i] {
                case "d", "i": out += "\(ai < args.count ? args[ai] : 0)"; ai += 1
                case "u": out += "\(ai < args.count ? args[ai] : 0)"; ai += 1
                case "x": out += String(ai < args.count ? args[ai] : 0, radix: 16); ai += 1
                case "X": out += String(ai < args.count ? args[ai] : 0, radix: 16).uppercased(); ai += 1
                case "o": out += String(ai < args.count ? args[ai] : 0, radix: 8); ai += 1
                case "c": out += String(UnicodeScalar(UInt8((ai < args.count ? args[ai] : 0) & 0xFF))); ai += 1
                case "s": out += getString(ai < args.count ? args[ai] : 0); ai += 1
                case "p": out += "0x" + String(ai < args.count ? args[ai] : 0, radix: 16); ai += 1
                case "l":
                    if i + 1 < ch.count, ch[i + 1] == "d" {
                        out += "\(ai < args.count ? args[ai] : 0)"; ai += 1; i += 1
                    }
                case "%": out += "%"
                default: out += "%" + String(ch[i])
                }
            } else { out += String(ch[i]) }
            i += 1
        }
        output(out); return out.count
    }

    private func malloc(_ args: [Int]) throws -> Int {
        let size = args.first ?? 0
        if size <= 0 || size > interpreter.maxHeap - heapUsed { throw CInterpreterError.memoryLimit }
        let addr = heapUsed; heapUsed += size
        return addr
    }
}
    private func getString(_ p: Int) -> String {
        if p < 0 || p >= heapUsed { return "" }
        var s = ""; var i = p
        while i < heapUsed && heap[i] != 0 { s += String(UnicodeScalar(heap[i])); i += 1 }
        return s
    }
}
                while true {
                    if let c = c, try eval(c) == 0 { break }
                    breaking = false; try exec(b)
                    if returnValue != nil { break }
                    if breaking { breaking = false; break }
                    if continuing { continuing = false }
                    if let st = st { _ = try eval(st) }
                }
            case .do(let b, let c):
                repeat {
                    breaking = false; try exec(b)
                    if returnValue != nil { break }
                    if breaking { breaking = false; break }
                    if continuing { continuing = false }
                    if try eval(c) == 0 { break }
                } while true
            case .return(let e): returnValue = try e.map { try eval($0) } ?? 0
            case .break: breaking = true
            case .continue: continuing = true
            }
        }
    }
}
        while true {
            if case .op(let o) = lexer.current(), o == "[" {
                lexer.advance(); let idx = try tryParseExpr(); try lexer.expectOp("]"); e = .index(e, idx)
            } else if case .op(let o) = lexer.current(), o == "(" {
                if case .ident(let name) = e {
                    lexer.advance(); var args: [Expr] = []
                    if case .op(let o2) = lexer.current(), o2 != ")" {
                        repeat { args.append(try tryParseExpr()) } while matchOp(",")
                    }
                    try lexer.expectOp(")"); e = .call(name, args)
                } else { break }
            } else if case .op(let o) = lexer.current(), o == "++" || o == "--" {
                let op = (case .op(let x) = lexer.current())!; lexer.advance(); e = .unary(op, e)
            } else { break }
        }
        return e
    }

    fileprivate func parsePrimary() throws -> Expr {
        switch lexer.current() {
        case .intLit(let v): lexer.advance(); return .intLit(v)
        case .charLit(let v): lexer.advance(); return .intLit(v)
        case .strLit(let s): lexer.advance(); return .strLit(s)
        case .ident(let n): lexer.advance(); return n == "NULL" ? .intLit(0) : .ident(n)
        case .op(let o) where o == "(":
            lexer.advance()
            if isTypeStart() { let t = try parseType(); try lexer.expectOp(")"); return .cast(t, try parseUnary()) }
            let e = try tryParseExpr(); try lexer.expectOp(")"); return e
        default: throw CInterpreterError.parseError("unexpected token at line \(lexer.curLine())")
        }
    }

    fileprivate func isTypeStart() -> Bool {
        if case .keyword(let k) = lexer.current() { return ["int","char","void"].contains(k) }
        return false
    }

    fileprivate func bin(_ next: () throws -> Expr, _ ops: [String]) rethrows -> Expr {
        var l = try next()
        while case .op(let o) = lexer.current(), ops.contains(o) {
            lexer.advance(); l = .binary(o, l, try next())
        }
        return l
    }
}

    fileprivate func isDeclStart() -> Bool {
        if case .keyword(let k) = lexer.current() { return ["int","char","void"].contains(k) }
        return false
    }

    fileprivate func matchOp(_ s: String) -> Bool {
        if case .op(let o) = lexer.current(), o == s { lexer.advance(); return true }
        return false
    }
}
        }

        private func parseType() throws -> String {
            var t = ""
            if case .keyword(let k) = lexer.current(), ["int","char","void"].contains(k) {
                t = k; lexer.advance()
            } else if case .ident(let n) = lexer.current() {
                t = n; lexer.advance()
            } else {
                throw CInterpreterError.parseError("expected type at line \(lexer.curLine())")
            }
            while case .op(let o) = lexer.current(), o == "*" { t += "*"; lexer.advance() }
            return t
        }

        private func parseBlock() throws -> Stmt {
            try lexer.expectOp("{")
            var stmts: [Stmt] = []
            while case .op(let o) = lexer.current(), o != "}" {
                stmts.append(try parseStmt())
            }
            try lexer.expectOp("}")
            return .block(stmts)
        }
    }
}
        func current() -> Token { (pos < tokens.count) ? tokens[pos] : .eof }
        func advance() -> Token { let t = current(); if pos < tokens.count { pos += 1 }; return t }
        func curLine() -> Int { line }
        func expectOp(_ s: String) throws {
            if case .op(let o) = current(), o == s { advance() }
            else { throw CInterpreterError.parseError("expected '\(s)' at line \(line)") }
        }
        func expectKeyword(_ s: String) throws {
            if case .keyword(let k) = current(), k == s { advance() }
            else { throw CInterpreterError.parseError("expected '\(s)' at line \(line)") }
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        isNumber || ("a"..."f").contains(lowercased().first ?? "\0")
    }
}
            exitCode = 1
        } catch {
            stderr = "Error: \(error.localizedDescription)"
            exitCode = 1
        }
        let duration = Int(start.timeIntervalSinceNow * -1000)
        if stdout.count > maxOutput {
            stdout = String(stdout.prefix(maxOutput)) + "\n... (truncated)"
        }
        return CInterpreterResult(stdout: stdout, stderr: stderr, exitCode: exitCode, durationMs: duration, steps: steps)
    }
}