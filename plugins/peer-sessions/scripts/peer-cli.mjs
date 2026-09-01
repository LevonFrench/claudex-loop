import { brokerRequest } from '../server/client.mjs';

const [command, ...args] = process.argv.slice(2);
let result;
switch (command) {
  case 'list': result = await brokerRequest('list'); break;
  case 'resolve': result = await brokerRequest('resolve', { name: args.join(' ') }); break;
  case 'status': result = await brokerRequest('status', { handle: args[0] }); break;
  case 'read': result = await brokerRequest('read', { handle: args[0], cursor: Number(args[1] || 0), maxChars: 262144 }); break;
  case 'view': result = await brokerRequest('view', { handle: args[0] }); break;
  case 'stop': result = await brokerRequest('stop', { handle: args[0] }); break;
  case 'broker-stop': result = await brokerRequest('shutdown'); break;
  default: throw new Error('Usage: npm run peer -- list|resolve <name>|status <handle>|read <handle> [cursor]|view <handle>|stop <handle>|broker-stop');
}
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
