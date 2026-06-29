#!/usr/bin/env python3
"""
Beam relay server v2 — Channel-based broadcast
All devices on the same channel receive all messages.
Port: 8899
"""
import asyncio
import base64
import json
import os
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
import jwt
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

# ── Config ────────────────────────────────────────────────────────────────────
AUTH_TOKEN     = os.environ.get("BEAM_AUTH_TOKEN", "42bb6684ae6c90d74e546c4bfa99976f")
APNS_KEY_ID    = os.environ.get("APNS_KEY_ID", "")
APNS_TEAM_ID   = os.environ.get("APNS_TEAM_ID", "")
_apns_key_file = os.environ.get("APNS_KEY_FILE", "")
APNS_KEY_P8    = open(_apns_key_file).read().strip() if _apns_key_file else os.environ.get("APNS_KEY_P8", "")
BUNDLE_ID      = os.environ.get("BEAM_BUNDLE_ID", "com.fangduo.beam")
APNS_PROD      = os.environ.get("APNS_PROD", "0") == "1"
_fcm_sa_file   = os.environ.get("FCM_SA_FILE", "")
_fcm_sa_json   = os.environ.get("FCM_SA_JSON", "")
FCM_SA: dict   = json.loads(open(_fcm_sa_file).read()) if _fcm_sa_file else \
                 json.loads(_fcm_sa_json) if _fcm_sa_json else {}
GOOGLE_PROXY   = os.environ.get("GOOGLE_PROXY", "")   # e.g. "http://127.0.0.1:7890"
DB_PATH        = os.environ.get("BEAM_DB", "/opt/beam/beam.db")
FILES_DIR      = os.environ.get("BEAM_FILES", "/opt/beam/files")

# ── Database ──────────────────────────────────────────────────────────────────
def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db

