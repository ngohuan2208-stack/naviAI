import Foundation

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
                           "!","&","|","^","~","=","(",")","{","}","[","]",";",",",".","?",":"]
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
extension CInterpreter {
    final class Parser {
        let lexer: Lexer
        var functions: [Function] = []

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
            while case .op(let o) = lexer.current(), o != ";" { lexer.advance() }
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

        fileprivate func matchOp(_ s: String) -> Bool {
            if case .op(let o) = lexer.current(), o == s { lexer.advance(); return true }
            return false
        }
    }
}
extension CInterpreter.Parser {
    fileprivate func parseStmt() throws -> Stmt {
        if case .op(let o) = lexer.current(), o == "{" {
            return try parseBlock()
        }
        if case .keyword(let k) = lexer.current() {
            switch k {
            case "if":
                lexer.advance(); try lexer.expectOp("(")
                let cond = try tryParseExpr(); try lexer.expectOp(")")
                let thenS = try parseStmt()
                var elseS: Stmt? = nil
                if case .keyword(let k2) = lexer.current(), k2 == "else" {
                    lexer.advance(); elseS = try parseStmt()
                }
                return .if(cond, thenS, elseS)
            case "while":
                lexer.advance(); try lexer.expectOp("(")
                let cond = try tryParseExpr(); try lexer.expectOp(")")
                return .while(cond, try parseStmt())
            case "for":
                lexer.advance()
                return try parseFor()
            case "do":
                lexer.advance()
                let body = try parseStmt()
                try lexer.expectKeyword("while"); try lexer.expectOp("(")
                let cond = try tryParseExpr()
                try lexer.expectOp(")"); try lexer.expectOp(";")
                return .do(body, cond)
            case "return":
                lexer.advance()
                var e: Expr? = nil
                if case .op(let o) = lexer.current(), o != ";" { e = try tryParseExpr() }
                try lexer.expectOp(";")
                return .return(e)
            case "break": lexer.advance(); try lexer.expectOp(";"); return .break
            case "continue": lexer.advance(); try lexer.expectOp(";"); return .continue
            default: break
            }
        }
        if isDeclStart() { return try parseDecl() }
        let e = try tryParseExpr(); try lexer.expectOp(";"); return .expr(e)
    }

    private func parseFor() throws -> Stmt {
        try lexer.expectOp("(")
        let ini: Stmt?
        if isDeclStart() { ini = try parseDeclNoSemi() }
        else if isExprStart() { ini = .expr(try tryParseExpr()) }
        else { ini = nil }
        try lexer.expectOp(";")
        let co: Expr? = isExprStart() ? try tryParseExpr() : nil
        try lexer.expectOp(";")
        let st: Expr? = isExprStart() ? try tryParseExpr() : nil
        try lexer.expectOp(")")
        return .for(ini, co, st, try parseStmt())
    }

    private func parseDecl() throws -> Stmt {
        let t = try parseType()
        var name = "__v"
        if case .ident(let n) = lexer.current() { lexer.advance(); name = n }
        var ini: Expr? = nil
        if case .op(let o) = lexer.current(), o == "=" { lexer.advance(); ini = try tryParseExpr() }
        try lexer.expectOp(";")
        return .decl(t, name, ini)
    }

    private func parseDeclNoSemi() throws -> Stmt {
        let t = try parseType()
        var name = "__v"
        if case .ident(let n) = lexer.current() { lexer.advance(); name = n }
        var ini: Expr? = nil
        if case .op(let o) = lexer.current(), o == "=" { lexer.advance(); ini = try tryParseExpr() }
        return .decl(t, name, ini)
    }

    private func isDeclStart() -> Bool {
        if case .keyword(let k) = lexer.current() { return ["int","char","void"].contains(k) }
        return false
    }

