// .build/plugins/PackageToJS/outputs/Package/runtime.js
var SwiftClosureDeallocator = class {
  constructor(exports$1) {
    if (typeof FinalizationRegistry === "undefined") {
      throw new Error("The Swift part of JavaScriptKit was configured to require the availability of JavaScript WeakRefs. Please build with `-Xswiftc -DJAVASCRIPTKIT_WITHOUT_WEAKREFS` to disable features that use WeakRefs.");
    }
    this.functionRegistry = new FinalizationRegistry((id) => {
      exports$1.swjs_free_host_function(id);
    });
  }
  track(func, func_ref) {
    this.functionRegistry.register(func, func_ref);
  }
};
function assertNever(x, message) {
  throw new Error(message);
}
var MAIN_THREAD_TID = -1;
var decode = (kind, payload1, payload2, objectSpace) => {
  switch (kind) {
    case 0:
      switch (payload1) {
        case 0:
          return false;
        case 1:
          return true;
      }
    // falls through
    case 2:
      return payload2;
    case 1:
    case 3:
    case 7:
    case 8:
      return objectSpace.getObject(payload1);
    case 4:
      return null;
    case 5:
      return void 0;
    default:
      assertNever(kind, `JSValue Type kind "${kind}" is not supported`);
  }
};
var decodeArray = (ptr, length, memory, objectSpace) => {
  const basePtr = ptr >>> 0;
  const count = length >>> 0;
  if (count === 0) {
    return [];
  }
  let result = [];
  for (let index = 0; index < count; index++) {
    const base = basePtr + 16 * index;
    const kind = memory.getUint32(base, true);
    const payload1 = memory.getUint32(base + 4, true);
    const payload2 = memory.getFloat64(base + 8, true);
    result.push(decode(kind, payload1, payload2, objectSpace));
  }
  return result;
};
var write = (value, kind_ptr, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace) => {
  const kind = writeAndReturnKindBits(value, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace);
  memory.setUint32(kind_ptr >>> 0, kind, true);
};
var writeAndReturnKindBits = (value, payload1_ptr, payload2_ptr, is_exception, memory, objectSpace) => {
  const exceptionBit = (is_exception ? 1 : 0) << 31;
  const payload1Offset = payload1_ptr >>> 0;
  const payload2Offset = payload2_ptr >>> 0;
  if (value === null) {
    return exceptionBit | 4;
  }
  const writeRef = (kind) => {
    memory.setUint32(payload1Offset, objectSpace.retain(value), true);
    return exceptionBit | kind;
  };
  const type = typeof value;
  switch (type) {
    case "boolean": {
      memory.setUint32(payload1Offset, value ? 1 : 0, true);
      return exceptionBit | 0;
    }
    case "number": {
      memory.setFloat64(payload2Offset, value, true);
      return exceptionBit | 2;
    }
    case "string": {
      return writeRef(
        1
        /* Kind.String */
      );
    }
    case "undefined": {
      return exceptionBit | 5;
    }
    case "object": {
      return writeRef(
        3
        /* Kind.Object */
      );
    }
    case "function": {
      return writeRef(
        3
        /* Kind.Object */
      );
    }
    case "symbol": {
      return writeRef(
        7
        /* Kind.Symbol */
      );
    }
    case "bigint": {
      return writeRef(
        8
        /* Kind.BigInt */
      );
    }
    default:
      assertNever(type, `Type "${type}" is not supported yet`);
  }
  throw new Error("Unreachable");
};
function decodeObjectRefs(ptr, length, memory) {
  const basePtr = ptr >>> 0;
  const count = length >>> 0;
  const result = new Array(count);
  for (let i = 0; i < count; i++) {
    result[i] = memory.getUint32(basePtr + 4 * i, true);
  }
  return result;
}
var ITCInterface = class {
  constructor(memory) {
    this.memory = memory;
  }
  send(sendingObject, transferringObjects, sendingContext) {
    const object = this.memory.getObject(sendingObject);
    const transfer = transferringObjects.map((ref) => this.memory.getObject(ref));
    return { object, sendingContext, transfer };
  }
  sendObjects(sendingObjects, transferringObjects, sendingContext) {
    const objects = sendingObjects.map((ref) => this.memory.getObject(ref));
    const transfer = transferringObjects.map((ref) => this.memory.getObject(ref));
    return { object: objects, sendingContext, transfer };
  }
  invokeRemoteJSObjectBody(invocationContext) {
    return { object: void 0, transfer: [] };
  }
  release(objectRef) {
    this.memory.release(objectRef);
    return { object: void 0, transfer: [] };
  }
};
var MessageBroker = class {
  constructor(selfTid, threadChannel, handlers) {
    this.selfTid = selfTid;
    this.threadChannel = threadChannel;
    this.handlers = handlers;
  }
  request(message) {
    if (message.data.targetTid == this.selfTid) {
      this.handlers.onRequest(message);
    } else if ("postMessageToWorkerThread" in this.threadChannel) {
      this.threadChannel.postMessageToWorkerThread(message.data.targetTid, message, []);
    } else if ("postMessageToMainThread" in this.threadChannel) {
      this.threadChannel.postMessageToMainThread(message, []);
    } else {
      throw new Error("unreachable");
    }
  }
  reply(message) {
    if (message.data.sourceTid == this.selfTid) {
      this.handlers.onResponse(message);
      return;
    }
    const transfer = message.data.response.ok ? message.data.response.value.transfer : [];
    if ("postMessageToWorkerThread" in this.threadChannel) {
      this.threadChannel.postMessageToWorkerThread(message.data.sourceTid, message, transfer);
    } else if ("postMessageToMainThread" in this.threadChannel) {
      this.threadChannel.postMessageToMainThread(message, transfer);
    } else {
      throw new Error("unreachable");
    }
  }
  onReceivingRequest(message) {
    if (message.data.targetTid == this.selfTid) {
      this.handlers.onRequest(message);
    } else if ("postMessageToWorkerThread" in this.threadChannel) {
      this.threadChannel.postMessageToWorkerThread(message.data.targetTid, message, []);
    } else if ("postMessageToMainThread" in this.threadChannel) {
      throw new Error("unreachable");
    }
  }
  onReceivingResponse(message) {
    if (message.data.sourceTid == this.selfTid) {
      this.handlers.onResponse(message);
    } else if ("postMessageToWorkerThread" in this.threadChannel) {
      const transfer = message.data.response.ok ? message.data.response.value.transfer : [];
      this.threadChannel.postMessageToWorkerThread(message.data.sourceTid, message, transfer);
    } else if ("postMessageToMainThread" in this.threadChannel) {
      throw new Error("unreachable");
    }
  }
};
function serializeError(error) {
  if (error instanceof Error) {
    return {
      isError: true,
      value: {
        message: error.message,
        name: error.name,
        stack: error.stack
      }
    };
  }
  return { isError: false, value: error };
}
function deserializeError(error) {
  if (error.isError) {
    return Object.assign(new Error(error.value.message), error.value);
  }
  return error.value;
}
var globalVariable = globalThis;
var SLOT_BITS = 24;
var SLOT_MASK = (1 << SLOT_BITS) - 1;
var GEN_MASK = (1 << 32 - SLOT_BITS) - 1;
var JSObjectSpace = class {
  constructor() {
    this._slotByValue = /* @__PURE__ */ new Map();
    this._values = [];
    this._stateBySlot = [];
    this._freeSlotStack = [];
    this._values[0] = void 0;
    this._values[1] = globalVariable;
    this._slotByValue.set(globalVariable, 1);
    this._stateBySlot[1] = 1;
  }
  retain(value) {
    const slot = this._slotByValue.get(value);
    if (slot !== void 0) {
      const state2 = this._stateBySlot[slot];
      const nextState = state2 + 1 >>> 0;
      if ((nextState & SLOT_MASK) === 0) {
        throw new RangeError(`Reference count overflow at slot ${slot}`);
      }
      this._stateBySlot[slot] = nextState;
      return (nextState & ~SLOT_MASK | slot) >>> 0;
    }
    let newSlot;
    let state;
    if (this._freeSlotStack.length > 0) {
      newSlot = this._freeSlotStack.pop();
      const gen = this._stateBySlot[newSlot] >>> SLOT_BITS;
      state = (gen << SLOT_BITS | 1) >>> 0;
    } else {
      newSlot = this._values.length;
      if (newSlot > SLOT_MASK) {
        throw new RangeError(`Reference slot overflow: ${newSlot} exceeds ${SLOT_MASK}`);
      }
      state = 1;
    }
    this._stateBySlot[newSlot] = state;
    this._values[newSlot] = value;
    this._slotByValue.set(value, newSlot);
    return (state & ~SLOT_MASK | newSlot) >>> 0;
  }
  retainByRef(reference) {
    const state = this._getValidatedSlotState(reference);
    const slot = reference & SLOT_MASK;
    const nextState = state + 1 >>> 0;
    if ((nextState & SLOT_MASK) === 0) {
      throw new RangeError(`Reference count overflow at slot ${slot}`);
    }
    this._stateBySlot[slot] = nextState;
    return reference;
  }
  release(reference) {
    const state = this._getValidatedSlotState(reference);
    const slot = reference & SLOT_MASK;
    if ((state & SLOT_MASK) > 1) {
      this._stateBySlot[slot] = state - 1 >>> 0;
      return;
    }
    this._slotByValue.delete(this._values[slot]);
    this._values[slot] = void 0;
    const nextGen = (state >>> SLOT_BITS) + 1 & GEN_MASK;
    this._stateBySlot[slot] = nextGen << SLOT_BITS >>> 0;
    this._freeSlotStack.push(slot);
  }
  getObject(reference) {
    this._getValidatedSlotState(reference);
    return this._values[reference & SLOT_MASK];
  }
  // Returns the packed state for the slot, after validating the reference.
  _getValidatedSlotState(reference) {
    const slot = reference & SLOT_MASK;
    if (slot === 0)
      throw new ReferenceError(`Attempted to use invalid reference ${reference}`);
    const state = this._stateBySlot[slot];
    if (state === void 0 || (state & SLOT_MASK) === 0) {
      throw new ReferenceError(`Attempted to use invalid reference ${reference}`);
    }
    if (state >>> SLOT_BITS !== reference >>> SLOT_BITS) {
      throw new ReferenceError(`Attempted to use stale reference ${reference}`);
    }
    return state;
  }
};
var SwiftRuntime = class {
  constructor(options) {
    this.version = 708;
    this.textDecoder = new TextDecoder("utf-8");
    this.textEncoder = new TextEncoder();
    this.UnsafeEventLoopYield = UnsafeEventLoopYield;
    this.importObjects = () => this.wasmImports;
    this._instance = null;
    this.memory = new JSObjectSpace();
    this._closureDeallocator = null;
    this.tid = null;
    this.options = options || {};
    this.getDataView = () => {
      throw new Error("Please call setInstance() before using any JavaScriptKit APIs from Swift.");
    };
    this.getUint8Array = () => {
      throw new Error("Please call setInstance() before using any JavaScriptKit APIs from Swift.");
    };
    this.wasmMemory = null;
  }
  setInstance(instance) {
    this._instance = instance;
    const wasmMemory = instance.exports.memory;
    if (wasmMemory instanceof WebAssembly.Memory) {
      let cachedDataView = new DataView(wasmMemory.buffer);
      let cachedUint8Array = new Uint8Array(wasmMemory.buffer);
      if (Object.getPrototypeOf(wasmMemory.buffer).constructor.name === "SharedArrayBuffer") {
        this.getDataView = () => {
          if (cachedDataView.buffer !== wasmMemory.buffer) {
            cachedDataView = new DataView(wasmMemory.buffer);
          }
          return cachedDataView;
        };
        this.getUint8Array = () => {
          if (cachedUint8Array.buffer !== wasmMemory.buffer) {
            cachedUint8Array = new Uint8Array(wasmMemory.buffer);
          }
          return cachedUint8Array;
        };
      } else {
        this.getDataView = () => {
          if (cachedDataView.buffer.byteLength === 0) {
            cachedDataView = new DataView(wasmMemory.buffer);
          }
          return cachedDataView;
        };
        this.getUint8Array = () => {
          if (cachedUint8Array.byteLength === 0) {
            cachedUint8Array = new Uint8Array(wasmMemory.buffer);
          }
          return cachedUint8Array;
        };
      }
      this.wasmMemory = wasmMemory;
    } else {
      throw new Error("instance.exports.memory is not a WebAssembly.Memory!?");
    }
    if (typeof this.exports._start === "function") {
      throw new Error(`JavaScriptKit supports only WASI reactor ABI.
                Please make sure you are building with:
                -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
                `);
    }
    if (this.exports.swjs_library_version() != this.version) {
      throw new Error(`The versions of JavaScriptKit are incompatible.
                WebAssembly runtime ${this.exports.swjs_library_version()} != JS runtime ${this.version}`);
    }
  }
  main() {
    const instance = this.instance;
    try {
      if (typeof instance.exports.main === "function") {
        instance.exports.main();
      } else if (typeof instance.exports.__main_argc_argv === "function") {
        instance.exports.__main_argc_argv(0, 0);
      }
    } catch (error) {
      if (error instanceof UnsafeEventLoopYield) {
        return;
      }
      throw error;
    }
  }
  /**
   * Start a new thread with the given `tid` and `startArg`, which
   * is forwarded to the `wasi_thread_start` function.
   * This function is expected to be called from the spawned Web Worker thread.
   */
  startThread(tid, startArg) {
    this.tid = tid;
    const instance = this.instance;
    try {
      if (typeof instance.exports.wasi_thread_start === "function") {
        instance.exports.wasi_thread_start(tid, startArg);
      } else {
        throw new Error(`The WebAssembly module is not built for wasm32-unknown-wasip1-threads target.`);
      }
    } catch (error) {
      if (error instanceof UnsafeEventLoopYield) {
        return;
      }
      throw error;
    }
  }
  get instance() {
    if (!this._instance)
      throw new Error("WebAssembly instance is not set yet");
    return this._instance;
  }
  get exports() {
    return this.instance.exports;
  }
  get closureDeallocator() {
    if (this._closureDeallocator)
      return this._closureDeallocator;
    const features = this.exports.swjs_library_features();
    const librarySupportsWeakRef = (features & 1) != 0;
    if (librarySupportsWeakRef) {
      this._closureDeallocator = new SwiftClosureDeallocator(this.exports);
    }
    return this._closureDeallocator;
  }
  callHostFunction(host_func_id, line, file, args) {
    const argc = args.length;
    const argv = this.exports.swjs_prepare_host_function_call(argc);
    const memory = this.memory;
    const dataView = this.getDataView();
    for (let index = 0; index < args.length; index++) {
      const argument = args[index];
      const base = argv + 16 * index;
      write(argument, base, base + 4, base + 8, false, dataView, memory);
    }
    let output;
    const callback_func_ref = memory.retain((result) => {
      output = result;
    });
    const alreadyReleased = this.exports.swjs_call_host_function(host_func_id, argv, argc, callback_func_ref);
    if (alreadyReleased) {
      throw new Error(`The JSClosure has been already released by Swift side. The closure is created at ${file}:${line} @${host_func_id}`);
    }
    this.exports.swjs_cleanup_host_function_call(argv);
    return output;
  }
  get wasmImports() {
    let broker = null;
    const getMessageBroker = (threadChannel) => {
      var _a;
      if (broker)
        return broker;
      const itcInterface = new ITCInterface(this.memory);
      const defaultRequestHandler = (message) => {
        const request = message.data.request;
        const result = itcInterface[request.method].apply(itcInterface, request.parameters);
        return { ok: true, value: result };
      };
      const requestHandlers = {
        invokeRemoteJSObjectBody: (message) => {
          const invocationContext = message.data.request.parameters[0];
          const hasError = this.exports.swjs_invoke_remote_jsobject_body(invocationContext);
          return {
            ok: true,
            value: {
              object: hasError,
              sendingContext: message.data.context,
              transfer: []
            }
          };
        }
      };
      const defaultResponseHandler = (message) => {
        if (message.data.response.ok) {
          const object = this.memory.retain(message.data.response.value.object);
          this.exports.swjs_receive_response(object, message.data.context);
        } else {
          const error = deserializeError(message.data.response.error);
          const errorObject = this.memory.retain(error);
          this.exports.swjs_receive_error(errorObject, message.data.context);
        }
      };
      const responseHandlers = {
        invokeRemoteJSObjectBody: (_message) => {
        }
      };
      const newBroker = new MessageBroker((_a = this.tid) !== null && _a !== void 0 ? _a : -1, threadChannel, {
        onRequest: (message) => {
          var _a2;
          let returnValue;
          try {
            const method = message.data.request.method;
            const handler = (_a2 = requestHandlers[method]) !== null && _a2 !== void 0 ? _a2 : defaultRequestHandler;
            returnValue = handler(message);
          } catch (error) {
            returnValue = {
              ok: false,
              error: serializeError(error)
            };
          }
          const responseMessage = {
            type: "response",
            data: {
              sourceTid: message.data.sourceTid,
              context: message.data.context,
              requestMethod: message.data.request.method,
              response: returnValue
            }
          };
          try {
            newBroker.reply(responseMessage);
          } catch (error) {
            responseMessage.data.response = {
              ok: false,
              error: serializeError(new TypeError(`Failed to serialize message: ${error}`))
            };
            newBroker.reply(responseMessage);
          }
        },
        onResponse: (message) => {
          var _a2;
          const method = message.data.requestMethod;
          const handler = (_a2 = responseHandlers[method]) !== null && _a2 !== void 0 ? _a2 : defaultResponseHandler;
          handler(message);
        }
      });
      broker = newBroker;
      return newBroker;
    };
    return {
      swjs_set_prop: (ref, name, kind, payload1, payload2) => {
        const memory = this.memory;
        const obj = memory.getObject(ref);
        const key = memory.getObject(name);
        const value = decode(kind, payload1, payload2, memory);
        obj[key] = value;
      },
      swjs_get_prop: (ref, name, payload1_ptr, payload2_ptr) => {
        const memory = this.memory;
        const obj = memory.getObject(ref);
        const key = memory.getObject(name);
        const result = obj[key];
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_set_subscript: (ref, index, kind, payload1, payload2) => {
        const memory = this.memory;
        const obj = memory.getObject(ref);
        const value = decode(kind, payload1, payload2, memory);
        obj[index] = value;
      },
      swjs_get_subscript: (ref, index, payload1_ptr, payload2_ptr) => {
        const obj = this.memory.getObject(ref);
        const result = obj[index];
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_encode_string: (ref, bytes_ptr_result) => {
        const memory = this.memory;
        const bytes = this.textEncoder.encode(memory.getObject(ref));
        const bytes_ptr = memory.retain(bytes);
        this.getDataView().setUint32(bytes_ptr_result >>> 0, bytes_ptr, true);
        return bytes.length;
      },
      swjs_decode_string: (
        // NOTE: TextDecoder can't decode typed arrays backed by SharedArrayBuffer
        this.options.sharedMemory == true ? (bytes_ptr, length) => {
          const bytesOffset = bytes_ptr >>> 0;
          const byteLength = length >>> 0;
          const bytes = this.getUint8Array().slice(bytesOffset, bytesOffset + byteLength);
          const string = this.textDecoder.decode(bytes);
          return this.memory.retain(string);
        } : (bytes_ptr, length) => {
          const bytesOffset = bytes_ptr >>> 0;
          const byteLength = length >>> 0;
          const bytes = this.getUint8Array().subarray(bytesOffset, bytesOffset + byteLength);
          const string = this.textDecoder.decode(bytes);
          return this.memory.retain(string);
        }
      ),
      swjs_load_string: (ref, buffer) => {
        const bytes = this.memory.getObject(ref);
        this.getUint8Array().set(bytes, buffer >>> 0);
      },
      swjs_call_function: (ref, argv, argc, payload1_ptr, payload2_ptr) => {
        const memory = this.memory;
        const func = memory.getObject(ref);
        let result;
        try {
          const args = decodeArray(argv, argc, this.getDataView(), memory);
          result = func(...args);
        } catch (error) {
          return writeAndReturnKindBits(error, payload1_ptr, payload2_ptr, true, this.getDataView(), this.memory);
        }
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_call_function_no_catch: (ref, argv, argc, payload1_ptr, payload2_ptr) => {
        const memory = this.memory;
        const func = memory.getObject(ref);
        const args = decodeArray(argv, argc, this.getDataView(), memory);
        const result = func(...args);
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_call_function_with_this: (obj_ref, func_ref, argv, argc, payload1_ptr, payload2_ptr) => {
        const memory = this.memory;
        const obj = memory.getObject(obj_ref);
        const func = memory.getObject(func_ref);
        let result;
        try {
          const args = decodeArray(argv, argc, this.getDataView(), memory);
          result = func.apply(obj, args);
        } catch (error) {
          return writeAndReturnKindBits(error, payload1_ptr, payload2_ptr, true, this.getDataView(), this.memory);
        }
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_call_function_with_this_no_catch: (obj_ref, func_ref, argv, argc, payload1_ptr, payload2_ptr) => {
        const memory = this.memory;
        const obj = memory.getObject(obj_ref);
        const func = memory.getObject(func_ref);
        const args = decodeArray(argv, argc, this.getDataView(), memory);
        const result = func.apply(obj, args);
        return writeAndReturnKindBits(result, payload1_ptr, payload2_ptr, false, this.getDataView(), this.memory);
      },
      swjs_call_new: (ref, argv, argc) => {
        const memory = this.memory;
        const constructor = memory.getObject(ref);
        const args = decodeArray(argv, argc, this.getDataView(), memory);
        const instance = new constructor(...args);
        return this.memory.retain(instance);
      },
      swjs_call_throwing_new: (ref, argv, argc, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr) => {
        let memory = this.memory;
        const constructor = memory.getObject(ref);
        let result;
        try {
          const args = decodeArray(argv, argc, this.getDataView(), memory);
          result = new constructor(...args);
        } catch (error) {
          write(error, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr, true, this.getDataView(), this.memory);
          return -1;
        }
        memory = this.memory;
        write(null, exception_kind_ptr, exception_payload1_ptr, exception_payload2_ptr, false, this.getDataView(), memory);
        return memory.retain(result);
      },
      swjs_instanceof: (obj_ref, constructor_ref) => {
        const memory = this.memory;
        const obj = memory.getObject(obj_ref);
        const constructor = memory.getObject(constructor_ref);
        return obj instanceof constructor;
      },
      swjs_value_equals: (lhs_ref, rhs_ref) => {
        const memory = this.memory;
        const lhs = memory.getObject(lhs_ref);
        const rhs = memory.getObject(rhs_ref);
        return lhs == rhs;
      },
      swjs_create_function: (host_func_id, line, file) => {
        var _a;
        const fileString = this.memory.getObject(file);
        const func = (...args) => this.callHostFunction(host_func_id, line, fileString, args);
        const func_ref = this.memory.retain(func);
        (_a = this.closureDeallocator) === null || _a === void 0 ? void 0 : _a.track(func, host_func_id);
        return func_ref;
      },
      swjs_create_oneshot_function: (host_func_id, line, file) => {
        const fileString = this.memory.getObject(file);
        const func = (...args) => this.callHostFunction(host_func_id, line, fileString, args);
        const func_ref = this.memory.retain(func);
        return func_ref;
      },
      swjs_create_typed_array: (constructor_ref, elementsPtr, length) => {
        const ArrayType = this.memory.getObject(constructor_ref);
        if (length == 0) {
          return this.memory.retain(new ArrayType());
        }
        const array = new ArrayType(this.wasmMemory.buffer, elementsPtr >>> 0, length >>> 0);
        return this.memory.retain(array.slice());
      },
      swjs_create_object: () => {
        return this.memory.retain({});
      },
      swjs_load_typed_array: (ref, buffer) => {
        const memory = this.memory;
        const typedArray = memory.getObject(ref);
        const bytes = new Uint8Array(typedArray.buffer);
        this.getUint8Array().set(bytes, buffer >>> 0);
      },
      swjs_release: (ref) => {
        this.memory.release(ref);
      },
      swjs_release_remote: (tid, ref) => {
        var _a;
        if (!this.options.threadChannel) {
          throw new Error("threadChannel is not set in options given to SwiftRuntime. Please set it to release objects on remote threads.");
        }
        const broker2 = getMessageBroker(this.options.threadChannel);
        broker2.request({
          type: "request",
          data: {
            sourceTid: (_a = this.tid) !== null && _a !== void 0 ? _a : MAIN_THREAD_TID,
            targetTid: tid,
            context: 0,
            request: {
              method: "release",
              parameters: [ref]
            }
          }
        });
      },
      swjs_i64_to_bigint: (value, signed) => {
        return this.memory.retain(signed ? value : BigInt.asUintN(64, value));
      },
      swjs_bigint_to_i64: (ref, signed) => {
        const object = this.memory.getObject(ref);
        if (typeof object !== "bigint") {
          throw new Error(`Expected a BigInt, but got ${typeof object}`);
        }
        if (signed) {
          return object;
        } else {
          if (object < BigInt(0)) {
            return BigInt(0);
          }
          return BigInt.asIntN(64, object);
        }
      },
      swjs_i64_to_bigint_slow: (lower, upper, signed) => {
        const value = BigInt.asUintN(32, BigInt(lower)) + (BigInt.asUintN(32, BigInt(upper)) << BigInt(32));
        return this.memory.retain(signed ? BigInt.asIntN(64, value) : BigInt.asUintN(64, value));
      },
      swjs_unsafe_event_loop_yield: () => {
        throw new UnsafeEventLoopYield();
      },
      swjs_send_job_to_main_thread: (unowned_job) => {
        this.postMessageToMainThread({
          type: "job",
          data: unowned_job
        });
      },
      swjs_listen_message_from_main_thread: () => {
        const threadChannel = this.options.threadChannel;
        if (!(threadChannel && "listenMessageFromMainThread" in threadChannel)) {
          throw new Error("listenMessageFromMainThread is not set in options given to SwiftRuntime. Please set it to listen to wake events from the main thread.");
        }
        const broker2 = getMessageBroker(threadChannel);
        threadChannel.listenMessageFromMainThread((message) => {
          switch (message.type) {
            case "wake":
              this.exports.swjs_wake_worker_thread();
              break;
            case "request": {
              broker2.onReceivingRequest(message);
              break;
            }
            case "response": {
              broker2.onReceivingResponse(message);
              break;
            }
            default: {
              const unknownMessage = message;
              throw new Error(`Unknown message type: ${unknownMessage}`);
            }
          }
        });
      },
      swjs_wake_up_worker_thread: (tid) => {
        this.postMessageToWorkerThread(tid, { type: "wake" });
      },
      swjs_listen_message_from_worker_thread: (tid) => {
        const threadChannel = this.options.threadChannel;
        if (!(threadChannel && "listenMessageFromWorkerThread" in threadChannel)) {
          throw new Error("listenMessageFromWorkerThread is not set in options given to SwiftRuntime. Please set it to listen to jobs from worker threads.");
        }
        const broker2 = getMessageBroker(threadChannel);
        threadChannel.listenMessageFromWorkerThread(tid, (message) => {
          switch (message.type) {
            case "job":
              this.exports.swjs_enqueue_main_job_from_worker(message.data);
              break;
            case "request": {
              broker2.onReceivingRequest(message);
              break;
            }
            case "response": {
              broker2.onReceivingResponse(message);
              break;
            }
            default: {
              const unknownMessage = message;
              throw new Error(`Unknown message type: ${unknownMessage}`);
            }
          }
        });
      },
      swjs_terminate_worker_thread: (tid) => {
        var _a;
        const threadChannel = this.options.threadChannel;
        if (threadChannel && "terminateWorkerThread" in threadChannel) {
          (_a = threadChannel.terminateWorkerThread) === null || _a === void 0 ? void 0 : _a.call(threadChannel, tid);
        }
      },
      swjs_get_worker_thread_id: () => {
        return this.tid || -1;
      },
      swjs_request_sending_object: (sending_object, transferring_objects, transferring_objects_count, object_source_tid, sending_context) => {
        var _a;
        if (!this.options.threadChannel) {
          throw new Error("threadChannel is not set in options given to SwiftRuntime. Please set it to request transferring objects.");
        }
        const broker2 = getMessageBroker(this.options.threadChannel);
        const transferringObjects = decodeObjectRefs(transferring_objects, transferring_objects_count, this.getDataView());
        broker2.request({
          type: "request",
          data: {
            sourceTid: (_a = this.tid) !== null && _a !== void 0 ? _a : MAIN_THREAD_TID,
            targetTid: object_source_tid,
            context: sending_context,
            request: {
              method: "send",
              parameters: [
                sending_object,
                transferringObjects,
                sending_context
              ]
            }
          }
        });
      },
      swjs_request_sending_objects: (sending_objects, sending_objects_count, transferring_objects, transferring_objects_count, object_source_tid, sending_context) => {
        var _a;
        if (!this.options.threadChannel) {
          throw new Error("threadChannel is not set in options given to SwiftRuntime. Please set it to request transferring objects.");
        }
        const broker2 = getMessageBroker(this.options.threadChannel);
        const dataView = this.getDataView();
        const sendingObjects = decodeObjectRefs(sending_objects, sending_objects_count, dataView);
        const transferringObjects = decodeObjectRefs(transferring_objects, transferring_objects_count, dataView);
        broker2.request({
          type: "request",
          data: {
            sourceTid: (_a = this.tid) !== null && _a !== void 0 ? _a : MAIN_THREAD_TID,
            targetTid: object_source_tid,
            context: sending_context,
            request: {
              method: "sendObjects",
              parameters: [
                sendingObjects,
                transferringObjects,
                sending_context
              ]
            }
          }
        });
      },
      swjs_request_remote_jsobject_body: (object_source_tid, invocation_context) => {
        var _a;
        if (!this.options.threadChannel) {
          throw new Error("threadChannel is not set in options given to SwiftRuntime. Please set it to request remote JSObject access.");
        }
        const broker2 = getMessageBroker(this.options.threadChannel);
        broker2.request({
          type: "request",
          data: {
            sourceTid: (_a = this.tid) !== null && _a !== void 0 ? _a : MAIN_THREAD_TID,
            targetTid: object_source_tid,
            context: invocation_context,
            request: {
              method: "invokeRemoteJSObjectBody",
              parameters: [invocation_context]
            }
          }
        });
      }
    };
  }
  postMessageToMainThread(message, transfer = []) {
    const threadChannel = this.options.threadChannel;
    if (!(threadChannel && "postMessageToMainThread" in threadChannel)) {
      throw new Error("postMessageToMainThread is not set in options given to SwiftRuntime. Please set it to send messages to the main thread.");
    }
    threadChannel.postMessageToMainThread(message, transfer);
  }
  postMessageToWorkerThread(tid, message, transfer = []) {
    const threadChannel = this.options.threadChannel;
    if (!(threadChannel && "postMessageToWorkerThread" in threadChannel)) {
      throw new Error("postMessageToWorkerThread is not set in options given to SwiftRuntime. Please set it to send messages to worker threads.");
    }
    threadChannel.postMessageToWorkerThread(tid, message, transfer);
  }
};
var UnsafeEventLoopYield = class extends Error {
};

// .build/plugins/PackageToJS/outputs/Package/bridge-js.js
async function createInstantiator(options, swift) {
  let instance;
  let memory;
  let setException;
  let decodeString;
  const textDecoder = new TextDecoder("utf-8");
  const textEncoder = new TextEncoder("utf-8");
  let tmpRetString;
  let tmpRetBytes;
  let tmpRetException;
  let tmpRetOptionalBool;
  let tmpRetOptionalInt;
  let tmpRetOptionalFloat;
  let tmpRetOptionalDouble;
  let tmpRetOptionalHeapObject;
  let strStack = [];
  let i32Stack = [];
  let i64Stack = [];
  let f32Stack = [];
  let f64Stack = [];
  let ptrStack = [];
  let taStack = [];
  const enumHelpers = {};
  const structHelpers = {};
  let _exports = null;
  let bjs = null;
  const __bjs_arrayCodecCache = /* @__PURE__ */ new WeakMap();
  function __bjs_arrayCodec(elementCodec) {
    let codec = __bjs_arrayCodecCache.get(elementCodec);
    if (codec !== void 0) {
      return codec;
    }
    codec = {
      lower(value) {
        for (let i = 0; i < value.length; i++) {
          elementCodec.lower(value[i]);
        }
        i32Stack.push(value.length);
      },
      lift() {
        const count = i32Stack.pop();
        if (count === -1) {
          return taStack.pop();
        }
        const result = new Array(count);
        for (let i = count - 1; i >= 0; i--) {
          result[i] = elementCodec.lift();
        }
        return result;
      }
    };
    __bjs_arrayCodecCache.set(elementCodec, codec);
    return codec;
  }
  const __bjs_optionalCodecCache = /* @__PURE__ */ new WeakMap();
  const __bjs_optionalCodecUndefinedOrCache = /* @__PURE__ */ new WeakMap();
  function __bjs_optionalCodec(elementCodec, isUndefinedOr = false) {
    const cache = isUndefinedOr ? __bjs_optionalCodecUndefinedOrCache : __bjs_optionalCodecCache;
    let codec = cache.get(elementCodec);
    if (codec !== void 0) {
      return codec;
    }
    codec = {
      lower(value) {
        const isSome = isUndefinedOr ? value !== void 0 : value != null;
        if (isSome) {
          elementCodec.lower(value);
          i32Stack.push(1);
        } else {
          i32Stack.push(0);
        }
      },
      lift() {
        if (i32Stack.pop() === 0) {
          return isUndefinedOr ? void 0 : null;
        }
        return elementCodec.lift();
      }
    };
    cache.set(elementCodec, codec);
    return codec;
  }
  const __bjs_dictCodecCache = /* @__PURE__ */ new WeakMap();
  function __bjs_dictCodec(valueCodec) {
    let codec = __bjs_dictCodecCache.get(valueCodec);
    if (codec !== void 0) {
      return codec;
    }
    codec = {
      lower(value) {
        const keys = Object.keys(value);
        for (let i = 0; i < keys.length; i++) {
          __bjs_stringCodec.lower(keys[i]);
          valueCodec.lower(value[keys[i]]);
        }
        i32Stack.push(keys.length);
      },
      lift() {
        const count = i32Stack.pop();
        const result = {};
        for (let i = 0; i < count; i++) {
          const value = valueCodec.lift();
          const key = __bjs_stringCodec.lift();
          result[key] = value;
        }
        return result;
      }
    };
    __bjs_dictCodecCache.set(valueCodec, codec);
    return codec;
  }
  const __bjs_stringCodec = {
    lower: (v) => {
      const bytes = textEncoder.encode(v);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
    },
    lift: () => {
      const string = strStack.pop();
      return string;
    }
  };
  const __bjs_primitiveCodecs = {
    Bool: {
      lower: (v) => {
        i32Stack.push(v ? 1 : 0);
      },
      lift: () => {
        const bool = i32Stack.pop() !== 0;
        return bool;
      }
    },
    Int: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop();
        return int;
      }
    },
    Int8: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop();
        return int;
      }
    },
    UInt8: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop() >>> 0;
        return int;
      }
    },
    Int16: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop();
        return int;
      }
    },
    UInt16: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop() >>> 0;
        return int;
      }
    },
    Int32: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop();
        return int;
      }
    },
    UInt32: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop() >>> 0;
        return int;
      }
    },
    UInt: {
      lower: (v) => {
        i32Stack.push(v | 0);
      },
      lift: () => {
        const int = i32Stack.pop() >>> 0;
        return int;
      }
    },
    Int64: {
      lower: (v) => {
        i64Stack.push(v);
      },
      lift: () => {
        const int = i64Stack.pop();
        return int;
      }
    },
    UInt64: {
      lower: (v) => {
        i64Stack.push(v);
      },
      lift: () => {
        const int = i64Stack.pop();
        return int;
      }
    },
    Float: {
      lower: (v) => {
        f32Stack.push(Math.fround(v));
      },
      lift: () => {
        const f32 = f32Stack.pop();
        return f32;
      }
    },
    Double: {
      lower: (v) => {
        f64Stack.push(v);
      },
      lift: () => {
        const f64 = f64Stack.pop();
        return f64;
      }
    },
    String: __bjs_stringCodec,
    JSValue: {
      lower: (v) => {
        const [vKind, vPayload1, vPayload2] = __bjs_jsValueLower(v);
        i32Stack.push(vKind);
        i32Stack.push(vPayload1);
        f64Stack.push(vPayload2);
      },
      lift: () => {
        const jsValuePayload2 = f64Stack.pop();
        const jsValuePayload1 = i32Stack.pop();
        const jsValueKind = i32Stack.pop();
        const jsValue = __bjs_jsValueLift(jsValueKind, jsValuePayload1, jsValuePayload2);
        return jsValue;
      }
    }
  };
  function __bjs_jsValueLower(value) {
    let kind;
    let payload1;
    let payload2;
    if (value === null) {
      kind = 4;
      payload1 = 0;
      payload2 = 0;
    } else {
      switch (typeof value) {
        case "boolean":
          kind = 0;
          payload1 = value ? 1 : 0;
          payload2 = 0;
          break;
        case "number":
          kind = 2;
          payload1 = 0;
          payload2 = value;
          break;
        case "string":
          kind = 1;
          payload1 = swift.memory.retain(value);
          payload2 = 0;
          break;
        case "undefined":
          kind = 5;
          payload1 = 0;
          payload2 = 0;
          break;
        case "object":
          kind = 3;
          payload1 = swift.memory.retain(value);
          payload2 = 0;
          break;
        case "function":
          kind = 3;
          payload1 = swift.memory.retain(value);
          payload2 = 0;
          break;
        case "symbol":
          kind = 7;
          payload1 = swift.memory.retain(value);
          payload2 = 0;
          break;
        case "bigint":
          kind = 8;
          payload1 = swift.memory.retain(value);
          payload2 = 0;
          break;
        default:
          throw new TypeError("Unsupported JSValue type");
      }
    }
    return [kind, payload1, payload2];
  }
  function __bjs_jsValueLift(kind, payload1, payload2) {
    let jsValue;
    switch (kind) {
      case 0:
        jsValue = payload1 !== 0;
        break;
      case 1:
        jsValue = swift.memory.getObject(payload1);
        break;
      case 2:
        jsValue = payload2;
        break;
      case 3:
        jsValue = swift.memory.getObject(payload1);
        break;
      case 4:
        jsValue = null;
        break;
      case 5:
        jsValue = void 0;
        break;
      case 7:
        jsValue = swift.memory.getObject(payload1);
        break;
      case 8:
        jsValue = swift.memory.getObject(payload1);
        break;
      default:
        throw new TypeError("Unsupported JSValue kind " + kind);
    }
    return jsValue;
  }
  const swiftClosureRegistry = typeof FinalizationRegistry === "undefined" ? { register: () => {
  }, unregister: () => {
  } } : new FinalizationRegistry((state) => {
    if (state.unregistered) {
      return;
    }
    instance?.exports?.bjs_release_swift_closure(state.pointer);
  });
  const makeClosure = (pointer, file, line, func) => {
    const state = { pointer, file, line, unregistered: false };
    const real = (...args) => {
      if (state.unregistered) {
        const bytes = new Uint8Array(memory.buffer, state.file >>> 0);
        let length = 0;
        while (bytes[length] !== 0) {
          length += 1;
        }
        const fileID = decodeString(state.file, length);
        throw new Error(`Attempted to call a released JSTypedClosure created at ${fileID}:${state.line}`);
      }
      return func(...args);
    };
    real.__unregister = () => {
      if (state.unregistered) {
        return;
      }
      state.unregistered = true;
      swiftClosureRegistry.unregister(state);
    };
    swiftClosureRegistry.register(real, state, state);
    return swift.memory.retain(real);
  };
  const __bjs_codec_M10RunnerWasmT14JSNotebookCell = {
    lower: (v) => {
      structHelpers.M10RunnerWasmT14JSNotebookCell.lower(v);
    },
    lift: () => {
      const struct = structHelpers.M10RunnerWasmT14JSNotebookCell.lift();
      return struct;
    }
  };
  const __bjs_codec_Array_M10RunnerWasmT14JSNotebookCell = __bjs_arrayCodec(__bjs_codec_M10RunnerWasmT14JSNotebookCell);
  const __bjs_codec_M10RunnerWasmT11JSSuiteItem = {
    lower: (v) => {
      structHelpers.M10RunnerWasmT11JSSuiteItem.lower(v);
    },
    lift: () => {
      const struct = structHelpers.M10RunnerWasmT11JSSuiteItem.lift();
      return struct;
    }
  };
  const __bjs_codec_Array_M10RunnerWasmT11JSSuiteItem = __bjs_arrayCodec(__bjs_codec_M10RunnerWasmT11JSSuiteItem);
  const __bjs_codec_Array_String = __bjs_arrayCodec(__bjs_stringCodec);
  const __bjs_codec_Optional_String = __bjs_optionalCodec(__bjs_stringCodec);
  const __bjs_codec_Optional_Double = __bjs_optionalCodec(__bjs_primitiveCodecs.Double);
  const __bjs_codec_Optional_Int = __bjs_optionalCodec(__bjs_primitiveCodecs.Int);
  const __bjs_codec_M10RunnerWasmT13JSTestOutcome = {
    lower: (v) => {
      structHelpers.M10RunnerWasmT13JSTestOutcome.lower(v);
    },
    lift: () => {
      const struct = structHelpers.M10RunnerWasmT13JSTestOutcome.lift();
      return struct;
    }
  };
  const __bjs_codec_Array_M10RunnerWasmT13JSTestOutcome = __bjs_arrayCodec(__bjs_codec_M10RunnerWasmT13JSTestOutcome);
  const __bjs_createStructHelpers_M10RunnerWasmT14JSNotebookCell = () => ({
    lower: (value) => {
      const bytes = textEncoder.encode(value.cellType);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      const bytes1 = textEncoder.encode(value.source);
      const id1 = swift.memory.retain(bytes1);
      i32Stack.push(bytes1.length);
      i32Stack.push(id1);
    },
    lift: () => {
      const string = strStack.pop();
      const string1 = strStack.pop();
      return { cellType: string1, source: string };
    }
  });
  const __bjs_createStructHelpers_M10RunnerWasmT17JSExtractedPython = () => ({
    lower: (value) => {
      const bytes = textEncoder.encode(value.executableModule);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      const bytes1 = textEncoder.encode(value.introspectableSource);
      const id1 = swift.memory.retain(bytes1);
      i32Stack.push(bytes1.length);
      i32Stack.push(id1);
      i32Stack.push(value.codeCellCount | 0);
    },
    lift: () => {
      const int = i32Stack.pop();
      const string = strStack.pop();
      const string1 = strStack.pop();
      return { executableModule: string1, introspectableSource: string, codeCellCount: int };
    }
  });
  const __bjs_createStructHelpers_M10RunnerWasmT17JSExtractedSource = () => ({
    lower: (value) => {
      const bytes = textEncoder.encode(value.source);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      i32Stack.push(value.codeCellCount | 0);
    },
    lift: () => {
      const int = i32Stack.pop();
      const string = strStack.pop();
      return { source: string, codeCellCount: int };
    }
  });
  const __bjs_createStructHelpers_M10RunnerWasmT11JSSuiteItem = () => ({
    lower: (value) => {
      const bytes = textEncoder.encode(value.script);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      const bytes1 = textEncoder.encode(value.tier);
      const id1 = swift.memory.retain(bytes1);
      i32Stack.push(bytes1.length);
      i32Stack.push(id1);
      __bjs_codec_Optional_String.lower(value.displayName);
      __bjs_codec_Array_String.lower(value.dependsOn);
      i32Stack.push(value.points | 0);
    },
    lift: () => {
      const int = i32Stack.pop();
      const arrayResult = __bjs_codec_Array_String.lift();
      const optValue = __bjs_codec_Optional_String.lift();
      const string = strStack.pop();
      const string1 = strStack.pop();
      return { script: string1, tier: string, displayName: optValue, dependsOn: arrayResult, points: int };
    }
  });
  const __bjs_createStructHelpers_M10RunnerWasmT14JSScriptOutput = () => ({
    lower: (value) => {
      i32Stack.push(value.exitCode | 0);
      const bytes = textEncoder.encode(value.stdout);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      const bytes1 = textEncoder.encode(value.stderr);
      const id1 = swift.memory.retain(bytes1);
      i32Stack.push(bytes1.length);
      i32Stack.push(id1);
      i32Stack.push(value.executionTimeMs | 0);
      i32Stack.push(value.timedOut ? 1 : 0);
    },
    lift: () => {
      const bool = i32Stack.pop() !== 0;
      const int = i32Stack.pop();
      const string = strStack.pop();
      const string1 = strStack.pop();
      const int1 = i32Stack.pop();
      return { exitCode: int1, stdout: string1, stderr: string, executionTimeMs: int, timedOut: bool };
    }
  });
  const __bjs_createStructHelpers_M10RunnerWasmT13JSTestOutcome = () => ({
    lower: (value) => {
      const bytes = textEncoder.encode(value.testName);
      const id = swift.memory.retain(bytes);
      i32Stack.push(bytes.length);
      i32Stack.push(id);
      __bjs_codec_Optional_String.lower(value.testClass);
      const bytes1 = textEncoder.encode(value.tier);
      const id1 = swift.memory.retain(bytes1);
      i32Stack.push(bytes1.length);
      i32Stack.push(id1);
      const bytes2 = textEncoder.encode(value.status);
      const id2 = swift.memory.retain(bytes2);
      i32Stack.push(bytes2.length);
      i32Stack.push(id2);
      const bytes3 = textEncoder.encode(value.shortResult);
      const id3 = swift.memory.retain(bytes3);
      i32Stack.push(bytes3.length);
      i32Stack.push(id3);
      __bjs_codec_Optional_String.lower(value.longResult);
      f64Stack.push(value.score);
      i32Stack.push(value.points | 0);
      __bjs_codec_Optional_Double.lower(value.metric);
      i32Stack.push(value.executionTimeMs | 0);
      __bjs_codec_Optional_Int.lower(value.memoryUsageBytes);
      i32Stack.push(value.attemptNumber | 0);
      i32Stack.push(value.isFirstPassSuccess ? 1 : 0);
    },
    lift: () => {
      const bool = i32Stack.pop() !== 0;
      const int = i32Stack.pop();
      const optValue = __bjs_codec_Optional_Int.lift();
      const int1 = i32Stack.pop();
      const optValue1 = __bjs_codec_Optional_Double.lift();
      const int2 = i32Stack.pop();
      const f64 = f64Stack.pop();
      const optValue2 = __bjs_codec_Optional_String.lift();
      const string = strStack.pop();
      const string1 = strStack.pop();
      const string2 = strStack.pop();
      const optValue3 = __bjs_codec_Optional_String.lift();
      const string3 = strStack.pop();
      return { testName: string3, testClass: optValue3, tier: string2, status: string1, shortResult: string, longResult: optValue2, score: f64, points: int2, metric: optValue1, executionTimeMs: int1, memoryUsageBytes: optValue, attemptNumber: int, isFirstPassSuccess: bool };
    }
  });
  return {
    /**
     * @param {WebAssembly.Imports} importObject
     */
    addImports: (importObject, importsContext) => {
      bjs = {};
      importObject["bjs"] = bjs;
      bjs["swift_js_return_string"] = function(ptr, len) {
        tmpRetString = decodeString(ptr, len);
      };
      bjs["swift_js_init_memory"] = function(sourceId, bytesPtr) {
        const source = swift.memory.getObject(sourceId);
        swift.memory.release(sourceId);
        const bytes = new Uint8Array(memory.buffer, bytesPtr >>> 0);
        bytes.set(source);
      };
      bjs["swift_js_make_js_string"] = function(ptr, len) {
        return swift.memory.retain(decodeString(ptr, len));
      };
      bjs["swift_js_init_memory_with_result"] = function(ptr, len) {
        const target = new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
        target.set(tmpRetBytes);
        tmpRetBytes = void 0;
      };
      bjs["swift_js_throw"] = function(id) {
        tmpRetException = swift.memory.retainByRef(id);
      };
      bjs["swift_js_retain"] = function(id) {
        return swift.memory.retainByRef(id);
      };
      bjs["swift_js_release"] = function(id) {
        swift.memory.release(id);
      };
      bjs["swift_js_push_i32"] = function(v) {
        i32Stack.push(v | 0);
      };
      bjs["swift_js_push_f32"] = function(v) {
        f32Stack.push(Math.fround(v));
      };
      bjs["swift_js_push_f64"] = function(v) {
        f64Stack.push(v);
      };
      bjs["swift_js_push_string"] = function(ptr, len) {
        const value = decodeString(ptr, len);
        strStack.push(value);
      };
      bjs["swift_js_pop_i32"] = function() {
        return i32Stack.pop();
      };
      bjs["swift_js_pop_f32"] = function() {
        return f32Stack.pop();
      };
      bjs["swift_js_pop_f64"] = function() {
        return f64Stack.pop();
      };
      bjs["swift_js_push_pointer"] = function(pointer) {
        ptrStack.push(pointer);
      };
      bjs["swift_js_pop_pointer"] = function() {
        return ptrStack.pop();
      };
      bjs["swift_js_push_i64"] = function(v) {
        i64Stack.push(v);
      };
      bjs["swift_js_pop_i64"] = function() {
        return i64Stack.pop();
      };
      const taCtors = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
      bjs["swift_js_push_typed_array"] = function(kind, ptr, count) {
        const Ctor = taCtors[kind];
        const byteLen = count * Ctor.BYTES_PER_ELEMENT;
        const copy = memory.buffer.slice(ptr, ptr + byteLen);
        taStack.push(Array.from(new Ctor(copy)));
      };
      bjs["swift_js_struct_lower_JSNotebookCell"] = function(objectId) {
        structHelpers.M10RunnerWasmT14JSNotebookCell.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSNotebookCell"] = function() {
        const value = structHelpers.M10RunnerWasmT14JSNotebookCell.lift();
        return swift.memory.retain(value);
      };
      bjs["swift_js_struct_lower_JSExtractedPython"] = function(objectId) {
        structHelpers.M10RunnerWasmT17JSExtractedPython.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSExtractedPython"] = function() {
        const value = structHelpers.M10RunnerWasmT17JSExtractedPython.lift();
        return swift.memory.retain(value);
      };
      bjs["swift_js_struct_lower_JSExtractedSource"] = function(objectId) {
        structHelpers.M10RunnerWasmT17JSExtractedSource.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSExtractedSource"] = function() {
        const value = structHelpers.M10RunnerWasmT17JSExtractedSource.lift();
        return swift.memory.retain(value);
      };
      bjs["swift_js_struct_lower_JSSuiteItem"] = function(objectId) {
        structHelpers.M10RunnerWasmT11JSSuiteItem.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSSuiteItem"] = function() {
        const value = structHelpers.M10RunnerWasmT11JSSuiteItem.lift();
        return swift.memory.retain(value);
      };
      bjs["swift_js_struct_lower_JSScriptOutput"] = function(objectId) {
        structHelpers.M10RunnerWasmT14JSScriptOutput.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSScriptOutput"] = function() {
        const value = structHelpers.M10RunnerWasmT14JSScriptOutput.lift();
        return swift.memory.retain(value);
      };
      bjs["swift_js_struct_lower_JSTestOutcome"] = function(objectId) {
        structHelpers.M10RunnerWasmT13JSTestOutcome.lower(swift.memory.getObject(objectId));
      };
      bjs["swift_js_struct_lift_JSTestOutcome"] = function() {
        const value = structHelpers.M10RunnerWasmT13JSTestOutcome.lift();
        return swift.memory.retain(value);
      };
      bjs["bjs_core_register_type_handles"] = function() {
      };
      bjs["bjs_RunnerWasm_register_type_handles"] = function() {
      };
      const __bjs_promiseSettlers = /* @__PURE__ */ Symbol("JavaScriptKit.promiseSettlers");
      bjs["swift_js_make_promise"] = function() {
        let resolve, reject;
        const promise = new Promise((res, rej) => {
          resolve = res;
          reject = rej;
        });
        promise[__bjs_promiseSettlers] = { resolve, reject };
        return swift.memory.retain(promise);
      };
      bjs["promise_resolve_RunnerWasm_Sa13JSTestOutcomeV"] = function(promise) {
        try {
          const arrayResult = __bjs_codec_Array_M10RunnerWasmT13JSTestOutcome.lift();
          swift.memory.getObject(promise)[__bjs_promiseSettlers].resolve(arrayResult);
        } catch (error) {
          setException(error);
        }
      };
      bjs["promise_resolve_RunnerWasm_14JSScriptOutputV"] = function(promise) {
        try {
          const structValue = structHelpers.M10RunnerWasmT14JSScriptOutput.lift();
          swift.memory.getObject(promise)[__bjs_promiseSettlers].resolve(structValue);
        } catch (error) {
          setException(error);
        }
      };
      bjs["promise_reject_RunnerWasm"] = function(promise, valueKind, valuePayload1, valuePayload2) {
        try {
          const jsValue = __bjs_jsValueLift(valueKind, valuePayload1, valuePayload2);
          swift.memory.getObject(promise)[__bjs_promiseSettlers].reject(jsValue);
        } catch (error) {
          setException(error);
        }
      };
      bjs["swift_js_return_optional_bool"] = function(isSome, value) {
        if (isSome === 0) {
          tmpRetOptionalBool = null;
        } else {
          tmpRetOptionalBool = value !== 0;
        }
      };
      bjs["swift_js_return_optional_int"] = function(isSome, value) {
        if (isSome === 0) {
          tmpRetOptionalInt = null;
        } else {
          tmpRetOptionalInt = value | 0;
        }
      };
      bjs["swift_js_return_optional_float"] = function(isSome, value) {
        if (isSome === 0) {
          tmpRetOptionalFloat = null;
        } else {
          tmpRetOptionalFloat = Math.fround(value);
        }
      };
      bjs["swift_js_return_optional_double"] = function(isSome, value) {
        if (isSome === 0) {
          tmpRetOptionalDouble = null;
        } else {
          tmpRetOptionalDouble = value;
        }
      };
      bjs["swift_js_return_optional_string"] = function(isSome, ptr, len) {
        if (isSome === 0) {
          tmpRetString = null;
        } else {
          tmpRetString = decodeString(ptr, len);
        }
      };
      bjs["swift_js_return_optional_object"] = function(isSome, objectId) {
        if (isSome === 0) {
          tmpRetString = null;
        } else {
          tmpRetString = swift.memory.getObject(objectId);
        }
      };
      bjs["swift_js_return_optional_heap_object"] = function(isSome, pointer) {
        if (isSome === 0) {
          tmpRetOptionalHeapObject = null;
        } else {
          tmpRetOptionalHeapObject = pointer;
        }
      };
      bjs["swift_js_get_optional_int_presence"] = function() {
        return tmpRetOptionalInt != null ? 1 : 0;
      };
      bjs["swift_js_get_optional_int_value"] = function() {
        const value = tmpRetOptionalInt;
        tmpRetOptionalInt = void 0;
        return value;
      };
      bjs["swift_js_get_optional_string"] = function() {
        const str = tmpRetString;
        tmpRetString = void 0;
        if (str == null) {
          return -1;
        } else {
          const bytes = textEncoder.encode(str);
          tmpRetBytes = bytes;
          return bytes.length;
        }
      };
      bjs["swift_js_get_optional_float_presence"] = function() {
        return tmpRetOptionalFloat != null ? 1 : 0;
      };
      bjs["swift_js_get_optional_float_value"] = function() {
        const value = tmpRetOptionalFloat;
        tmpRetOptionalFloat = void 0;
        return value;
      };
      bjs["swift_js_get_optional_double_presence"] = function() {
        return tmpRetOptionalDouble != null ? 1 : 0;
      };
      bjs["swift_js_get_optional_double_value"] = function() {
        const value = tmpRetOptionalDouble;
        tmpRetOptionalDouble = void 0;
        return value;
      };
      bjs["swift_js_get_optional_heap_object_pointer"] = function() {
        const pointer = tmpRetOptionalHeapObject;
        tmpRetOptionalHeapObject = void 0;
        return pointer || 0;
      };
      bjs["swift_js_closure_unregister"] = function(funcRef) {
      };
      bjs["swift_js_closure_unregister"] = function(funcRef) {
        const func = swift.memory.getObject(funcRef);
        func.__unregister();
      };
      bjs["invoke_js_callback_RunnerWasm_10RunnerWasmSS_Sb"] = function(callbackId, param0Bytes, param0Count) {
        try {
          const callback = swift.memory.getObject(callbackId);
          const string = decodeString(param0Bytes, param0Count);
          let ret = callback(string);
          return ret ? 1 : 0;
        } catch (error) {
          setException(error);
          return 0;
        }
      };
      bjs["make_swift_closure_RunnerWasm_10RunnerWasmSS_Sb"] = function(boxPtr, file, line) {
        const lower_closure_RunnerWasm_10RunnerWasmSS_Sb = function(param0) {
          const param0Bytes = textEncoder.encode(param0);
          const param0Id = swift.memory.retain(param0Bytes);
          const ret = instance.exports.invoke_swift_closure_RunnerWasm_10RunnerWasmSS_Sb(boxPtr, param0Id, param0Bytes.length);
          if (tmpRetException) {
            const error = swift.memory.getObject(tmpRetException);
            swift.memory.release(tmpRetException);
            tmpRetException = void 0;
            throw error;
          }
          return ret !== 0;
        };
        return makeClosure(boxPtr, file, line, lower_closure_RunnerWasm_10RunnerWasmSS_Sb);
      };
      bjs["invoke_js_callback_RunnerWasm_10RunnerWasmYaSSSi_14JSScriptOutputV"] = function(resolveRef, rejectRef, callbackId, param0Bytes, param0Count, param1) {
        const resolve = swift.memory.getObject(resolveRef);
        const reject = swift.memory.getObject(rejectRef);
        const callback = swift.memory.getObject(callbackId);
        const string = decodeString(param0Bytes, param0Count);
        callback(string, param1).then(resolve, reject);
      };
      bjs["make_swift_closure_RunnerWasm_10RunnerWasmYaSSSi_14JSScriptOutputV"] = function(boxPtr, file, line) {
        const lower_closure_RunnerWasm_10RunnerWasmYaSSSi_14JSScriptOutputV = function(param0, param1) {
          const param0Bytes = textEncoder.encode(param0);
          const param0Id = swift.memory.retain(param0Bytes);
          const ret = instance.exports.invoke_swift_closure_RunnerWasm_10RunnerWasmYaSSSi_14JSScriptOutputV(boxPtr, param0Id, param0Bytes.length, param1);
          const ret1 = swift.memory.getObject(ret);
          swift.memory.release(ret);
          return ret1;
        };
        return makeClosure(boxPtr, file, line, lower_closure_RunnerWasm_10RunnerWasmYaSSSi_14JSScriptOutputV);
      };
      bjs["invoke_js_callback_RunnerWasm_10RunnerWasms14JSScriptOutputV_y"] = function(callbackId) {
        try {
          const callback = swift.memory.getObject(callbackId);
          const structValue = structHelpers.M10RunnerWasmT14JSScriptOutput.lift();
          callback(structValue);
        } catch (error) {
          setException(error);
        }
      };
      bjs["make_swift_closure_RunnerWasm_10RunnerWasms14JSScriptOutputV_y"] = function(boxPtr, file, line) {
        const lower_closure_RunnerWasm_10RunnerWasms14JSScriptOutputV_y = function(param0) {
          structHelpers.M10RunnerWasmT14JSScriptOutput.lower(param0);
          instance.exports.invoke_swift_closure_RunnerWasm_10RunnerWasms14JSScriptOutputV_y(boxPtr);
          if (tmpRetException) {
            const error = swift.memory.getObject(tmpRetException);
            swift.memory.release(tmpRetException);
            tmpRetException = void 0;
            throw error;
          }
        };
        return makeClosure(boxPtr, file, line, lower_closure_RunnerWasm_10RunnerWasms14JSScriptOutputV_y);
      };
      bjs["invoke_js_callback_RunnerWasm_10RunnerWasms7JSValueV_y"] = function(callbackId, param0Kind, param0Payload1, param0Payload2) {
        try {
          const callback = swift.memory.getObject(callbackId);
          const jsValue = __bjs_jsValueLift(param0Kind, param0Payload1, param0Payload2);
          callback(jsValue);
        } catch (error) {
          setException(error);
        }
      };
      bjs["make_swift_closure_RunnerWasm_10RunnerWasms7JSValueV_y"] = function(boxPtr, file, line) {
        const lower_closure_RunnerWasm_10RunnerWasms7JSValueV_y = function(param0) {
          const [param0Kind, param0Payload1, param0Payload2] = __bjs_jsValueLower(param0);
          instance.exports.invoke_swift_closure_RunnerWasm_10RunnerWasms7JSValueV_y(boxPtr, param0Kind, param0Payload1, param0Payload2);
          if (tmpRetException) {
            const error = swift.memory.getObject(tmpRetException);
            swift.memory.release(tmpRetException);
            tmpRetException = void 0;
            throw error;
          }
        };
        return makeClosure(boxPtr, file, line, lower_closure_RunnerWasm_10RunnerWasms7JSValueV_y);
      };
    },
    setInstance: (i) => {
      instance = i;
      memory = instance.exports.memory;
      decodeString = (ptr, len) => {
        const bytes = new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
        return textDecoder.decode(bytes);
      };
      setException = (error) => {
        instance.exports._swift_js_exception.value = swift.memory.retain(error);
      };
    },
    /** @param {WebAssembly.Instance} instance */
    createExports: (instance2) => {
      const js = swift.memory.heap;
      const __bjs_helpers_M10RunnerWasmT14JSNotebookCell = __bjs_createStructHelpers_M10RunnerWasmT14JSNotebookCell();
      structHelpers.M10RunnerWasmT14JSNotebookCell = __bjs_helpers_M10RunnerWasmT14JSNotebookCell;
      const __bjs_helpers_M10RunnerWasmT17JSExtractedPython = __bjs_createStructHelpers_M10RunnerWasmT17JSExtractedPython();
      structHelpers.M10RunnerWasmT17JSExtractedPython = __bjs_helpers_M10RunnerWasmT17JSExtractedPython;
      const __bjs_helpers_M10RunnerWasmT17JSExtractedSource = __bjs_createStructHelpers_M10RunnerWasmT17JSExtractedSource();
      structHelpers.M10RunnerWasmT17JSExtractedSource = __bjs_helpers_M10RunnerWasmT17JSExtractedSource;
      const __bjs_helpers_M10RunnerWasmT11JSSuiteItem = __bjs_createStructHelpers_M10RunnerWasmT11JSSuiteItem();
      structHelpers.M10RunnerWasmT11JSSuiteItem = __bjs_helpers_M10RunnerWasmT11JSSuiteItem;
      const __bjs_helpers_M10RunnerWasmT14JSScriptOutput = __bjs_createStructHelpers_M10RunnerWasmT14JSScriptOutput();
      structHelpers.M10RunnerWasmT14JSScriptOutput = __bjs_helpers_M10RunnerWasmT14JSScriptOutput;
      const __bjs_helpers_M10RunnerWasmT13JSTestOutcome = __bjs_createStructHelpers_M10RunnerWasmT13JSTestOutcome();
      structHelpers.M10RunnerWasmT13JSTestOutcome = __bjs_helpers_M10RunnerWasmT13JSTestOutcome;
      const exports = {
        extractPython: function bjs_extractPython(cells, filename) {
          __bjs_codec_Array_M10RunnerWasmT14JSNotebookCell.lower(cells);
          const filenameBytes = textEncoder.encode(filename);
          const filenameId = swift.memory.retain(filenameBytes);
          instance2.exports.bjs_extractPython(filenameId, filenameBytes.length);
          const structValue = structHelpers.M10RunnerWasmT17JSExtractedPython.lift();
          return structValue;
        },
        extractR: function bjs_extractR(cells, filename) {
          __bjs_codec_Array_M10RunnerWasmT14JSNotebookCell.lower(cells);
          const filenameBytes = textEncoder.encode(filename);
          const filenameId = swift.memory.retain(filenameBytes);
          instance2.exports.bjs_extractR(filenameId, filenameBytes.length);
          const structValue = structHelpers.M10RunnerWasmT17JSExtractedSource.lift();
          return structValue;
        },
        extractLua: function bjs_extractLua(cells, filename) {
          __bjs_codec_Array_M10RunnerWasmT14JSNotebookCell.lower(cells);
          const filenameBytes = textEncoder.encode(filename);
          const filenameId = swift.memory.retain(filenameBytes);
          instance2.exports.bjs_extractLua(filenameId, filenameBytes.length);
          const structValue = structHelpers.M10RunnerWasmT17JSExtractedSource.lift();
          return structValue;
        },
        extractOctave: function bjs_extractOctave(cells, filename) {
          __bjs_codec_Array_M10RunnerWasmT14JSNotebookCell.lower(cells);
          const filenameBytes = textEncoder.encode(filename);
          const filenameId = swift.memory.retain(filenameBytes);
          instance2.exports.bjs_extractOctave(filenameId, filenameBytes.length);
          const structValue = structHelpers.M10RunnerWasmT17JSExtractedSource.lift();
          return structValue;
        },
        classifyScript: function bjs_classifyScript(name, source) {
          const nameBytes = textEncoder.encode(name);
          const nameId = swift.memory.retain(nameBytes);
          const sourceBytes = textEncoder.encode(source);
          const sourceId = swift.memory.retain(sourceBytes);
          instance2.exports.bjs_classifyScript(nameId, nameBytes.length, sourceId, sourceBytes.length);
          const ret = tmpRetString;
          tmpRetString = void 0;
          return ret;
        },
        executeSuites: function bjs_executeSuites(suites, timeLimitSeconds, attemptNumber, scriptExists, run) {
          __bjs_codec_Array_M10RunnerWasmT11JSSuiteItem.lower(suites);
          const callbackId = swift.memory.retain(scriptExists);
          const callbackId1 = swift.memory.retain(run);
          const ret = instance2.exports.bjs_executeSuites(timeLimitSeconds, attemptNumber, callbackId, callbackId1);
          const ret1 = swift.memory.getObject(ret);
          swift.memory.release(ret);
          return ret1;
        },
        JSExtractedPython: {
          init: function(executableModule, introspectableSource, codeCellCount) {
            const executableModuleBytes = textEncoder.encode(executableModule);
            const executableModuleId = swift.memory.retain(executableModuleBytes);
            const introspectableSourceBytes = textEncoder.encode(introspectableSource);
            const introspectableSourceId = swift.memory.retain(introspectableSourceBytes);
            instance2.exports.bjs_JSExtractedPython_init(executableModuleId, executableModuleBytes.length, introspectableSourceId, introspectableSourceBytes.length, codeCellCount);
            const structValue = structHelpers.M10RunnerWasmT17JSExtractedPython.lift();
            return structValue;
          }
        },
        JSExtractedSource: {
          init: function(source, codeCellCount) {
            const sourceBytes = textEncoder.encode(source);
            const sourceId = swift.memory.retain(sourceBytes);
            instance2.exports.bjs_JSExtractedSource_init(sourceId, sourceBytes.length, codeCellCount);
            const structValue = structHelpers.M10RunnerWasmT17JSExtractedSource.lift();
            return structValue;
          }
        },
        JSNotebookCell: {
          init: function(cellType, source) {
            const cellTypeBytes = textEncoder.encode(cellType);
            const cellTypeId = swift.memory.retain(cellTypeBytes);
            const sourceBytes = textEncoder.encode(source);
            const sourceId = swift.memory.retain(sourceBytes);
            instance2.exports.bjs_JSNotebookCell_init(cellTypeId, cellTypeBytes.length, sourceId, sourceBytes.length);
            const structValue = structHelpers.M10RunnerWasmT14JSNotebookCell.lift();
            return structValue;
          }
        },
        JSScriptOutput: {
          init: function(exitCode, stdout, stderr, executionTimeMs, timedOut) {
            const stdoutBytes = textEncoder.encode(stdout);
            const stdoutId = swift.memory.retain(stdoutBytes);
            const stderrBytes = textEncoder.encode(stderr);
            const stderrId = swift.memory.retain(stderrBytes);
            instance2.exports.bjs_JSScriptOutput_init(exitCode, stdoutId, stdoutBytes.length, stderrId, stderrBytes.length, executionTimeMs, timedOut);
            const structValue = structHelpers.M10RunnerWasmT14JSScriptOutput.lift();
            return structValue;
          }
        },
        JSSuiteItem: {
          init: function(script, tier, displayName, dependsOn, points) {
            const scriptBytes = textEncoder.encode(script);
            const scriptId = swift.memory.retain(scriptBytes);
            const tierBytes = textEncoder.encode(tier);
            const tierId = swift.memory.retain(tierBytes);
            const isSome = displayName != null;
            let result, result1;
            if (isSome) {
              const displayNameBytes = textEncoder.encode(displayName);
              const displayNameId = swift.memory.retain(displayNameBytes);
              result = displayNameId;
              result1 = displayNameBytes.length;
            } else {
              result = 0;
              result1 = 0;
            }
            __bjs_codec_Array_String.lower(dependsOn);
            instance2.exports.bjs_JSSuiteItem_init(scriptId, scriptBytes.length, tierId, tierBytes.length, +isSome, result, result1, points);
            const structValue = structHelpers.M10RunnerWasmT11JSSuiteItem.lift();
            return structValue;
          }
        },
        JSTestOutcome: {
          init: function(testName, testClass, tier, status, shortResult, longResult, score, points, metric, executionTimeMs, memoryUsageBytes, attemptNumber, isFirstPassSuccess) {
            const testNameBytes = textEncoder.encode(testName);
            const testNameId = swift.memory.retain(testNameBytes);
            const isSome = testClass != null;
            let result, result1;
            if (isSome) {
              const testClassBytes = textEncoder.encode(testClass);
              const testClassId = swift.memory.retain(testClassBytes);
              result = testClassId;
              result1 = testClassBytes.length;
            } else {
              result = 0;
              result1 = 0;
            }
            const tierBytes = textEncoder.encode(tier);
            const tierId = swift.memory.retain(tierBytes);
            const statusBytes = textEncoder.encode(status);
            const statusId = swift.memory.retain(statusBytes);
            const shortResultBytes = textEncoder.encode(shortResult);
            const shortResultId = swift.memory.retain(shortResultBytes);
            const isSome1 = longResult != null;
            let result2, result3;
            if (isSome1) {
              const longResultBytes = textEncoder.encode(longResult);
              const longResultId = swift.memory.retain(longResultBytes);
              result2 = longResultId;
              result3 = longResultBytes.length;
            } else {
              result2 = 0;
              result3 = 0;
            }
            const isSome2 = metric != null;
            const isSome3 = memoryUsageBytes != null;
            instance2.exports.bjs_JSTestOutcome_init(testNameId, testNameBytes.length, +isSome, result, result1, tierId, tierBytes.length, statusId, statusBytes.length, shortResultId, shortResultBytes.length, +isSome1, result2, result3, score, points, +isSome2, isSome2 ? metric : 0, executionTimeMs, +isSome3, isSome3 ? memoryUsageBytes : 0, attemptNumber, isFirstPassSuccess);
            const structValue = structHelpers.M10RunnerWasmT13JSTestOutcome.lift();
            return structValue;
          }
        }
      };
      _exports = exports;
      return exports;
    }
  };
}

