#!/usr/bin/env python3
"""Build the language tour as a static HTML site.

Renders docs/tour.md and docs/zh-CN/tour.md into a self-contained page
each (inline CSS, a small copy-button script, no external assets beyond
the logo). The output is what `devtools/publish-tour.sh` uploads to
docs.emo-lang.cn.

Requires Python 3 and the `markdown` package (python-markdown):
    python3 -c 'import markdown'

    build-tour-site.py [--out DIR] [--repo URL] [--branch NAME]

The links inside the tour point at other Markdown files; on the public
page they are rewritten to the repository's GitHub blob/tree URLs, so a
single-page site never carries a dead relative link.
"""

import argparse
import html
import os
import posixpath
import re
import shutil
import sys

try:
    import markdown
except ImportError:
    sys.exit("build-tour-site: needs python-markdown (python3 -m pip install markdown)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PAGES = [
    {
        "src": "docs/tour.md",
        "out": "guides/tour/index.html",
        "logo": "/logo.png",
        "lang": "en",
        "title": "A tour of Emo",
        "description": "A ten-minute tour of Emo: every runnable block is compiled to Wasm and checked against its output.",
        "home_href": "/guides/tour/",
        "switch_href": "/zh/guides/tour/",
        "switch_label": "中文",
        "source": "docs/tour.md",
        "source_href": "/guides/tour/tour.md",
        "source_label": "source",
        "verified": "Every runnable block is compiled to Wasm and checked by <code>just tour</code>.",
    },
    {
        "src": "docs/zh-CN/tour.md",
        "out": "zh/guides/tour/index.html",
        "logo": "/logo.png",
        "lang": "zh-CN",
        "title": "Emo 语言导览",
        "description": "十分钟的 Emo 语言导览:每个可运行的代码块都编译为 Wasm,并与输出逐字节核对。",
        "home_href": "/zh/guides/tour/",
        "switch_href": "/guides/tour/",
        "switch_label": "English",
        "source": "docs/zh-CN/tour.md",
        "source_href": "/zh/guides/tour/tour.md",
        "source_label": "源码",
        "verified": "每个可运行的代码块都编译为 Wasm,并由 <code>just tour</code> 核对。",
    },
]

