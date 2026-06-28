import { getConfig, saveConfig, deviceId, DEFAULTS } from '../config.js';
import { sendText, register } from '../api.js';

const $ = id => document.getElementById(id);

let cfg, devId;

async function init() {
  cfg   = await getConfig();
  devId = await deviceId();

  // Auto-register on open
  if (cfg.channelId) {
    register(cfg, devId).catch(() => {});
  }

  loadInbox();

  // Settings form pre-fill
  $('cfg-channel').value = cfg.channelId || '';
  $('cfg-pw').value      = cfg.channelPw || '';

  // Show settings if not configured
  if (!cfg.channelId) showSettings();
}

function showFeedback(msg, type = '') {
  const el = $('feedback');
  el.textContent = msg;
  el.className   = type;
  if (type === 'ok') setTimeout(() => { el.textContent = ''; }, 2500);
}

// ── Send text ─────────────────────────────────────────────────────────────────
$('btn-send-text').addEventListener('click', async () => {
  const text = $('input-text').value.trim();
  if (!text) return;
  if (!cfg.channelId) { showSettings(); return; }
  try {
    await sendText(cfg, devId, text);
    $('input-text').value = '';
    showFeedback('✓ 已发送', 'ok');
  } catch (e) {
    showFeedback(`✗ ${e.message}`, 'err');
  }
});

// ── Send clipboard ────────────────────────────────────────────────────────────
$('btn-send-clip').addEventListener('click', async () => {
  if (!cfg.channelId) { showSettings(); return; }
  try {
    const text = await navigator.clipboard.readText();
    if (!text.trim()) { showFeedback('剪贴板为空', 'err'); return; }
    await sendText(cfg, devId, text.trim());
    showFeedback('✓ 剪贴板已发送', 'ok');
  } catch (e) {
    showFeedback(`✗ ${e.message}`, 'err');
  }
});

// ── Send file ─────────────────────────────────────────────────────────────────
$('btn-send-file').addEventListener('click', () => $('file-input').click());

$('file-input').addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  if (!cfg.channelId) { showSettings(); return; }
  if (file.size > 100 * 1024 * 1024) {
    showFeedback('文件不能超过 100 MB', 'err'); return;
  }
  showFeedback('上传中…');
  try {
    // Read file in popup context, hand off bytes to background service worker.
    // This survives popup close on Windows (where the file picker steals focus).
    const buffer = await file.arrayBuffer();
    const bytes  = Array.from(new Uint8Array(buffer));
    await new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({ type: 'upload-file', bytes, filename: file.name }, res => {
        if (chrome.runtime.lastError) return reject(new Error(chrome.runtime.lastError.message));
        res?.ok ? resolve() : reject(new Error(res?.error || '上传失败'));
      });
    });
    showFeedback(`✓ 已发送 ${file.name}`, 'ok');
  } catch (err) {
    showFeedback(`✗ ${err.message}`, 'err');
  }
  e.target.value = '';
});

// ── Inbox ─────────────────────────────────────────────────────────────────────
async function loadInbox() {
  const data = await new Promise(r =>
    chrome.runtime.sendMessage({ type: 'get-inbox' }, r)
  );
  const inbox = data?.inbox || [];
  const list  = $('inbox-list');

  if (!inbox.length) {
    list.innerHTML = '<div class="inbox-empty">收件箱为空<br>来自其他设备的推送会出现在这里</div>';
    return;
  }

  list.innerHTML = inbox.map(msg => {
    const icon = msg.msg_type === 'file' ? '📎' : '💬';
    const text = msg.msg_type === 'file'
      ? (msg.filename || '文件')
      : (msg.content || '').slice(0, 80);
    const ago  = timeAgo(msg.receivedAt);
    const fileBtn = msg.msg_type === 'file' && msg.filename
      ? `<button class="dl-file-btn" data-fileid="${escHtml(msg.content || '')}" data-filename="${escHtml(msg.filename)}">⬇️ 下载</button>`
      : '';
    return `<div class="inbox-item" data-content="${escHtml(msg.content || '')}" data-type="${msg.msg_type}">
      <span class="inbox-icon">${icon}</span>
      <div class="inbox-body">
        <div class="inbox-text">${escHtml(text)}</div>
        <div class="inbox-meta">${ago}${fileBtn}</div>
      </div>
    </div>`;
  }).join('');

  // Click to copy text
  list.querySelectorAll('.inbox-item[data-type="text"]').forEach(el => {
    el.addEventListener('click', () => {
      navigator.clipboard.writeText(el.dataset.content).then(() => {
        showFeedback('✓ 已复制到剪贴板', 'ok');
      });
    });
  });

  // Download file from server
  list.querySelectorAll('.dl-file-btn').forEach(btn => {
    btn.addEventListener('click', async e => {
      e.stopPropagation();
      const fileId   = btn.dataset.fileid;
      const filename = btn.dataset.filename;
      if (!fileId) { showFeedback('文件 ID 缺失', 'err'); return; }
      // fileId is either a GoFile URL (https://...) or a legacy Beam file_id
      if (fileId.startsWith('https://')) {
        // GoFile URL — open in new tab (GoFile page has download button)
        chrome.tabs.create({ url: fileId });
        showFeedback('✓ 已在新标签页打开', 'ok');
      } else {
        const url = `${cfg.server}/download/${fileId}?auth_token=${cfg.authToken}&filename=${encodeURIComponent(filename)}`;
        chrome.downloads.download({ url, filename, saveAs: false }, id => {
          if (chrome.runtime.lastError || id === undefined) {
            showFeedback('下载失败', 'err');
          } else {
            showFeedback('⬇️ 下载中…', 'ok');
          }
        });
      }
    });
  });
}

// ── Settings ──────────────────────────────────────────────────────────────────
function showSettings() {
  $('send-panel').classList.add('hidden');
  $('settings-panel').classList.remove('hidden');
}

function hideSettings() {
  $('send-panel').classList.remove('hidden');
  $('settings-panel').classList.add('hidden');
}

$('btn-settings').addEventListener('click', () => {
  if ($('settings-panel').classList.contains('hidden')) showSettings();
  else hideSettings();
});

$('btn-cancel').addEventListener('click', hideSettings);

$('btn-save').addEventListener('click', async () => {
  const newCfg = {
    server:    DEFAULTS.server,
    authToken: DEFAULTS.authToken,
    channelId: $('cfg-channel').value.trim(),
    channelPw: $('cfg-pw').value.trim(),
  };
  await saveConfig(newCfg);
  cfg = newCfg;
  hideSettings();
  showFeedback('✓ 设置已保存', 'ok');
  chrome.runtime.sendMessage({ type: 'restart-sse' });
  if (cfg.channelId) register(cfg, devId).catch(() => {});
});

// ── Helpers ───────────────────────────────────────────────────────────────────
function escHtml(str) {
  return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function timeAgo(ts) {
  const diff = (Date.now() - ts) / 1000;
  if (diff < 60)   return '刚刚';
  if (diff < 3600) return `${Math.floor(diff/60)}分钟前`;
  if (diff < 86400) return `${Math.floor(diff/3600)}小时前`;
  return `${Math.floor(diff/86400)}天前`;
}

// Auto-refresh inbox when background updates storage
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.inbox) loadInbox();
});

init();
