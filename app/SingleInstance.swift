import Foundation

/// Two copies of Asistan (the installed one and a build copy) both answered the same call.
/// Only one may run: the copy in /Applications replaces any other; any other copy steps aside.
enum SingleInstance {
    enum Decision: Equatable { case run, replace([Int32]), quit(String) }

    static func installed(_ path: String) -> Bool {
        path.hasPrefix("/Applications/")
    }

    /// `others`: the other running copies with the same bundle ID, as (pid, bundle path).
    static func decide(selfPath: String, others: [(pid: Int32, path: String)]) -> Decision {
        guard !others.isEmpty else { return .run }
        if installed(selfPath), !others.contains(where: { installed($0.path) }) {
            return .replace(others.map { $0.pid })
        }
        return .quit(others[0].path)
    }
}
