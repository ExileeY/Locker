import Foundation
import XCTest

enum TestSupport {
    static func tempDir() -> String {
        let p = NSTemporaryDirectory() + "locker-tests-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return String(cString: realpath(p, nil))
    }

    static func makeRepo(named name: String, in parent: String) -> Repo {
        let path = parent + "/" + name
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let g = GitClient()
        try! g.run(["init", "-q", "-b", "main"], in: path)
        try! g.run(["config", "user.email", "t@t.t"], in: path)
        try! g.run(["config", "user.name", "t"], in: path)
        try! "hi".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        try! g.run(["add", "."], in: path)
        try! g.run(["commit", "-q", "-m", "init"], in: path)
        return Repo(name: name, path: path, defaultBranch: "main")
    }

    /// Clones `upstream` so the result has an `origin` remote with `origin/main`.
    static func makeClone(of upstream: Repo, named name: String, in parent: String) -> Repo {
        let path = parent + "/" + name
        let g = GitClient()
        try! g.run(["clone", "-q", upstream.path, path], in: parent)
        try! g.run(["config", "user.email", "t@t.t"], in: path)
        try! g.run(["config", "user.name", "t"], in: path)
        return Repo(name: name, path: path, defaultBranch: "main")
    }
}
