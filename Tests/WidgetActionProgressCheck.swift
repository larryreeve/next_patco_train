#if SWIFT_PACKAGE
@testable import PATCOLogic
#endif
import Foundation

struct WidgetActionProgressCheck {
    static func run() throws {
        if CommandLine.arguments.count == 2 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            print(WidgetActionProgress.begin(.refresh, directory: root) == nil ? "busy" : "started")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        precondition(WidgetActionProgress.current(now: now, directory: root) == nil)
        let first = WidgetActionProgress.begin(.reverse, now: now, directory: root)!
        precondition(WidgetActionProgress.current(now: now, directory: root) == first)
        precondition(WidgetActionProgress.begin(.mode, now: now, directory: root) == nil)
        precondition(first.isActive(at: now.addingTimeInterval(29)))
        precondition(!first.isActive(at: now.addingTimeInterval(30)))
        precondition(!first.isActive(at: now.addingTimeInterval(-1)))
        precondition(first.permitsWork(reserving: 8, at: now))
        precondition(first.permitsWork(reserving: 8, at: now.addingTimeInterval(15)))
        precondition(!first.permitsWork(reserving: 8, at: now.addingTimeInterval(16)))
        precondition(!first.permitsWork(at: now.addingTimeInterval(24)))
        precondition(!first.permitsWork(at: now.addingTimeInterval(-1)))
        precondition(WidgetActionProgress.current(now: now.addingTimeInterval(30), directory: root) == nil)
        let replacement = WidgetActionProgress.begin(.mode, now: now.addingTimeInterval(31), directory: root)!
        WidgetActionProgress.finish(first, directory: root)
        precondition(WidgetActionProgress.current(now: now.addingTimeInterval(31), directory: root) == replacement)
        WidgetActionProgress.finish(replacement, directory: root)
        precondition(WidgetActionProgress.current(now: now.addingTimeInterval(31), directory: root) == nil)

        let workers = try (0..<6).map { _ -> (Process, Pipe) in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [root.path]
            process.standardOutput = pipe
            try process.run()
            return (process, pipe)
        }
        let results = workers.map { process, pipe in
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        }
        precondition(results.filter { $0.contains("started") }.count == 1)
        let source = try SourceInspection.widget()
        let refresh = source.components(separatedBy: "private enum WidgetInteractiveRefresh {")[1]
            .components(separatedBy: "struct RefreshPATCOWidgetIntent")[0]
        precondition(!refresh.contains("for _ in"))
        precondition(refresh.contains("WidgetActionProgress.current()?.id == progress.id"))
        precondition(refresh.contains("canContinue(reserving: 8)"))
        precondition(source.contains("let effectiveLocation = WidgetRefreshState.guidanceAllowed"))
        precondition(source.contains("let reachabilityMode = !WidgetRefreshState.guidanceAllowed ? nil"))
        precondition(source.contains("mode ?? .driving"))
        precondition(source.contains(".disabled(!WidgetReachabilitySettings.isEnabled || self.mode == nil)"))
        for kind in ["reverse", "mode", "refresh"] {
            precondition(source.contains("WidgetActionProgress.begin(.\(kind))"))
            precondition(source.contains("Toggle(isOn: workingAction == .\(kind), intent:"))
        }
        precondition(source.components(separatedBy: ".toggleStyle(WidgetActionProgressStyle(size: size))").count == 4)
        let style = source.components(separatedBy: "private struct WidgetActionProgressStyle: ToggleStyle")[1]
            .components(separatedBy: "struct NextPATCOTrainHomeWidget")[0]
        precondition(style.contains("configuration.isOn.toggle()"))
        precondition(style.contains("Image(systemName: \"hourglass\").opacity(configuration.isOn ? 1 : 0)"))
        precondition(!style.contains(".disabled("), "Optimistic feedback must not latch controls disabled")
        precondition(!style.contains("@State"), "Pending state must reset from the delivered timeline")
        precondition(source.components(separatedBy: "WidgetActionProgress.finish(progress)").count == 4)
        precondition(source.contains("progress.map { [$0.expiresAt] }"))
        precondition(source.contains("$0.isActive(at: entryDate) ? $0.kind : nil"))
        precondition(!source.contains("Toggle(isOn: false, intent:"))
        print("Widget action progress checks passed: completion, timeout, stale completion, clock rollback and six concurrent processes")
    }
}
