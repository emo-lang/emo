// The browser host for the TypeScript runtime: line-buffered console
// output, the one process context the page's root runs under, and the
// `dom_*` capability family. The compiler concatenates this file after
// ts_core.ts and strips the types, so the bundle has no host imports
// and never touches `process`.

let _browserPid: number | null = null;
let _browserPending = "";

// A browser has no process: each line prints as it completes, and a
// trailing partial line is flushed when the root body ends.
function browserWrite(text: string): void {
  _browserPending += text;
  const cut = _browserPending.lastIndexOf("\n");
  if (cut < 0) return;
  const whole = _browserPending.slice(0, cut);
  _browserPending = _browserPending.slice(cut + 1);
  for (const line of whole.split("\n")) console.log(line);
}

function browserShutdown(): void {
  if (_browserPending.length === 0) return;
  console.log(_browserPending);
  _browserPending = "";
}

// One pid for the page: the root body runs under it, and an event
// delivered from a listener runs under the same id, so `self_pid()`
// stays meaningful across the browser's callbacks.
function browserRunAs<T>(pid: number, f: () => T): T {
  _browserPid = pid;
  return f();
}

function browserCurrentPid(): number | null {
  return _browserPid;
}

// ---- DOM ----

// A DOM node crosses into Emo as an Int64 handle into this table; the
// page's own objects stay on the host side, like the networking section's
// sockets. A node's handle is handed out once and answered again for as
// long as the node lives — the retained diff tells two references to one
// element apart from two elements by comparing handles — and is never
// given to another node. 0 is no node's handle: it is what `dom_child`
// answers for an index the parent does not reach, and what
// `dom_insert_before` takes for "at the end".
let _domNext = 1;
const _domNodes = new Map<number, any>();
const _domHandles = new WeakMap<object, bigint>();
let _domSink: ((tag: bigint, text: string) => any) | null = null;

function domHandle(node: any): bigint {
  if (typeof node === "object" && node !== null) {
    const known = _domHandles.get(node);
    if (known !== undefined) return known;
  }
  const id = _domNext++;
  _domNodes.set(id, node);
  // The handle is a BigInt like every Int64 the runtime carries: a
  // plain number in dynamic position is a Byte there, and a known
  // element's handle answered as one made `>=` against it refuse.
  if (typeof node === "object" && node !== null) _domHandles.set(node, BigInt(id));
  return BigInt(id);
}

function domNode(handle: any): any {
  const node = _domNodes.get(Number(handle));
  if (node === undefined)
    throw new Error("dom: handle " + handle + " names no live node");
  return node;
}

// The mount point: `#emo-root` when the page provides one, the body
// otherwise. There is no implicit document structure beyond this.
function domRoot(): bigint {
  const root = document.getElementById("emo-root") || document.body;
  if (!root)
    throw new Error(
      "dom: the page has neither an `#emo-root` element nor a body"
    );
  return domHandle(root);
}

function domElement(tag: any): bigint {
  return domHandle(document.createElement(String(tag)));
}

function domText(text: any): bigint {
  return domHandle(document.createTextNode(String(text)));
}

function domSetText(handle: any, text: any): void {
  domNode(handle).textContent = String(text);
}

// A CSS property by its CSS name (`background-color`, `font-size`),
// which is also how the ui core's Style keys are spelled.
function domSetStyle(handle: any, name: any, value: any): void {
  domNode(handle).style.setProperty(String(name), String(value));
}

// A property or attribute by its DOM name (`type`, `value`, `disabled`,
// `class`). The value is the dynamic Emo value as the runtime carries
// it; the interface program passes strings and booleans.
function domSetProp(handle: any, name: any, value: any): void {
  const node = domNode(handle);
  if (name === "class") node.className = String(value);
  else node[String(name)] = value;
}

function domAppend(parent: any, child: any): void {
  domNode(parent).appendChild(domNode(child));
}

// The child at an index, as its handle; 0 when the parent has none there.
function domChild(handle: any, index: any): bigint {
  const node = domNode(handle).children[Number(index)];
  return node === undefined ? 0n : domHandle(node);
}

