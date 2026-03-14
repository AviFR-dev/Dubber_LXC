#!/usr/bin/env python3
"""
Plex AI Dubber — Label Watcher Daemon
Author: Avi Fridlindas | License: MIT

Watches Plex for movies tagged with "dub-{language}" labels.
Automatically queues them for AI dubbing.

Label flow:  dub-spanish → dubbing-spanish → dubbed-spanish

Usage:
  python dubber_watcher.py --config /opt/dubber/config.json
"""

import argparse, json, os, subprocess, sys, shutil, time, logging
from pathlib import Path
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.StreamHandler(), logging.FileHandler("/opt/dubber/watcher.log")],
)
log = logging.getLogger("dubber-watcher")

DEFAULT_CONFIG = {
    "plex_url": "", "plex_token": "", "hf_token": "",
    "target_languages": {"spanish": "spa"},
    "source_language": "eng", "tts_engine": "coqui", "device": "cpu",
    "whisper_model": "medium", "nllb_model": "nllb-200-1.3B",
    "scan_interval": 120, "output_dir": "/opt/dubber/output",
    "path_prefix_plex": "", "path_prefix_local": "",
}

def load_config(path):
    if not os.path.exists(path):
        log.info(f"Creating config template at {path}...")
        with open(path, "w") as f: json.dump(DEFAULT_CONFIG, f, indent=2)
        log.info("Edit it with your tokens, then restart."); sys.exit(0)
    with open(path) as f: config = json.load(f)
    if not config.get("plex_token"): log.error("plex_token empty!"); sys.exit(1)
    if not config.get("hf_token"): log.error("hf_token empty!"); sys.exit(1)
    for k, v in DEFAULT_CONFIG.items():
        if k not in config: config[k] = v
    return config

def connect_plex(config):
    from plexapi.server import PlexServer
    server = PlexServer(config["plex_url"], config["plex_token"])
    log.info(f"Connected to Plex: {server.friendlyName}")
    return server

def map_path(fp, config):
    p, l = config.get("path_prefix_plex", ""), config.get("path_prefix_local", "")
    return fp.replace(p, l, 1) if p and l and fp.startswith(p) else fp

def find_labeled_movies(server, config):
    jobs = []
    for section in server.library.sections():
        if section.type != "movie": continue
        for lang_name, lang_code in config["target_languages"].items():
            try:
                for movie in section.search(label=f"dub-{lang_name}"):
                    jobs.append((movie, lang_name, lang_code))
            except Exception as e:
                log.warning(f"Error searching '{section.title}': {e}")
    return jobs

def update_label(movie, old, new):
    try: movie.removeLabel(old)
    except: pass
    try: movie.addLabel(new)
    except Exception as e: log.warning(f"Label error: {e}")

def count_audio_streams(fp):
    r = subprocess.run(["ffprobe","-v","quiet","-select_streams","a","-show_entries","stream=index","-of","csv=p=0",fp], capture_output=True, text=True)
    return len([l for l in r.stdout.strip().split("\n") if l.strip()])

def run_dubbing(movie_file, config, lang_name, lang_code):
    output_dir = os.path.join(config["output_dir"], f"job_{int(time.time())}")
    os.makedirs(output_dir, exist_ok=True)
    cmd = ["open-dubbing", "--input_file", movie_file, "--target_language", lang_code,
           "--source_language", config["source_language"], "--hugging_face_token", config["hf_token"],
           "--output_directory", output_dir, "--tts", config["tts_engine"],
           "--device", config["device"], "--nllb_model", config["nllb_model"],
           "--whisper_model", config["whisper_model"]]
    env = os.environ.copy(); env["COQUI_TOS_AGREED"] = "1"
    log.info(f"Dubbing: {os.path.basename(movie_file)} → {lang_name}")
    start = time.time()
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
        for line in proc.stdout: log.debug(f"  {line.rstrip()}")
        proc.wait()
        log.info(f"Finished in {(time.time()-start)/60:.1f}min (exit: {proc.returncode})")
        if proc.returncode != 0: return None
    except Exception as e: log.error(f"Crash: {e}"); return None
    for pat in ["*dubbed*", f"*{lang_code}*", "*.mp4"]:
        for m in Path(output_dir).rglob(pat):
            if m.suffix in (".mp4",".mkv") and m.name != os.path.basename(movie_file): return str(m)
    return None