STYLE = r"""
:root {
  --bg: #14161a;
  --panel: #1c1f26;
  --sunk: #0f1115;
  --line: #2a2e37;
  --text: #d7dae0;
  --dim: #8b919c;
  --accent: #4fb477;
  --accent-dim: #2f6b48;
  --warn: #d19a66;
  --mono: "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", Arial, sans-serif;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: var(--sans);
  font-size: 16px;
  line-height: 1.7;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
header {
  position: sticky;
  top: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 10px 24px;
  border-bottom: 1px solid var(--line);
  background: rgba(20, 22, 26, 0.92);
  backdrop-filter: blur(6px);
}
.brand {
  font-family: var(--mono);
  font-size: 16px;
  font-weight: 600;
  color: var(--text);
  letter-spacing: 0.02em;
}
.brand span { color: var(--accent); }
nav { display: flex; align-items: center; gap: 18px; font-family: var(--mono); font-size: 13px; }
nav a { color: var(--dim); }
nav a:hover { color: var(--text); text-decoration: none; }
.layout {
  display: grid;
  grid-template-columns: 250px minmax(0, 840px);
  justify-content: center;
  gap: 56px;
  max-width: 1220px;
  margin: 0 auto;
  padding: 36px 28px 90px;
}
aside {
  position: sticky;
  top: 76px;
  align-self: start;
  max-height: calc(100vh - 104px);
  overflow: auto;
  padding-right: 14px;
  border-right: 1px solid var(--line);
  font-family: var(--mono);
  font-size: 12.5px;
  line-height: 1.55;
}
aside .toc > ul { list-style: none; margin: 0; padding: 0; }
aside .toc ul { list-style: none; padding-left: 12px; }
aside .toc > ul > li { margin-bottom: 10px; }
aside .toc > ul > li > a { color: var(--text); }
aside .toc > ul > li > ul > li > a { color: var(--dim); }
aside a:hover { color: var(--accent); text-decoration: none; }
main { min-width: 0; }
main h1 {
  margin: 0 0 18px;
  font-size: 34px;
  line-height: 1.2;
  letter-spacing: -0.01em;
}
main h2 {
  margin: 56px 0 16px;
  padding-top: 22px;
  border-top: 1px solid var(--line);
  font-size: 24px;
  line-height: 1.3;
}
main h3 { margin: 32px 0 12px; font-size: 19px; }
main p { margin: 0 0 16px; }
main ul, main ol { margin: 0 0 16px; padding-left: 26px; }
main li { margin: 4px 0; }
main li > p { margin: 0; }
main strong { color: #fff; }
code {
  font-family: var(--mono);
  font-size: 0.88em;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 5px;
  padding: 1px 5px;
}
pre {
  position: relative;
  margin: 0 0 20px;
  padding: 16px 18px;
  background: var(--sunk);
  border: 1px solid var(--line);
  border-radius: 9px;
  overflow: auto;
}
pre code {
  display: block;
  padding: 0;
  background: none;
  border: 0;
  font-size: 13.5px;
  line-height: 1.6;
  color: #cfd4dc;
  white-space: pre;
}
pre.output {
  background: #121a15;
  border-color: var(--accent-dim);
}
pre.output code { color: #a8c6b6; }
pre .copy {
  position: absolute;
  top: 9px;
  right: 9px;
  padding: 3px 8px;
  font-family: var(--mono);
  font-size: 11px;
  color: var(--dim);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 5px;
  cursor: pointer;
  opacity: 0;
  transition: opacity 120ms;
}
pre:hover .copy { opacity: 1; }
pre .copy:hover { color: var(--text); }
table { width: 100%; border-collapse: collapse; margin: 0 0 20px; font-size: 14.5px; }
th, td { border: 1px solid var(--line); padding: 8px 12px; text-align: left; vertical-align: top; }
th { background: var(--panel); font-weight: 600; }
blockquote {
  margin: 0 0 16px;
  padding: 2px 18px;
  border-left: 3px solid var(--accent-dim);
  color: var(--dim);
}
hr { border: 0; border-top: 1px solid var(--line); margin: 36px 0; }
footer {
  border-top: 1px solid var(--line);
  padding: 26px 24px 40px;
  text-align: center;
  color: var(--dim);
  font-size: 13px;
}
footer code { font-size: 0.92em; }
footer p { margin: 4px 0; }
@media (max-width: 900px) {
  .layout { grid-template-columns: 1fr; gap: 28px; padding: 24px 20px 70px; }
  aside {
    position: static;
    max-height: none;
    padding: 0 0 16px;
    border-right: 0;
    border-bottom: 1px solid var(--line);
  }
  aside .toc > ul { display: flex; flex-wrap: wrap; gap: 6px 16px; }
  aside .toc > ul > li { margin: 0; }
  aside .toc ul ul { display: none; }
  main h1 { font-size: 28px; }
  pre code { font-size: 12.5px; }
}
"""

SCRIPT = r"""
document.querySelectorAll('pre').forEach(function (pre) {
  if (pre.classList.contains('output')) return;
  var code = pre.querySelector('code');
  if (!code) return;
  var button = document.createElement('button');
  button.className = 'copy';
  button.type = 'button';
  button.textContent = 'copy';
  button.addEventListener('click', function () {
    navigator.clipboard.writeText(code.innerText).then(function () {
      button.textContent = 'copied';
      setTimeout(function () { button.textContent = 'copy'; }, 1200);
    });
  });
  pre.appendChild(button);
});
"""