function domRemove(parent: any, child: any): void {
  domNode(parent).removeChild(domNode(child));
}

// The child under the parent, ahead of `before` — at the end when
// `before` is 0. A child that already sits under the parent moves.
function domInsertBefore(parent: any, child: any, before: any): void {
  const node = domNode(parent);
  const ref = Number(before) === 0 ? null : domNode(before);
  node.insertBefore(domNode(child), ref);
}

function domClear(handle: any): void {
  const node = domNode(handle);
  while (node.firstChild) node.removeChild(node.firstChild);
}

// Every event carries the tag the interface program chose for it; the
// listener hands that tag to the sink, which steps the Elm loop. An
// `input` event is a field's: the element's own value rides with the
// tag, the way a click's text is empty.
function domConnect(handle: any, event: any, tag: any): void {
  domNode(handle).addEventListener(String(event), () => {
    const text = String(event) === "input" ? domValue(handle) : "";
    domDeliver(BigInt(tag), text);
  });
}

function domValue(handle: any): string {
  const node = domNode(handle);
  return node.value === undefined ? "" : String(node.value);
}

function domSetSink(sink: any): void {
  _domSink = sink;
}

function domSetTitle(title: any): void {
  document.title = String(title);
}

function domViewport(): any {
  return new ETuple([
    new EFloat(window.innerWidth),
    new EFloat(window.innerHeight),
  ]);
}

// An event's failure is the root's: report it and keep the page
// listening. A listener firing before the interface program installed
// its sink is a wiring mistake, said so once per event.
function domDeliver(tag: bigint, text: string): void {
  if (_domSink === null) {
    console.error(
      "dom: event " + tag + " fired before dom_sink registered a sink"
    );
    return;
  }
  Promise.resolve(_domSink(tag, text)).catch((e: any) => {
    try {
      _taskError(e);
    } catch (err) {
      console.error(err);
    }
  });
}

function browserRuntimeImpl(name: string, args: any[]): any {
  switch (name) {
    case "time_now_ms":
      // The wall clock, UTC epoch milliseconds: Date.now is exactly
      // that, and the answer rides the Int64 shape.
      return BigInt(Date.now());
    case "time_mono_ns":
      // The monotonic clock, nanoseconds, floor'd from
      // performance.now()'s milliseconds — the reading binary64 can
      // carry.
      return BigInt(Math.trunc(performance.now() * 1e6));
    case "time_sleep_ms":
      // Park the task: the timer rides the event loop (sleepMs), and
      // the promise the emitter awaits is the park.
      return sleepMs(Number(args[0]));
    case "dom_root":
      return domRoot();
    case "dom_element":
      return domElement(args[0]);
    case "dom_text":
      return domText(args[0]);
    case "dom_set_text":
      return domSetText(args[0], args[1]);
    case "dom_set_style":
      return domSetStyle(args[0], args[1], args[2]);
    case "dom_set_prop":
      return domSetProp(args[0], args[1], args[2]);
    case "dom_append":
      return domAppend(args[0], args[1]);
    case "dom_child":
      return domChild(args[0], args[1]);
    case "dom_remove":
      return domRemove(args[0], args[1]);
    case "dom_insert_before":
      return domInsertBefore(args[0], args[1], args[2]);
    case "dom_clear":
      return domClear(args[0]);
    case "dom_connect":
      return domConnect(args[0], args[1], args[2]);
    case "dom_value":
      return domValue(args[0]);
    case "dom_sink":
      return domSetSink(args[0]);
    case "dom_title":
      return domSetTitle(args[0]);
    case "dom_viewport":
      return domViewport();
    default:
      throw new Error(
        "the `" +
          name +
          "` runtime implementation is not available on the browser target"
      );
  }
}

// The page's listeners outlive the root body — the interface program's
// `run` returns as soon as the browser owns the event loop — so ending
// the root only flushes the pending output line.
_host = {
  write: browserWrite,
  runAs: browserRunAs,
  currentPid: browserCurrentPid,
  shutdownOnRootEnd: () => false,
  shutdown: browserShutdown,
  method: () => _hostMethodMiss,
  runtimeImpl: browserRuntimeImpl,
};
