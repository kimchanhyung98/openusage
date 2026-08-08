import Foundation

/// 실행 중인 Codeium 계열 language server(Antigravity 번들 `language_server`, `agy` CLI) 탐지 — 로컬 Connect-RPC 호출용 CSRF token + listening port 반환.
/// Tauri 호스트 `ls.discover`의 Swift port — `ps` 스캔, 이름+marker flag 매칭, argv에서 flag 추출, `lsof`로 port read.
/// 전부 blocking subprocess I/O — `discover`는 main actor 밖에서 호출.
struct LanguageServerDiscovery: Sendable {
    struct Options: Sendable {
        /// 매칭할 실행 파일 이름 (e.g. `language_server`, `agy`).
        var processName: String
        /// `--app_data_dir`/`--ide_name`/`--override_ide_name`에 정확 매칭하는 소문자 marker — 실패 시 `/marker/` 경로 substring fallback, 빈 배열은 "아무 인스턴스나 매칭".
        var markers: [String]
        /// CSRF token 값을 담는 flag (e.g. `--csrf_token`) — 빈 값은 token 없음.
        var csrfFlag: String
        /// HTTP fallback port를 담는 선택적 flag (e.g. `--extension_server_port`).
        var portFlag: String?
    }

    struct Result: Sendable {
        var pid: Int32
        var csrf: String
        var ports: [Int]
        var extensionPort: Int?
    }

    var processRunner: ProcessRunning = SystemProcessRunner()

    func discover(_ options: Options) -> Result? {
        guard let psOutput = try? processRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: [:],
            timeout: 5
        ), psOutput.succeeded else {
            AppLog.warn(.subprocess, "ls discover: ps failed for \(options.processName)")
            return nil
        }

        let candidates = Self.rankedCandidates(psOutput: psOutput.stdout, options: options)
        guard !candidates.isEmpty else {
            AppLog.info(.subprocess, "ls discover: \(options.processName) process not found")
            return nil
        }

        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.fileExists(atPath: $0) }

        for candidate in candidates {
            let csrf: String
            if options.csrfFlag.trimmingCharacters(in: .whitespaces).isEmpty {
                csrf = ""
            } else if let value = Self.extractFlag(command: candidate.command, flag: options.csrfFlag) {
                csrf = value
            } else {
                continue
            }

            let extensionPort = options.portFlag
                .flatMap { Self.extractFlag(command: candidate.command, flag: $0) }
                .flatMap { Int($0) }

            var ports: [Int] = []
            if let lsofPath, let result = try? processRunner.run(
                executable: lsofPath,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                environment: [:],
                timeout: 5
            ), result.succeeded {
                ports = Self.parseListeningPorts(result.stdout)
            }

            if ports.isEmpty && extensionPort == nil {
                continue
            }

            AppLog.info(.subprocess, "ls discover: found \(options.processName) pid=\(candidate.pid) ports=\(ports)")
            return Result(pid: candidate.pid, csrf: csrf, ports: ports, extensionPort: extensionPort)
        }

        return nil
    }

    // MARK: - Pure helpers (port of the Rust host logic; unit-tested directly)

    /// `ps -ax -o pid=,command=` 출력을 process+marker 매칭 candidate로 파싱 — marker rank 순 정렬(정확 flag 매칭이 경로 substring보다 우선).
    static func rankedCandidates(psOutput: String, options: Options) -> [(pid: Int32, command: String)] {
        let processNameLower = options.processName.lowercased()
        let markersLower = options.markers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let spaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let pidString = String(line[..<spaceIndex])
            let command = String(line[line.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidString),
                  commandMatchesProcess(command: command, processNameLower: processNameLower),
                  let rank = markerRank(command: command, markersLower: markersLower)
            else { continue }
            ranked.append((rank, pid, command))
        }

        return ranked
            .sorted { $0.rank < $1.rank }
            .map { (pid: $0.pid, command: $0.command) }
    }

    /// command 문자열에서 CLI flag 값 추출 — `--flag value`와 `--flag=value` 지원.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEq = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flagEq) {
                return String(part.dropFirst(flagEq.count))
            }
        }
        return nil
    }

    /// marker 매칭 우선순위 — 정확한 `--ide_name`/`--override_ide_name`/`--app_data_dir` 값은 rank 0("antigravity"의 "antigravity-next" 오매칭 방지), `/marker/` 경로 substring은 rank 1.
    /// marker 없음은 rank 0(모든 인스턴스 매칭), 무매칭은 nil.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }

        let ideName = extractFlag(command: command, flag: "--ide_name")?.lowercased()
        let overrideIdeName = extractFlag(command: command, flag: "--override_ide_name")?.lowercased()
        let appData = extractFlag(command: command, flag: "--app_data_dir")?.lowercased()
        if ideName != nil || overrideIdeName != nil || appData != nil {
            let matches = markersLower.contains { marker in
                ideName == marker || overrideIdeName == marker || appData == marker
            }
            return matches ? 0 : nil
        }

        let commandLower = command.lowercased()
        let matches = markersLower.contains { commandLower.contains("/\($0)/") }
        return matches ? 1 : nil
    }

    /// 첫 argv token — 따옴표로 감싼 실행 경로 지원.
    static func argv0(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) {
            return String(rest[..<end])
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func commandMatchesProcess(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }

        let exeName = (argv0(command: command) as NSString).lastPathComponent.lowercased()
        if exeName == processNameLower { return true }

        let commandLower = command.lowercased()
        if processNameLower.count >= 8 {
            return exeName.hasPrefix("\(processNameLower)_") || commandLower.contains(processNameLower)
        }
        return commandLower.hasSuffix("/\(processNameLower)")
            || commandLower.contains("/\(processNameLower) ")
            || commandLower.contains("/\(processNameLower)\t")
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN` 출력에서 listening port 파싱 (dedupe, 오름차순).
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            // e.g. "... TCP 127.0.0.1:52168 (LISTEN)" — address:port를 찾아 token 역순 스캔.
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }
}
