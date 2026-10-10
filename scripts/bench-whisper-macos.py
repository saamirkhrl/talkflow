#!/usr/bin/env python3
"""Measures one whisper-server setup: latency, word error rate and memory.

    scripts/bench-whisper-macos.py <name> <whisper-server> <model.bin> [server args...]

For example, the live engine and the final-pass engine as the app runs them:

    scripts/bench-whisper-macos.py small .build/whisper-engine/whisper-server \\
        ~/Library/Application\\ Support/TalkFlow/models/ggml-small.en-q5_1.bin
    scripts/bench-whisper-macos.py turbo .build/whisper-engine/whisper-server \\
        ~/Library/Application\\ Support/TalkFlow/models/ggml-large-v3-turbo-q5_0.bin

Starts the server on port 8197 (not 8178/8179, which a running talkflow
uses), sends every clip three times through /inference with the app's kind of
prompt, and prints one JSON line: time to first answer, footprint (what
Activity Monitor calls Memory) at start and after the run, mean word error
rate, and median latency per clip length. The line, with every transcript,
is also appended to .build/whisper-bench/results.jsonl.

The clips are spoken by macOS's `say` (3s, 11s, 30s and 45s, several voices)
and made once into .build/whisper-bench. Synthetic speech is cleaner than a
real voice, so the error rates are for comparing setups with each other,
not a measure of real dictation.
"""
import json, os, re, statistics, subprocess, sys, time, urllib.request, uuid, wave

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(PROJECT, ".build", "whisper-bench")
PORT = 8197
PROMPT = "I'm Samir, and I use talkflow, a dictation app."

CLIPS = [
    ("short_daniel", "Daniel", "Can you send me the report by Friday afternoon?"),
    ("short_samantha", "Samantha", "Remind me to call the dentist tomorrow morning at nine."),
    ("short_flo", "Flo (English (US))", "Thanks for the update, that sounds great to me."),
    ("medium_daniel", "Daniel", "Hi Sarah, I wanted to follow up on our meeting from last week. We agreed to move the launch to the second week of November, so the design team has a little more time to finish the onboarding screens."),
    ("medium_samantha", "Samantha", "The new build fixes the crash when you open settings, it keeps your permissions after an update, and the dashboard loads about twice as fast as before. Please test it on your machine and let me know what you find."),
    ("medium_eddy", "Eddy (English (US))", "I think we should keep the pricing simple. One free plan with a weekly limit, and one paid plan that removes the limit and adds the cloud transcription option for people who want it."),
    ("long_daniel", "Daniel", "Good morning everyone. I want to give a quick update on where we are with the project. Over the last two weeks we rewrote the speech engine so that it uses much less memory, which matters a lot on older laptops with only eight gigabytes. We also fixed several bugs that customers reported, including one where text was typed into the wrong window after switching apps. Next week we will focus on the Windows version, and after that we plan to look at support for more languages. If you have questions, send them to me before Thursday so I can answer them at the review meeting."),
    ("long_samantha", "Samantha", "Dear Michael, thank you for taking the time to meet with us yesterday. As we discussed, our team can deliver the first version of the integration by the end of the month, provided we receive access to the test environment this week. We will share a short written plan with milestones, costs, and the names of the people responsible for each part. Please let me know if anything in the plan needs to change, and whether your legal team needs to review the contract before we start. I look forward to working together. Best regards, Anna."),
]


def make_clips():
    """Writes each clip as 16 kHz mono WAV, plus a 45s one made of two."""
    os.makedirs(WORK, exist_ok=True)
    references = {}
    for clip, voice, text in CLIPS:
        references[clip] = text
        wav = os.path.join(WORK, clip + ".wav")
        if os.path.exists(wav):
            continue
        aiff = os.path.join(WORK, clip + ".aiff")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
        os.remove(aiff)
    references["xlong_45s"] = references["long_daniel"] + " " + references["medium_daniel"]
    joined = os.path.join(WORK, "xlong_45s.wav")
    if not os.path.exists(joined):
        frames, params = b"", None
        for part in ("long_daniel", "medium_daniel"):
            with wave.open(os.path.join(WORK, part + ".wav")) as w:
                params = w.getparams()
                frames += w.readframes(w.getnframes())
        with wave.open(joined, "wb") as w:
            w.setparams(params)
            w.writeframes(frames)
    return references


def words(text):
    text = re.sub(r"[^a-z0-9' ]", " ", text.lower().replace("-", " "))
    return text.split()


def word_error_rate(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        previous, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            current = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, previous + (r[i - 1] != h[j - 1]))
            previous = current
    return d[len(h)] / max(len(r), 1)


def transcribe(wav_path):
    boundary = "b" + uuid.uuid4().hex
    with open(wav_path, "rb") as f:
        audio = f.read()
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
            f"Content-Type: audio/wav\r\n\r\n").encode() + audio + (
            f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{PROMPT}\r\n--{boundary}--\r\n").encode()
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}/inference", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    started = time.time()
    text = urllib.request.urlopen(request, timeout=120).read().decode()
    return time.time() - started, " ".join(text.split())


def answering():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=1)
        return True
    except Exception:
        return False


def footprint_mb(pid):
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"phys_footprint:\s+([\d.]+)\s*(KB|MB|GB)", out)
    if match is None:
        return float("nan")
    value, unit = float(match.group(1)), match.group(2)
    return value * 1024 if unit == "GB" else value / 1024 if unit == "KB" else value


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    name, binary, model, *extra = sys.argv[1:]
    references = make_clips()
    if answering():
        sys.exit(f"error: something already answers on port {PORT}")
    log = open(os.path.join(WORK, f"server-{name}.log"), "w")
    started = time.time()
    server = subprocess.Popen([binary, "-m", model, "--host", "127.0.0.1", "--port", str(PORT), "-nt", *extra],
                              stdout=log, stderr=log)
    try:
        while not answering():
            if server.poll() is not None:
                sys.exit(f"error: whisper-server exited, see {log.name}")
            time.sleep(0.05)
        first_answer = time.time() - started
        loaded = footprint_mb(server.pid)
        transcribe(os.path.join(WORK, "short_daniel.wav"))  # warm-up
        clips = {}
        for clip in sorted(references):
            latencies, text = [], ""
            for _ in range(3):
                seconds, text = transcribe(os.path.join(WORK, clip + ".wav"))
                latencies.append(seconds)
            clips[clip] = {"median_s": round(statistics.median(latencies), 3),
                           "wer": round(word_error_rate(references[clip], text), 3), "text": text}
        by_length = lambda prefix: round(statistics.mean(c["median_s"] for k, c in clips.items() if k.startswith(prefix)), 3)
        result = {
            "name": name, "model": os.path.basename(model), "args": extra,
            "first_answer_s": round(first_answer, 2),
            "footprint_loaded_mb": round(loaded), "footprint_after_mb": round(footprint_mb(server.pid)),
            "wer_mean": round(statistics.mean(c["wer"] for c in clips.values()), 4),
            "latency_3s": by_length("short"), "latency_11s": by_length("medium"),
            "latency_30s": by_length("long"), "latency_45s": clips["xlong_45s"]["median_s"],
        }
        print(json.dumps(result))
        with open(os.path.join(WORK, "results.jsonl"), "a") as out:
            out.write(json.dumps({**result, "clips": clips}) + "\n")
    finally:
        server.terminate()
        server.wait()


if __name__ == "__main__":
    main()