// .build/plugins/PackageToJS/outputs/Package/instantiate.js
var MODULE_PATH = "RunnerWasm.7a6e938e50c7.wasm";
async function instantiate(options) {
  const { instantiator, ...result } = await _instantiate(options);
  options.wasi.initialize(result.instance);
  result.swift.main();
  return result;
}
async function _instantiate(options) {
  const _WebAssembly = options.WebAssembly || WebAssembly;
  const moduleSource = options.module;
  const { wasi } = options;
  const swift = new SwiftRuntime({});
  const instantiator = await createInstantiator(options, swift);
  const importObject = {
    javascript_kit: swift.wasmImports,
    wasi_snapshot_preview1: wasi.wasiImport
  };
  const importsContext = {
    getInstance: () => instance,
    getExports: () => exports,
    _swift: swift
  };
  instantiator.addImports(importObject, importsContext);
  options.addToCoreImports?.(importObject, importsContext);
  let module;
  let instance;
  let exports;
  if (moduleSource instanceof _WebAssembly.Module) {
    module = moduleSource;
    instance = await _WebAssembly.instantiate(module, importObject);
  } else if (typeof Response === "function" && (moduleSource instanceof Response || moduleSource instanceof Promise)) {
    if (typeof _WebAssembly.instantiateStreaming === "function") {
      const result = await _WebAssembly.instantiateStreaming(
        moduleSource,
        importObject
      );
      module = result.module;
      instance = result.instance;
    } else {
      const moduleBytes = await (await moduleSource).arrayBuffer();
      module = await _WebAssembly.compile(moduleBytes);
      instance = await _WebAssembly.instantiate(module, importObject);
    }
  } else {
    module = await _WebAssembly.compile(moduleSource);
    instance = await _WebAssembly.instantiate(module, importObject);
  }
  instance = options.instrumentInstance?.(instance, { _swift: swift }) ?? instance;
  swift.setInstance(instance);
  instantiator.setInstance(instance);
  exports = instantiator.createExports(instance);
  return {
    instance,
    swift,
    exports,
    instantiator
  };
}

