chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'copy' && msg.text) {
    navigator.clipboard.writeText(msg.text).catch(() => {});
  }
});
