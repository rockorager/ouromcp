"""Optional real Amp doctor smoke test, with isolated settings and XDG paths."""
import json
import shutil
import subprocess

from support import BIN, Environment, exposed


def main():
    amp = shutil.which("amp")
    if amp is None:
        raise SystemExit("Install Amp to run this optional host compatibility check")
    e = Environment()
    try:
        e.descriptor()
        service = e.service()
        settings = e.root / "settings.json"
        settings.write_text("{}\n")
        command = [amp, "mcp", "doctor", "ouro-bridge", "--settings-file", str(settings),
                   "--mcp-config", json.dumps({"ouro-bridge": {"command": str(BIN), "args": []}})]
        result = subprocess.run(command, cwd=e.root, env=e.env, text=True,
                                capture_output=True, timeout=30)
        output = result.stdout + result.stderr
        print(output, end="")
        # Doctor also exits zero for failed connections; check the status itself.
        assert result.returncode == 0, result.returncode
        assert f"connected (1 tools: {exposed('add')})" in output, output
        assert ": error" not in output, output
        assert not service.connections, "Doctor discovery activated the application"
        print("PASS: Amp connected, discovered the expected tool, and made zero app connections")
    finally:
        e.close()


if __name__ == "__main__":
    main()
