import crypto from 'node:crypto';
import path from 'node:path';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { PLUGIN_ROOT } from '../server/runtime.mjs';

export class McpClient {
  constructor() {
    this.pending = new Map();
    this.child = spawn(process.execPath, [path.join(PLUGIN_ROOT, 'server', 'mcp-stdio.mjs')], {
      cwd: PLUGIN_ROOT, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
    });
    readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity }).on('line', (line) => {
      const message = JSON.parse(line);
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
    this.child.once('exit', (code) => {
      for (const pending of this.pending.values()) pending.reject(new Error(`MCP server exited with code ${code}.`));
      this.pending.clear();
    });
  }

  request(method, params = {}) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });
  }

  async initialize() {
    return this.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'peer-acceptance', version: '1' } });
  }

  async callTool(name, args = {}) {
    const response = await this.request('tools/call', { name, arguments: args });
    if (response.isError) throw new Error(response.content?.[0]?.text || `${name} failed.`);
    return response.structuredContent;
  }

  close() {
    this.child.stdin.end();
    this.child.kill();
  }
}