def mux_audio(original, dubbed, lang_code, lang_name):
    od = os.path.dirname(dubbed)
    audio = os.path.join(od, "dubbed_audio.aac")
    if subprocess.run(["ffmpeg","-y","-i",dubbed,"-vn","-acodec","aac","-b:a","192k",audio], capture_output=True).returncode != 0: return False
    ext = Path(original).suffix.lower()
    tmp = original + f".{lang_code}_temp{ext}"
    idx = count_audio_streams(original)
    if ext == ".mkv":
        cmd = ["mkvmerge","-o",tmp,original,"--language",f"0:{lang_code}","--track-name",f"0:{lang_name.title()} (AI Dubbed)",audio]
    else:
        cmd = ["ffmpeg","-y","-i",original,"-i",audio,"-map","0","-map","1:a","-c","copy",f"-metadata:s:a:{idx}",f"language={lang_code}",f"-metadata:s:a:{idx}",f"title={lang_name.title()} (AI Dubbed)",tmp]
    if subprocess.run(cmd, capture_output=True).returncode != 0: return False
    shutil.copy2(original, original + ".pre_dub_backup")
    shutil.move(tmp, original)
    return True

def process_job(movie, lang_name, lang_code, config, server):
    log.info(f"{'='*50}")
    log.info(f"JOB: {movie.title} ({movie.year}) → {lang_name}")
    update_label(movie, f"dub-{lang_name}", f"dubbing-{lang_name}")
    try:
        fp = map_path(movie.media[0].parts[0].file, config)
    except Exception as e:
        log.error(f"Path error: {e}"); update_label(movie, f"dubbing-{lang_name}", f"dub-failed-{lang_name}"); return
    if not os.path.exists(fp):
        log.error(f"File not found: {fp}"); update_label(movie, f"dubbing-{lang_name}", f"dub-failed-{lang_name}"); return
    dubbed = run_dubbing(fp, config, lang_name, lang_code)
    if not dubbed:
        update_label(movie, f"dubbing-{lang_name}", f"dub-failed-{lang_name}"); return
    if not mux_audio(fp, dubbed, lang_code, lang_name):
        update_label(movie, f"dubbing-{lang_name}", f"dub-failed-{lang_name}"); return
    try: movie.section().update()
    except: pass
    update_label(movie, f"dubbing-{lang_name}", f"dubbed-{lang_name}")
    log.info(f"DONE: {movie.title} → {lang_name}")

def main_loop(config):
    server = connect_plex(config)
    interval = config.get("scan_interval", 120)
    log.info(f"Watching every {interval}s. Add 'dub-<language>' label in Plex to dub.")
    while True:
        try:
            jobs = find_labeled_movies(server, config)
            if jobs:
                log.info(f"Found {len(jobs)} job(s)")
                for movie, ln, lc in jobs:
                    process_job(movie, ln, lc, config, server)
                    try: server = connect_plex(config)
                    except: pass
        except KeyboardInterrupt: log.info("Stopped."); break
        except Exception as e:
            log.error(f"Scan error: {e}")
            try: time.sleep(10); server = connect_plex(config)
            except: time.sleep(60); continue
        time.sleep(interval)

def main():
    parser = argparse.ArgumentParser(description="Plex AI Dubber — Label Watcher")
    parser.add_argument("--config", default="/opt/dubber/config.json")
    parser.add_argument("--once", action="store_true", help="Scan once and exit")
    args = parser.parse_args()
    config = load_config(args.config)
    if args.once:
        server = connect_plex(config)
        jobs = find_labeled_movies(server, config)
        for m, ln, lc in jobs: process_job(m, ln, lc, config, server)
        if not jobs: log.info("No labeled movies found.")
    else: main_loop(config)

if __name__ == "__main__": main()
