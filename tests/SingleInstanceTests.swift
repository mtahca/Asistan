import Foundation
@main struct SingleInstanceTests {
    static func check(_ value: Bool, line: Int = #line) {
        if !value { print("Tek örnek: satır \(line) başarısız."); exit(1) }
    }
    static func main() {
        let installed = "/Applications/Asistan.app"
        let build = "/Users/m/Documents/Claude/Asistan-0.8/Asistan.app"
        check(SingleInstance.decide(selfPath: installed, others: []) == .run)
        check(SingleInstance.decide(selfPath: build, others: []) == .run)
        // The installed copy takes over from a build copy.
        check(SingleInstance.decide(selfPath: installed, others: [(pid: 42, path: build)]) == .replace([42]))
        // A build copy never runs beside the installed one, or beside another build copy.
        check(SingleInstance.decide(selfPath: build, others: [(pid: 7, path: installed)]) == .quit(installed))
        check(SingleInstance.decide(selfPath: build, others: [(pid: 7, path: build + "2")]) == .quit(build + "2"))
        // A second launch of the installed copy leaves the first one running.
        check(SingleInstance.decide(selfPath: installed, others: [(pid: 7, path: installed)]) == .quit(installed))
        print("Tek örnek testleri geçti.")
    }
}
