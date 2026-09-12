import { createApp } from './server.js';

const port = Number(process.env.PORT) || 7000;
createApp().listen(port, () => {
  console.log(`stalker-stremio-addon listening on http://0.0.0.0:${port}`);
  console.log(`Open http://localhost:${port} to configure a portal.`);
});