def init_db():
    db = get_db()
    # Create tables (new installs)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS devices (
            device_id   TEXT PRIMARY KEY,
            channel_id  TEXT NOT NULL DEFAULT 'default',
            device_type TEXT NOT NULL,
            push_token  TEXT,
            updated_at  REAL
        );
        CREATE TABLE IF NOT EXISTS messages (
            id          TEXT PRIMARY KEY,
            channel_id  TEXT NOT NULL DEFAULT 'default',
            from_device TEXT,
            msg_type    TEXT,
            content     TEXT,
            filename    TEXT,
            created_at  REAL,
            acked_by    TEXT DEFAULT ''
        );
    """)
    # Migrate existing tables (add missing columns)
    cols = {r[1] for r in db.execute("PRAGMA table_info(devices)")}
    if "channel_id" not in cols:
        db.execute("ALTER TABLE devices ADD COLUMN channel_id TEXT NOT NULL DEFAULT 'default'")
    cols = {r[1] for r in db.execute("PRAGMA table_info(messages)")}
    if "channel_id" not in cols:
        db.execute("ALTER TABLE messages ADD COLUMN channel_id TEXT NOT NULL DEFAULT 'default'")
    if "from_device" not in cols:
        db.execute("ALTER TABLE messages ADD COLUMN from_device TEXT DEFAULT ''")
    if "acked_by" not in cols:
        db.execute("ALTER TABLE messages ADD COLUMN acked_by TEXT DEFAULT ''")
    # Drop old columns that no longer exist (SQLite can't drop, just ignore)
    db.executescript("""
        CREATE INDEX IF NOT EXISTS idx_msg_channel ON messages(channel_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_dev_channel  ON devices(channel_id);
    """)
    db.commit()
    db.close()

# ── SSE hub: channel_id → {device_id: asyncio.Queue} ────────────────────────
sse_channels: dict[str, dict[str, asyncio.Queue]] = {}

async def broadcast(channel_id: str, msg: dict, exclude_device: str = ""):
    bucket = sse_channels.get(channel_id, {})
    for dev_id, q in bucket.items():
        if dev_id != exclude_device:
            await q.put(msg)

# ── APNs ──────────────────────────────────────────────────────────────────────
def _apns_jwt():
    payload = {"iss": APNS_TEAM_ID, "iat": int(time.time())}
    return jwt.encode(payload, APNS_KEY_P8, algorithm="ES256",
                      headers={"kid": APNS_KEY_ID, "alg": "ES256"})

async def push_apns(token: str, title: str, body: str, data: dict):
    if not APNS_KEY_P8:
        return
    host = "api.push.apple.com" if APNS_PROD else "api.sandbox.push.apple.com"
    payload = {
        "aps": {"alert": {"title": title, "body": body}, "sound": "default", "badge": 1},
        "beam": data
    }
    hdrs = {"authorization": f"bearer {_apns_jwt()}",
            "apns-topic": BUNDLE_ID, "apns-push-type": "alert",
            "content-type": "application/json"}
    async with httpx.AsyncClient(http2=True) as c:
        try:
            r = await c.post(f"https://{host}/3/device/{token}",
                             json=payload, headers=hdrs, timeout=10)
            if r.status_code != 200:
                print(f"[apns] {r.status_code}: {r.text}")
        except Exception as e:
            print(f"[apns] error: {e}")

def _google_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(proxy=GOOGLE_PROXY) if GOOGLE_PROXY else httpx.AsyncClient()

async def _fcm_token() -> str:
    """Get OAuth2 bearer token for FCM v1 using service account."""
    now = int(time.time())
    claim = {
        "iss":   FCM_SA["client_email"],
        "scope": "https://www.googleapis.com/auth/firebase.messaging",
        "aud":   "https://oauth2.googleapis.com/token",
        "iat":   now,
        "exp":   now + 3600,
    }
    signed = jwt.encode(claim, FCM_SA["private_key"], algorithm="RS256")
    async with _google_client() as c:
        r = await c.post("https://oauth2.googleapis.com/token",
                         data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                               "assertion": signed},
                         timeout=15)
        return r.json()["access_token"]

async def push_fcm(token: str, title: str, body: str, data: dict):
    if not FCM_SA:
        return
    try:
        access_token = await _fcm_token()
        project_id   = FCM_SA["project_id"]
        payload = {
            "message": {
                "token": token,
                "notification": {"title": title, "body": body},
                "data": {k: str(v) for k, v in data.items() if v is not None},
                "android": {"priority": "HIGH", "notification": {"channel_id": "beam_channel"}},
            }
        }
        url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
        async with _google_client() as c:
            r = await c.post(url, json=payload,
                             headers={"Authorization": f"Bearer {access_token}",
                                      "Content-Type": "application/json"},
                             timeout=15)
            if r.status_code != 200:
                print(f"[fcm] {r.status_code}: {r.text}")
            else:
                print(f"[fcm] sent ok to {token[:20]}...")
    except Exception as e:
        print(f"[fcm] error: {type(e).__name__}: {e}")

# ── App lifespan ──────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    os.makedirs(FILES_DIR, exist_ok=True)
    init_db()
    print(f"[beam] v2 ready  auth={AUTH_TOKEN[:8]}…")
    yield

app = FastAPI(lifespan=lifespan)

def auth(token: str):
    if token != AUTH_TOKEN:
        raise HTTPException(401, "Unauthorized")

# ── Models ────────────────────────────────────────────────────────────────────
class RegisterReq(BaseModel):
    device_id:   str
    channel_id:  str
    device_type: str        # mac | windows | ios | android | chrome
    push_token:  Optional[str] = None
    auth_token:  str

class SendReq(BaseModel):
    from_device: str
    channel_id:  str
    msg_type:    str        # text | file
    content:     str
    filename:    Optional[str] = None
    auth_token:  str

class AckReq(BaseModel):
    message_id: str
    device_id:  str
    auth_token: str

# ── Routes ────────────────────────────────────────────────────────────────────
@app.post("/register")
async def register(req: RegisterReq):
    auth(req.auth_token)
    db = get_db()
    db.execute(
        "INSERT INTO devices (device_id, channel_id, device_type, push_token, updated_at)"
        " VALUES (?,?,?,?,?)"
        " ON CONFLICT(device_id) DO UPDATE SET"
        "   channel_id=excluded.channel_id,"
        "   device_type=excluded.device_type,"
        "   push_token=COALESCE(excluded.push_token, push_token),"
        "   updated_at=excluded.updated_at",
        (req.device_id, req.channel_id, req.device_type,
         req.push_token, time.time())
    )
    db.commit()
    db.close()
    return {"ok": True}

@app.post("/send")
async def send(req: SendReq):
    auth(req.auth_token)
    msg = {
        "id":          str(uuid.uuid4()),
        "channel_id":  req.channel_id,
        "from_device": req.from_device,
        "msg_type":    req.msg_type,
        "content":     req.content,
        "filename":    req.filename,
        "created_at":  time.time(),
    }
    db = get_db()
    db.execute(
        "INSERT INTO messages (id,channel_id,from_device,msg_type,content,filename,created_at,acked_by)"
        " VALUES (?,?,?,?,?,?,?,'')",
        (msg["id"], req.channel_id, req.from_device,
         req.msg_type, req.content, req.filename, msg["created_at"])
    )
    db.commit()

    # Push to mobile devices on this channel
    mobile = db.execute(
        "SELECT device_id, device_type, push_token FROM devices "
        "WHERE channel_id=? AND device_type IN ('ios','android') "
        "AND push_token IS NOT NULL AND device_id != ?",
        (req.channel_id, req.from_device)
    ).fetchall()
    db.close()

    push_title = "Beam"
    push_body  = msg["content"] if req.msg_type == "text" else f"📎 {req.filename}"
    for row in mobile:
        if row["device_type"] == "ios":
            await push_apns(row["push_token"], push_title, push_body, msg)
        else:
            await push_fcm(row["push_token"], push_title, push_body, msg)

    # Broadcast to connected desktop SSE clients (exclude sender)
    await broadcast(req.channel_id, msg, exclude_device=req.from_device)
    return {"ok": True, "id": msg["id"]}

@app.get("/stream")
async def stream(device_id: str, channel_id: str, auth_token: str, request: Request):
    auth(auth_token)
    q: asyncio.Queue = asyncio.Queue()
    if channel_id not in sse_channels:
        sse_channels[channel_id] = {}
    sse_channels[channel_id][device_id] = q

    # Deliver unacked pending messages for this channel
    db = get_db()
    pending = db.execute(
        "SELECT * FROM messages WHERE channel_id=? AND from_device!=? "
        "AND (acked_by NOT LIKE ? ) ORDER BY created_at",
        (channel_id, device_id, f"%{device_id}%")
    ).fetchall()
    db.close()

    async def event_gen():
        for row in pending:
            yield f"data: {json.dumps(dict(row))}\n\n"
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(q.get(), timeout=8)
                    yield f"data: {json.dumps(msg)}\n\n"
                except asyncio.TimeoutError:
                    yield ": ping\n\n"
        except (asyncio.CancelledError, GeneratorExit):
            pass
        finally:
            ch = sse_channels.get(channel_id, {})
            if ch.get(device_id) is q:
                ch.pop(device_id, None)
            if channel_id in sse_channels and not sse_channels[channel_id]:
                del sse_channels[channel_id]

    return StreamingResponse(event_gen(),
                             media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})

@app.post("/ack")
async def ack(req: AckReq):
    auth(req.auth_token)
    db = get_db()
    row = db.execute("SELECT acked_by FROM messages WHERE id=?",
                     (req.message_id,)).fetchone()
    if row:
        current = row["acked_by"] or ""
        if req.device_id not in current:
            db.execute("UPDATE messages SET acked_by=? WHERE id=?",
                       (current + "," + req.device_id, req.message_id))
            db.commit()
    db.close()
    return {"ok": True}

@app.post("/upload")
async def upload_file(
    file:        UploadFile = File(...),
    from_device: str        = Form(...),
    channel_id:  str        = Form(...),
    auth_token:  str        = Form(...),
):
    auth(auth_token)
    file_id  = str(uuid.uuid4())
    dst      = os.path.join(FILES_DIR, file_id)
    with open(dst, "wb") as f:
        while chunk := await file.read(1024 * 1024):  # stream 1 MB at a time
            f.write(chunk)

    msg = {
        "id":          str(uuid.uuid4()),
        "channel_id":  channel_id,
        "from_device": from_device,
        "msg_type":    "file",
        "content":     file_id,      # file reference, not base64
        "filename":    file.filename,
        "created_at":  time.time(),
    }
    db = get_db()
    db.execute(
        "INSERT INTO messages (id,channel_id,from_device,msg_type,content,filename,created_at,acked_by)"
        " VALUES (?,?,?,?,?,?,?,'')",
        (msg["id"], channel_id, from_device, "file", file_id, file.filename, msg["created_at"])
    )
    db.commit()

    mobile = db.execute(
        "SELECT device_id, device_type, push_token FROM devices "
        "WHERE channel_id=? AND device_type IN ('ios','android') "
        "AND push_token IS NOT NULL AND device_id != ?",
        (channel_id, from_device)
    ).fetchall()
    db.close()

    push_body = f"📎 {file.filename}"
    for row in mobile:
        if row["device_type"] == "ios":
            await push_apns(row["push_token"], "Beam", push_body, msg)
        else:
            await push_fcm(row["push_token"], "Beam", push_body, msg)

    await broadcast(channel_id, msg, exclude_device=from_device)
    return {"ok": True, "id": msg["id"], "file_id": file_id}

@app.get("/download/{file_id}")
async def download_file(file_id: str, auth_token: str, filename: str = "file"):
    auth(auth_token)
    # Sanitize file_id (UUID only)
    if not all(c in "0123456789abcdef-" for c in file_id):
        raise HTTPException(400, "Invalid file id")
    path = os.path.join(FILES_DIR, file_id)
    if not os.path.exists(path):
        raise HTTPException(404, "File not found")
    return FileResponse(path, filename=filename)

@app.get("/health")
async def health():
    return {"ok": True, "ts": datetime.now(timezone.utc).isoformat(),
            "channels": len(sse_channels)}

@app.get("/demo", response_class=None)
async def demo_send(text: str = "Hello from Apple Reviewer!"):
    """Demo endpoint for App Review — sends a test push to the default channel."""
    from fastapi.responses import HTMLResponse
    msg = {
        "id":          str(uuid.uuid4()),
        "channel_id":  "default",
        "from_device": "reviewer",
        "msg_type":    "text",
        "content":     text,
        "filename":    None,
        "created_at":  time.time(),
    }
    db = get_db()
    db.execute(
        "INSERT INTO messages (id,channel_id,from_device,msg_type,content,filename,created_at,acked_by)"
        " VALUES (?,?,?,?,?,?,?,'')",
        (msg["id"], msg["channel_id"], msg["from_device"],
         msg["msg_type"], msg["content"], msg["filename"], msg["created_at"])
    )
    db.commit()

    # Send APNs/FCM push to all iOS/Android devices on the default channel
    mobile = db.execute(
        "SELECT device_id, device_type, push_token FROM devices "
        "WHERE channel_id='default' AND device_type IN ('ios','android') "
        "AND push_token IS NOT NULL",
    ).fetchall()
    db.close()

    for row in mobile:
        if row["device_type"] == "ios":
            await push_apns(row["push_token"], "Beam", text, msg)
        else:
            await push_fcm(row["push_token"], "Beam", text, msg)

    await broadcast("default", msg)
    html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Beam Push — Demo</title>
<style>body{{font-family:sans-serif;max-width:600px;margin:60px auto;padding:20px}}
.ok{{background:#d4edda;border:1px solid #c3e6cb;border-radius:8px;padding:20px}}
h2{{color:#155724}}p{{color:#155724}}</style></head>
<body><div class="ok"><h2>✅ Push Sent Successfully</h2>
<p>Message: <strong>{text}</strong></p>
<p>The Beam Push iOS app on the reviewer device should now display a notification.</p>
<p>Channel: <code>default</code> | Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}</p>
</div></body></html>"""
    return HTMLResponse(content=html)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8899)