// .build/plugins/PackageToJS/outputs/Package/node_modules/@bjorn3/browser_wasi_shim/dist/wasi_defs.js
var CLOCKID_REALTIME = 0;
var CLOCKID_MONOTONIC = 1;
var ERRNO_SUCCESS = 0;
var ERRNO_BADF = 8;
var ERRNO_EXIST = 20;
var ERRNO_INVAL = 28;
var ERRNO_ISDIR = 31;
var ERRNO_NAMETOOLONG = 37;
var ERRNO_NOENT = 44;
var ERRNO_NOSYS = 52;
var ERRNO_NOTDIR = 54;
var ERRNO_NOTEMPTY = 55;
var ERRNO_NOTSUP = 58;
var ERRNO_PERM = 63;
var ERRNO_NOTCAPABLE = 76;
var RIGHTS_FD_DATASYNC = 1 << 0;
var RIGHTS_FD_READ = 1 << 1;
var RIGHTS_FD_SEEK = 1 << 2;
var RIGHTS_FD_FDSTAT_SET_FLAGS = 1 << 3;
var RIGHTS_FD_SYNC = 1 << 4;
var RIGHTS_FD_TELL = 1 << 5;
var RIGHTS_FD_WRITE = 1 << 6;
var RIGHTS_FD_ADVISE = 1 << 7;
var RIGHTS_FD_ALLOCATE = 1 << 8;
var RIGHTS_PATH_CREATE_DIRECTORY = 1 << 9;
var RIGHTS_PATH_CREATE_FILE = 1 << 10;
var RIGHTS_PATH_LINK_SOURCE = 1 << 11;
var RIGHTS_PATH_LINK_TARGET = 1 << 12;
var RIGHTS_PATH_OPEN = 1 << 13;
var RIGHTS_FD_READDIR = 1 << 14;
var RIGHTS_PATH_READLINK = 1 << 15;
var RIGHTS_PATH_RENAME_SOURCE = 1 << 16;
var RIGHTS_PATH_RENAME_TARGET = 1 << 17;
var RIGHTS_PATH_FILESTAT_GET = 1 << 18;
var RIGHTS_PATH_FILESTAT_SET_SIZE = 1 << 19;
var RIGHTS_PATH_FILESTAT_SET_TIMES = 1 << 20;
var RIGHTS_FD_FILESTAT_GET = 1 << 21;
var RIGHTS_FD_FILESTAT_SET_SIZE = 1 << 22;
var RIGHTS_FD_FILESTAT_SET_TIMES = 1 << 23;
var RIGHTS_PATH_SYMLINK = 1 << 24;
var RIGHTS_PATH_REMOVE_DIRECTORY = 1 << 25;
var RIGHTS_PATH_UNLINK_FILE = 1 << 26;
var RIGHTS_POLL_FD_READWRITE = 1 << 27;
var RIGHTS_SOCK_SHUTDOWN = 1 << 28;
var Iovec = class _Iovec {
  static read_bytes(view, ptr) {
    const iovec = new _Iovec();
    iovec.buf = view.getUint32(ptr, true);
    iovec.buf_len = view.getUint32(ptr + 4, true);
    return iovec;
  }
  static read_bytes_array(view, ptr, len) {
    const iovecs = [];
    for (let i = 0; i < len; i++) {
      iovecs.push(_Iovec.read_bytes(view, ptr + 8 * i));
    }
    return iovecs;
  }
};
var Ciovec = class _Ciovec {
  static read_bytes(view, ptr) {
    const iovec = new _Ciovec();
    iovec.buf = view.getUint32(ptr, true);
    iovec.buf_len = view.getUint32(ptr + 4, true);
    return iovec;
  }
  static read_bytes_array(view, ptr, len) {
    const iovecs = [];
    for (let i = 0; i < len; i++) {
      iovecs.push(_Ciovec.read_bytes(view, ptr + 8 * i));
    }
    return iovecs;
  }
};
var WHENCE_SET = 0;
var WHENCE_CUR = 1;
var WHENCE_END = 2;
var FILETYPE_CHARACTER_DEVICE = 2;
var FILETYPE_DIRECTORY = 3;
var FILETYPE_REGULAR_FILE = 4;
var Dirent = class {
  head_length() {
    return 24;
  }
  name_length() {
    return this.dir_name.byteLength;
  }
  write_head_bytes(view, ptr) {
    view.setBigUint64(ptr, this.d_next, true);
    view.setBigUint64(ptr + 8, this.d_ino, true);
    view.setUint32(ptr + 16, this.dir_name.length, true);
    view.setUint8(ptr + 20, this.d_type);
  }
  write_name_bytes(view8, ptr, buf_len) {
    view8.set(this.dir_name.slice(0, Math.min(this.dir_name.byteLength, buf_len)), ptr);
  }
  constructor(next_cookie, name, type) {
    this.d_ino = 0n;
    const encoded_name = new TextEncoder().encode(name);
    this.d_next = next_cookie;
    this.d_namlen = encoded_name.byteLength;
    this.d_type = type;
    this.dir_name = encoded_name;
  }
};
var FDFLAGS_APPEND = 1 << 0;
var FDFLAGS_DSYNC = 1 << 1;
var FDFLAGS_NONBLOCK = 1 << 2;
var FDFLAGS_RSYNC = 1 << 3;
var FDFLAGS_SYNC = 1 << 4;
var Fdstat = class {
  write_bytes(view, ptr) {
    view.setUint8(ptr, this.fs_filetype);
    view.setUint16(ptr + 2, this.fs_flags, true);
    view.setBigUint64(ptr + 8, this.fs_rights_base, true);
    view.setBigUint64(ptr + 16, this.fs_rights_inherited, true);
  }
  constructor(filetype, flags) {
    this.fs_rights_base = 0n;
    this.fs_rights_inherited = 0n;
    this.fs_filetype = filetype;
    this.fs_flags = flags;
  }
};
var FSTFLAGS_ATIM = 1 << 0;
var FSTFLAGS_ATIM_NOW = 1 << 1;
var FSTFLAGS_MTIM = 1 << 2;
var FSTFLAGS_MTIM_NOW = 1 << 3;
var OFLAGS_CREAT = 1 << 0;
var OFLAGS_DIRECTORY = 1 << 1;
var OFLAGS_EXCL = 1 << 2;
var OFLAGS_TRUNC = 1 << 3;
var Filestat = class {
  write_bytes(view, ptr) {
    view.setBigUint64(ptr, this.dev, true);
    view.setBigUint64(ptr + 8, this.ino, true);
    view.setUint8(ptr + 16, this.filetype);
    view.setBigUint64(ptr + 24, this.nlink, true);
    view.setBigUint64(ptr + 32, this.size, true);
    view.setBigUint64(ptr + 38, this.atim, true);
    view.setBigUint64(ptr + 46, this.mtim, true);
    view.setBigUint64(ptr + 52, this.ctim, true);
  }
  constructor(filetype, size) {
    this.dev = 0n;
    this.ino = 0n;
    this.nlink = 0n;
    this.atim = 0n;
    this.mtim = 0n;
    this.ctim = 0n;
    this.filetype = filetype;
    this.size = size;
  }
};
var EVENTRWFLAGS_FD_READWRITE_HANGUP = 1 << 0;
var SUBCLOCKFLAGS_SUBSCRIPTION_CLOCK_ABSTIME = 1 << 0;
var RIFLAGS_RECV_PEEK = 1 << 0;
var RIFLAGS_RECV_WAITALL = 1 << 1;
var ROFLAGS_RECV_DATA_TRUNCATED = 1 << 0;
var SDFLAGS_RD = 1 << 0;
var SDFLAGS_WR = 1 << 1;
var PREOPENTYPE_DIR = 0;
var PrestatDir = class {
  write_bytes(view, ptr) {
    view.setUint32(ptr, this.pr_name.byteLength, true);
  }
  constructor(name) {
    this.pr_name = new TextEncoder().encode(name);
  }
};
var Prestat = class _Prestat {
  static dir(name) {
    const prestat = new _Prestat();
    prestat.tag = PREOPENTYPE_DIR;
    prestat.inner = new PrestatDir(name);
    return prestat;
  }
  write_bytes(view, ptr) {
    view.setUint32(ptr, this.tag, true);
    this.inner.write_bytes(view, ptr + 4);
  }
};

