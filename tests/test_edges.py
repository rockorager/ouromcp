import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import unittest

from support import APP, BIN, META, SUB, Environment, encode, exposed, tool, wait_for


class EdgeTests(unittest.TestCase):
    def setUp(self):
        self.e = Environment()
        self.addCleanup(self.e.close)

    def test_stdio_regular_files_advance_offsets_and_reach_eof(self):
        input_path = self.e.root / "input.jsonl"
        output_path = self.e.root / "output.jsonl"
        input_path.write_bytes(b"".join(encode({"jsonrpc": "2.0", "id": id,
            "method": "server/discover", "params": {"_meta": META}}) for id in range(3)))
        with input_path.open("rb") as source, output_path.open("wb") as destination:
            process = subprocess.run([str(BIN)], env=self.e.env, stdin=source,
                stdout=destination, stderr=subprocess.PIPE, timeout=3)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual([json.loads(line)["id"] for line in output_path.read_bytes().splitlines()], [0, 1, 2])

    def test_held_cache_lock_does_not_block_stdio(self):
        self.e.descriptor()
        service = self.e.service()
        b = self.e.bridge()
        b.call()
        cache = next((self.e.root / "cache/ouro/mcp").glob("*.json"))
        lock = cache.with_suffix(".lock")
        with lock.open("r+") as fd:
            fcntl.flock(fd, fcntl.LOCK_EX)
            cache.unlink()
            id = b.send("tools/call", {"name": exposed("add")})
            start = time.monotonic()
            b.request("server/discover")
            self.assertLess(time.monotonic() - start, .5)
            self.assertEqual(service.list_count, 1)
        self.assertIn("result", b.response(id))
        self.assertEqual(service.list_count, 2)
        self.assertTrue(lock.exists(), "lockfiles must never be unlinked")

    def test_xdg_relative_entries_and_single_data_home_path(self):
        self.e.descriptor([tool("user")])
        self.e.descriptor([tool("system")], system=True)
        b = self.e.bridge(env=self.e.env | {"XDG_DATA_HOME": "relative",
            "XDG_DATA_DIRS": "relative:" + self.e.env["XDG_DATA_DIRS"]})
        self.assertEqual(b.tools(), {exposed("system")})
        colon = self.e.root / "data:with-colon"
        (self.e.root / "data").rename(colon)
        c = self.e.bridge(env=self.e.env | {"XDG_DATA_HOME": str(colon)})
        self.assertEqual(c.tools(), {exposed("user")})

    def test_epoch_prevents_stale_cache_resurrection(self):
        self.e.descriptor()
        service = self.e.service(tools=[tool(), tool("old")])
        active = self.e.bridge()
        active.call()
        cache = next((self.e.root / "cache/ouro/mcp").glob("*.json"))
        stale = cache.read_bytes()
        service.delay = .3
        service.changed([tool(), tool("new")])
        wait_for(lambda: service.list_count == 2)
        # Simulate a pre-invalidation writer replacing the file late.
        cache.write_bytes(stale)
        offline = self.e.bridge()
        self.assertEqual(offline.tools(), {exposed("add")})
        wait_for(lambda: cache.read_bytes() != stale)
        self.assertEqual(offline.tools(), {exposed("add"), exposed("new")})
        self.assertEqual(len(service.connections), 1)

    def test_private_scope_filter_context_corruption_and_jitter(self):
        self.e.descriptor()
        service = self.e.service(tools=[tool(), tool("live")])
        all_apps = self.e.bridge()
        before = time.time() * 1000
        all_apps.call()
        cache = next((self.e.root / "cache/ouro/mcp").glob("*.json"))
        data = json.loads(cache.read_text())
        self.assertEqual(data["cacheScope"], "private")
        self.assertGreaterEqual(data["expires"], before + 53900)
        self.assertLessEqual(data["expires"], time.time() * 1000 + 60000)
        self.assertEqual(cache.stat().st_mode & 0o077, 0)
        restricted = self.e.bridge("--app", APP)
        self.assertEqual(restricted.tools(), {exposed("add")})
        restricted.call()
        self.assertEqual(service.list_count, 2, "different effective exposure contexts cannot share private catalogs")
        cache.write_text("corrupt")
        offline = self.e.bridge()
        self.assertEqual(offline.tools(), {exposed("add")})
        self.assertEqual(service.list_count, 2)

    def test_zero_ttl_and_paginated_expiry_do_not_wake_offline_apps(self):
        self.e.descriptor()
        service = self.e.service(ttl=0)
        active = self.e.bridge()
        active.call()
        active.call()
        self.assertEqual(service.list_count, 2)
        time.sleep(.2)
        self.assertEqual(service.list_count, 2)
        service.list_mode = "pages"
        active.call()
        self.assertEqual(service.list_count, 4)
        offline = self.e.bridge()
        self.assertEqual(offline.tools(), {exposed("add")}, "first page TTL elapsed before last page arrived")
        self.assertEqual(service.list_count, 4)

    def test_cache_number_lexemes_roundtrip(self):
        self.e.descriptor()
        numeric = tool()
        numeric["inputSchema"]["default"] = "LEXEMES"
        service = self.e.service(tools=[numeric])
        numbers = b'[1.0,1e0,999999999999999999999999999999999999,1e999,-0.125]'
        service.replacements[b'"LEXEMES"'] = numbers
        active = self.e.bridge()
        active.call()
        cache = next((self.e.root / "cache/ouro/mcp").glob("*.json"))
        self.assertIn(numbers, cache.read_bytes())
        offline = self.e.bridge()
        wire = offline.response(offline.send("tools/list"), raw=True)
        self.assertIn(numbers, wire)
        self.assertEqual(len(service.connections), 1)

    def test_canonical_catalog_reordering_does_not_notify(self):
        self.e.descriptor()
        service = self.e.service(tools=[tool("other"), tool()])
        b = self.e.bridge()
        b.call()
        b.listen()
        service.changed([dict(reversed(list(tool().items()))), tool("other")])
        wait_for(lambda: service.list_count == 2)
        b.tools()
        self.assertFalse(any(m.get("method") == "notifications/tools/list_changed" for m, _ in b.pending))

    def test_unsupported_and_empty_ack_fallback_without_replay(self):
        self.e.descriptor()
        service = self.e.service(ack="unsupported", ttl=0)
        b = self.e.bridge()
        b.call()
        b.call()
        self.assertEqual(service.list_count, 2)
        b.close()
        service.ack = "empty"
        c = self.e.bridge()
        c.call()
        self.assertEqual(service.list_count, 3)
        self.assertEqual(len(service.calls), 3)

    def test_runtime_symlinks_uninstalled_and_dead_process(self):
        self.e.descriptor()
        child = subprocess.Popen([sys.executable, "-c", "import ctypes,time; ctypes.CDLL(None).prctl(15,b'a ) b) c',0,0,0); print('ready',flush=True); time.sleep(30)"], stdout=subprocess.PIPE)
        self.addCleanup(lambda: child.poll() is None and child.terminate())
        self.assertEqual(child.stdout.readline(), b"ready\n")
        child.stdout.close()
        ticks = Path(f"/proc/{child.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
        runtime = {"pid": child.pid, "start_ticks": ticks}
        path = self.e.descriptor([tool("live")], runtime_dir=True, runtime=runtime)
        self.e.descriptor([tool("uninstalled")], app="uninstalled", runtime_dir=True, runtime=runtime)
        b = self.e.bridge()
        self.assertEqual(b.tools(), {exposed("live")}, "final ')' must delimit /proc stat comm")
        saved = path.with_suffix(".saved")
        path.rename(saved)
        path.symlink_to(saved)
        self.assertEqual(b.tools(), {exposed("add")})
        path.unlink()
        saved.rename(path)
        directory = path.parent
        directory.chmod(0o777)
        self.assertEqual(b.tools(), {exposed("add")})
        directory.chmod(0o700)
        self.assertEqual(b.tools(), {exposed("live")})
        child.terminate()
        child.wait(timeout=3)
        self.assertEqual(b.tools(), {exposed("add")})

    def test_slow_app_capacity_cancellation_and_other_app_isolation(self):
        self.e.descriptor()
        slow = self.e.service(call_mode="silent")
        other = "dev.test.fast"
        self.e.descriptor(app=other)
        self.e.service(app=other)
        b = self.e.bridge()
        ids = [b.send("tools/call", {"name": exposed("add")}) for _ in range(31)]
        self.assertIn("capacity", b.response(ids[-1])["error"]["message"])
        self.assertEqual(b.call(13, app=other)["structuredContent"], {"count": 13})
        wait_for(lambda: len(slow.calls) == 30)
        for id in ids[:-1]:
            b.raw(encode({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": id}}))
        wait_for(lambda: len(slow.cancelled) == 30)
        slow.call_mode = "normal"
        self.assertEqual(b.call(3)["structuredContent"], {"count": 3})

    def test_malformed_oversize_and_output_saturation_are_process_local(self):
        self.e.descriptor()
        healthy = self.e.bridge()
        bad = self.e.bridge()
        bad.raw(b"{invalid}\n")
        self.assertEqual(bad.receive()["error"]["code"], -32700)
        self.assertEqual(bad.tools(), {exposed("add")})
        bad.raw(b"x" * (256 * 1024))
        bad.p.wait(timeout=3)
        self.assertNotEqual(bad.p.returncode, 0)
        self.assertEqual(healthy.tools(), {exposed("add")})
        # Hundreds of requests in a small write create more than the bounded
        # output queue while this host deliberately never reads stdout.
        blocked = self.e.bridge()
        request = encode({"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": META}})
        try:
            blocked.raw(request * 2000)
        except BrokenPipeError:
            pass
        blocked.p.wait(timeout=3)
        self.assertNotEqual(blocked.p.returncode, 0)
        self.assertEqual(healthy.tools(), {exposed("add")})

    def test_catalog_and_pagination_capacity_fail_honestly(self):
        huge = [tool(str(i)) | {"description": "x" * 700} for i in range(200)]
        self.e.descriptor(huge)
        self.e.descriptor(huge, app="another")
        b = self.e.bridge()
        self.assertIn("capacity", b.response(b.send("tools/list"))["error"]["message"])
        self.e.descriptor()
        service = self.e.service(list_mode="cycle")
        reply = b.response(b.send("tools/call", {"name": exposed("add")}))
        self.assertIn("error", reply)
        self.assertEqual(service.list_count, 16)
        self.assertEqual(service.calls, [])

    def test_eof_during_unacknowledged_subscription_does_not_start_list(self):
        self.e.descriptor()
        service = self.e.service(ack="silent")
        b = self.e.bridge()
        b.send("tools/call", {"name": exposed("add")})
        wait_for(lambda: len(service.connections) == 1)
        b.close()
        self.assertEqual(b.p.returncode, 0)
        self.assertEqual(service.list_count, 0)
        self.assertEqual(service.calls, [])

    def test_nonreading_socket_output_capacity_isolated_from_other_app(self):
        self.e.descriptor()
        slow = self.e.service(call_mode="pause_reads")
        other = "dev.test.fast"
        self.e.descriptor(app=other)
        self.e.service(app=other)
        b = self.e.bridge()
        b.call()
        ids = [b.send("tools/call", {"name": exposed("add"), "arguments": {"padding": "x" * 200000}}) for _ in range(7)]
        self.assertIn("error", b.response(ids[0]))
        self.assertEqual(b.call(17, app=other)["structuredContent"], {"count": 17})
        self.assertEqual(len(slow.calls), 1)

    def test_request_and_ack_deadlines_do_not_block_healthy_peer(self):
        self.e.descriptor()
        stalled = self.e.service(call_mode="silent")
        silent_app = "dev.test.noack"
        self.e.descriptor(app=silent_app)
        silent = self.e.service(app=silent_app, ack="silent")
        b = self.e.bridge()
        call = b.send("tools/call", {"name": exposed("add")})
        ack = b.send("tools/call", {"name": exposed("add", silent_app)})
        wait_for(lambda: len(stalled.calls) == 1 and len(silent.connections) == 1)
        started = time.monotonic()
        b.request("server/discover")
        self.assertLess(time.monotonic() - started, .5)
        self.assertIn("deadline", b.response(call, seconds=12)["error"]["message"])
        self.assertIn("deadline", b.response(ack)["error"]["message"])
        wait_for(lambda: stalled.calls[0]["id"] in stalled.cancelled)
        self.assertEqual(silent.list_count, 0)
        self.assertEqual(len(stalled.calls), 1)


if __name__ == "__main__":
    unittest.main()
