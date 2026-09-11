import concurrent.futures
import json
import os
from pathlib import Path
import select
import time
import unittest

from support import APP, META, SUB, Environment, encode, exposed, tool, wait_for


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.e = Environment()
        self.addCleanup(self.e.close)

    def test_offline_precedence_and_no_connect(self):
        self.e.descriptor([tool("system")], system=True)
        top = self.e.descriptor([tool("user")])
        service = self.e.service()
        b = self.e.bridge()
        self.assertEqual(b.tools(), {exposed("user")})
        transformed = b.request("tools/list")["tools"][0]
        self.assertEqual(transformed, tool("user") | {
            "name": exposed("user"), "description": f"[{APP}/user] Independent fixture"})
        self.assertEqual(service.connections, [])
        top.write_text("invalid")
        time.sleep(1.2)
        self.assertEqual(b.tools(), {exposed("user")})
        b.reload()
        self.assertEqual(b.tools(), set())
        top.unlink()
        b.reload()
        self.assertEqual(b.tools(), {exposed("system")})
        self.assertEqual(service.connections, [])

    def test_shared_service_cache_and_eof(self):
        self.e.descriptor()
        service = self.e.service(delay=.15)
        bridges = [self.e.bridge() for _ in range(3)]
        with concurrent.futures.ThreadPoolExecutor() as pool:
            counts = list(pool.map(lambda b: b.call()["structuredContent"]["count"], bridges))
        self.assertEqual(sorted(counts), [1, 2, 3])
        self.assertEqual(service.list_count, 1)
        self.assertEqual(len(service.connections), 3)
        bridges[0].close()
        self.assertEqual(bridges[0].p.returncode, 0)
        self.assertEqual(bridges[1].call(5)["structuredContent"], {"count": 8})

    def test_wire_number_lexemes_and_id_translation(self):
        path = self.e.descriptor()
        path.write_text(path.read_text().replace('"type":"object"', '"type":"object","enum":[1.0,1e0,1e999,-0.125]'))
        service = self.e.service(call_mode="numbers")
        b = self.e.bridge()
        raw_catalog = b.response(b.send("tools/list"), raw=True)
        self.assertIn(b'"enum":[1.0,1e0,1e999,-0.125]', raw_catalog)
        id = 999999999999999999999999999999999997
        request = encode({"jsonrpc": "2.0", "id": id, "method": "tools/call",
                          "params": {"_meta": META, "name": exposed("add"), "arguments": {"values": "NUMBERS"}}})
        numbers = b'[1.0,1e0,999999999999999999999999999999999999,1e999,-0.125]'
        b.raw(request.replace(b'"NUMBERS"', numbers))
        response = b.response(id, raw=True)
        self.assertIn(numbers, response)
        self.assertIn(numbers, service.raw_calls[0])
        self.assertNotEqual(service.calls[0]["id"], id)
        self.assertIn(str(id).encode(), response)

    def test_dirty_reread_and_upstream_notification(self):
        self.e.descriptor()
        service = self.e.service(delay=.25)
        b = self.e.bridge()
        subscription = b.listen()
        id = b.send("tools/call", {"name": exposed("add"), "arguments": {}})
        wait_for(lambda: service.list_count == 1)
        service.changed([tool(), tool("new")])
        self.assertIn("result", b.response(id))
        b.receive(lambda m: m.get("method") == "notifications/tools/list_changed" and m["params"]["_meta"][SUB] == subscription)
        self.assertEqual(service.list_count, 2)
        self.assertEqual(b.tools(), {exposed("add"), exposed("new")})
        offline = self.e.bridge()
        self.assertEqual(offline.tools(), {exposed("add"), exposed("new")})
        self.assertEqual(len(service.connections), 1)

    def test_cancel_translates_id_without_cancelling_other_calls(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        b = self.e.bridge()
        id = b.send("tools/call", {"name": exposed("add"), "arguments": {}}, id="host-request")
        wait_for(lambda: len(service.calls) == 1)
        b.raw(encode({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": id}}))
        wait_for(lambda: service.calls[0]["id"] in service.cancelled)
        service.call_mode = "normal"
        self.assertEqual(b.call(7)["structuredContent"], {"count": 7})

    def test_no_replay_and_bad_app_isolation(self):
        self.e.descriptor()
        bad = self.e.service(call_mode="disconnect")
        other = "dev.test.other"
        self.e.descriptor(app=other)
        self.e.service(app=other)
        b = self.e.bridge()
        result = b.response(b.send("tools/call", {"name": exposed("add"), "arguments": {}}))
        self.assertIn("error", result)
        self.assertEqual(len(bad.calls), 1)
        self.assertEqual(b.call(9, app=other)["structuredContent"], {"count": 9})

    def test_out_of_order_response_ids_and_late_cancelled_reply(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        b = self.e.bridge()
        first = b.send("tools/call", {"name": exposed("add")}, id="first")
        second = b.send("tools/call", {"name": exposed("add")}, id=0)
        wait_for(lambda: len(service.calls) == 2)
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[1]["id"],
            "result": {"content": [], "structuredContent": {"value": 29}}})
        self.assertEqual(b.response(second)["result"]["structuredContent"], {"value": 29})
        b.raw(encode({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": first}}))
        wait_for(lambda: service.calls[0]["id"] in service.cancelled)
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[0]["id"],
            "result": {"content": [], "structuredContent": {"value": 71}}})
        b.request("server/discover")
        self.assertFalse(any(m.get("id") == first for m, _ in b.pending))

    def test_runtime_override_liveness_security_endpoint_and_removal(self):
        self.e.descriptor()
        ticks = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()[19]
        runtime = {"pid": os.getpid(), "start_ticks": ticks}
        p = self.e.descriptor([tool("live")], runtime_dir=True, runtime=runtime)
        b = self.e.bridge()
        self.assertEqual(b.tools(), {exposed("live")})
        p.chmod(0o666)
        b.reload()
        self.assertEqual(b.tools(), {exposed("add")})
        p.chmod(0o600)
        data = json.loads(p.read_text())
        data["endpoint"]["runtime_path"] = "evil"
        p.write_bytes(encode(data))
        b.reload()
        self.assertEqual(b.tools(), {exposed("add")})
        data["endpoint"]["runtime_path"] = "s-" + APP
        data["runtime"]["start_ticks"] = "0"
        p.write_bytes(encode(data))
        b.reload()
        self.assertEqual(b.tools(), {exposed("add")})
        data["runtime"]["start_ticks"] = ticks
        p.write_bytes(encode(data))
        b.reload()
        self.assertEqual(b.tools(), {exposed("live")})
        p.unlink()
        b.reload()
        self.assertEqual(b.tools(), {exposed("add")})

    def test_modern_metadata_and_subscription_capacity(self):
        b = self.e.bridge()
        result = b.request("server/discover")
        self.assertEqual(result["supportedVersions"], ["2026-07-28"])
        id = b.send("tools/list", {"_meta": META | {"io.modelcontextprotocol/protocolVersion": "2025-11-25"}})
        self.assertEqual(b.response(id)["error"]["code"], -32022)
        id = b.send("tools/list", {"_meta": {}})
        self.assertEqual(b.response(id)["error"]["code"], -32602)
        id = b.send("initialize")
        self.assertEqual(b.response(id)["error"]["code"], -32600)
        for _ in range(32):
            b.listen()
        id = b.send("subscriptions/listen", {"notifications": {"toolsListChanged": True}})
        self.assertIn("capacity", b.response(id)["error"]["message"])
        b.close()
        self.assertEqual(b.p.returncode, 0)

    def test_offline_cache_expiry_reverts_without_connecting(self):
        self.e.descriptor()
        service = self.e.service(tools=[tool(), tool("live")], ttl=400)
        active = self.e.bridge()
        active.call()
        offline = self.e.bridge()
        self.assertIn(exposed("live"), offline.tools())
        time.sleep(.5)
        self.assertEqual(offline.tools(), {exposed("add")})
        self.assertEqual(len(service.connections), 1)
        self.assertEqual(service.list_count, 1)

    def test_bad_ack_and_oversize_peer_are_isolated(self):
        self.e.descriptor()
        service = self.e.service(ack="out_of_order")
        b = self.e.bridge()
        self.assertIn("error", b.response(b.send("tools/call", {"name": exposed("add")})))
        self.assertEqual(service.list_count, 0)
        service.ack = "normal"
        service.call_mode = "oversize"
        time.sleep(.15)
        self.assertIn("error", b.response(b.send("tools/call", {"name": exposed("add")})))
        self.assertEqual(b.request("server/discover")["supportedVersions"], ["2026-07-28"])

    def test_runtime_publication_preserves_connection_and_inflight_mutation(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        b = self.e.bridge()
        id = b.send("tools/call", {"name": exposed("add"), "arguments": {"amount": 2}})
        wait_for(lambda: len(service.calls) == 1)
        ticks = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()[19]
        self.e.descriptor(runtime_dir=True, runtime={"pid": os.getpid(), "start_ticks": ticks})
        b.reload()
        self.assertEqual(b.tools(), {exposed("add")})
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[0]["id"],
                     "result": {"content": [], "structuredContent": {"count": 2}}})
        self.assertEqual(b.response(id)["result"]["structuredContent"], {"count": 2})
        service.call_mode = "normal"
        self.assertEqual(b.call(9)["structuredContent"], {"count": 9})
        self.assertEqual(len(service.connections), 1)
        self.assertEqual(len(service.calls), 2)

    def test_explicit_reload_discovers_without_activation_and_notifies(self):
        b = self.e.bridge()
        subscription = b.listen()
        self.assertEqual(b.tools(), set())
        self.assertIn("reload-tools", {t["name"] for t in b.request("tools/list")["tools"]})
        self.e.descriptor([tool("new")])
        service = self.e.service(tools=[tool("new")])
        time.sleep(1.2)
        self.assertEqual(b.tools(), set())
        result = b.reload()
        self.assertEqual(result["structuredContent"], {"applications": 1, "tools": 1, "failures": 0})
        self.assertEqual(json.loads(result["content"][0]["text"]), result["structuredContent"])
        b.receive(lambda m: m.get("method") == "notifications/tools/list_changed" and m["params"]["_meta"][SUB] == subscription)
        self.assertEqual(b.tools(), {exposed("new")})
        b.reload()
        self.assertEqual(service.connections, [])

    def test_reload_invalidates_offline_live_cache_without_connecting(self):
        self.e.descriptor()
        service = self.e.service(tools=[tool(), tool("live")])
        active = self.e.bridge()
        active.call()
        offline = self.e.bridge()
        self.assertEqual(offline.tools(), {exposed("add"), exposed("live")})
        result = offline.reload()
        self.assertEqual(result["structuredContent"], {"applications": 1, "tools": 1, "failures": 0})
        self.assertEqual(offline.tools(), {exposed("add")})
        self.assertEqual(len(service.connections), 1)

    def test_reload_replaces_connected_schema_and_reports_failed_refresh(self):
        self.e.descriptor()
        service = self.e.service()
        b = self.e.bridge()
        b.call()
        changed = tool() | {"inputSchema": {"type": "object", "properties": {"new": {"type": "boolean"}}}}
        service.tools = [changed]
        self.assertFalse(b.reload()["isError"])
        tools = b.request("tools/list")["tools"]
        self.assertEqual(next(t for t in tools if t["name"] == exposed("add"))["inputSchema"], changed["inputSchema"])
        self.assertEqual(service.list_count, 2)
        service.tools = [{"name": "invalid"}]
        result = b.reload()
        self.assertTrue(result["isError"])
        self.assertEqual(result["structuredContent"]["failures"], 1)
        self.assertEqual(json.loads(result["content"][0]["text"]), result["structuredContent"])
        self.assertEqual(len(service.connections), 1)


if __name__ == "__main__":
    unittest.main()