// .build/plugins/PackageToJS/outputs/Package/node_modules/@bjorn3/browser_wasi_shim/dist/debug.js
var Debug = class Debug2 {
  enable(enabled) {
    this.log = createLogger(enabled === void 0 ? true : enabled, this.prefix);
  }
  get enabled() {
    return this.isEnabled;
  }
  constructor(isEnabled) {
    this.isEnabled = isEnabled;
    this.prefix = "wasi:";
    this.enable(isEnabled);
  }
};
function createLogger(enabled, prefix) {
  if (enabled) {
    const a = console.log.bind(console, "%c%s", "color: #265BA0", prefix);
    return a;
  } else {
    return () => {
    };
  }
}
var debug = new Debug(false);

// .build/plugins/PackageToJS/outputs/Package/node_modules/@bjorn3/browser_wasi_shim/dist/wasi.js
var WASIProcExit = class extends Error {
  constructor(code) {
    super("exit with exit code " + code);
    this.code = code;
  }
};
var WASI = class WASI2 {
  start(instance) {
    this.inst = instance;
    try {
      instance.exports._start();
      return 0;
    } catch (e) {
      if (e instanceof WASIProcExit) {
        return e.code;
      } else {
        throw e;
      }
    }
  }
  initialize(instance) {
    this.inst = instance;
    if (instance.exports._initialize) {
      instance.exports._initialize();
    }
  }
  constructor(args, env, fds, options = {}) {
    this.args = [];
    this.env = [];
    this.fds = [];
    debug.enable(options.debug);
    this.args = args;
    this.env = env;
    this.fds = fds;
    const self = this;
    this.wasiImport = { args_sizes_get(argc, argv_buf_size) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      buffer.setUint32(argc, self.args.length, true);
      let buf_size = 0;
      for (const arg of self.args) {
        buf_size += arg.length + 1;
      }
      buffer.setUint32(argv_buf_size, buf_size, true);
      debug.log(buffer.getUint32(argc, true), buffer.getUint32(argv_buf_size, true));
      return 0;
    }, args_get(argv, argv_buf) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      const orig_argv_buf = argv_buf;
      for (let i = 0; i < self.args.length; i++) {
        buffer.setUint32(argv, argv_buf, true);
        argv += 4;
        const arg = new TextEncoder().encode(self.args[i]);
        buffer8.set(arg, argv_buf);
        buffer.setUint8(argv_buf + arg.length, 0);
        argv_buf += arg.length + 1;
      }
      if (debug.enabled) {
        debug.log(new TextDecoder("utf-8").decode(buffer8.slice(orig_argv_buf, argv_buf)));
      }
      return 0;
    }, environ_sizes_get(environ_count, environ_size) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      buffer.setUint32(environ_count, self.env.length, true);
      let buf_size = 0;
      for (const environ of self.env) {
        buf_size += environ.length + 1;
      }
      buffer.setUint32(environ_size, buf_size, true);
      debug.log(buffer.getUint32(environ_count, true), buffer.getUint32(environ_size, true));
      return 0;
    }, environ_get(environ, environ_buf) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      const orig_environ_buf = environ_buf;
      for (let i = 0; i < self.env.length; i++) {
        buffer.setUint32(environ, environ_buf, true);
        environ += 4;
        const e = new TextEncoder().encode(self.env[i]);
        buffer8.set(e, environ_buf);
        buffer.setUint8(environ_buf + e.length, 0);
        environ_buf += e.length + 1;
      }
      if (debug.enabled) {
        debug.log(new TextDecoder("utf-8").decode(buffer8.slice(orig_environ_buf, environ_buf)));
      }
      return 0;
    }, clock_res_get(id, res_ptr) {
      let resolutionValue;
      switch (id) {
        case CLOCKID_MONOTONIC: {
          resolutionValue = 5000n;
          break;
        }
        case CLOCKID_REALTIME: {
          resolutionValue = 1000000n;
          break;
        }
        default:
          return ERRNO_NOSYS;
      }
      const view = new DataView(self.inst.exports.memory.buffer);
      view.setBigUint64(res_ptr, resolutionValue, true);
      return ERRNO_SUCCESS;
    }, clock_time_get(id, precision, time) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      if (id === CLOCKID_REALTIME) {
        buffer.setBigUint64(time, BigInt((/* @__PURE__ */ new Date()).getTime()) * 1000000n, true);
      } else if (id == CLOCKID_MONOTONIC) {
        let monotonic_time;
        try {
          monotonic_time = BigInt(Math.round(performance.now() * 1e6));
        } catch (e) {
          monotonic_time = 0n;
        }
        buffer.setBigUint64(time, monotonic_time, true);
      } else {
        buffer.setBigUint64(time, 0n, true);
      }
      return 0;
    }, fd_advise(fd, offset, len, advice) {
      if (self.fds[fd] != void 0) {
        return ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, fd_allocate(fd, offset, len) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_allocate(offset, len);
      } else {
        return ERRNO_BADF;
      }
    }, fd_close(fd) {
      if (self.fds[fd] != void 0) {
        const ret = self.fds[fd].fd_close();
        self.fds[fd] = void 0;
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_datasync(fd) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_sync();
      } else {
        return ERRNO_BADF;
      }
    }, fd_fdstat_get(fd, fdstat_ptr) {
      if (self.fds[fd] != void 0) {
        const { ret, fdstat } = self.fds[fd].fd_fdstat_get();
        if (fdstat != null) {
          fdstat.write_bytes(new DataView(self.inst.exports.memory.buffer), fdstat_ptr);
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_fdstat_set_flags(fd, flags) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_fdstat_set_flags(flags);
      } else {
        return ERRNO_BADF;
      }
    }, fd_fdstat_set_rights(fd, fs_rights_base, fs_rights_inheriting) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_fdstat_set_rights(fs_rights_base, fs_rights_inheriting);
      } else {
        return ERRNO_BADF;
      }
    }, fd_filestat_get(fd, filestat_ptr) {
      if (self.fds[fd] != void 0) {
        const { ret, filestat } = self.fds[fd].fd_filestat_get();
        if (filestat != null) {
          filestat.write_bytes(new DataView(self.inst.exports.memory.buffer), filestat_ptr);
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_filestat_set_size(fd, size) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_filestat_set_size(size);
      } else {
        return ERRNO_BADF;
      }
    }, fd_filestat_set_times(fd, atim, mtim, fst_flags) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_filestat_set_times(atim, mtim, fst_flags);
      } else {
        return ERRNO_BADF;
      }
    }, fd_pread(fd, iovs_ptr, iovs_len, offset, nread_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const iovecs = Iovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
        let nread = 0;
        for (const iovec of iovecs) {
          const { ret, data } = self.fds[fd].fd_pread(iovec.buf_len, offset);
          if (ret != ERRNO_SUCCESS) {
            buffer.setUint32(nread_ptr, nread, true);
            return ret;
          }
          buffer8.set(data, iovec.buf);
          nread += data.length;
          offset += BigInt(data.length);
          if (data.length != iovec.buf_len) {
            break;
          }
        }
        buffer.setUint32(nread_ptr, nread, true);
        return ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, fd_prestat_get(fd, buf_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const { ret, prestat } = self.fds[fd].fd_prestat_get();
        if (prestat != null) {
          prestat.write_bytes(buffer, buf_ptr);
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_prestat_dir_name(fd, path_ptr, path_len) {
      if (self.fds[fd] != void 0) {
        const { ret, prestat } = self.fds[fd].fd_prestat_get();
        if (prestat == null) {
          return ret;
        }
        const prestat_dir_name = prestat.inner.pr_name;
        const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
        buffer8.set(prestat_dir_name.slice(0, path_len), path_ptr);
        return prestat_dir_name.byteLength > path_len ? ERRNO_NAMETOOLONG : ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, fd_pwrite(fd, iovs_ptr, iovs_len, offset, nwritten_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const iovecs = Ciovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
        let nwritten = 0;
        for (const iovec of iovecs) {
          const data = buffer8.slice(iovec.buf, iovec.buf + iovec.buf_len);
          const { ret, nwritten: nwritten_part } = self.fds[fd].fd_pwrite(data, offset);
          if (ret != ERRNO_SUCCESS) {
            buffer.setUint32(nwritten_ptr, nwritten, true);
            return ret;
          }
          nwritten += nwritten_part;
          offset += BigInt(nwritten_part);
          if (nwritten_part != data.byteLength) {
            break;
          }
        }
        buffer.setUint32(nwritten_ptr, nwritten, true);
        return ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, fd_read(fd, iovs_ptr, iovs_len, nread_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const iovecs = Iovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
        let nread = 0;
        for (const iovec of iovecs) {
          const { ret, data } = self.fds[fd].fd_read(iovec.buf_len);
          if (ret != ERRNO_SUCCESS) {
            buffer.setUint32(nread_ptr, nread, true);
            return ret;
          }
          buffer8.set(data, iovec.buf);
          nread += data.length;
          if (data.length != iovec.buf_len) {
            break;
          }
        }
        buffer.setUint32(nread_ptr, nread, true);
        return ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, fd_readdir(fd, buf, buf_len, cookie, bufused_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        let bufused = 0;
        while (true) {
          const { ret, dirent } = self.fds[fd].fd_readdir_single(cookie);
          if (ret != 0) {
            buffer.setUint32(bufused_ptr, bufused, true);
            return ret;
          }
          if (dirent == null) {
            break;
          }
          if (buf_len - bufused < dirent.head_length()) {
            bufused = buf_len;
            break;
          }
          const head_bytes = new ArrayBuffer(dirent.head_length());
          dirent.write_head_bytes(new DataView(head_bytes), 0);
          buffer8.set(new Uint8Array(head_bytes).slice(0, Math.min(head_bytes.byteLength, buf_len - bufused)), buf);
          buf += dirent.head_length();
          bufused += dirent.head_length();
          if (buf_len - bufused < dirent.name_length()) {
            bufused = buf_len;
            break;
          }
          dirent.write_name_bytes(buffer8, buf, buf_len - bufused);
          buf += dirent.name_length();
          bufused += dirent.name_length();
          cookie = dirent.d_next;
        }
        buffer.setUint32(bufused_ptr, bufused, true);
        return 0;
      } else {
        return ERRNO_BADF;
      }
    }, fd_renumber(fd, to) {
      if (self.fds[fd] != void 0 && self.fds[to] != void 0) {
        const ret = self.fds[to].fd_close();
        if (ret != 0) {
          return ret;
        }
        self.fds[to] = self.fds[fd];
        self.fds[fd] = void 0;
        return 0;
      } else {
        return ERRNO_BADF;
      }
    }, fd_seek(fd, offset, whence, offset_out_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const { ret, offset: offset_out } = self.fds[fd].fd_seek(offset, whence);
        buffer.setBigInt64(offset_out_ptr, offset_out, true);
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_sync(fd) {
      if (self.fds[fd] != void 0) {
        return self.fds[fd].fd_sync();
      } else {
        return ERRNO_BADF;
      }
    }, fd_tell(fd, offset_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const { ret, offset } = self.fds[fd].fd_tell();
        buffer.setBigUint64(offset_ptr, offset, true);
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const iovecs = Ciovec.read_bytes_array(buffer, iovs_ptr, iovs_len);
        let nwritten = 0;
        for (const iovec of iovecs) {
          const data = buffer8.slice(iovec.buf, iovec.buf + iovec.buf_len);
          const { ret, nwritten: nwritten_part } = self.fds[fd].fd_write(data);
          if (ret != ERRNO_SUCCESS) {
            buffer.setUint32(nwritten_ptr, nwritten, true);
            return ret;
          }
          nwritten += nwritten_part;
          if (nwritten_part != data.byteLength) {
            break;
          }
        }
        buffer.setUint32(nwritten_ptr, nwritten, true);
        return ERRNO_SUCCESS;
      } else {
        return ERRNO_BADF;
      }
    }, path_create_directory(fd, path_ptr, path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        return self.fds[fd].path_create_directory(path);
      } else {
        return ERRNO_BADF;
      }
    }, path_filestat_get(fd, flags, path_ptr, path_len, filestat_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        const { ret, filestat } = self.fds[fd].path_filestat_get(flags, path);
        if (filestat != null) {
          filestat.write_bytes(buffer, filestat_ptr);
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, path_filestat_set_times(fd, flags, path_ptr, path_len, atim, mtim, fst_flags) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        return self.fds[fd].path_filestat_set_times(flags, path, atim, mtim, fst_flags);
      } else {
        return ERRNO_BADF;
      }
    }, path_link(old_fd, old_flags, old_path_ptr, old_path_len, new_fd, new_path_ptr, new_path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[old_fd] != void 0 && self.fds[new_fd] != void 0) {
        const old_path = new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
        const new_path = new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
        const { ret, inode_obj } = self.fds[old_fd].path_lookup(old_path, old_flags);
        if (inode_obj == null) {
          return ret;
        }
        return self.fds[new_fd].path_link(new_path, inode_obj, false);
      } else {
        return ERRNO_BADF;
      }
    }, path_open(fd, dirflags, path_ptr, path_len, oflags, fs_rights_base, fs_rights_inheriting, fd_flags, opened_fd_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        debug.log(path);
        const { ret, fd_obj } = self.fds[fd].path_open(dirflags, path, oflags, fs_rights_base, fs_rights_inheriting, fd_flags);
        if (ret != 0) {
          return ret;
        }
        self.fds.push(fd_obj);
        const opened_fd = self.fds.length - 1;
        buffer.setUint32(opened_fd_ptr, opened_fd, true);
        return 0;
      } else {
        return ERRNO_BADF;
      }
    }, path_readlink(fd, path_ptr, path_len, buf_ptr, buf_len, nread_ptr) {
      const buffer = new DataView(self.inst.exports.memory.buffer);
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        debug.log(path);
        const { ret, data } = self.fds[fd].path_readlink(path);
        if (data != null) {
          const data_buf = new TextEncoder().encode(data);
          if (data_buf.length > buf_len) {
            buffer.setUint32(nread_ptr, 0, true);
            return ERRNO_BADF;
          }
          buffer8.set(data_buf, buf_ptr);
          buffer.setUint32(nread_ptr, data_buf.length, true);
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, path_remove_directory(fd, path_ptr, path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        return self.fds[fd].path_remove_directory(path);
      } else {
        return ERRNO_BADF;
      }
    }, path_rename(fd, old_path_ptr, old_path_len, new_fd, new_path_ptr, new_path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0 && self.fds[new_fd] != void 0) {
        const old_path = new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
        const new_path = new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
        let { ret, inode_obj } = self.fds[fd].path_unlink(old_path);
        if (inode_obj == null) {
          return ret;
        }
        ret = self.fds[new_fd].path_link(new_path, inode_obj, true);
        if (ret != ERRNO_SUCCESS) {
          if (self.fds[fd].path_link(old_path, inode_obj, true) != ERRNO_SUCCESS) {
            throw "path_link should always return success when relinking an inode back to the original place";
          }
        }
        return ret;
      } else {
        return ERRNO_BADF;
      }
    }, path_symlink(old_path_ptr, old_path_len, fd, new_path_ptr, new_path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const old_path = new TextDecoder("utf-8").decode(buffer8.slice(old_path_ptr, old_path_ptr + old_path_len));
        const new_path = new TextDecoder("utf-8").decode(buffer8.slice(new_path_ptr, new_path_ptr + new_path_len));
        return ERRNO_NOTSUP;
      } else {
        return ERRNO_BADF;
      }
    }, path_unlink_file(fd, path_ptr, path_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      if (self.fds[fd] != void 0) {
        const path = new TextDecoder("utf-8").decode(buffer8.slice(path_ptr, path_ptr + path_len));
        return self.fds[fd].path_unlink_file(path);
      } else {
        return ERRNO_BADF;
      }
    }, poll_oneoff(in_, out, nsubscriptions) {
      throw "async io not supported";
    }, proc_exit(exit_code) {
      throw new WASIProcExit(exit_code);
    }, proc_raise(sig) {
      throw "raised signal " + sig;
    }, sched_yield() {
    }, random_get(buf, buf_len) {
      const buffer8 = new Uint8Array(self.inst.exports.memory.buffer);
      for (let i = 0; i < buf_len; i++) {
        buffer8[buf + i] = Math.random() * 256 | 0;
      }
    }, sock_recv(fd, ri_data, ri_flags) {
      throw "sockets not supported";
    }, sock_send(fd, si_data, si_flags) {
      throw "sockets not supported";
    }, sock_shutdown(fd, how) {
      throw "sockets not supported";
    }, sock_accept(fd, flags) {
      throw "sockets not supported";
    } };
  }
};

