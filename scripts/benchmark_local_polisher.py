#!/usr/bin/env python3
"""Repeatable warm-latency/output benchmark for installed local MLX models."""
import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import time

ROOT = Path.home() / "Library/Application Support/Typer/MLX"
MODELS = {
    "qwen025": ("mlx-community/Qwen2.5-0.5B-Instruct-4bit", "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"),
    "smollm2": ("mlx-community/SmolLM2-360M-Instruct-6bit", "642affd1f9e387d1b56c745894afc83795aebe1d"),
}


def error_rate(reference, output):
    left, right = list(reference), list(output)
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (a != b)))
        previous = current
    return previous[-1] / max(1, len(left))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=MODELS, action="append")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--dataset", default=str(Path(__file__).resolve().parents[1] / "Resources/polisher_benchmark.json"))
    args = parser.parse_args()
    dataset = json.loads(Path(args.dataset).read_text(encoding="utf-8"))
    results = {"machine": subprocess.check_output(["/usr/bin/uname", "-m"], text=True).strip(),
               "models": {}}
    for key in args.model or list(MODELS):
        repo, revision = MODELS[key]
        model_dir = ROOT / "models" / key
        worker = ROOT / "mlx_worker.py"
        python = ROOT / "venv/bin/python3"
        if not (model_dir / "config.json").exists():
            raise SystemExit(f"Model not installed: {key}; run the app's explicit model setup first")
        env = dict(os.environ, HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
        child_usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        process = subprocess.Popen([str(python), str(worker), "--model", repo, "--revision", revision,
                                    "--model-dir", str(model_dir)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True, bufsize=1, env=env)
        startup_start = time.perf_counter()
        ready = json.loads(process.stdout.readline())
        startup = time.perf_counter() - startup_start
        if ready.get("ready") is not True:
            raise SystemExit(f"Worker did not become ready: {ready}")
        samples = []
        times = []
        first_token_times = []
        try:
            for case in dataset:
                repeats = []
                final = ""
                for _ in range(args.repeats):
                    start = time.perf_counter()
                    process.stdin.write(json.dumps({"transcript": case["input"]}, ensure_ascii=False) + "\n")
                    process.stdin.flush()
                    response = json.loads(process.stdout.readline())
                    repeats.append(time.perf_counter() - start)
                    if "error" in response:
                        raise RuntimeError(response["error"])
                    final = response["text"]
                    if response.get("first_token_seconds") is not None:
                        first_token_times.append(response["first_token_seconds"])
                times.extend(repeats)
                samples.append({"input": case["input"], "reference": case["reference"],
                                "output": final, "warm_latency_seconds": repeats})
        finally:
            try:
                process.stdin.write('{"command":"shutdown"}\n')
                process.stdin.flush()
            except BrokenPipeError:
                pass
            process.terminate()
            process.wait(timeout=10)
        child_usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        ordered = sorted(times)
        p95 = ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]
        wer = sum(error_rate(s["reference"].lower().split(), s["output"].lower().split()) for s in samples) / len(samples)
        cer = sum(error_rate(s["reference"], s["output"]) for s in samples) / len(samples)
        results["models"][key] = {"repository": repo, "revision": revision,
            "cold_worker_startup_seconds": startup, "warm_median_seconds": statistics.median(times),
            "warm_p95_seconds": p95,
            "first_token_median_seconds": statistics.median(first_token_times) if first_token_times else None,
            "mean_reference_wer": wer, "mean_reference_cer": cer,
            "worker_cpu_seconds": (child_usage_after.ru_utime + child_usage_after.ru_stime)
                                  - (child_usage_before.ru_utime + child_usage_before.ru_stime),
            "worker_peak_rss_mib": child_usage_after.ru_maxrss / (1024 * 1024),
            "samples": samples}
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
