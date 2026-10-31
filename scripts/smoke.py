#!/usr/bin/env python3
"""Exercise the installed CLI with generated audio; uses Python's standard library."""
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import wave

binary = str(Path(sys.argv[1]).resolve())


def run(*args, code=0):
    result = subprocess.run([binary, *map(str, args)], text=True, capture_output=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result


assert "USAGE" in run("--help").stdout
assert run("--version").stdout.startswith("sing ")
info = json.loads(run("info", "--json").stdout)
assert info["component"] == "aufx/vois/appl"

with tempfile.TemporaryDirectory(prefix="sing-smoke-") as temporary:
    directory = Path(temporary)
    source = directory / "input with spaces.wav"
    with wave.open(str(source), "wb") as audio:
        audio.setparams((2, 2, 44100, 0, "NONE", "not compressed"))
        audio.writeframes(b"".join(
            struct.pack("<hh", int(6000 * math.sin(i * .03)), int(5000 * math.cos(i * .04)))
            for i in range(22051)
        ))
    original = source.read_bytes()
    output = directory / "voice.wav"
    result = json.loads(run("vocals", source, "-o", output, "--json").stdout)
    assert result["frames"] == 22051
    assert result["sampleRate"] == 44100 and result["channels"] == 2
    assert result["output"] == str(output)
    assert output.read_bytes()[:4] == b"RIFF"
    saved = output.read_bytes()

    failed = run("vocals", source, "-o", output, "--json", code=1)
    error = json.loads(failed.stderr)
    assert error["exitCode"] == 1 and not failed.stdout
    assert output.read_bytes() == saved

    failed = run("process", source, "-o", output, "--mix", "nan", "--json", code=2)
    assert json.loads(failed.stderr)["exitCode"] == 2
    assert output.read_bytes() == saved
    run("vocals", source, "-o", output, "--force", "--quality", "standard", "--json")
    assert source.read_bytes() == original

    if info["mix"]["minimum"] <= -100:
        run("instrumental", source, "-o", directory / "backing.wav", "--json")
    run("process", source, "-o", directory / "blend.wav", "--mix", "-60", "--json",
        code=0 if info["mix"]["minimum"] <= -60 else 1)
    run("info", "--quality", "standard", code=2)
    run("process", source, "-o", output, code=2)
    run("vocals", source, "-o", output, "--mix", "50", code=2)

print("CLI smoke test passed.")
