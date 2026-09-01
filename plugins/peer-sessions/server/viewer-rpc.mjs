import { brokerRequest } from './client.mjs';

// Viewers only mirror an existing broker; they must never start one. A viewer that
// outlives its broker would otherwise resurrect an empty daemon on every poll.
const options = { spawn: false };
const [action, ...args] = process.argv.slice(2);
let result;
switch (action) {
  case 'status':
    result = await brokerRequest('status', { handle: args[0] }, options);
    break;
  case 'read':
    result = await brokerRequest('read', { handle: args[0], cursor: Number(args[1]) || 0, maxChars: 65536 }, options);
    break;
  case 'send':
    result = await brokerRequest('send', { handle: args[0], text: Buffer.from(args[1] || '', 'base64').toString('utf8') }, options);
    break;
  case 'event':
    result = await brokerRequest('viewerEvent', {
      handle: args[0], viewerId: args[1], event: args[2],
      message: args[3] ? Buffer.from(args[3], 'base64').toString('utf8') : ''
    }, options);
    break;
  default:
    throw new Error('Unknown viewer RPC action.');
}
process.stdout.write(`${JSON.stringify(result)}\n`);
