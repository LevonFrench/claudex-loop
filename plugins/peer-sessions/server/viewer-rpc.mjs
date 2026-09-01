import { brokerRequest } from './client.mjs';

const [action, ...args] = process.argv.slice(2);
let result;
switch (action) {
  case 'status':
    result = await brokerRequest('status', { handle: args[0] });
    break;
  case 'read':
    result = await brokerRequest('read', { handle: args[0], cursor: Number(args[1]) || 0, maxChars: 65536 });
    break;
  case 'send':
    result = await brokerRequest('send', { handle: args[0], text: Buffer.from(args[1] || '', 'base64').toString('utf8') });
    break;
  case 'event':
    result = await brokerRequest('viewerEvent', {
      handle: args[0], viewerId: args[1], event: args[2],
      message: args[3] ? Buffer.from(args[3], 'base64').toString('utf8') : ''
    });
    break;
  default:
    throw new Error('Unknown viewer RPC action.');
}
process.stdout.write(`${JSON.stringify(result)}\n`);
