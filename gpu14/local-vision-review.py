#!/usr/bin/env python3
"""gpu-14 STOPGAP screen review (tsp-e4xdz): review-screen.sh's opencode wrapper hangs
to its 480 s timeout while the local model answers vision in ~1-4 s. This sends frames
to the SAME local model with the SAME screen-reviewer agent instructions (read from the
pinned automation checkout), bypassing only opencode. Local only: no cloud, no pixels
printed. Output is labelled as fallback so nobody mistakes it for review-screen.sh.

usage: local-vision-review.py --prompt "..." img1.jpg [img2 ... img4]
"""
import argparse, base64, hashlib, json, mimetypes, pathlib, re, sys, time, urllib.request

PIN = "/home/matt/wt/.driver-pins/pocketforge-automation-3fe9d59e9c1be37a0e1b4e5075c9d66806cf2d5f"
AGENT = pathlib.Path(PIN) / ".opencode/agents/screen-reviewer.md"
URL = "http://10.0.40.90:8000/v1/chat/completions"
MODEL = "cyankiwi/Qwen3.8-27B-AWQ-INT4"

ap = argparse.ArgumentParser()
ap.add_argument("--prompt", required=True)
ap.add_argument("images", nargs="+")
a = ap.parse_args()
if len(a.images) > 4:
    sys.exit("max 4 images (served --limit-mm-per-prompt image:4)")
text = AGENT.read_text()
m = re.match(r"^---\n.*?\n---\n", text, re.S)
system = text[m.end():] if m else text
content = [{"type": "text", "text": a.prompt}]
shas = []
for p in a.images:
    b = pathlib.Path(p).read_bytes()
    shas.append((p, hashlib.sha256(b).hexdigest()))
    mime = mimetypes.guess_type(p)[0] or "image/jpeg"
    content.append({"type": "image_url", "image_url": {"url": f"data:{mime};base64," + base64.b64encode(b).decode()}})
body = {"model": MODEL, "temperature": 0.2, "max_tokens": 6000,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}]}
t = time.time()
req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
r = json.load(urllib.request.urlopen(req, timeout=600))
msg = r["choices"][0]["message"]
print("review_status=fallback_direct_vllm (review-screen.sh wrapper hang, tsp-e4xdz)")
print(f"model={MODEL} agent_prompt_sha256={hashlib.sha256(system.encode()).hexdigest()[:16]} latency_s={time.time()-t:.1f} "
      f"finish={r['choices'][0].get('finish_reason')} usage={r.get('usage')}")
for p, s in shas:
    print(f"image={p} sha256={s}")
print("---")
print((msg.get("content") or "").strip())
