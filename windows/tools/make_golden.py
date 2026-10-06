#!/usr/bin/env python3
"""Records the Mac app's own output for every transcript in tests/golden/corpus.json.

The Windows rule tests compare against these, so "identical output" is checked
against what the Mac binary actually does rather than against a reading of it.
Run on a Mac after changing a rule or the corpus:

    swift build
    python3 windows/tools/make_golden.py [path/to/talkflowd]

It calls `talkflowd --formattest "<text>"` once per input (the same
Dictation.render the hotkey uses) and writes tests/golden/render.json.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GOLDEN = ROOT / "windows/tests/golden"


def main() -> None:
    binary = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build/debug/talkflowd")
    out_file = pathlib.Path(tempfile.gettempdir()) / "talkflow-formattest.txt"
    corpus = json.loads((GOLDEN / "corpus.json").read_text(encoding="utf-8"))
    cases = []
    for text in corpus:
        if out_file.exists():
            out_file.unlink()
        subprocess.run([binary, "--formattest", text], check=True, env={**os.environ})
        raw = out_file.read_text(encoding="utf-8")
        _, _, rendered = raw.partition("\n")
        cases.append({"input": text, "expected": rendered})
    (GOLDEN / "render.json").write_text(json.dumps(cases, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(cases)} cases to {(GOLDEN / 'render.json').relative_to(ROOT)}")

    # Apple's sentence splits, for the splitter that stands in for NLTokenizer.
    with tempfile.TemporaryDirectory() as work:
        tool = pathlib.Path(work) / "sentences"
        subprocess.run(["swiftc", "-O", str(ROOT / "windows/tools/sentences.swift"), "-o", str(tool)], check=True)
        inputs = corpus + json.loads((GOLDEN / "sentences-extra.json").read_text(encoding="utf-8"))
        result = subprocess.run([str(tool)], input=json.dumps(inputs).encode(), capture_output=True, check=True)
    splits = json.loads(result.stdout)
    (GOLDEN / "sentences.json").write_text(json.dumps(splits, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(splits)} cases to {(GOLDEN / 'sentences.json').relative_to(ROOT)}")


if __name__ == "__main__":
    main()