def rewrite_links(body, src_rel, repo, branch):
    """Point relative Markdown/directory links at the GitHub source."""
    base = posixpath.dirname(src_rel)

    def one(m):
        href = m.group(1)
        if href.startswith(("#", "http://", "https://", "mailto:", "//")):
            return m.group(0)
        path, sep, frag = href.partition("#")
        target = posixpath.normpath(posixpath.join(base, path)) if path else src_rel
        fs = os.path.join(ROOT, target)
        kind = "tree" if os.path.isdir(fs) else "blob"
        url = "%s/%s/%s/%s" % (repo.rstrip("/"), kind, branch, target)
        if sep:
            url += "#" + frag
        return 'href="%s"' % url

    return re.sub(r'href="([^"]*)"', one, body)


def strip_fence_info(text):
    """python-markdown's fenced_code takes one word, not the tour's
    `emo run id=...` attributes; the page only needs the language."""
    out = []
    inside = False
    for line in text.split("\n"):
        m = re.match(r"^(`{3,})[ \t]*(\S+)(.*)$", line)
        if not inside and m:
            line = m.group(1) + m.group(2)
            inside = True
        elif inside and re.match(r"^`{3,}[ \t]*$", line):
            inside = False
        out.append(line)
    return "\n".join(out)


def render(page, repo, branch):
    src = os.path.join(ROOT, page["src"])
    with open(src, encoding="utf-8") as f:
        text = strip_fence_info(f.read())
    md = markdown.Markdown(
        extensions=["fenced_code", "tables", "toc", "sane_lists"],
        extension_configs={"toc": {"permalink": False}},
    )
    body = md.convert(text)
    toc = md.toc
    body = rewrite_links(body, page["src"], repo, branch)
    body = body.replace(
        '<pre><code class="language-output">',
        '<pre class="output"><code class="language-output">',
    )
    return TEMPLATE.format(
        lang=page["lang"],
        title=html.escape(page["title"]),
        description=html.escape(page["description"]),
        logo=page["logo"],
        home_href=page["home_href"],
        switch_href=page["switch_href"],
        switch_label=html.escape(page["switch_label"]),
        source_href=page["source_href"],
        source_label=html.escape(page["source_label"]),
        toc=toc,
        body=body,
        verified=page["verified"],
        style=STYLE,
        script=SCRIPT,
    )


TEMPLATE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="icon" href="{logo}">
<style>{style}</style>
</head>
<body>
<header>
  <a class="brand" href="{home_href}">emo<span>.tour</span></a>
  <nav>
    <a href="{switch_href}">{switch_label}</a>
    <a href="{source_href}">{source_label}</a>
  </nav>
</header>
<div class="layout">
  <aside>{toc}</aside>
  <main>{body}</main>
</div>
<footer>
  <p>{verified}</p>
  <p>Emo · MIT License · <a href="https://github.com/emo-lang/emo">github.com/emo-lang/emo</a></p>
</footer>
<script>{script}</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description="Build the Emo language tour site.")
    ap.add_argument("--out", default=os.path.join(ROOT, "_build", "tour-site"))
    ap.add_argument("--repo", default="https://github.com/emo-lang/emo")
    ap.add_argument("--branch", default="develop")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    # The output is a generated, gitignored site tree; clearing it keeps
    # a moved page from lingering in the publish set.
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)

    for page in PAGES:
        dest = os.path.join(out, page["out"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(render(page, args.repo, args.branch))
        print("built %s" % os.path.relpath(dest, ROOT))
        # the authored Markdown rides beside the page, so "source" works
        # before the branch is merged anywhere
        with open(os.path.join(ROOT, page["src"]), encoding="utf-8") as f:
            raw = f.read()
        copy_dir = os.path.join(out, os.path.dirname(page["out"]))
        os.makedirs(copy_dir, exist_ok=True)
        copy = os.path.join(copy_dir, "tour.md")
        with open(copy, "w", encoding="utf-8") as f:
            f.write(raw)
        print("built %s" % os.path.relpath(copy, ROOT))

    logo = os.path.join(ROOT, "public", "assets", "logo.png")
    if os.path.exists(logo):
        shutil.copyfile(logo, os.path.join(out, "logo.png"))
        print("built %s" % os.path.relpath(os.path.join(out, "logo.png"), ROOT))


if __name__ == "__main__":
    main()
