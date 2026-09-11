"""Independent wire fixtures. No bridge code is imported by these tests."""
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time

BIN = Path(os.environ.get("OURO_MCP_BINARY", "zig-out/bin/ouro-mcp")).resolve()
VERSION = "2026-07-28"
META = {"io.modelcontextprotocol/protocolVersion": VERSION,
        "io.modelcontextprotocol/clientCapabilities": {}}
SUB = "io.modelcontextprotocol/subscriptionId"
APP = "dev.test.counter"


def exposed(name, app=APP):
    return "ouro_" + hashlib.sha256((app + "\0" + name).encode()).hexdigest()


def tool(name="add"):
    return {"name": name, "description": "Independent fixture", "inputSchema": {"type": "object"}}


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode() + b"\n"


def wait_for(predicate, seconds=3):
    end = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= end:
            raise AssertionError("condition did not become true")
        time.sleep(.01)


class Environment:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="om-")
        self.root = Path(self.temp.name)
        self.env = os.environ | {"HOME": str(self.root), "XDG_RUNTIME_DIR": str(self.root),
            "XDG_DATA_HOME": str(self.root / "data"), "XDG_DATA_DIRS": str(self.root / "system"),
            "XDG_CACHE_HOME": str(self.root / "cache")}
        self.bridges = []
        self.services = []

    def descriptor(self, tools=None, app=APP, system=False, runtime_dir=False, **extra):
        root = self.root if runtime_dir else self.root / ("system" if system else "data")
        path = root / "ouro/mcp/apps" / (app + ".json")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        value = {"schema_version": 1, "application_id": app,
                 "endpoint": {"runtime_path": "s-" + app}, "tools": tools if tools is not None else [tool()]}
        value.update(extra)
        temp = path.with_suffix(".tmp")
        temp.write_bytes(encode(value))
        temp.replace(path)
        return path

    def bridge(self, *args, env=None):
        bridge = Bridge(env or self.env, args)
        self.bridges.append(bridge)
        return bridge

    def service(self, **options):
        service = Service(self.root, **options)
        self.services.append(service)
        return service

    def close(self):
        for bridge in self.bridges:
            bridge.close()
        for service in self.services:
            service.close()
        self.temp.cleanup()


