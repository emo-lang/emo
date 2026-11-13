// The playground's page: an editor, the examples, and one fetch — the
// whole protocol is POST /api/run and the JSON the server answers.

const editor = document.getElementById("editor");
const run_button = document.getElementById("run");
const picker = document.getElementById("examples");
const status_line = document.getElementById("status");
const out_pane = document.getElementById("stdout");
const err_pane = document.getElementById("stderr");

const status_words = {
  ok: "finished",
  compile: "compile error",
  curfew: "stopped at the curfew",
  crash: "runtime failure",
  error: "playground error",
};

function set_status(state, detail) {
  status_line.dataset.state = state;
  status_line.textContent = detail;
}

async function load_examples() {
  try {
    const names = await (await fetch("/examples")).json();
    for (const name of names) {
      const option = document.createElement("option");
      option.value = name;
      option.textContent = name;
      picker.appendChild(option);
    }
  } catch (_) {
    // The dropdown stays empty; the editor still works.
  }
}

picker.addEventListener("change", async () => {
  const name = picker.value;
  if (!name) return;
  try {
    const doc = await (await fetch("/examples/" + encodeURIComponent(name))).json();
    editor.value = doc.code;
    set_status("idle", name + " loaded — press Run");
  } catch (_) {
    set_status("error", "could not load " + name);
  }
});

function show(result) {
  out_pane.textContent = result.stdout;
  err_pane.textContent = result.stderr;
  if (result.curfew) {
    document.getElementById("curfew").textContent = result.curfew;
  }
  set_status(result.status, status_words[result.status] || result.status);
}

async function run() {
  const code = editor.value;
  if (!code.trim()) return;
  run_button.disabled = true;
  set_status("running", "running…");
  try {
    const response = await fetch("/api/run", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: code }),
    });
    const body = await response.json();
    if (!response.ok) {
      show({ status: "error", stdout: "", stderr: body.error || response.statusText });
    } else {
      show(body);
    }
  } catch (why) {
    set_status("error", String(why));
  } finally {
    run_button.disabled = false;
  }
}

run_button.addEventListener("click", run);

editor.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    run();
  }
  // The tab key inserts two spaces, the way an editor is expected to.
  if (event.key === "Tab") {
    event.preventDefault();
    const at = editor.selectionStart;
    editor.value = editor.value.slice(0, at) + "  " + editor.value.slice(editor.selectionEnd);
    editor.selectionStart = editor.selectionEnd = at + 2;
  }
});

load_examples();
editor.focus();
