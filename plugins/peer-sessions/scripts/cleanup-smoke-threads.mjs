import crypto from 'node:crypto';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { resolveProviderExecutable } from '../server/session-manager.mjs';

class AppServerClient {
  constructor(executable) {
    this.pending = new Map();
    this.child = spawn(executable, ['app-server', '--listen', 'stdio://'], {
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
    });
    readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity }).on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.id === undefined) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message || 'Codex app-server request failed.'));
      else pending.resolve(message.result);
    });
    this.child.once('exit', (code) => {
      for (const pending of this.pending.values()) pending.reject(new Error(`Codex app-server exited with code ${code}.`));
      this.pending.clear();
    });
  }

  request(method, params = {}) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(`${JSON.stringify({ method, id, params })}\n`);
    });
  }

  notify(method, params = {}) {
    this.child.stdin.write(`${JSON.stringify({ method, params })}\n`);
  }

  close() {
    this.child.stdin.end();
    this.child.kill();
  }
}

const deleteMatches = process.argv.includes('--delete');
const client = new AppServerClient(await resolveProviderExecutable('codex'));
const matches = [];
let cursor = null;
try {
  await client.request('initialize', { clientInfo: { name: 'peer_sessions_cleanup', title: 'Peer Sessions cleanup', version: '0.1.0' } });
  client.notify('initialized');
  do {
    const page = await client.request('thread/list', {
      archived: false,
      cursor,
      limit: 100,
      sortKey: 'created_at',
      sortDirection: 'desc',
      sourceKinds: []
    });
    for (const thread of page.data || []) {
      if (/^Reply with exactly PEER_ACCEPT_CODEX_[123]\b/.test(thread.preview) ||
          /^This is a Peer Sessions transport smoke\b/i.test(thread.preview)) {
        matches.push(thread.id);
      }
    }
    cursor = page.nextCursor || null;
  } while (cursor);

  if (deleteMatches) {
    for (const threadId of matches) await client.request('thread/delete', { threadId });
    process.stdout.write(`Deleted ${matches.length} Peer Sessions smoke thread(s).\n`);
  } else {
    process.stdout.write(`Found ${matches.length} Peer Sessions smoke thread(s). Re-run with --delete to remove only those exact matches.\n`);
  }
} finally {
  client.close();
}
