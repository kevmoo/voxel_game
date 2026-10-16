import { compileStreaming } from './worker.mjs';

compileStreaming(fetch('worker.wasm')).then(app => {
  return app.instantiate({});
}).then(inst => {
  inst.invokeMain();
});