    private func isExprStart() -> Bool {
        switch lexer.current() {
        case .op(let o): return o != ";" && o != ")"
        case .eof: return false
        default: return true
        }
    }
}
extension CInterpreter.Parser {
    fileprivate func tryParseExpr() throws -> Expr { try parseAssign() }

    fileprivate func parseAssign() throws -> Expr {
        let lhs = try parseTernary()
        if case .op(let o) = lexer.current(), ["=","+=","-=","*=","/="].contains(o) {
            lexer.advance()
            return .assign(o, lhs, try parseAssign())
        }
        return lhs
    }

    fileprivate func parseTernary() throws -> Expr {
        let cond = try parseOr()
        if case .op(let o) = lexer.current(), o == "?" {
            lexer.advance()
            let a = try tryParseExpr()
            try lexer.expectOp(":")
            let b = try parseTernary()
            return .binary("?", cond, .binary(":", a, b))
        }
        return cond
    }

    fileprivate func parseOr()  throws -> Expr { bin(parseAnd, ["||"]) }
    fileprivate func parseAnd() throws -> Expr { bin(parseBitOr, ["&&"]) }
    fileprivate func parseBitOr() throws -> Expr { bin(parseXor, ["|"]) }
    fileprivate func parseXor() throws -> Expr { bin(parseBitAnd, ["^"]) }
    fileprivate func parseBitAnd() throws -> Expr { bin(parseEq, ["&"]) }

    private func parseEq() throws -> Expr {
        var l = try parseComp()
        while case .op(let o) = lexer.current(), ["==","!="].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseComp())
        }
        return l
    }

    private func parseComp() throws -> Expr {
        var l = try parseShift()
        while case .op(let o) = lexer.current(), ["<",">","<=",">="].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseShift())
        }
        return l
    }

    private func parseShift() throws -> Expr {
        var l = try parseAdd()
        while case .op(let o) = lexer.current(), ["<<",">>"].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseAdd())
        }
        return l
    }

    private func parseAdd() throws -> Expr {
        var l = try parseMul()
        while case .op(let o) = lexer.current(), ["+","-"].contains(o) {
            lexer.advance(); l = .binary(o, l, try parseMul())
        }
        return l
    }

    private func parseMul() throws -> Expr {
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
        while true {
            if case .op(let o) = lexer.current(), o == "[" {
                lexer.advance()
                let idx = try tryParseExpr()
                try lexer.expectOp("]")
                e = .index(e, idx)
            } else if case .op(let o) = lexer.current(), o == "(" {
                if case .ident(let name) = e {
                    lexer.advance()
                    var args: [Expr] = []
                    if case .op(let o2) = lexer.current(), o2 != ")" {
                        repeat { args.append(try tryParseExpr()) } while matchOp(",")
                    }
                    try lexer.expectOp(")")
                    e = .call(name, args)
                } else { break }
            } else { break }
        }
        return e
    }

    fileprivate func parsePrimary() throws -> Expr {
        switch lexer.current() {
        case .intLit(let v): lexer.advance(); return .intLit(v)
        case .charLit(let v): lexer.advance(); return .intLit(v)
        case .strLit(let s): lexer.advance(); return .strLit(s)
        case .ident(let n):
            lexer.advance()
            return n == "NULL" ? .intLit(0) : .ident(n)
        case .op(let o) where o == "(":
            lexer.advance()
            if isTypeStart() {
                let t = try parseType()
                try lexer.expectOp(")")
                return .cast(t, try parseUnary())
            }
            let e = try tryParseExpr()
            try lexer.expectOp(")")
            return e
        default:
            throw CInterpreterError.parseError("unexpected token at line \(lexer.curLine())")
        }
    }

    private func isTypeStart() -> Bool {
        if case .keyword(let k) = lexer.current() { return ["int","char","void"].contains(k) }
        return false
    }

    private func bin(_ next: () throws -> Expr, _ ops: [String]) throws -> Expr {
        var l = try next()
        while case .op(let o) = lexer.current(), ops.contains(o) {
            lexer.advance(); l = .binary(o, l, try next())
        }
        return l
    }
}
extension CInterpreter {
    final class VM {
        let interpreter: CInterpreter
        let output: (String) -> Void
        var steps = 0
        var heap: [UInt8] = []
        var heapUsed = 0
        var vars: [[String: Int]] = [[:]]
        var functions: [String: Function] = [:]
        var returnValue: Int? = nil
        var breaking = false
        var continuing = false

