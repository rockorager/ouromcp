"""Host compatibility fixtures; the Unix service still requires modern MCP."""
import concurrent.futures
import json
import time
import unittest

from support import Bridge, Environment, META, SUB, encode, exposed, tool, wait_for

LEGACY = "2025-11-25"
INIT = {"protocolVersion": LEGACY, "capabilities": {"sampling": {}},
        "clientInfo": {"name": "independent-legacy-fixture", "version": "1"}}


class LegacyBridge(Bridge):
    def send(self, method, params=None, id=None):
        if id is None:
            self.next_id += 1
            id = self.next_id
        message = {"jsonrpc": "2.0", "id": id, "method": method}
        if params is not None:
            message["params"] = params
        self.raw(encode(message))
        return id

    def initialized(self):
        self.raw(encode({"jsonrpc": "2.0", "method": "notifications/initialized"}))


class LegacyTests(unittest.TestCase):
    def setUp(self):
        self.e = Environment()
        self.addCleanup(self.e.close)

    def bridge(self, ready=True):
        b = LegacyBridge(self.e.env, ())
        self.e.bridges.append(b)
        if ready:
            self.assertEqual(b.request("initialize", INIT), {
                "protocolVersion": LEGACY, "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "ouro-mcp", "version": "0.1.0"}})
            b.initialized()
        return b

    def test_handshake_offline_list_and_ping(self):
        self.e.descriptor()
        service = self.e.service()
        b = self.bridge(ready=False)
        # Out-of-order initialized must not make an unnegotiated host ready.
        b.initialized()
        self.assertIn("error", b.response(b.send("tools/list")))
        b.request("initialize", INIT)
        self.e.descriptor([tool("updated")])
        time.sleep(1.2)  # Let the one-second descriptor scan run before ready.
        self.assertEqual(b.request("ping"), {})
        self.assertEqual(b.response(b.send("tools/list"))["error"]["code"], -32600)
        self.assertFalse(b.pending)
        b.initialized()
        self.assertEqual(set(b.request("tools/list")), {"tools"})
        self.assertEqual(b.tools(), {exposed("updated")})
        self.assertEqual(b.request("ping"), {})
        self.assertEqual(service.connections, [])

    def test_malformed_initialize_and_supported_alternative(self):
        for invalid in ({}, INIT | {"protocolVersion": 123}, INIT | {"capabilities": []},
                        INIT | {"clientInfo": {"name": "missing-version"}}, INIT | {"_meta": META}):
            with self.subTest(invalid=invalid):
                b = self.bridge(ready=False)
                self.assertEqual(b.response(b.send("initialize", invalid))["error"]["code"], -32602)
                result = b.request("initialize", INIT | {"protocolVersion": "2099-01-01"})
                self.assertEqual(result["protocolVersion"], LEGACY)
                b.initialized()
                self.assertEqual(b.request("ping"), {})

    def test_modes_cannot_be_changed_or_mixed(self):
        legacy = self.bridge()
        self.assertEqual(legacy.response(legacy.send("initialize", INIT))["error"]["code"], -32600)
        self.assertEqual(legacy.response(legacy.send("tools/list", {"_meta": META}))["error"]["code"], -32602)
        for method in ("server/discover", "subscriptions/listen", "resources/list"):
            self.assertEqual(legacy.response(legacy.send(method))["error"]["code"], -32601)
        self.assertEqual(legacy.response(legacy.send("tools/call", {"name": "x", "task": {}}))["error"]["code"], -32602)
        modern = self.e.bridge()
        self.assertEqual(modern.request("server/discover")["supportedVersions"], ["2026-07-28"])
        modern.raw(encode({"jsonrpc": "2.0", "id": "switch", "method": "initialize", "params": INIT}))
        self.assertEqual(modern.response("switch")["error"]["code"], -32600)
        self.assertEqual(modern.request("tools/list")["resultType"], "complete")

    def test_mixed_hosts_share_cache_and_service_but_not_notification_format(self):
        self.e.descriptor()
        service = self.e.service(delay=.15)
        legacy, modern = self.bridge(), self.e.bridge()
        subscription = modern.listen()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            counts = list(pool.map(lambda b: b.call()["structuredContent"]["count"], (legacy, modern)))
        self.assertEqual(sorted(counts), [1, 2])
        self.assertEqual(service.list_count, 1)
        service.changed([tool(), tool("new")])
        notice = legacy.receive(lambda m: m.get("method") == "notifications/tools/list_changed")
        self.assertEqual(notice, {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        notice = modern.receive(lambda m: m.get("method") == "notifications/tools/list_changed")
        self.assertEqual(notice["params"]["_meta"][SUB], subscription)
        self.assertEqual(legacy.tools(), {exposed("add"), exposed("new")})
        legacy.close()
        self.assertEqual(modern.call(5)["structuredContent"], {"count": 7})

    def test_legacy_dirty_reread_and_numbers(self):
        self.e.descriptor()
        service = self.e.service(delay=.25, call_mode="numbers")
        b = self.bridge()
        numbers = b'[1.0,1e0,999999999999999999999999999999999999,1e999,-0.125]'
        id = 999999999999999999999999999999999997
        b.raw(encode({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {
            "name": exposed("add"), "arguments": {"values": "NUMBERS"},
            "_meta": {"progressToken": "not-forwarded"}}}).replace(b'"NUMBERS"', numbers))
        wait_for(lambda: service.list_count == 1)
        service.changed([tool(), tool("new")])
        response = b.response(id, raw=True)
        self.assertIn(numbers, response)
        self.assertIn(str(id).encode(), response)
        self.assertNotIn(b'"resultType"', response)
        self.assertIn(numbers, service.raw_calls[0])
        self.assertNotIn(b'progressToken', service.raw_calls[0])
        self.assertEqual(service.list_count, 2)
        self.assertEqual(b.tools(), {exposed("add"), exposed("new")})

    def test_cancellation_late_reply_and_error_translation(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        b = self.bridge()
        first = b.send("tools/call", {"name": exposed("add")}, id="cancel-me")
        second = b.send("tools/call", {"name": exposed("add")}, id=0)
        wait_for(lambda: len(service.calls) == 2)
        b.raw(encode({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": first}}))
        wait_for(lambda: service.calls[0]["id"] in service.cancelled)
        self.assertNotIn(service.calls[1]["id"], service.cancelled)
        error = {"code": -32602, "message": "fixture failure", "data": {"nested": 17}}
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[1]["id"], "error": error})
        self.assertEqual(b.response(second), {"jsonrpc": "2.0", "id": 0, "error": error})
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[0]["id"], "result": {"content": []}})
        service.call_mode = "normal"
        self.assertEqual(b.call(7), {"content": [], "structuredContent": {"count": 7}})
        self.assertFalse(any(m.get("id") == first for m, _ in b.pending))

    def test_json_text_and_structured_results_survive_both_host_modes(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        for legacy in (False, True):
            b = self.bridge() if legacy else self.e.bridge()
            for is_error in (False, True):
                with self.subTest(legacy=legacy, is_error=is_error):
                    data = ({"error": {"code": "Failed", "message": 'bad "value"\n\\é'}} if is_error else
                            {"windows": [{"title": 'a "title"\n\\é', "x": -37}], "focused": None,
                             "snapshot": "x" * (300 * 1024)})
                    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
                    expected = {"content": [{"type": "text", "text": text}],
                                "structuredContent": data, "isError": is_error}
                    count = len(service.calls)
                    id = b.send("tools/call", {"name": exposed("add")})
                    wait_for(lambda: len(service.calls) == count + 1)
                    service.send(service.connections[-1], {"jsonrpc": "2.0", "id": service.calls[-1]["id"],
                                 "result": expected | {"resultType": "complete"}})
                    result = b.response(id)["result"]
                    self.assertEqual(result, expected if legacy else expected | {"resultType": "complete"})
                    self.assertEqual(json.loads(result["content"][0]["text"]), result["structuredContent"])
                    if not is_error:
                        self.assertGreater(len(encode({"jsonrpc": "2.0", "id": id, "result": result})), 256 * 1024)
            b.close()

    def test_result_envelope_only_and_no_replay(self):
        self.e.descriptor()
        service = self.e.service(call_mode="silent")
        b = self.bridge()
        id = b.send("tools/call", {"name": exposed("add")})
        wait_for(lambda: len(service.calls) == 1)
        payload = {"content": [{"type": "text", "text": "failure"}], "isError": True,
                   "structuredContent": {"resultType": "application-data", "ttlMs": 17},
                   "_meta": {"fixture": 29}}
        service.send(service.connections[0], {"jsonrpc": "2.0", "id": service.calls[0]["id"],
            "result": payload | {"resultType": "complete", "ttlMs": 3, "cacheScope": "private"}})
        self.assertEqual(b.response(id)["result"], payload)
        service.call_mode = "disconnect"
        self.assertIn("error", b.response(b.send("tools/call", {"name": exposed("add")})))
        self.assertEqual(len(service.calls), 2)
        self.assertEqual(b.request("ping"), {})
