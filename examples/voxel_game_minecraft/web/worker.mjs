// Compiles a dart2wasm-generated main module from `source` which can then
// be instantiated via the `instantiate` method.
//
// `source` needs to be a `Response` object (or promise thereof) e.g. created
// via the `fetch()` JS API.
export async function compileStreaming(source) {
  const builtins = {builtins: ['js-string'], importedStringConstants: ''};
  return new CompiledApp(
      await _compileStreaming(source, builtins), builtins);
}

// Compiles a dart2wasm-generated wasm module from `bytes` which is then
// instantiable via the `instantiate` method.
export async function compile(bytes) {
  const builtins = {builtins: ['js-string'], importedStringConstants: ''};
  return new CompiledApp(await WebAssembly.compile(bytes, builtins), builtins);
}

let _isCompileStreamingSupported;
async function _compileStreaming(source, builtins) {
  _isCompileStreamingSupported ??= WebAssembly.compileStreaming(
    new Response(
      new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,23,1,14,119,97,115,109,58,106,115,45,115,116,114,105,110,103,4,99,97,115,116,0,0]),
      {headers: {'Content-Type': 'application/wasm'}},
    ),
    builtins,
  ).then(() => false, (e) => e instanceof WebAssembly.CompileError);
  if (await _isCompileStreamingSupported) {
    return WebAssembly.compileStreaming(source, builtins);
  }
  return WebAssembly.compile(await (await source).arrayBuffer(), builtins);
}

class CompiledApp {
  constructor(module, builtins) {
    this.module = module;
    this.builtins = builtins;
  }