        init(interpreter: CInterpreter, output: @escaping (String) -> Void) {
            self.interpreter = interpreter
            self.output = output
        }

        func execute(_ functions: [Function]) throws {
            for f in functions { self.functions[f.name] = f }
            if let main = functions.first(where: { $0.name == "main" }) {
                try call(main, [])
            }
        }

        func checkSteps() throws {
            steps += 1
            if steps > interpreter.maxSteps { throw CInterpreterError.timeout }
        }

        func alloc(_ bytes: Int) throws -> Int {
            let p = heapUsed
            heapUsed += bytes
            if heapUsed > interpreter.maxHeap { throw CInterpreterError.memoryLimit }
            while heap.count < heapUsed { heap.append(0) }
            return p
        }

        func load(_ p: Int) throws -> Int {
            guard p >= 0, p < heap.count else {
                throw CInterpreterError.runtimeError("bad read at \(p)")
            }
            return Int(heap[p])
        }

        func load32(_ p: Int) throws -> Int {
            var v = 0
            for i in 0..<4 { v |= (try load(p + i)) << (i * 8) }
            return v
        }

        func store(_ p: Int, _ v: Int) throws {
            guard p >= 0, p < heap.count else {
                throw CInterpreterError.runtimeError("bad write at \(p)")
            }
            heap[p] = UInt8(v & 0xFF)
        }

        func store32(_ p: Int, _ v: Int) throws {
            for i in 0..<4 { try store(p + i, (v >> (i * 8)) & 0xFF) }
        }

        func lookup(_ name: String) throws -> Int {
            if let v = vars.last?[name] { return v }
            throw CInterpreterError.runtimeError("undefined variable '\(name)'")
        }
    }
}

