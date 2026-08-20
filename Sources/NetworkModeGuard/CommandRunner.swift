import Foundation

struct CommandResult: Equatable, Sendable {
    let output: String
    let error: String
    let status: Int32

    var succeeded: Bool { status == 0 }
}

protocol CommandRunning {
    func run(_ executable: String, arguments: [String]) -> CommandResult
}

struct SystemCommandRunner: CommandRunning {
    func run(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandResult(output: output, error: error, status: process.terminationStatus)
        } catch {
            return CommandResult(output: "", error: error.localizedDescription, status: -1)
        }
    }
}

struct ScriptedCommandRunner: CommandRunning {
    private let responses: [String: CommandResult]

    init(responses: [String: CommandResult]) {
        self.responses = responses
    }

    func run(_ executable: String, arguments: [String]) -> CommandResult {
        responses[Self.key(executable, arguments)] ?? CommandResult(output: "", error: "No scripted response", status: 1)
    }

    static func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }
}
