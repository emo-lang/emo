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
// page's own objects stay on the host side, like the networking
// section's sockets. Handles are never reused, so a stale one names no
// node and raises rather than touching the wrong element.
let _domNext = 1;
const _domNodes = new Map<number, any>();
let _domSink: ((tag: bigint) => any) | null = null;

function domHandle(node: any): bigint {
  const id = _domNext++;
  _domNodes.set(id, node);
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

function domClear(handle: any): void {
  const node = domNode(handle);
  while (node.firstChild) node.removeChild(node.firstChild);
}

// Every event carries the tag the interface program chose for it; the
// listener hands that tag to the sink, which steps the Elm loop.
function domConnect(handle: any, event: any, tag: any): void {
  domNode(handle).addEventListener(String(event), () => {
    domDeliver(BigInt(tag));
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
function domDeliver(tag: bigint): void {
  if (_domSink === null) {
    console.error(
      "dom: event " + tag + " fired before dom_sink registered a sink"
    );
    return;
  }
  Promise.resolve(_domSink(tag)).catch((e: any) => {
    try {
      _taskError(e);
    } catch (err) {
      console.error(err);
    }
  });
}

function browserRuntimeImpl(name: string, args: any[]): any {
  switch (name) {
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
