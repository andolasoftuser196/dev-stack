// The `scheduler` role runs this, once per tick, forever.
console.log(JSON.stringify({
  level: 'info', msg: 'scheduler tick', instance: process.env.SSMD_INSTANCE ?? 'main',
}));