// .build/plugins/PackageToJS/outputs/Package/node_modules/@bjorn3/browser_wasi_shim/dist/fd.js
var Fd = class {
  fd_allocate(offset, len) {
    return ERRNO_NOTSUP;
  }
  fd_close() {
    return 0;
  }
  fd_fdstat_get() {
    return { ret: ERRNO_NOTSUP, fdstat: null };
  }
  fd_fdstat_set_flags(flags) {
    return ERRNO_NOTSUP;
  }
  fd_fdstat_set_rights(fs_rights_base, fs_rights_inheriting) {
    return ERRNO_NOTSUP;
  }
  fd_filestat_get() {
    return { ret: ERRNO_NOTSUP, filestat: null };
  }
  fd_filestat_set_size(size) {
    return ERRNO_NOTSUP;
  }
  fd_filestat_set_times(atim, mtim, fst_flags) {
    return ERRNO_NOTSUP;
  }
  fd_pread(size, offset) {
    return { ret: ERRNO_NOTSUP, data: new Uint8Array() };
  }
  fd_prestat_get() {
    return { ret: ERRNO_NOTSUP, prestat: null };
  }
  fd_pwrite(data, offset) {
    return { ret: ERRNO_NOTSUP, nwritten: 0 };
  }
  fd_read(size) {
    return { ret: ERRNO_NOTSUP, data: new Uint8Array() };
  }
  fd_readdir_single(cookie) {
    return { ret: ERRNO_NOTSUP, dirent: null };
  }
  fd_seek(offset, whence) {
    return { ret: ERRNO_NOTSUP, offset: 0n };
  }
  fd_sync() {
    return 0;
  }
  fd_tell() {
    return { ret: ERRNO_NOTSUP, offset: 0n };
  }
  fd_write(data) {
    return { ret: ERRNO_NOTSUP, nwritten: 0 };
  }
  path_create_directory(path) {
    return ERRNO_NOTSUP;
  }
  path_filestat_get(flags, path) {
    return { ret: ERRNO_NOTSUP, filestat: null };
  }
  path_filestat_set_times(flags, path, atim, mtim, fst_flags) {
    return ERRNO_NOTSUP;
  }
  path_link(path, inode, allow_dir) {
    return ERRNO_NOTSUP;
  }
  path_unlink(path) {
    return { ret: ERRNO_NOTSUP, inode_obj: null };
  }
  path_lookup(path, dirflags) {
    return { ret: ERRNO_NOTSUP, inode_obj: null };
  }
  path_open(dirflags, path, oflags, fs_rights_base, fs_rights_inheriting, fd_flags) {
    return { ret: ERRNO_NOTDIR, fd_obj: null };
  }
  path_readlink(path) {
    return { ret: ERRNO_NOTSUP, data: null };
  }
  path_remove_directory(path) {
    return ERRNO_NOTSUP;
  }
  path_rename(old_path, new_fd, new_path) {
    return ERRNO_NOTSUP;
  }
  path_unlink_file(path) {
    return ERRNO_NOTSUP;
  }
};
var Inode = class {
};

