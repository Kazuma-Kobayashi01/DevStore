@testable import DevStoreCore
@testable import DevStoreMCP
import XCTest

final class MCPServerTests: XCTestCase {
    var root: URL!
    var server: MCPServer!
    var paths: DevStorePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devstore-mcp-\(newId())")
        paths = DevStorePaths(hostRoot: root.appendingPathComponent("host"), slotRoot: root.appendingPathComponent("slots"))
        server = MCPServer(library: Library(paths: paths))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func call(_ obj: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let reply = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    func tool(_ name: String, _ args: [String: Any] = [:]) throws -> (isError: Bool, text: String) {
        let r = try call(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": name, "arguments": args]])
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    func testInitializeAndToolList() throws {
        let r = try call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertEqual((r["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.protocolVersion)
        let list = try call(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("devstore_apply"))
        XCTAssertFalse(names.contains { $0.contains("approve") }, "agents must not have an approval tool")
    }

    func testNoToolSchemaAcceptsConfirmation() {
        for t in MCPServer.tools {
            let props = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            XCTAssertFalse(props.keys.contains { $0.lowercased().contains("confirm") || $0.lowercased().contains("approv") })
        }
    }

    func testNotificationGetsNoReply() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testApplyWithoutGrantIsRefused() throws {
        let ops = Operations(library: Library(paths: paths))
        var p = Plan(planId: newId(), action: .mount, level: .mount, targets: ["environmentId": "e1"],
                     preconditions: [], effects: [], notTouched: [], createdAt: timestamp())
        p.planDigest = try p.computedDigest()
        try ops.save(p)
        let r = try tool("devstore_apply", ["planId": p.planId, "confirmed": true])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("not authorized"))
    }

    func testUnknownMethodAndTool() throws {
        XCTAssertNotNil(try call(["jsonrpc": "2.0", "id": 3, "method": "nope"])["error"])
        XCTAssertTrue(try tool("nope").isError)
    }
}
