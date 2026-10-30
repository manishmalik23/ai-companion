import { contextBridge, ipcRenderer } from 'electron';
const subscribe = (channel: string, callback: (state?: unknown) => void) => {
  const listener = (_event: Electron.IpcRendererEvent, value?: unknown) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};
contextBridge.exposeInMainWorld('pip', {
  decision: (id: string, decision: 'allow' | 'deny') => ipcRenderer.invoke('pip:decision', id, decision),
  answer: (id: string, answers: Record<string, string>) => ipcRenderer.invoke('pip:answer', id, answers),
  defer: (id: string) => ipcRenderer.invoke('pip:defer', id),
  dismiss: (id: string) => ipcRenderer.invoke('pip:dismiss', id),
  openSession: (id: string, snapshot: string) => ipcRenderer.invoke('pip:open-session', id, snapshot),
  selectCharacter: (choice: string) => ipcRenderer.invoke('pip:select-character', choice),
  regions: (value: unknown) => ipcRenderer.send('pip:regions', value),
  beginDrag: () => ipcRenderer.send('pip:drag-start'),
  endDrag: () => ipcRenderer.send('pip:drag-end'),
  openChat: (provider: 'claude' | 'chatgpt') => ipcRenderer.invoke('pip:open-chat', provider),
  quit: () => ipcRenderer.send('pip:quit'),
  onAppearance: (callback: () => void) => subscribe('pip:show-appearance', callback),
  onState: (callback: (state: unknown) => void) => subscribe('pip:state', callback)
});
