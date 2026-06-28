// Beam API client
export async function register(cfg, devId) {
  await fetch(`${cfg.server}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      device_id:   devId,
      channel_id:  cfg.channelId,
      device_type: 'chrome',
      auth_token:  cfg.authToken,
    }),
  });
}

export async function sendText(cfg, devId, text) {
  const r = await fetch(`${cfg.server}/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from_device: devId,
      channel_id:  cfg.channelId,
      msg_type:    'text',
      content:     text,
      auth_token:  cfg.authToken,
    }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function sendFile(cfg, devId, file) {
  const form = new FormData();
  form.append('from_device', devId);
  form.append('channel_id',  cfg.channelId);
  form.append('auth_token',  cfg.authToken);
  form.append('file', file, file.name);
  const r = await fetch(`${cfg.server}/upload`, { method: 'POST', body: form });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function ack(cfg, devId, messageId) {
  await fetch(`${cfg.server}/ack`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message_id: messageId,
      device_id:  devId,
      auth_token: cfg.authToken,
    }),
  }).catch(() => {});
}
