const redis = require("redis");

const client = redis.createClient({
  url: process.env.REDIS_URL || "redis://127.0.0.1:6379",
  socket: {
    // Keep retrying (capped backoff) instead of giving up permanently after a
    // few attempts - a permanent giveup meant every request touching the
    // cache (e.g. GET /orders) started throwing ClientClosedError forever
    // once Redis was unavailable at boot, even if it came back up later.
    reconnectStrategy: retries => Math.min(retries * 200, 5000),
  },
});

let loggedError = false;
client.on("error", err => {
  if (!loggedError) {
    console.error("Redis error (caching endpoints will be unavailable):", err.message);
    loggedError = true;
  }
});

(async () => {
  try {
    await client.connect();
    console.log("✅ Redis connected");
  } catch (err) {
    console.error("Redis connection failed, continuing without cache:", err.message);
  }
})();

module.exports = client;
