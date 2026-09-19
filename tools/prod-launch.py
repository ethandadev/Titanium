#!/usr/bin/env python3
"""
Launch a *production* Fabric + Minecraft 1.21.11 client with a built Titanium
jar, outside Loom's development environment.

Why this exists: the dev environment runs with deobfuscated names and loads
libtitanium.dylib from disk. A real install runs against intermediary names
(so mixins depend on correct remapping / refmap) and loads the dylib extracted
from inside the jar. Neither is exercised by `./gradlew runClient`.

Uses a private game directory; never touches the user's launcher files.
Libraries are read from the vanilla launcher's library cache when present and
downloaded (hash-checked) into a private cache otherwise.

  tools/prod-launch.py <titanium.jar> [--selfcheck LABEL] [--no-titanium]
"""
import argparse, hashlib, json, os, platform, shutil, subprocess, sys, urllib.request
from pathlib import Path

MC_VERSION = "1.21.11"
LOADER = "0.19.5"
HOME = Path.home()
VANILLA = HOME / "Library/Application Support/minecraft"
CACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "titanium-prod"
JRE = VANILLA / "runtime/java-runtime-delta/mac-os-arm64/java-runtime-delta/jre.bundle/Contents/Home/bin/java"
LOOM_ASSETS = HOME / ".gradle/caches/fabric-loom/assets"

def fetch(url, dest, sha1=None):
    dest = Path(dest)
    if dest.exists() and (sha1 is None or hashlib.sha1(dest.read_bytes()).hexdigest() == sha1):
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    if sha1 and hashlib.sha1(tmp.read_bytes()).hexdigest() != sha1:
        tmp.unlink(); sys.exit(f"hash mismatch for {url}")
    tmp.replace(dest)
    return dest

def maven_path(coord):
    g, a, v, *c = coord.split(":")
    name = f"{a}-{v}" + (f"-{c[0]}" if c else "") + ".jar"
    return f"{g.replace('.', '/')}/{a}/{v}/{name}"

def allowed(lib):
    """Vanilla OS rules, plus: only arm64 macOS natives."""
    name = lib["name"]
    if ":natives-" in name and not name.endswith(":natives-macos-arm64"):
        return False
    ok = True
    for rule in lib.get("rules", []):
        applies = "os" not in rule or rule["os"].get("name") == "osx"
        if applies: ok = rule["action"] == "allow"
    return ok

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jar")
    ap.add_argument("--selfcheck", default="prod")
    ap.add_argument("--no-titanium", action="store_true")
    ap.add_argument("--extra", nargs="*", default=[])
    ap.add_argument("--extra-mod", action="append", default=[], help="additional mod jar(s) to install")
    a = ap.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("macOS on Apple silicon only")

    vjson = json.loads((VANILLA / f"versions/{MC_VERSION}/{MC_VERSION}.json").read_text())
    fab = json.loads(urllib.request.urlopen(
        f"https://meta.fabricmc.net/v2/versions/loader/{MC_VERSION}/{LOADER}/profile/json", timeout=60).read())

    cp = []
    for lib in vjson["libraries"]:
        if not allowed(lib): continue
        art = lib.get("downloads", {}).get("artifact")
        if not art: continue
        local = VANILLA / "libraries" / art["path"]
        cp.append(local if local.exists() else fetch(art["url"], CACHE / "libraries" / art["path"], art["sha1"]))
    for lib in fab["libraries"]:
        path = maven_path(lib["name"])
        cp.append(fetch(lib.get("url", "https://maven.fabricmc.net/") + path, CACHE / "libraries" / path,
                        lib.get("sha1")))
    client = fetch(vjson["downloads"]["client"]["url"], CACHE / f"{MC_VERSION}-client.jar",
                   vjson["downloads"]["client"]["sha1"])
    cp.append(client)

    game = CACHE / "game"
    (game / "mods").mkdir(parents=True, exist_ok=True)
    for old in (game / "mods").glob("*.jar"): old.unlink()
    shutil.copy(a.jar, game / "mods")
    for m in a.extra_mod: shutil.copy(m, game / "mods")
    opts = game / "options.txt"
    if not opts.exists():
        opts.write_text("onboardAccessibility:false\ntutorialStep:none\n")

    # Loom stores the index as "<version>-<id>.json"; the vanilla launcher as "<id>.json".
    idx = vjson["assetIndex"]["id"]
    if (LOOM_ASSETS / f"indexes/{MC_VERSION}-{idx}.json").exists():
        assets, index_id = LOOM_ASSETS, f"{MC_VERSION}-{idx}"
    elif (VANILLA / f"assets/indexes/{idx}.json").exists():
        assets, index_id = VANILLA / "assets", idx
    else:
        sys.exit("no asset index found; run ./gradlew runClient once to download assets")
    cmd = [str(JRE), "-XstartOnFirstThread", "-Xmx4G",
           f"-Dtitanium.selfcheck={a.selfcheck}", "-Dtitanium.selfcheck.exit=true",
           *(["-Dtitanium.enabled=false"] if a.no_titanium else []), *a.extra,
           "-cp", ":".join(str(p) for p in cp), fab["mainClass"],
           "--version", MC_VERSION, "--gameDir", str(game), "--assetsDir", str(assets),
           "--assetIndex", index_id, "--accessToken", "0",
           "--username", "TitaniumProd", "--userType", "legacy"]
    print(f"classpath entries: {len(cp)}  game dir: {game}  assets: {assets}", flush=True)
    sys.exit(subprocess.call(cmd, cwd=game))

if __name__ == "__main__":
    main()
