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
            AB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Float64Array) return 1;
        return 2;
      },
      AC: (wasmFunction,f) => finalizeWrapper(f, function(x0,x1) { return wasmFunction(f,arguments.length,x0,x1) }),
      B: s => printToConsole(s),
      BB: Function.prototype.call.bind(DataView.prototype.setFloat64),
      BC: (p, s, f) => p.then(s, (e) => f(e, e === undefined)),
      C: Function.prototype.call.bind(Number.prototype.toString),
      CB: (t, s) => t.set(s),
      CC: (c) =>
      queueMicrotask(() => dartInstance.exports.$invokeCallback(c)),
      D: Function.prototype.call.bind(BigInt.prototype.toString),
      DB: Function.prototype.call.bind(DataView.prototype.setFloat32),
      DC: o => o,
      E: (exn) => {
        let stackString = exn.toString();
        let frames = stackString.split('\n');
        let drop = 4;
        if (frames[0].startsWith('Error')) {
            drop += 1;
        }
        return frames.slice(drop).join('\n');
      },
      EB: Function.prototype.call.bind(DataView.prototype.getFloat32),
      EC: (o, i) => o[i],
      F: () => new Error().stack,
      FB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Float32Array) return 1;
        return 2;
      },
      FC: o => o.length,
      G: s => JSON.stringify(s),
      GB: Function.prototype.call.bind(DataView.prototype.getUint32),
      GC: o => {
        const proto = Object.getPrototypeOf(o);
        return proto === Object.prototype || proto === null;
      },
      H: Function.prototype.call.bind(Number.prototype.toString),
      HB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Uint32Array) return 1;
        return 2;
      },
      HC: o => {
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
      I: Function.prototype.call.bind(String.prototype.indexOf),
      IB: Function.prototype.call.bind(DataView.prototype.getInt32),
      IC: o => {
        if (o === undefined || o === null) return 0;
        if (typeof o === 'boolean') return 1;
        return 2;
      },
      J: (s, p, i) => s.lastIndexOf(p, i),
      JB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Int32Array) return 1;
        return 2;
      },
      K: (exn) => {
        if (exn instanceof Error) {
          return exn.stack;
        } else {
          return null;
        }
      },
      KB: Function.prototype.call.bind(DataView.prototype.getUint16),
      L: o => String(o),
      LB: o => o instanceof Uint16Array,
      M: o => o === undefined,
      MB: Function.prototype.call.bind(DataView.prototype.getInt16),
      N: (wasmFunction,f) => finalizeWrapper(f, function(x0) { return wasmFunction(f,arguments.length,x0) }),
      NB: o => o instanceof Int16Array,
      O: (x0,x1) => x0.postMessage(x1),
      OB: o => o instanceof Uint8ClampedArray,
      P: (x0,x1) => { x0.onmessage = x1 },
      PB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Uint8Array) return 1;
        return 2;
      },
      Q: (x0,x1,x2) => x0.postMessage(x1,x2),
      QB: Function.prototype.call.bind(DataView.prototype.setInt32),
      R: () => ({}),
      RB: Function.prototype.call.bind(DataView.prototype.setUint32),
      S: (o, p, v) => o[p] = v,
      SB: Function.prototype.call.bind(DataView.prototype.setInt16),
      T: () => [],
      TB: Function.prototype.call.bind(DataView.prototype.setUint16),
      U: (a, i) => a.push(i),
      UB: Function.prototype.call.bind(DataView.prototype.setUint8),
      V: x0 => x0.random(),
      VB: Function.prototype.call.bind(DataView.prototype.setInt8),
      W: o => o,
      WB: Function.prototype.call.bind(DataView.prototype.getInt8),
      X: o => {
        if (o === undefined || o === null) return 0;
        if (typeof o === 'number') return 1;
        return 2;
      },
      XB: o => {
        if (o === null || o === undefined) return 0;
        if (o instanceof Int8Array) return 1;
        return 2;
      },
      Y: () => globalThis.Math,
      YB: o => o,
      Z: x0 => new Int8Array(x0),
      ZB: (o, start, length) => new Float64Array(o.buffer, o.byteOffset + start, length),
      a: x0 => new Uint8Array(x0),
      aB: (o, start, length) => new Float32Array(o.buffer, o.byteOffset + start, length),
      b: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmI8ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      bB: (o, start, length) => new Uint32Array(o.buffer, o.byteOffset + start, length),
      c: x0 => new Uint8ClampedArray(x0),
      cB: (o, start, length) => new Int32Array(o.buffer, o.byteOffset + start, length),
      d: x0 => new Int16Array(x0),
      dB: (o, start, length) => new Uint16Array(o.buffer, o.byteOffset + start, length),
      e: x0 => new Uint16Array(x0),
      eB: (o, start, length) => new Int16Array(o.buffer, o.byteOffset + start, length),
      f: x0 => new Int32Array(x0),
      fB: (o, start, length) => new Uint8ClampedArray(o.buffer, o.byteOffset + start, length),
      g: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmI32ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      gB: (o, start, length) => new Uint8Array(o.buffer, o.byteOffset + start, length),
      h: x0 => new Uint32Array(x0),
      hB: (o, start, length) => new Int8Array(o.buffer, o.byteOffset + start, length),
      i: x0 => new Float32Array(x0),
      iB: b => !!b,
      j: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmF32ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      jB: (o, t) => typeof o === t,
      k: x0 => new Float64Array(x0),
      kB: (o, p) => o[p],
      l: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const getValue = dartInstance.exports.$wasmF64ArrayGet;
        for (let i = 0; i < length; i++) {
          jsArray[jsArrayOffset + i] = getValue(wasmArray, wasmArrayOffset + i);
        }
      },
      lB: x0 => x0.data,
      m: x0 => new ArrayBuffer(x0),
      mB: () => globalThis,
      n: (x0,x1,x2) => new Uint8Array(x0,x1,x2),
      nB: () => typeof dartUseDateNowForTicks !== "undefined",
      o: (x0,x1,x2) => new DataView(x0,x1,x2),
      oB: () => Date.now(),
      p: (o, p) => o[p],
      pB: () => 1000 * performance.now(),
      q: x0 => new Array(x0),
      qB: (l, r) => l === r,
      r: (x0,x1,x2) => { x0[x1] = x2 },
      rB: (jsArray, jsArrayOffset, wasmArray, wasmArrayOffset, length) => {
        const setValue = dartInstance.exports.$wasmI8ArraySet;
        for (let i = 0; i < length; i++) {
          setValue(wasmArray, wasmArrayOffset + i, jsArray[jsArrayOffset + i]);
        }
      },
      s: (o) => new DataView(o.buffer, o.byteOffset, o.byteLength),
      sB: (a, i) => a[i],
      t: Function.prototype.call.bind(Object.getOwnPropertyDescriptor(DataView.prototype, 'byteLength').get),
      tB: a => a.length,
      u: o => o.buffer,
      uB: o => o instanceof Array,
      v: Function.prototype.call.bind(DataView.prototype.getUint8),
      vB: x0 => x0.length,
      w: (b, o) => new DataView(b, o),
      wB: o => Object.keys(o),
      x: (b, o, l) => new DataView(b, o, l),
      xB: f => f.dartFunction,
      y: o => o.byteOffset,
      yB: o => typeof o === 'function' && o[jsWrappedDartFunctionSymbol] === true,
      z: Function.prototype.call.bind(DataView.prototype.getFloat64),
      zB: (wasmFunction,f) => finalizeWrapper(f, function(x0) { return wasmFunction(f,arguments.length,x0) }),

    };

    const baseImports = {
      _: dart2wasm,
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