// .build/plugins/PackageToJS/outputs/Package/node_modules/@bjorn3/browser_wasi_shim/dist/fs_mem.js
var OpenFile = class extends Fd {
  fd_allocate(offset, len) {
    if (this.file.size > offset + len) {
    } else {
      const new_data = new Uint8Array(Number(offset + len));
      new_data.set(this.file.data, 0);
      this.file.data = new_data;
    }
    return ERRNO_SUCCESS;
  }
  fd_fdstat_get() {
    return { ret: 0, fdstat: new Fdstat(FILETYPE_REGULAR_FILE, 0) };
  }
  fd_filestat_set_size(size) {
    if (this.file.size > size) {
      this.file.data = new Uint8Array(this.file.data.buffer.slice(0, Number(size)));
    } else {
      const new_data = new Uint8Array(Number(size));
      new_data.set(this.file.data, 0);
      this.file.data = new_data;
    }
    return ERRNO_SUCCESS;
  }
  fd_read(size) {
    const slice = this.file.data.slice(Number(this.file_pos), Number(this.file_pos + BigInt(size)));
    this.file_pos += BigInt(slice.length);
    return { ret: 0, data: slice };
  }
  fd_pread(size, offset) {
    const slice = this.file.data.slice(Number(offset), Number(offset + BigInt(size)));
    return { ret: 0, data: slice };
  }
  fd_seek(offset, whence) {
    let calculated_offset;
    switch (whence) {
      case WHENCE_SET:
        calculated_offset = offset;
        break;
      case WHENCE_CUR:
        calculated_offset = this.file_pos + offset;
        break;
      case WHENCE_END:
        calculated_offset = BigInt(this.file.data.byteLength) + offset;
        break;
      default:
        return { ret: ERRNO_INVAL, offset: 0n };
    }
    if (calculated_offset < 0) {
      return { ret: ERRNO_INVAL, offset: 0n };
    }
    this.file_pos = calculated_offset;
    return { ret: 0, offset: this.file_pos };
  }
  fd_tell() {
    return { ret: 0, offset: this.file_pos };
  }
  fd_write(data) {
    if (this.file.readonly) return { ret: ERRNO_BADF, nwritten: 0 };
    if (this.file_pos + BigInt(data.byteLength) > this.file.size) {
      const old = this.file.data;
      this.file.data = new Uint8Array(Number(this.file_pos + BigInt(data.byteLength)));
      this.file.data.set(old);
    }
    this.file.data.set(data, Number(this.file_pos));
    this.file_pos += BigInt(data.byteLength);
    return { ret: 0, nwritten: data.byteLength };
  }
  fd_pwrite(data, offset) {
    if (this.file.readonly) return { ret: ERRNO_BADF, nwritten: 0 };
    if (offset + BigInt(data.byteLength) > this.file.size) {
      const old = this.file.data;
      this.file.data = new Uint8Array(Number(offset + BigInt(data.byteLength)));
      this.file.data.set(old);
    }
    this.file.data.set(data, Number(offset));
    return { ret: 0, nwritten: data.byteLength };
  }
  fd_filestat_get() {
    return { ret: 0, filestat: this.file.stat() };
  }
  constructor(file) {
    super();
    this.file_pos = 0n;
    this.file = file;
  }
};
var OpenDirectory = class extends Fd {
  fd_seek(offset, whence) {
    return { ret: ERRNO_BADF, offset: 0n };
  }
  fd_tell() {
    return { ret: ERRNO_BADF, offset: 0n };
  }
  fd_allocate(offset, len) {
    return ERRNO_BADF;
  }
  fd_fdstat_get() {
    return { ret: 0, fdstat: new Fdstat(FILETYPE_DIRECTORY, 0) };
  }
  fd_readdir_single(cookie) {
    if (debug.enabled) {
      debug.log("readdir_single", cookie);
      debug.log(cookie, this.dir.contents.keys());
    }
    if (cookie == 0n) {
      return { ret: ERRNO_SUCCESS, dirent: new Dirent(1n, ".", FILETYPE_DIRECTORY) };
    } else if (cookie == 1n) {
      return { ret: ERRNO_SUCCESS, dirent: new Dirent(2n, "..", FILETYPE_DIRECTORY) };
    }
    if (cookie >= BigInt(this.dir.contents.size) + 2n) {
      return { ret: 0, dirent: null };
    }
    const [name, entry] = Array.from(this.dir.contents.entries())[Number(cookie - 2n)];
    return { ret: 0, dirent: new Dirent(cookie + 1n, name, entry.stat().filetype) };
  }
  path_filestat_get(flags, path_str) {
    const { ret: path_err, path } = Path.from(path_str);
    if (path == null) {
      return { ret: path_err, filestat: null };
    }
    const { ret, entry } = this.dir.get_entry_for_path(path);
    if (entry == null) {
      return { ret, filestat: null };
    }
    return { ret: 0, filestat: entry.stat() };
  }
  path_lookup(path_str, dirflags) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return { ret: path_ret, inode_obj: null };
    }
    const { ret, entry } = this.dir.get_entry_for_path(path);
    if (entry == null) {
      return { ret, inode_obj: null };
    }
    return { ret: ERRNO_SUCCESS, inode_obj: entry };
  }
  path_open(dirflags, path_str, oflags, fs_rights_base, fs_rights_inheriting, fd_flags) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return { ret: path_ret, fd_obj: null };
    }
    let { ret, entry } = this.dir.get_entry_for_path(path);
    if (entry == null) {
      if (ret != ERRNO_NOENT) {
        return { ret, fd_obj: null };
      }
      if ((oflags & OFLAGS_CREAT) == OFLAGS_CREAT) {
        const { ret: ret2, entry: new_entry } = this.dir.create_entry_for_path(path_str, (oflags & OFLAGS_DIRECTORY) == OFLAGS_DIRECTORY);
        if (new_entry == null) {
          return { ret: ret2, fd_obj: null };
        }
        entry = new_entry;
      } else {
        return { ret: ERRNO_NOENT, fd_obj: null };
      }
    } else if ((oflags & OFLAGS_EXCL) == OFLAGS_EXCL) {
      return { ret: ERRNO_EXIST, fd_obj: null };
    }
    if ((oflags & OFLAGS_DIRECTORY) == OFLAGS_DIRECTORY && entry.stat().filetype !== FILETYPE_DIRECTORY) {
      return { ret: ERRNO_NOTDIR, fd_obj: null };
    }
    return entry.path_open(oflags, fs_rights_base, fd_flags);
  }
  path_create_directory(path) {
    return this.path_open(0, path, OFLAGS_CREAT | OFLAGS_DIRECTORY, 0n, 0n, 0).ret;
  }
  path_link(path_str, inode, allow_dir) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return path_ret;
    }
    if (path.is_dir) {
      return ERRNO_NOENT;
    }
    const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, true);
    if (parent_entry == null || filename == null) {
      return parent_ret;
    }
    if (entry != null) {
      const source_is_dir = inode.stat().filetype == FILETYPE_DIRECTORY;
      const target_is_dir = entry.stat().filetype == FILETYPE_DIRECTORY;
      if (source_is_dir && target_is_dir) {
        if (allow_dir && entry instanceof Directory) {
          if (entry.contents.size == 0) {
          } else {
            return ERRNO_NOTEMPTY;
          }
        } else {
          return ERRNO_EXIST;
        }
      } else if (source_is_dir && !target_is_dir) {
        return ERRNO_NOTDIR;
      } else if (!source_is_dir && target_is_dir) {
        return ERRNO_ISDIR;
      } else if (inode.stat().filetype == FILETYPE_REGULAR_FILE && entry.stat().filetype == FILETYPE_REGULAR_FILE) {
      } else {
        return ERRNO_EXIST;
      }
    }
    if (!allow_dir && inode.stat().filetype == FILETYPE_DIRECTORY) {
      return ERRNO_PERM;
    }
    parent_entry.contents.set(filename, inode);
    return ERRNO_SUCCESS;
  }
  path_unlink(path_str) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return { ret: path_ret, inode_obj: null };
    }
    const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, true);
    if (parent_entry == null || filename == null) {
      return { ret: parent_ret, inode_obj: null };
    }
    if (entry == null) {
      return { ret: ERRNO_NOENT, inode_obj: null };
    }
    parent_entry.contents.delete(filename);
    return { ret: ERRNO_SUCCESS, inode_obj: entry };
  }
  path_unlink_file(path_str) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return path_ret;
    }
    const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, false);
    if (parent_entry == null || filename == null || entry == null) {
      return parent_ret;
    }
    if (entry.stat().filetype === FILETYPE_DIRECTORY) {
      return ERRNO_ISDIR;
    }
    parent_entry.contents.delete(filename);
    return ERRNO_SUCCESS;
  }
  path_remove_directory(path_str) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return path_ret;
    }
    const { ret: parent_ret, parent_entry, filename, entry } = this.dir.get_parent_dir_and_entry_for_path(path, false);
    if (parent_entry == null || filename == null || entry == null) {
      return parent_ret;
    }
    if (!(entry instanceof Directory) || entry.stat().filetype !== FILETYPE_DIRECTORY) {
      return ERRNO_NOTDIR;
    }
    if (entry.contents.size !== 0) {
      return ERRNO_NOTEMPTY;
    }
    if (!parent_entry.contents.delete(filename)) {
      return ERRNO_NOENT;
    }
    return ERRNO_SUCCESS;
  }
  fd_filestat_get() {
    return { ret: 0, filestat: this.dir.stat() };
  }
  fd_filestat_set_size(size) {
    return ERRNO_BADF;
  }
  fd_read(size) {
    return { ret: ERRNO_BADF, data: new Uint8Array() };
  }
  fd_pread(size, offset) {
    return { ret: ERRNO_BADF, data: new Uint8Array() };
  }
  fd_write(data) {
    return { ret: ERRNO_BADF, nwritten: 0 };
  }
  fd_pwrite(data, offset) {
    return { ret: ERRNO_BADF, nwritten: 0 };
  }
  constructor(dir) {
    super();
    this.dir = dir;
  }
};
var PreopenDirectory = class extends OpenDirectory {
  fd_prestat_get() {
    return { ret: 0, prestat: Prestat.dir(this.prestat_name) };
  }
  constructor(name, contents) {
    super(new Directory(contents));
    this.prestat_name = name;
  }
};
var File = class extends Inode {
  path_open(oflags, fs_rights_base, fd_flags) {
    if (this.readonly && (fs_rights_base & BigInt(RIGHTS_FD_WRITE)) == BigInt(RIGHTS_FD_WRITE)) {
      return { ret: ERRNO_PERM, fd_obj: null };
    }
    if ((oflags & OFLAGS_TRUNC) == OFLAGS_TRUNC) {
      if (this.readonly) return { ret: ERRNO_PERM, fd_obj: null };
      this.data = new Uint8Array([]);
    }
    const file = new OpenFile(this);
    if (fd_flags & FDFLAGS_APPEND) file.fd_seek(0n, WHENCE_END);
    return { ret: ERRNO_SUCCESS, fd_obj: file };
  }
  get size() {
    return BigInt(this.data.byteLength);
  }
  stat() {
    return new Filestat(FILETYPE_REGULAR_FILE, this.size);
  }
  constructor(data, options) {
    super();
    this.data = new Uint8Array(data);
    this.readonly = !!options?.readonly;
  }
};
var Path = class Path2 {
  static from(path) {
    const self = new Path2();
    self.is_dir = path.endsWith("/");
    if (path.startsWith("/")) {
      return { ret: ERRNO_NOTCAPABLE, path: null };
    }
    if (path.includes("\0")) {
      return { ret: ERRNO_INVAL, path: null };
    }
    for (const component of path.split("/")) {
      if (component === "" || component === ".") {
        continue;
      }
      if (component === "..") {
        if (self.parts.pop() == void 0) {
          return { ret: ERRNO_NOTCAPABLE, path: null };
        }
        continue;
      }
      self.parts.push(component);
    }
    return { ret: ERRNO_SUCCESS, path: self };
  }
  to_path_string() {
    let s = this.parts.join("/");
    if (this.is_dir) {
      s += "/";
    }
    return s;
  }
  constructor() {
    this.parts = [];
    this.is_dir = false;
  }
};
var Directory = class _Directory extends Inode {
  path_open(oflags, fs_rights_base, fd_flags) {
    return { ret: ERRNO_SUCCESS, fd_obj: new OpenDirectory(this) };
  }
  stat() {
    return new Filestat(FILETYPE_DIRECTORY, 0n);
  }
  get_entry_for_path(path) {
    let entry = this;
    for (const component of path.parts) {
      if (!(entry instanceof _Directory)) {
        return { ret: ERRNO_NOTDIR, entry: null };
      }
      const child = entry.contents.get(component);
      if (child !== void 0) {
        entry = child;
      } else {
        debug.log(component);
        return { ret: ERRNO_NOENT, entry: null };
      }
    }
    if (path.is_dir) {
      if (entry.stat().filetype != FILETYPE_DIRECTORY) {
        return { ret: ERRNO_NOTDIR, entry: null };
      }
    }
    return { ret: ERRNO_SUCCESS, entry };
  }
  get_parent_dir_and_entry_for_path(path, allow_undefined) {
    const filename = path.parts.pop();
    if (filename === void 0) {
      return { ret: ERRNO_INVAL, parent_entry: null, filename: null, entry: null };
    }
    const { ret: entry_ret, entry: parent_entry } = this.get_entry_for_path(path);
    if (parent_entry == null) {
      return { ret: entry_ret, parent_entry: null, filename: null, entry: null };
    }
    if (!(parent_entry instanceof _Directory)) {
      return { ret: ERRNO_NOTDIR, parent_entry: null, filename: null, entry: null };
    }
    const entry = parent_entry.contents.get(filename);
    if (entry === void 0) {
      if (!allow_undefined) {
        return { ret: ERRNO_NOENT, parent_entry: null, filename: null, entry: null };
      } else {
        return { ret: ERRNO_SUCCESS, parent_entry, filename, entry: null };
      }
    }
    if (path.is_dir) {
      if (entry.stat().filetype != FILETYPE_DIRECTORY) {
        return { ret: ERRNO_NOTDIR, parent_entry: null, filename: null, entry: null };
      }
    }
    return { ret: ERRNO_SUCCESS, parent_entry, filename, entry };
  }
  create_entry_for_path(path_str, is_dir) {
    const { ret: path_ret, path } = Path.from(path_str);
    if (path == null) {
      return { ret: path_ret, entry: null };
    }
    let { ret: parent_ret, parent_entry, filename, entry } = this.get_parent_dir_and_entry_for_path(path, true);
    if (parent_entry == null || filename == null) {
      return { ret: parent_ret, entry: null };
    }
    if (entry != null) {
      return { ret: ERRNO_EXIST, entry: null };
    }
    debug.log("create", path);
    let new_child;
    if (!is_dir) {
      new_child = new File(new ArrayBuffer(0));
    } else {
      new_child = new _Directory(/* @__PURE__ */ new Map());
    }
    parent_entry.contents.set(filename, new_child);
    entry = new_child;
    return { ret: ERRNO_SUCCESS, entry };
  }
  constructor(contents) {
    super();
    if (contents instanceof Array) {
      this.contents = new Map(contents);
    } else {
      this.contents = contents;
    }
  }
};
var ConsoleStdout = class _ConsoleStdout extends Fd {
  fd_filestat_get() {
    const filestat = new Filestat(FILETYPE_CHARACTER_DEVICE, BigInt(0));
    return { ret: 0, filestat };
  }
  fd_fdstat_get() {
    const fdstat = new Fdstat(FILETYPE_CHARACTER_DEVICE, 0);
    fdstat.fs_rights_base = BigInt(RIGHTS_FD_WRITE);
    return { ret: 0, fdstat };
  }
  fd_write(data) {
    this.write(data);
    return { ret: 0, nwritten: data.byteLength };
  }
  static lineBuffered(write2) {
    const dec = new TextDecoder("utf-8", { fatal: false });
    let line_buf = "";
    return new _ConsoleStdout((buffer) => {
      line_buf += dec.decode(buffer, { stream: true });
      const lines = line_buf.split("\n");
      for (const [i, line] of lines.entries()) {
        if (i < lines.length - 1) {
          write2(line);
        } else {
          line_buf = line;
        }
      }
    });
  }
  constructor(write2) {
    super();
    this.write = write2;
  }
};

