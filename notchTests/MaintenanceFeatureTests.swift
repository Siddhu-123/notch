import Foundation
import Testing
@testable import notch

struct MaintenanceFeatureTests {
    @Test func cleanupScopeRejectsRootsSystemHomeAndTraversal() {
        let home = "/Users/example"
        let roots = ["/Users/example/Library/Caches", "/Users/example/Documents", "/Applications"]
        #expect(!CleanupScope.isAllowed(path: "/", home: home, roots: roots, resolvedPath: "/"))
        #expect(!CleanupScope.isAllowed(path: "/System", home: home, roots: roots, resolvedPath: "/System"))
        #expect(!CleanupScope.isAllowed(path: home, home: home, roots: roots, resolvedPath: home))
        #expect(!CleanupScope.isAllowed(path: "/Users/example/Library/Caches/../Documents/file", home: home, roots: roots, resolvedPath: "/Users/example/Documents/file"))
        #expect(!CleanupScope.isAllowed(path: "/Users/example/Library/Caches/../../System/file", home: home, roots: roots, resolvedPath: "/System/file"))
    }

    @Test func cleanupScopeAcceptsOnlyDescendantsOfApprovedRoots() {
        let home = "/Users/example"
        let roots = ["/Users/example/Library/Caches", "/Users/example/Documents", "/Applications"]
        #expect(CleanupScope.isAllowed(path: "/Users/example/Library/Caches", home: home, roots: roots, resolvedPath: "/Users/example/Library/Caches"))
        #expect(CleanupScope.isAllowed(path: "/Users/example/Library/Caches/app/file", home: home, roots: roots, resolvedPath: "/Users/example/Library/Caches/app/file"))
        #expect(CleanupScope.isAllowed(path: "/Users/example/Documents/Projects", home: home, roots: roots, resolvedPath: "/Users/example/Documents/Projects"))
        #expect(CleanupScope.isAllowed(path: "/Applications/Example.app", home: home, roots: roots, resolvedPath: "/Applications/Example.app"))
        #expect(!CleanupScope.isAllowed(path: "/Users/example/Library/CachesSibling/file", home: home, roots: roots, resolvedPath: "/Users/example/Library/CachesSibling/file"))
        #expect(!CleanupScope.isAllowed(path: "/Applications/Utilities/Example.app", home: home, roots: roots, resolvedPath: "/Applications/Utilities/Example.app"))
    }

    @Test func cleanupScopeRejectsSymlinksThatResolveOutsideTheirApprovedRoot() {
        let home = "/Users/example"
        let roots = ["/Users/example/Library/Caches", "/Users/example/Documents"]
        #expect(!CleanupScope.isAllowed(
            path: "/Users/example/Library/Caches/Link/private",
            home: home,
            roots: roots,
            resolvedPath: "/Users/example/Documents/private"
        ))
        #expect(CleanupScope.isAllowed(
            path: "/Users/example/Library/Caches/Link/cache",
            home: home,
            roots: roots,
            resolvedPath: "/Users/example/Library/Caches/cache"
        ))
    }

    @Test func leftoverMatcherFindsBundleIdentifiersAndExactAppNames() {
        #expect(LeftoverMatcher.matches(bundleID: "com.example.PhotoDesk", name: "Photo Desk", candidate: "com.example.photodesk.plist"))
        #expect(LeftoverMatcher.matches(bundleID: "com.example.PhotoDesk", name: "Photo Desk", candidate: "Photo Desk"))
        #expect(!LeftoverMatcher.matches(bundleID: "com.example.PhotoDesk", name: "Photo Desk", candidate: "com.other.Calendar"))
        #expect(!LeftoverMatcher.matches(bundleID: "", name: "", candidate: ""))
        #expect(!LeftoverMatcher.matches(bundleID: "com.example.PhotoDesk", name: "Photo Desk", candidate: "Photo Desk Helper"))
        #expect(!LeftoverMatcher.matches(bundleID: "com.example.PhotoDesk", name: "Photo Desk", candidate: "com.example.PhotoDesk2.plist"))
    }

    @Test func maintenanceReplyParserSkipsMalformedRowsAndClampsSizes() {
        let parsed = MaintenanceItem.parse([
            "items": [
                ["path": "/Users/example/Library/Caches/a", "size": 42, "category": "Caches"],
                ["path": "relative/path", "size": 3],
                ["size": 7],
                ["path": "/Users/example/file", "size": -9, "modified": 1_000.0, "group": "g", "canQuit": true]
            ]
        ])
        #expect(parsed.count == 2)
        #expect(parsed[0].path == "/Users/example/Library/Caches/a")
        #expect(parsed[0].size == 42)
        #expect(parsed[0].category == "Caches")
        #expect(parsed[1].size == 0)
        #expect(parsed[1].modified == Date(timeIntervalSince1970: 1_000))
        #expect(parsed[1].group == "g")
        #expect(parsed[1].canQuit)
        #expect(MaintenanceItem.parse(nil).isEmpty)
        #expect(MaintenanceItem.parse(["items": "bad"]).isEmpty)
    }

    @Test func duplicateKeepPolicyKeepsNewestInEveryGroupAndBreaksTiesByPath() {
        let early = Date(timeIntervalSince1970: 10)
        let latest = Date(timeIntervalSince1970: 20)
        let items = [
            MaintenanceItem(path: "/tmp/a", size: 100, group: "one", modified: early),
            MaintenanceItem(path: "/tmp/b", size: 100, group: "one", modified: latest),
            MaintenanceItem(path: "/tmp/c", size: 100, group: "one", modified: latest),
            MaintenanceItem(path: "/tmp/d", size: 80, group: "two", modified: early),
            MaintenanceItem(path: "/tmp/ignored", size: 1, group: "")
        ]
        #expect(DuplicateKeepPolicy.defaultKeepPaths(items) == ["/tmp/b", "/tmp/d"])
        #expect(DuplicateKeepPolicy.defaultKeepPaths([]).isEmpty)
    }
}