extension CInterpreter.VM {
    fileprivate func exec(_ s: Stmt) throws {
        checkSteps()
        if returnValue != nil || breaking || continuing { return }
        switch s {
        case .expr(let e): _ = try eval(e)
        case .decl(let t, let n, let ini):
            let v = try ini.map { try eval($0) } ?? 0
            set(n, v); _ = t
        case .block(let ss):
            for s in ss {
                try exec(s)
                if returnValue != nil || breaking || continuing { break }
            }
        case .if(let c, let t, let e):
            if try eval(c) != 0 { try exec(t) } else if let e = e { try exec(e) }
        case .while(let c, let b):
            while try eval(c) != 0 {
                breaking = false
                try exec(b)
                if returnValue != nil { break }
                if breaking { breaking = false; break }
                if continuing { continuing = false }
            }
        case .for(let ini, let cond, let step, let body):
            if let ini = ini { try exec(ini) }
            while true {
                if let c = cond, try eval(c) == 0 { break }
                try exec(body)
                if returnValue != nil { break }
                if breaking { breaking = false; break }
                if continuing { continuing = false }
                if let st = step { _ = try eval(st) }
            }
        case .do(let body, let cond):
            while true {
                try exec(body)
                if returnValue != nil { break }
                if breaking { breaking = false; break }
                if continuing { continuing = false }
                if try eval(cond) == 0 { break }
            }
        case .return(let e):
            returnValue = try e.map { try eval($0) } ?? 0
        case .break: breaking = true
        case .continue: continuing = true
        }
    }
}
extension CInterpreter.VM {
    fileprivate func eval(_ e: Expr) throws -> Int {
        checkSteps()
        switch e {
        case .intLit(let v): return v
        case .strLit(let s):
            let bytes = Array(s.utf8) + [0]
            let p = try alloc(bytes.count)
            for (i, b) in bytes.enumerated() { try store(p + i, Int(b)) }
            return p
        case .ident(let n):
            if n == "NULL" { return 0 }
            return try lookup(n)
        case .unary(let op, let v):
            let x = try eval(v)
            switch op {
            case "-": return -x
            case "!": return x == 0 ? 1 : 0
            case "~": return ~x
            case "&": return x
            case "*": return try load32(x)
            case "++": try assign(valueOf(v), x + 1); return x + 1
            case "--": try assign(valueOf(v), x - 1); return x - 1
            default: throw CInterpreterError.runtimeError("unknown unary op \(op)")
            }
        case .binary(let op, let l, let r):
            switch op {
            case "&&": return try eval(l) != 0 && eval(r) != 0 ? 1 : 0
            case "||": return try eval(l) != 0 || eval(r) != 0 ? 1 : 0
            case "?":
                guard case .binary(":", let tv, let fv) = r else {
                    throw CInterpreterError.runtimeError("malformed conditional")
                }
                return try eval(l) != 0 ? eval(tv) : eval(fv)
            default:
                let a = try eval(l), b = try eval(r)
                return try arith(op, a, b)
            }
        case .assign(let op, let target, let value):
            let v = try eval(value)
            if op == "=" {
                try assignExpr(target, v)
            } else {
                let a = try eval(target)
                try assignExpr(target, try arith(String(op.prefix(1)), a, v))
            }
            return v
        case .call(let name, let args):
            return try callFn(name, args)
        case .addr(let e): return try eval(e)
        case .deref(let e): return try load32(try eval(e))
        case .index(let base, let idx):
            let b = try eval(base), i = try eval(idx)
            return try load32(b + i * 4)
        case .cast(let t, let v):
            let x = try eval(v)
            if t.contains("char") { return x & 0xFF }
            return x
        case .sizeof: return 4
        }
    }

    private func arith(_ op: String, _ a: Int, _ b: Int) throws -> Int {
        switch op {
        case "+": return a + b
        case "-": return a - b
        case "*": return a * b
        case "/": return b == 0 ? 0 : a / b
        case "%": return b == 0 ? 0 : a % b
        case "==": return a == b ? 1 : 0
        case "!=": return a != b ? 1 : 0
        case "<":  return a <  b ? 1 : 0
        case ">":  return a >  b ? 1 : 0
        case "<=": return a <= b ? 1 : 0
        case ">=": return a >= b ? 1 : 0
        case "&":  return a & b
        case "|":  return a | b
        case "^":  return a ^ b
        case "<<": return a << b
        case ">>": return a >> b
        default: throw CInterpreterError.runtimeError("unknown binary op '\(op)'")
        }
    }

    private func valueOf(_ e: Expr) -> String {
        if case .ident(let n) = e { return n }
        return ""
    }

    private func assignExpr(_ target: Expr, _ v: Int) throws {
        switch target {
        case .ident(let n): try assign(n, v)
        case .deref(let p): try store32(try eval(p), v)
        case .index(let base, let idx):
            let b = try eval(base), i = try eval(idx)
            try store32(b + i * 4, v)
        default: throw CInterpreterError.runtimeError("invalid assignment target")
        }
    }

    func assign(_ name: String, _ v: Int) throws {
        if vars.last?[name] != nil { vars[vars.count - 1][name] = v; return }
        vars[vars.count - 1][name] = v
    }

    func set(_ name: String, _ v: Int) { vars[vars.count - 1][name] = v }

