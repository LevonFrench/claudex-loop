process.stdin.once('data', () => process.exit(7));
process.stdin.resume();
setInterval(() => {}, 1000);
