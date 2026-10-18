// The browser backend's page harness (T48.11): a stub page just large
// enough for the runtime's `dom_*` host, the corpus bundle, and a script
// of event tags clicked in order.
//
//   node page.mjs <bundle.js> <tag,tag,...>
//
// The bundle is a plain script — no imports, no `process` — so importing
// it is running the program. A button carries its tag as the `name`/
// `value` pair the backend sets (the same markup contract `ui_ssr`
// emits), which is how the script finds the element an event belongs to.
// Everything the program prints comes from the loop's `update`; this
// harness prints nothing on success.

import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const bundle = process.argv[2];
const script = process.argv[3] ?? "";

if (!bundle) {
  console.error("usage: node page.mjs <bundle.js> <tag,tag,...>");
  process.exit(2);
}

function element(tagName) {
  const el = {
    tagName,
    nodeType: 1,
    children: [],
    parentNode: null,
    textContent: "",
    value: "",
    name: "",
    listeners: {},
    style: {
      props: {},
      setProperty(name, value) {
        this.props[name] = value;
      },
    },
    addEventListener(type, fn) {
      (el.listeners[type] = el.listeners[type] ?? []).push(fn);
    },
    appendChild(child) {
      child.parentNode = el;
      el.children.push(child);
      return child;
    },
    removeChild(child) {
      el.children = el.children.filter((x) => x !== child);
      child.parentNode = null;
      return child;
    },
  };
  Object.defineProperty(el, "firstChild", {
    get() {
      return el.children[0] ?? null;
    },
  });
  return el;
}

const body = element("body");
const root = element("div");
root.id = "emo-root";
body.appendChild(root);

globalThis.document = {
  title: "",
  body,
  getElementById: (id) => (id === "emo-root" ? root : null),
  createElement: element,
  createTextNode: (data) => ({ nodeType: 3, data }),
};
globalThis.window = { innerWidth: 800, innerHeight: 600 };

function findTagged(node, tag) {
  if (node.name === "event" && String(node.value) === tag) {
    return node;
  }
  for (const child of node.children) {
    const found = findTagged(child, tag);
    if (found) {
      return found;
    }
  }
  return null;
}

const tick = () => new Promise((done) => setTimeout(done, 0));

await import(pathToFileURL(resolve(bundle)).href);
await tick();

for (const tag of script.split(",").filter((t) => t.length > 0)) {
  const target = findTagged(root, tag);
  if (target === null) {
    console.error("page: no element carries event " + tag);
    process.exit(1);
  }
  const listeners = target.listeners.click ?? [];
  if (listeners.length === 0) {
    console.error("page: the element carrying event " + tag + " has no click listener");
    process.exit(1);
  }
  for (const click of listeners) {
    click();
  }
  await tick();
}
