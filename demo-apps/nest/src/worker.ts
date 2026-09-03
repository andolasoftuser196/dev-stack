// The `queue` role runs this. A real project would consume from BullMQ here;
// the demo only needs to prove the worker container starts, stays up, and is
// restarted by the entrypoint rather than by compose.
const every = Number(process.env.WORKER_TICK_SECONDS ?? 30) * 1000;

setInterval(() => {
  console.log(JSON.stringify({
    level: 'info', msg: 'worker tick', instance: process.env.SSMD_INSTANCE ?? 'main',
  }));
}, every);

console.log(JSON.stringify({ level: 'info', msg: 'worker started' }));