// .build/plugins/PackageToJS/outputs/Package/platforms/browser.js
async function defaultBrowserSetup(options) {
  const args = options.args ?? [];
  const onStdoutLine = options.onStdoutLine ?? ((line) => console.log(line));
  const onStderrLine = options.onStderrLine ?? ((line) => console.error(line));
  const wasi = new WASI(
    /* args */
    [MODULE_PATH, ...args],
    /* env */
    [],
    /* fd */
    [
      new OpenFile(new File([])),
      // stdin
      ConsoleStdout.lineBuffered((stdout) => {
        onStdoutLine(stdout);
      }),
      ConsoleStdout.lineBuffered((stderr) => {
        onStderrLine(stderr);
      }),
      new PreopenDirectory("/", /* @__PURE__ */ new Map())
    ],
    { debug: false }
  );
  return {
    module: options.module,
    getImports() {
      return options.getImports();
    },
    wasi: Object.assign(wasi, {
      setInstance(instance) {
        wasi.inst = instance;
      }
    })
  };
}

// .build/plugins/PackageToJS/outputs/Package/index.js
async function initBrowser(_options) {
  const options = _options || {
    /** @returns {import('./instantiate.d').Imports} */
    getImports() {
      (() => {
        throw new Error("No imports provided");
      })();
    }
  };
  let module = options.module;
  if (!module) {
    module = fetch(new URL("RunnerWasm.7a6e938e50c7.wasm", import.meta.url));
  }
  const instantiateOptions = await defaultBrowserSetup({
    module,
    getImports: () => options.getImports()
  });
  return await instantiate(instantiateOptions);
}
async function init(options) {
  return initBrowser(options);
}

