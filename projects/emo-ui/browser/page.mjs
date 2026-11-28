// The browser backend's page harness (T48.11): a stub page just large
// enough for the runtime's `dom_*` host, the corpus bundle, and a script
// of steps — a tag clicked, or `tag=text` typed into the field carrying
// that tag.
//
//   node page.mjs <bundle.js> <step,step,...>
//
// The bundle is a plain script — no imports, no `process` — so importing
// it is running the program. A button carries its tag as the `name`/
// `value` pair the backend sets (the same markup contract `ui_ssr`
// emits), which is how the script finds the element an event belongs to.
// Everything the program prints comes from the loop's `update`; this
// harness prints nothing on success. A bundle with no script steps its
// own frames (`../retained/`) and is run for what it prints.
//
// The element model carries what the retained patch uses: `children` by
// index, `removeChild`, and an `insertBefore` that moves a child already
// under the parent.

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
    // A child that already sits here moves: it leaves its place first.
    insertBefore(child, ref) {
      child.parentNode = el;
      el.children = el.children.filter((x) => x !== child);
      const at = ref === null ? -1 : el.children.indexOf(ref);
      el.children.splice(at < 0 ? el.children.length : at, 0, child);
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

// An editable field carries its tag as the `name` `emo-<tag>`, the same
// markup contract `ui_ssr` emits.
function findInput(node, name) {
  if (node.tagName === "input" && node.name === name) {
    return node;
  }
  for (const child of node.children) {
    const found = findInput(child, name);
    if (found) {
      return found;
    }
  }
  return null;
}

const tick = () => new Promise((done) => setTimeout(done, 0));

await import(pathToFileURL(resolve(bundle)).href);
await tick();

// The core's key vocabulary, for the steps that press a key.
const keyNumbers = { Enter: 10, Escape: 27 };
const keyNames = { 10: "Enter", 27: "Escape" };

// A step is a tag to click, `tag=text` to type into the field carrying
// that tag, or `tag^key` to press a key on it: the field's `keydown`
// listeners fire with the key's name, which is what a pressed key is to
// the runtime's host.
for (const step of script.split(",").filter((s) => s.length > 0)) {
  const caret = step.indexOf("^");
  const eq = step.indexOf("=");
  const tag = step.slice(0, caret >= 0 ? caret : eq >= 0 ? eq : step.length);
  const text = eq >= 0 ? step.slice(eq + 1) : null;
  const key = caret >= 0 ? Number(step.slice(caret + 1)) : null;
  const target =
    text === null && key === null
      ? findTagged(root, tag)
      : findInput(root, "emo-" + tag);
  if (target === null) {
    console.error("page: no element carries event " + tag);
    process.exit(1);
  }
  if (key !== null) {
    const name = keyNames[key];
    if (name === undefined) {
      console.error("page: no key number " + key + " in the vocabulary");
      process.exit(1);
    }
    for (const fn of target.listeners.keydown ?? []) {
      fn({ key: name });
    }
    await tick();
    continue;
  }
  if (text !== null) {
    target.value = text;
    for (const fn of target.listeners.input ?? []) {
      fn();
    }
    await tick();
    continue;
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