    private func call(_ fn: Function, _ args: [Int]) throws {
        var frame: [String: Int] = [:]
        for (i, p) in fn.params.enumerated() { frame[p.1] = i < args.count ? args[i] : 0 }
        vars.append(frame)
        try exec(fn.body)
        vars.removeLast()
    }
}
extension CInterpreter.VM {
    fileprivate func callFn(_ name: String, _ args: [Expr]) throws -> Int {
        checkSteps()
        let argVals = try args.map { try eval($0) }
        switch name {
        case "printf": return try printf(args)
        case "putchar":
            if let c = argVals.first {
                output(String(UnicodeScalar(UInt8(c & 0xFF))))
            }
            return 1
        case "puts":
            if let p = argVals.first { output(readString(p) + "\n") }
            return 0
        case "malloc": return try alloc(argVals.first ?? 0)
        case "calloc":
            let n = argVals.count > 0 ? argVals[0] : 0
            let s = argVals.count > 1 ? argVals[1] : 0
            return try alloc(n * s)
        case "free": return 0
        case "strlen": return argVals.first.map { readString($0).count } ?? 0
        case "strcpy":
            if argVals.count >= 2 {
                let src = readString(argVals[1])
                for (i, b) in Array(src.utf8 + [0]).enumerated() {
                    try store(argVals[0] + i, Int(b))
                }
                return argVals[0]
            }
            return 0
        case "strcmp":
            if argVals.count >= 2 {
                let a = readString(argVals[0]), b = readString(argVals[1])
                if a < b { return -1 } else if a > b { return 1 } else { return 0 }
            }
            return 0
        case "memset":
            if argVals.count >= 3 {
                for i in 0..<argVals[2] { try store(argVals[0] + i, argVals[1] & 0xFF) }
                return argVals[0]
            }
            return 0
        case "memcpy":
            if argVals.count >= 3 {
                for i in 0..<argVals[2] {
                    let b = try load(argVals[1] + i)
                    try store(argVals[0] + i, b)
                }
                return argVals[0]
            }
            return 0
        case "atoi":
            if let p = argVals.first {
                return Int(readString(p).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            return 0
        case "abs": return argVals.first.map { abs($0) } ?? 0
        case "getchar": return 0
        case "exit":
            throw CInterpreterError.runtimeError("exit(\(argVals.first ?? 0))")
        default: break
        }
        if let f = functions[name] {
            try call(f, argVals)
            if let rv = returnValue {
                returnValue = nil
                return rv
            }
            return 0
        }
        throw CInterpreterError.runtimeError("undefined function '\(name)'")
    }
}
extension CInterpreter.VM {
    fileprivate func printf(_ args: [Expr]) throws -> Int {
        guard let fmtExpr = args.first else { return 0 }
        let fmt = try stringOf(fmtExpr)
        var argIdx = 1
        var out = ""
        var i = 0
        while i < fmt.count {
            let c = fmt[fmt.index(fmt.startIndex, offsetBy: i)]
            if c == "%" && i + 1 < fmt.count {
                let next = fmt[fmt.index(fmt.startIndex, offsetBy: i + 1)]
                let spec = String(next)
                if argIdx < args.count {
                    let v = try eval(args[argIdx]); argIdx += 1
                    switch spec {
                    case "d", "i": out += String(v)
                    case "u": out += String(max(0, v))
                    case "c": out += String(UnicodeScalar(v & 0xFF) ?? "?")
                    case "x": out += String(v, radix: 16)
                    case "s": out += readString(v)
                    case "%": out += "%"
                    default: out += String(v)
                    }
                } else { out += "%\(spec)" }
                i += 2
            } else {
                out += String(c); i += 1
            }
        }
        output(out)
        return out.count
    }

    private func stringOf(_ e: Expr) throws -> String {
        if case .strLit(let s) = e { return s }
        let p = try eval(e)
        return readString(p)
    }

    private func readString(_ p: Int) -> String {
        var s = ""
        var i = p
        while i < heap.count, heap[i] != 0 {
            s += String(UnicodeScalar(heap[i]))
            i += 1
        }
        return s
    }
}
