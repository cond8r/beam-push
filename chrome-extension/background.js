import { getConfig, deviceId } from './config.js';
import { register, ack } from './api.js';

let sseController = null;

async function startSSE() {
  const cfg   = await getConfig();
  const devId = await deviceId();
  if (!cfg.channelId) return;

  await register(cfg, devId).catch(() => {});

  if (sseController) sseController.abort();
  sseController = new AbortController();

  try {
    const url  = `${cfg.server}/stream?device_id=${devId}&channel_id=${cfg.channelId}&auth_token=${cfg.authToken}`;
    const resp = await fetch(url, {
      signal:  sseController.signal,
      headers: { Accept: 'text/event-stream' },
    });
    if (!resp.ok || !resp.body) return;

    const reader = resp.body.getReader();
    const dec    = new TextDecoder();
    let   buf    = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf('\n\n')) !== -1) {
        const event = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        for (const line of event.split('\n')) {
          if (line.startsWith('data:')) {
            const raw = line.slice(5).trim();
            if (raw && !raw.startsWith(':')) {
              try {
                await handleMessage(JSON.parse(raw), cfg, devId);
              } catch (e) {
                console.error('[beam] handle error', e);
              }
            }
          }
        }
      }
    }
  } catch (e) {
    if (e.name !== 'AbortError') {
      console.warn('[beam] SSE error:', e.message);
    }
  }
}

async function handleMessage(msg, cfg, devId) {
  if (!msg.id) return;

  const body = msg.msg_type === 'file'
    ? `📎 ${msg.filename || '文件'}`
    : (msg.content || '').slice(0, 80);

  chrome.notifications.create(msg.id, {
    type:     'basic',
    iconUrl:  'icons/icon48.png',
    title:    '📲 Beam 收到消息',
    message:  body,
    priority: 2,
  });

  const data  = await chrome.storage.local.get({ inbox: [] });
  const inbox = data.inbox;
  inbox.unshift({ ...msg, receivedAt: Date.now() });
  if (inbox.length > 50) inbox.splice(50);
  await chrome.storage.local.set({ inbox });

  if (msg.msg_type === 'text' && msg.content) {
    await copyToClipboard(msg.content);
  }

  await ack(cfg, devId, msg.id);
}

async function copyToClipboard(text) {
  try {
    await chrome.offscreen.createDocument({
      url:           'offscreen.html',
      reasons:       ['CLIPBOARD'],
      justification: 'Copy received text to clipboard',
    }).catch(() => {});
    await chrome.runtime.sendMessage({ type: 'copy', text });
  } catch (e) {}
}

// Install / update
chrome.runtime.onInstalled.addListener(async () => {
  // Clear all old alarm names from previous versions
  await chrome.alarms.clear('beam-sse');
  await chrome.alarms.clear('beam-keepalive');
  chrome.alarms.create('beam-sse', { periodInMinutes: 0.17 }); // ~10s
  chrome.contextMenus.create({
    id:       'beam-send-selection',
    title:    '用 Beam 发送选中内容',
    contexts: ['selection'],
  });
  chrome.contextMenus.create({
    id:       'beam-send-link',
    title:    '用 Beam 发送链接',
    contexts: ['link'],
  });
  startSSE();
});

chrome.runtime.onStartup.addListener(() => {
  startSSE();
});

// Alarm: reconnect SSE to pick up any pending messages
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === 'beam-sse') startSSE();
});

// Notification click → open popup
chrome.notifications.onClicked.addListener(() => {
  chrome.action.openPopup().catch(() => {});
});

// Context menu
chrome.contextMenus.onClicked.addListener(async (info) => {
  const cfg   = await getConfig();
  const devId = await deviceId();
  if (!cfg.channelId) {
    chrome.notifications.create('no-channel', {
      type: 'basic', iconUrl: 'icons/icon48.png',
      title: 'Beam', message: '请先在扩展设置中填写频道名',
    });
    return;
  }
  const text = info.menuItemId === 'beam-send-link'
    ? info.linkUrl
    : info.selectionText;
  if (!text) return;
  try {
    const { sendText } = await import('./api.js');
    await sendText(cfg, devId, text);
    chrome.notifications.create('sent-' + Date.now(), {
      type: 'basic', iconUrl: 'icons/icon48.png',
      title: 'Beam ✓', message: text.slice(0, 60),
    });
  } catch (e) {
    chrome.notifications.create('err-' + Date.now(), {
      type: 'basic', iconUrl: 'icons/icon48.png',
      title: 'Beam ✗', message: `发送失败: ${e.message}`,
    });
  }
});

// Messages from popup
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'restart-sse') {
    startSSE().then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg.type === 'get-inbox') {
    chrome.storage.local.get({ inbox: [] }).then(d => sendResponse({ inbox: d.inbox }));
    return true;
  }
});