class Bridge:
    def __init__(self, env, args):
        self.p = subprocess.Popen([str(BIN), *args], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b""
        self.pending = []
        self.next_id = 1000

    def send(self, method, params=None, id=None):
        if id is None:
            self.next_id += 1
            id = self.next_id
        self.raw(encode({"jsonrpc": "2.0", "id": id, "method": method,
                         "params": {"_meta": META} | (params or {})}))
        return id

    def raw(self, wire):
        self.p.stdin.write(wire)
        self.p.stdin.flush()

    def receive(self, predicate=lambda m: True, seconds=5, raw=False):
        end = time.monotonic() + seconds
        while True:
            for i, (message, wire) in enumerate(self.pending):
                if predicate(message):
                    self.pending.pop(i)
                    return wire if raw else message
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                assert len(line) + 1 <= 4 * 1024 * 1024
                self.pending.append((json.loads(line), line))
                continue
            left = end - time.monotonic()
            assert left > 0 and select.select([self.p.stdout], [], [], left)[0], self.pending
            block = os.read(self.p.stdout.fileno(), 65536)
            assert block, self.p.stderr.read().decode()
            self.buffer += block

    def response(self, id, **kwargs):
        return self.receive(lambda m: m.get("id") == id, **kwargs)

    def request(self, method, params=None):
        reply = self.response(self.send(method, params))
        assert "error" not in reply, reply
        return reply["result"]

    def call(self, amount=1, app=APP, name="add"):
        return self.request("tools/call", {"name": exposed(name, app), "arguments": {"amount": amount}})

    def tools(self):
        return {t["name"] for t in self.request("tools/list")["tools"]}

    def listen(self):
        id = self.send("subscriptions/listen", {"notifications": {"toolsListChanged": True}})
        ack = self.receive(lambda m: m.get("method") == "notifications/subscriptions/acknowledged")
        assert ack["params"]["_meta"][SUB] == id
        assert ack["params"]["notifications"] == {"toolsListChanged": True}
        return id

    def close(self):
        if not self.p.stdin.closed:
            self.p.stdin.close()
        try:
            self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait(timeout=3)
            raise AssertionError("bridge did not exit on EOF")
        self.p.stdout.close()
        self.p.stderr.close()


class Service:
    def __init__(self, root, app=APP, tools=None, ttl=60000, delay=0, ack="normal", call_mode="normal", list_mode="normal"):
        self.path = root / ("s-" + app)
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(self.path))
        self.socket.listen()
        self.socket.settimeout(.1)
        self.tools = tools if tools is not None else [tool()]
        self.ttl = ttl
        self.delay = delay
        self.ack = ack
        self.call_mode = call_mode
        self.list_mode = list_mode
        self.replacements = {}
        self.counter = 0
        self.list_count = 0
        self.connections = []
        self.subscriptions = []
        self.calls = []
        self.cancelled = []
        self.raw_calls = []
        self.errors = []
        self.closed = False
        self.lock = threading.Lock()
        self.resume_reads = threading.Event()
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.closed:
            try:
                conn, _ = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections.append(conn)
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def send(self, conn, value):
        wire = encode(value)
        for before, after in self.replacements.items():
            wire = wire.replace(before, after)
        with self.lock:
            conn.sendall(wire)

    def serve(self, conn):
        try:
            with conn.makefile("rb") as stream:
                for raw in stream:
                    if not raw.endswith(b"\n"):
                        return
                    request = json.loads(raw)
                    method = request["method"]
                    p = request.get("params", {})
                    if method == "notifications/cancelled":
                        self.cancelled.append(p["requestId"])
                        continue
                    assert p["_meta"]["io.modelcontextprotocol/protocolVersion"] == VERSION
                    assert p["_meta"]["io.modelcontextprotocol/clientCapabilities"] == {}
                    id = request["id"]
                    if method == "subscriptions/listen":
                        if self.ack == "silent":
                            continue
                        if self.ack == "unsupported":
                            self.send(conn, {"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": "unsupported"}})
                            continue
                        self.subscriptions.append((conn, id))
                        name = "notifications/tools/list_changed" if self.ack == "out_of_order" else "notifications/subscriptions/acknowledged"
                        filters = {} if self.ack == "empty" else {"toolsListChanged": True}
                        self.send(conn, {"jsonrpc": "2.0", "method": name,
                                        "params": {"_meta": {SUB: id}, "notifications": filters}})
                    elif method == "tools/list":
                        self.list_count += 1
                        snapshot = list(self.tools)
                        time.sleep(self.delay)
                        result = {"resultType": "complete", "tools": snapshot,
                                  "ttlMs": self.ttl, "cacheScope": "private"}
                        if self.list_mode == "pages":
                            if "cursor" not in p:
                                result |= {"tools": [tool()], "ttlMs": 100, "nextCursor": "second"}
                            else:
                                assert p["cursor"] == "second"
                                time.sleep(.2)
                                result |= {"tools": [tool("second")], "ttlMs": 60000}
                        elif self.list_mode == "cycle":
                            result |= {"tools": [tool(str(self.list_count))], "nextCursor": "again"}
                        self.send(conn, {"jsonrpc": "2.0", "id": id, "result": result})
                    elif method == "tools/call":
                        self.calls.append(request)
                        self.raw_calls.append(raw)
                        if self.call_mode == "silent":
                            continue
                        if self.call_mode == "disconnect":
                            conn.shutdown(socket.SHUT_RDWR)
                            return
                        if self.call_mode == "numbers":
                            conn.sendall(b'{"jsonrpc":"2.0","id":' + str(id).encode() + b',"result":{"content":[],"structuredContent":{"values":[1.0,1e0,999999999999999999999999999999999999,1e999,-0.125]}}}\n')
                            continue
                        if self.call_mode == "oversize":
                            conn.sendall(b"x" * (4 * 1024 * 1024))
                            continue
                        self.counter += p.get("arguments", {}).get("amount", 0)
                        self.send(conn, {"jsonrpc": "2.0", "id": id, "result": {
                            "resultType": "complete", "content": [], "structuredContent": {"count": self.counter}}})
                        if self.call_mode == "pause_reads":
                            self.resume_reads.wait(30)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        except Exception as error:
            self.errors.append(error)

    def changed(self, tools):
        self.tools = tools
        for conn, id in self.subscriptions:
            try:
                self.send(conn, {"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                                 "params": {"_meta": {SUB: id}}})
            except OSError:
                pass

    def close(self):
        self.closed = True
        self.resume_reads.set()
        for conn in self.connections:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
        self.socket.close()
        self.thread.join(timeout=1)
        assert not self.errors, self.errors