// loader/runner-core-entry.js
var REJECTED_RUN_STDERR = "browser executor: script run rejected";
var NON_OBJECT_RUN_STDERR = "browser executor: non-object run result";
function toCells(cells) {
  return (Array.isArray(cells) ? cells : []).map((cell) => ({
    cellType: String(cell?.cell_type ?? cell?.cellType ?? ""),
    source: String(cell?.source ?? "")
  }));
}
function toSuiteItems(suites) {
  return (Array.isArray(suites) ? suites : []).map((entry) => ({
    script: String(entry?.script ?? ""),
    tier: String(entry?.tier ?? "public"),
    displayName: typeof entry?.displayName === "string" ? entry.displayName : null,
    dependsOn: Array.isArray(entry?.dependsOn) ? entry.dependsOn.map(String) : [],
    points: typeof entry?.points === "number" ? entry.points : 1
  }));
}
function toScriptOutput(value, fallbackStderr) {
  if (value === null || typeof value !== "object") {
    return { exitCode: 2, stdout: "", stderr: fallbackStderr, executionTimeMs: 0, timedOut: false };
  }
  return {
    exitCode: typeof value.exitCode === "number" ? value.exitCode : 2,
    stdout: typeof value.stdout === "string" ? value.stdout : "",
    stderr: typeof value.stderr === "string" ? value.stderr : "",
    executionTimeMs: typeof value.executionTimeMs === "number" ? value.executionTimeMs : 0,
    timedOut: value.timedOut === true
  };
}
function registerLegacyGlobals(exports, target = globalThis) {
  target.runnerExtractPython = (cells, filename) => exports.extractPython(toCells(cells), String(filename ?? ""));
  target.runnerExtractR = (cells, filename) => exports.extractR(toCells(cells), String(filename ?? ""));
  target.runnerExtractLua = (cells, filename) => exports.extractLua(toCells(cells), String(filename ?? ""));
  target.runnerExtractOctave = (cells, filename) => exports.extractOctave(toCells(cells), String(filename ?? ""));
  target.runnerClassifyScript = (name, source) => exports.classifyScript(String(name ?? ""), String(source ?? ""));
  target.runnerExecuteSuites = (suites, timeLimitSeconds, attemptNumber, scriptExists, run) => exports.executeSuites(
    toSuiteItems(suites),
    typeof timeLimitSeconds === "number" ? timeLimitSeconds : 10,
    typeof attemptNumber === "number" ? attemptNumber : 1,
    (name) => Boolean(scriptExists(name)),
    async (name, limit) => {
      let result;
      try {
        result = await run(name, limit);
      } catch (_) {
        return toScriptOutput(null, REJECTED_RUN_STDERR);
      }
      return toScriptOutput(result, NON_OBJECT_RUN_STDERR);
    }
  );
  return target;
}
async function init2(options) {
  const result = await init(options);
  registerLegacyGlobals(result.exports);
  return result;
}
export {
  init2 as init,
  registerLegacyGlobals
};
