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
const GOFILE_THRESHOLD = 50 * 1024 * 1024; // 50 MB

$('btn-send-file').addEventListener('click', () => $('file-input').click());

$('file-input').addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  if (!cfg.channelId) { showSettings(); return; }
  showProgress(0);
  try {
    if (file.size > GOFILE_THRESHOLD) {
      const downloadUrl = await uploadToGoFile(file, p => showProgress(p * 0.95));
      const r = await fetch(`${cfg.server}/send`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from_device: devId, channel_id: cfg.channelId,
          msg_type: 'file', content: downloadUrl,
          filename: file.name, auth_token: cfg.authToken,
        }),
      });
      if (!r.ok) throw new Error(`发送失败 HTTP ${r.status}`);
    } else {
      await uploadToBeam(file, p => showProgress(p));
    }
    showProgress(1);
    hideProgress();
    showFeedback(`✓ 已发送 ${file.name}`, 'ok');
  } catch (err) {
    hideProgress();
    showFeedback(`✗ ${err.message}`, 'err');
  }
  e.target.value = '';
});

function uploadToBeam(file, onProgress) {
  return new Promise((resolve, reject) => {
    const form = new FormData();
    form.append('from_device', devId);
    form.append('channel_id',  cfg.channelId);
    form.append('auth_token',  cfg.authToken);
    form.append('file', file, file.name);
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `${cfg.server}/upload`);
    xhr.upload.onprogress = ev => {
      if (ev.lengthComputable) onProgress(ev.loaded / ev.total);
    };
    xhr.onload  = () => xhr.status === 200 ? resolve() : reject(new Error(`HTTP ${xhr.status}`));
    xhr.onerror = () => reject(new Error('网络错误'));
    xhr.send(form);
  });
}

async function uploadToGoFile(file, onProgress) {
  const res    = await fetch('https://api.gofile.io/servers');
  const data   = await res.json();
  const server = data.data.servers[0].name;
  return new Promise((resolve, reject) => {
    const form = new FormData();
    form.append('file', file, file.name);
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `https://${server}.gofile.io/contents/uploadFile`);
    xhr.upload.onprogress = ev => {
      if (ev.lengthComputable) onProgress(ev.loaded / ev.total);
    };
    xhr.onload = () => {
      if (xhr.status !== 200) { reject(new Error(`GoFile HTTP ${xhr.status}`)); return; }
      const json = JSON.parse(xhr.responseText);
      if (json.status !== 'ok') { reject(new Error('GoFile 上传失败')); return; }
      resolve(json.data.downloadPage);
    };
    xhr.onerror = () => reject(new Error('GoFile 网络错误'));
    xhr.send(form);
  });
}

function showProgress(p) {
  $('upload-progress').classList.remove('hidden');
  $('feedback').textContent = '';
  $('progress-fill').style.width = `${Math.round(p * 100)}%`;
  $('progress-text').textContent  = `上传中 ${Math.round(p * 100)}%`;
}

function hideProgress() {
  setTimeout(() => {
    $('upload-progress').classList.add('hidden');
    $('progress-fill').style.width = '0%';
  }, 300);
}

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
