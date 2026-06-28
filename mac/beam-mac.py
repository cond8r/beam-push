#!/usr/bin/env python3
"""
Beam Mac — 菜单栏 App v2 (Channel 广播模式)
推名+推码 = channel，同 channel 所有设备互收消息
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request

import rumps

# ── Config ────────────────────────────────────────────────────────────────────
SERVER     = os.environ.get("BEAM_SERVER",     "http://82.156.210.133:8899")
TOKEN      = os.environ.get("BEAM_AUTH_TOKEN", "42bb6684ae6c90d74e546c4bfa99976f")
CHANNEL_ID = os.environ.get("BEAM_CHANNEL",    "default")
DEVICE_ID  = f"mac-{socket.gethostname()}"
MAX_FILE_MB = 10

# ── HTTP ──────────────────────────────────────────────────────────────────────
def _post(path: str, data: dict) -> dict:
    body = json.dumps(data).encode()
    req  = urllib.request.Request(
        SERVER + path, data=body,
        headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def _send(msg_type: str, content: str, filename: str = None):
    _post("/send", {
        "from_device": DEVICE_ID,
        "channel_id":  CHANNEL_ID,
        "msg_type":    msg_type,
        "content":     content,
        "filename":    filename,
        "auth_token":  TOKEN,
    })

# ── Clipboard ─────────────────────────────────────────────────────────────────
def set_clipboard(text: str):
    proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
    proc.communicate(text.encode())

def get_clipboard() -> str:
    return subprocess.check_output(["pbpaste"]).decode()

def _download_file(file_id: str, filename: str) -> str:
    params = urllib.parse.urlencode({"auth_token": TOKEN, "filename": filename})
    req = urllib.request.Request(f"{SERVER}/download/{file_id}?{params}")
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    dest = os.path.expanduser(f"~/Downloads/{filename}")
    with open(dest, "wb") as f:
        f.write(data)
    return dest

def _upload_file(path: str):
    filename = os.path.basename(path)
    with open(path, "rb") as f:
        file_data = f.read()
    boundary = f"BeamBoundary{int(time.time())}"
    body = b""
    for name, value in [("from_device", DEVICE_ID), ("channel_id", CHANNEL_ID), ("auth_token", TOKEN)]:
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
             f"Content-Type: application/octet-stream\r\n\r\n").encode()
    body += file_data
    body += f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"{SERVER}/upload", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())

# ── Notification ──────────────────────────────────────────────────────────────
def notify(title: str, body: str):
    body_safe  = body.replace('"', '\\"').replace("\\", "\\\\")
    title_safe = title.replace('"', '\\"').replace("\\", "\\\\")
    script = f'display notification "{body_safe}" with title "{title_safe}"'
    subprocess.run(["osascript", "-e", script], check=False)

# ── SSE receiver ──────────────────────────────────────────────────────────────
class SSEReceiver(threading.Thread):
    def __init__(self, app_ref):
        super().__init__(daemon=True, name="BeamSSE")
        self.app    = app_ref
        self._alive = threading.Event()
        self._alive.set()

    def stop(self):
        self._alive.clear()

    def run(self):
        while self._alive.is_set():
            s = None
            try:
                parsed = urllib.parse.urlparse(SERVER)
                host   = parsed.hostname
                port   = parsed.port or 80
                s      = socket.create_connection((host, port), timeout=60)
                path   = (f"/stream?device_id={DEVICE_ID}"
                          f"&channel_id={CHANNEL_ID}"
                          f"&auth_token={TOKEN}")
                req_str = (
                    f"GET {path} HTTP/1.1\r\n"
                    f"Host: {host}:{port}\r\n"
                    f"Accept: text/event-stream\r\n"
                    f"Cache-Control: no-cache\r\n"
                    f"Connection: keep-alive\r\n\r\n"
                )
                s.sendall(req_str.encode())
                # skip headers
                hdr = b""
                while b"\r\n\r\n" not in hdr:
                    hdr += s.recv(1)
                print("[sse] connected", flush=True)
                self.app.update_status(True)

                buf = ""
                s.settimeout(90)
                while self._alive.is_set():
                    try:
                        chunk = s.recv(4096)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    buf += chunk.decode("utf-8", errors="replace")
                    while "\n\n" in buf:
                        event, buf = buf.split("\n\n", 1)
                        for line in event.split("\n"):
                            line = line.strip()
                            if line.startswith("data:"):
                                raw = line[5:].strip()
                                if raw:
                                    try:
                                        self._dispatch(json.loads(raw))
                                    except Exception as e:
                                        print(f"[sse] dispatch error: {e}", flush=True)
                                        traceback.print_exc(file=sys.stdout)
                                        sys.stdout.flush()
            except Exception as e:
                if self._alive.is_set():
                    print(f"[sse] error: {type(e).__name__}: {e}", flush=True)
                    self.app.update_status(False)
                    time.sleep(5)
            finally:
                try:
                    if s: s.close()
                except Exception:
                    pass

    def _dispatch(self, msg: dict):
        msg_type = msg.get("msg_type", "text")
        content  = msg.get("content", "")
        filename = msg.get("filename") or "file"
        msg_id   = msg.get("id", "")
        from_dev = msg.get("from_device", "")

        if msg_type == "text":
            set_clipboard(content)
            short = content[:60] + ("…" if len(content) > 60 else "")
            notify("📲 Beam 收到", short)
        elif msg_type == "file":
            try:
                dest = _download_file(content, filename)
                subprocess.Popen(["open", dest])
                notify("📎 Beam 收到", f"文件：{filename}")
            except Exception as e:
                notify("Beam ✗", f"下载失败：{e}")

        # Ack
        try:
            _post("/ack", {"message_id": msg_id,
                           "device_id":  DEVICE_ID,
                           "auth_token": TOKEN})
        except Exception:
            pass

# ── File picker ───────────────────────────────────────────────────────────────
def pick_and_send_file():
    script = 'set f to choose file with prompt "选择要发送的文件："\nPOSIX path of f'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    path = r.stdout.strip()
    if not path or r.returncode != 0:
        return
    size_mb = os.path.getsize(path) / 1024 / 1024
    if size_mb > MAX_FILE_MB:
        notify("Beam", f"文件过大 ({size_mb:.1f} MB)，最大 {MAX_FILE_MB} MB")
        return
    filename = os.path.basename(path)
    try:
        _upload_file(path)
        notify("Beam ✓", f"已发送：{filename}")
    except Exception as e:
        notify("Beam ✗", str(e))

def ask_text(prompt="输入要发送的内容：") -> str:
    script = f'set r to display dialog "{prompt}" default answer "" buttons {{"取消","发送"}} default button "发送"\ntext returned of r'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        return ""
    return r.stdout.strip()

# ── Main App ──────────────────────────────────────────────────────────────────
class BeamApp(rumps.App):
    def __init__(self):
        super().__init__("📡", quit_button=None)
        self.menu = [
            rumps.MenuItem("发送文字…",  callback=self.send_text),
            rumps.MenuItem("发送文件…",  callback=self.send_file),
            rumps.MenuItem("发送剪贴板", callback=self.send_clip),
            None,
            rumps.MenuItem(f"Channel: {CHANNEL_ID}"),
            rumps.MenuItem("状态：连接中…"),
            None,
            rumps.MenuItem("退出 Beam", callback=rumps.quit_application),
        ]
        self._status = self.menu["状态：连接中…"]
        self._sse    = SSEReceiver(self)
        self._sse.start()
        threading.Thread(target=self._register, daemon=True).start()

    def _register(self):
        try:
            _post("/register", {
                "device_id":   DEVICE_ID,
                "channel_id":  CHANNEL_ID,
                "device_type": "mac",
                "auth_token":  TOKEN,
            })
        except Exception as e:
            print(f"[beam] register failed: {e}", flush=True)

    def update_status(self, connected: bool):
        self._status.title = "状态：已连接 ✓" if connected else "状态：离线 ✗"
        self.title = "📡" if connected else "📵"

    @rumps.clicked("发送文字…")
    def send_text(self, _):
        text = ask_text()
        if not text:
            return
        try:
            _send("text", text)
            notify("Beam ✓", text[:40])
        except Exception as e:
            notify("Beam ✗", str(e))

    @rumps.clicked("发送文件…")
    def send_file(self, _):
        threading.Thread(target=pick_and_send_file, daemon=True).start()

    @rumps.clicked("发送剪贴板")
    def send_clip(self, _):
        text = get_clipboard()
        if not text.strip():
            notify("Beam", "剪贴板为空")
            return
        try:
            _send("text", text)
            notify("Beam ✓", f"剪贴板：{text[:40]}")
        except Exception as e:
            notify("Beam ✗", str(e))


if __name__ == "__main__":
    BeamApp().run()