  // The second argument is an options object containing:
  // `loadDeferredModules` is a JS function that takes an array of module names
  //   matching wasm files produced by the dart2wasm compiler. It also takes a
  //   callback that should be invoked for each loaded module with 2 arguments:
  //   (1) the module name, (2) the loaded module in a format supported by
  //   `WebAssembly.compile` or `WebAssembly.compileStreaming`. The callback
  //   returns a Promise that resolves when the module is instantiated.
  //   loadDeferredModules should return a Promise that resolves when all the
  //   modules have been loaded and the callback promises have resolved.
  // `loadDeferredId` is a JS function that takes load ID produced by the
  //   compiler when the `use-load-ids` option is passed. Each load ID maps to
  //   one or more wasm files as specified in the emitted JSON file. It also
  //   takes a callback that should be invoked for each loaded module with 2
  //   arguments: (1) the module name, (2) the loaded module in a format
  //   supported by `WebAssembly.compile` or `WebAssembly.compileStreaming`.
  //   The callback returns a Promise that resolves when the module is
  //   instantiated.
  //   loadDeferredId should return a Promise that resolves when all the
  //   modules have been loaded and the callback promises have resolved.
  async instantiate(additionalImports, {loadDeferredModules, loadDeferredId} = {}) {
    let dartInstance;

    // Prints to the console
    function printToConsole(value) {
      if (typeof dartPrint == "function") {
        dartPrint(value);
        return;
      }
      if (typeof console == "object" && typeof console.log != "undefined") {
        console.log(value);
        return;
      }
      if (typeof print == "function") {
        print(value);
        return;
      }

      throw "Unable to print message: " + value;
    }

    // A special symbol attached to functions that wrap Dart functions.
    const jsWrappedDartFunctionSymbol = Symbol("JSWrappedDartFunction");

    function finalizeWrapper(dartFunction, wrapped) {
      wrapped.dartFunction = dartFunction;
      wrapped[jsWrappedDartFunctionSymbol] = true;
      return wrapped;
    }

    // Imports
    const dart2wasm = {
            AB: x0 => new Uint8ClampedArray(x0),
      AC: (o, i) => o[i],
      B: s => printToConsole(s),
      BB: x0 => new Int16Array(x0),
      BC: o => o.length,
      C: Function.prototype.call.bind(Number.prototype.toString),
      CB: x0 => new Uint16Array(x0),
      CC: o => {
        const proto = Object.getPrototypeOf(o);
        return proto === Object.prototype || proto === null;
      },
      D: Function.prototype.call.bind(BigInt.prototype.toString),
      DB: x0 => new Uint32Array(x0),
      DC: o => {
        if (o === undefined) return 1;
        var type = typeof o;
        if (type === 'boolean') return 2;
        if (type === 'number') return 3;
        if (type === 'string') return 4;
        if (o instanceof Array) return 5;
        if (ArrayBuffer.isView(o)) {
          if (o instanceof Int8Array) return 6;
          if (o instanceof Uint8Array) return 7;
          if (o instanceof Uint8ClampedArray) return 8;
          if (o instanceof Int16Array) return 9;
          if (o instanceof Uint16Array) return 10;
          if (o instanceof Int32Array) return 11;
          if (o instanceof Uint32Array) return 12;
          if (o instanceof Float32Array) return 13;
          if (o instanceof Float64Array) return 14;
          if (o instanceof DataView) return 15;
        }
        if (o instanceof ArrayBuffer) return 16;
        // Feature check for `SharedArrayBuffer` before doing a type-check.
        if (globalThis.SharedArrayBuffer !== undefined &&
            o instanceof SharedArrayBuffer) {
            return 17;
        }
        if (o instanceof Promise) return 18;
        return 19;
      },
      E: (exn) => {
        let stackString = exn.toString();
        let frames = stackString.split('\n');
        let drop = 4;
        if (frames[0].startsWith('Error')) {
            drop += 1;
        }
        return frames.slice(drop).join('\n');
      },
      EB: x0 => new Float64Array(x0),
      EC: o => {
        if (o === undefined || o === null) return 0;
        if (typeof o === 'boolean') return 1;
        return 2;
      },
      F: () => new Error().stack,
      FB: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmF64ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      FC: (o, t) => typeof o === t,
      G: s => JSON.stringify(s),
      GB: x0 => new ArrayBuffer(x0),
      GC: (o, p) => o[p],
      H: Function.prototype.call.bind(Number.prototype.toString),
      HB: (x0,x1,x2) => new Uint8Array(x0,x1,x2),
      HC: x0 => x0.data,
      I: Function.prototype.call.bind(String.prototype.indexOf),
      IB: (x0,x1,x2) => new DataView(x0,x1,x2),
      IC: () => globalThis,
      J: (exn) => {
        if (exn instanceof Error) {
          return exn.stack;
        } else {
          return null;
        }
      },
      JB: (o, p) => o[p],
      K: o => String(o),
      KB: (b, o) => new DataView(b, o),
      L: o => o === undefined,
      LB: (b, o, l) => new DataView(b, o, l),
      M: (wasmFunction,f) => finalizeWrapper(f, function(x0) { return wasmFunction(f,arguments.length,x0) }),
      MB: x0 => new Array(x0),
      N: (x0,x1) => x0.postMessage(x1),
      NB: (x0,x1,x2) => { x0[x1] = x2 },
      O: (x0,x1) => { x0.onmessage = x1 },
      OB: Function.prototype.call.bind(DataView.prototype.setUint8),
      P: (x0,x1,x2) => x0.postMessage(x1,x2),
      PB: o => o.byteOffset,
      Q: Function.prototype.call.bind(DataView.prototype.getUint8),
      QB: Function.prototype.call.bind(DataView.prototype.setFloat64),
      R: Function.prototype.call.bind(DataView.prototype.getFloat32),
      RB: Function.prototype.call.bind(DataView.prototype.getFloat64),
      S: () => typeof dartUseDateNowForTicks !== "undefined",
      SB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Float64Array) return 1;
        return 2;
      },
      T: () => Date.now(),
      TB: Function.prototype.call.bind(DataView.prototype.setUint32),
      U: () => 1000 * performance.now(),
      UB: Function.prototype.call.bind(DataView.prototype.getUint32),
      V: (l, r) => l === r,
      VB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Uint32Array) return 1;
        return 2;
      },
      W: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const setValue = dartInstance.exports.$wasmI8ArraySet;
        for (let i = 0; i < length; i++) {
          setValue(wasmArray, wasmArrayOffset + i, jsArray[jsArrayOffset + i]);
        }
      },
      WB: Function.prototype.call.bind(DataView.prototype.setUint16),
      X: (o, start, length) => new Uint8Array(o.buffer, o.byteOffset + start, length),
      XB: Function.prototype.call.bind(DataView.prototype.getUint16),
      Y: (a, i) => a[i],
      YB: o => o instanceof Uint16Array,
      Z: a => a.length,
      ZB: Function.prototype.call.bind(DataView.prototype.setInt16),
      a: o => o instanceof Array,
      aB: Function.prototype.call.bind(DataView.prototype.getInt16),
      b: x0 => new Int32Array(x0),
      bB: o => o instanceof Int16Array,
      c: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmI32ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      cB: o => o instanceof Uint8ClampedArray,
      d: (t, s) => t.set(s),
      dB: Function.prototype.call.bind(DataView.prototype.setInt8),
      e: (o) => new DataView(o.buffer, o.byteOffset, o.byteLength),
      eB: Function.prototype.call.bind(DataView.prototype.getInt8),
      f: Function.prototype.call.bind(Object.getOwnPropertyDescriptor(DataView.prototype, 'byteLength').get),
      fB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Int8Array) return 1;
        return 2;
      },
      g: Function.prototype.call.bind(DataView.prototype.setInt32),
      gB: (o, start, length) => new Float64Array(o.buffer, o.byteOffset + start, length),
      h: (o, start, length) => new Int32Array(o.buffer, o.byteOffset + start, length),
      hB: (o, start, length) => new Float32Array(o.buffer, o.byteOffset + start, length),
      i: o => o.buffer,
      iB: (o, start, length) => new Uint32Array(o.buffer, o.byteOffset + start, length),
      j: Function.prototype.call.bind(DataView.prototype.getInt32),
      jB: (o, start, length) => new Uint16Array(o.buffer, o.byteOffset + start, length),
      k: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Int32Array) return 1;
        return 2;
      },
      kB: (o, start, length) => new Int16Array(o.buffer, o.byteOffset + start, length),
      l: o => o,
      lB: (o, start, length) => new Uint8ClampedArray(o.buffer, o.byteOffset + start, length),
      m: x0 => new Float32Array(x0),
      mB: (o, start, length) => new Int8Array(o.buffer, o.byteOffset + start, length),
      n: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmF32ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      nB: b => !!b,
      o: x0 => x0.length,
      oB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Uint8Array) return 1;
        return 2;
      },
      p: o => o,
      pB: Function.prototype.call.bind(DataView.prototype.setFloat32),
      q: o => {
        if (o === undefined || o === null) return 0;
        if (typeof o === 'number') return 1;
        return 2;
      },
      qB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Float32Array) return 1;
        return 2;
      },
      r: x0 => new Uint8Array(x0),
      rB: o => Object.keys(o),
      s: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmI8ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      sB: f => f.dartFunction,
      t: x0 => x0.random(),
      tB: o => typeof o === 'function' && o[jsWrappedDartFunctionSymbol] === true,
      u: () => globalThis.Math,
      uB: (wasmFunction,f) => finalizeWrapper(f, function(x0) { return wasmFunction(f,arguments.length,x0) }),
      v: () => ({}),
      vB: (wasmFunction,f) => finalizeWrapper(f, function(x0,x1) { return wasmFunction(f,arguments.length,x0,x1) }),
      w: (o, p, v) => o[p] = v,
      wB: (p, s, f) => p.then(s, (e) => f(e, e === undefined)),
      x: () => [],
      xB: (c) =>
      queueMicrotask(() => dartInstance.exports.$invokeCallback(c)),
      y: (a, i) => a.push(i),
      yB: (s, p, i) => s.lastIndexOf(p, i),
      z: x0 => new Int8Array(x0),
      zB: o => o,

    };

    const baseImports = {
      dart2wasm: dart2wasm,
      Math: Math,
      Date: Date,
      Object: Object,
      Array: Array,
      Reflect: Reflect,
      WebAssembly: {
        JSTag: WebAssembly.JSTag,
      },
      "": new Proxy({}, { get(_, prop) { return prop; } }),

    };

    

    dartInstance = await WebAssembly.instantiate(this.module, {
      ...baseImports,
      ...additionalImports,
      
    });

    return new InstantiatedApp(this, dartInstance);
  }
}

class InstantiatedApp {
  constructor(compiledApp, instantiatedModule) {
    this.compiledApp = compiledApp;
    this.instantiatedModule = instantiatedModule;
  }

  // Call the main function with the given arguments.
  invokeMain(...args) {
    this.instantiatedModule.exports.$invokeMain(args);
  }
}
