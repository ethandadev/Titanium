#!/usr/bin/env python3
"""Render-thread hotspots from a Java Flight Recorder file.

    tools/jfr-hotspots.py recording.jfr [--thread "Render thread"] [--top 25]
                          [--start-ms N]

Reads jdk.ExecutionSample (thread running Java) and jdk.NativeMethodSample
(thread inside a native method, e.g. a JNI call into Metal) events with the
JDK's `jfr` tool (JDK 17+ on PATH, or $JFR); record both at the same period so
their counts are comparable. Keeps samples from one thread and prints:
  * self time: the top frame of each sample (where the CPU actually was);
  * inclusive time for the backend's own code (com.ethandadev.titanium.*),
    Blaze3d (com.mojang.blaze3d.*) and native (JNI) frames, so the share of
    the render thread spent in Titanium can be read off directly.
Native samples also include time *blocked* in native code (a semaphore or
drawable wait); check the backend's wait statistics before reading those as
CPU time.
"""
import argparse
import collections
import json
import os
import shutil
import subprocess
import sys


def jfr_tool():
    t = os.environ.get("JFR") or shutil.which("jfr")
    if not t:
        for cand in ("/Library/Java/JavaVirtualMachines/jdk-25.jdk/Contents/Home/bin/jfr",):
            if os.path.exists(cand):
                return cand
        sys.exit("jfr tool not found; set $JFR")
    return t


def type_name(f):
    # JFR writes internal names (com/foo/Bar); normalise to com.foo.Bar.
    return f.get("method", {}).get("type", {}).get("name", "").replace("/", ".")


def frame_name(f):
    return f"{type_name(f) or '?'}.{f.get('method', {}).get('name', '?')}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("--thread", default="Render thread")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--start-ms", type=float, default=None,
                    help="only samples at or after this many ms from the first sample")
    ap.add_argument("--last-ms", type=float, default=None,
                    help="only samples in the final N ms (e.g. a self-check's measured window)")
    args = ap.parse_args()

    out = subprocess.run([jfr_tool(), "print", "--json", "--stack-depth", "96",
                          "--events", "jdk.ExecutionSample,jdk.NativeMethodSample", args.recording],
                         check=True, capture_output=True, text=True).stdout
    events = json.loads(out)["recording"]["events"]
    samples = [e for e in events
               if (e["values"].get("sampledThread") or {}).get("javaName") == args.thread]
    if not samples:
        sys.exit(f"no samples for thread {args.thread!r}")

    def ts(e):
        return e["values"]["startTime"]
    samples.sort(key=ts)
    from datetime import datetime
    def parse(t):
        return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() * 1000
    if args.start_ms is not None:
        t0 = parse(ts(samples[0]))
        samples = [e for e in samples if parse(ts(e)) - t0 >= args.start_ms]
    if args.last_ms is not None:
        t1 = parse(ts(samples[-1]))
        samples = [e for e in samples if t1 - parse(ts(e)) <= args.last_ms]

    n = len(samples)
    kinds = collections.Counter(e["type"] for e in samples)
    print("event mix:", dict(kinds))
    self_t = collections.Counter()
    incl = collections.Counter()
    buckets = collections.Counter()
    for e in samples:
        frames = e["values"]["stackTrace"]["frames"]
        if not frames:
            continue
        self_t[frame_name(frames[0])] += 1
        seen = set()
        for f in frames:
            name = frame_name(f)
            if name not in seen:
                incl[name] += 1
                seen.add(name)
        types = [type_name(f) for f in frames]
        top = types[0]
        if any(t.startswith("com.ethandadev.titanium") for t in types):
            # Attribute to Titanium only if Titanium is on the stack *below* nothing
            # else of interest: i.e. the backend is executing (directly or via JNI).
            first_ti = next(i for i, t in enumerate(types) if t.startswith("com.ethandadev.titanium"))
            above = types[:first_ti]
            if all(t.startswith(("java.", "jdk.", "sun.", "com.ethandadev.titanium",
                                 "it.unimi", "com.google")) or t == "" for t in above):
                buckets["titanium backend (incl. JNI below it)"] += 1
                continue
        if top.startswith("com.mojang.blaze3d"):
            buckets["blaze3d (self)"] += 1
        elif top.startswith("net.minecraft"):
            buckets["minecraft (self)"] += 1
        else:
            buckets["other (self: jdk, libs)"] += 1

    print(f"{n} samples on {args.thread!r} (JFR samples up to 5 threads in Java and 1 in native code\n"
          "per period, so Java and native shares are not directly comparable)")
    print("\n-- where the render thread is (self), top", args.top)
    for name, c in self_t.most_common(args.top):
        print(f"{100.0 * c / n:6.1f}%  {name}")
    print("\n-- attribution")
    for k, c in buckets.most_common():
        print(f"{100.0 * c / n:6.1f}%  {k}")
    print("\n-- inclusive, Titanium and Blaze3d frames, top", args.top)
    for name, c in [(k, v) for k, v in incl.most_common()
                    if k.startswith(("com.ethandadev.titanium", "com.mojang.blaze3d"))][:args.top]:
        print(f"{100.0 * c / n:6.1f}%  {name}")
    print("\n-- inclusive, Minecraft frames, top", args.top)
    for name, c in [(k, v) for k, v in incl.most_common()
                    if k.startswith("net.minecraft")][:args.top]:
        print(f"{100.0 * c / n:6.1f}%  {name}")


if __name__ == "__main__":
    main()
