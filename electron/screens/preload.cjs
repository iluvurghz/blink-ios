// Bridge for the small local window (update): one message channel each way.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('screenBridge', {
  send: (msg) => ipcRenderer.send('screen', msg),
  on: (cb) => ipcRenderer.on('screen', (_e, msg) => cb(msg)),
});
