#!/usr/bin/env python3
"""Build the documentation site.

Each page renders from its Markdown source into a self-contained HTML
file in the VuePress-like shell: a top navbar, a left sidebar carrying
the site's guides and the current page's outline, and a readable content
column. CSS and the small scripts are inline; only the logo is external.

Requires Python 3 and the `markdown` package (python-markdown):
    python3 -c 'import markdown'

    build-docs-site.py [--out DIR] [--repo URL] [--branch NAME]
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
    sys.exit("build-docs-site: needs python-markdown (python3 -m pip install markdown)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PAGES = [
    {
        "id": "home",
        "src": "docs/main.md",
        "out": "index.html",
        "lang": "en",
        "title": "Emo documentation",
        "description": "The documentation map for Emo: Go's simplicity, C's speed, Ruby's elegance, the language tour, and the EmoUI guide.",
        "switch_href": "/zh/",
        "source_href": "/main.md",
        "source_label": "source",
        "verified": "This map is built from <code>docs/main.md</code>; the guides it links are built from this tree.",
        "links": {
            "docs/intro/tour.md": "/guides/tour/",
            "docs/emo-ui/intro.md": "/guides/emo-ui/intro",
            "docs/zh-CN/README.md": "/zh/",
        },
    },
    {
        "id": "home",
        "src": "docs/zh-CN/main.md",
        "out": "zh/index.html",
        "lang": "zh-CN",
        "title": "Emo 文档",
        "description": "Emo 的文档地图:Go 的简洁、C 的速度、Ruby 的优雅,以及语言导览与 EmoUI 入门。",
        "switch_href": "/",
        "source_href": "/zh/main.md",
        "source_label": "源码",
        "verified": "本页由 <code>docs/zh-CN/main.md</code> 构建;它链接的指南同样由本仓库构建。",
        "links": {
            "docs/zh-CN/intro/tour.md": "/zh/guides/tour/",
            "docs/zh-CN/emo-ui/intro.md": "/zh/guides/emo-ui/intro",
            "docs/zh-CN/README.md": "/zh/",
        },
    },
    {
        "id": "tour",
        "src": "docs/intro/tour.md",
        "out": "guides/tour/index.html",
        "lang": "en",
        "title": "A tour of Emo",
        "description": "A ten-minute tour of Emo: every runnable block is compiled to Wasm and checked against its output.",
        "switch_href": "/zh/guides/tour/",
        "source_href": "/guides/tour/tour.md",
        "source_label": "source",
        "verified": "Every runnable block is compiled to Wasm and checked by <code>just tour</code>.",
    },
    {
        "id": "tour",
        "src": "docs/zh-CN/intro/tour.md",
        "out": "zh/guides/tour/index.html",
        "lang": "zh-CN",
        "title": "Emo 语言导览",
        "description": "十分钟的 Emo 语言导览:每个可运行的代码块都编译为 Wasm,并与输出逐字节核对。",
        "switch_href": "/guides/tour/",
        "source_href": "/zh/guides/tour/tour.md",
        "source_label": "源码",
        "verified": "每个可运行的代码块都编译为 Wasm,并由 <code>just tour</code> 核对。",
    },
    {
        "id": "emo-ui",
        "src": "docs/emo-ui/intro.md",
        "out": "guides/emo-ui/intro.html",
        "lang": "en",
        "title": "Getting started with EmoUI",
        "description": "Build two EmoUI applications from scratch: a Hello, World window and a counter, with complete code.",
        "switch_href": "/zh/guides/emo-ui/intro",
        "source_href": "/guides/emo-ui/intro.md",
        "source_label": "source",
        "verified": "Both programs build against the in-tree EmoUI packages.",
    },
    {
        "id": "emo-ui",
        "src": "docs/zh-CN/emo-ui/intro.md",
        "out": "zh/guides/emo-ui/intro.html",
        "lang": "zh-CN",
        "title": "EmoUI 入门",
        "description": "从零写两个 EmoUI 应用:Hello, World 窗口与计数器,含完整代码。",
        "switch_href": "/guides/emo-ui/intro",
        "source_href": "/zh/guides/emo-ui/intro.md",
        "source_label": "源码",
        "verified": "两个程序都针对仓库内的 EmoUI 包构建。",
    },
]

L10N = {
    "en": {
        "on_this_page": "On this page",
        "menu": "Menu",
        "light": "Switch to light theme",
        "dark": "Switch to dark theme",
        "nav": [
            ("/", "Overview"),
            ("/guides/tour/", "Language tour"),
            ("/guides/emo-ui/intro", "EmoUI"),
        ],
    },
    "zh-CN": {
        "on_this_page": "本页目录",
        "menu": "菜单",
        "light": "切换到浅色主题",
        "dark": "切换到深色主题",
        "nav": [
            ("/zh/", "概览"),
            ("/zh/guides/tour/", "语言导览"),
            ("/zh/guides/emo-ui/intro", "EmoUI"),
        ],
    },
}

NAV_INDEX = {"home": 0, "tour": 1, "emo-ui": 2}

STYLE = r"""
:root {
  --bg: #ffffff;
  --panel: #f6f8fa;
  --sunk: #f6f8fa;
  --line: #eaecef;
  --text: #2c3e50;
  --dim: #6a737d;
  --accent: #3eaf7c;
  --accent-dim: #c6e8d8;
  --header-bg: rgba(255, 255, 255, 0.92);
  --code-text: #476582;
  --strong: #2c3e50;
  --out-bg: #f0f9f4;
  --out-text: #2d6a4f;
  --on-accent: #ffffff;
  --sidebar-bg: #f7f8fa;
  --navbar-h: 3.6rem;
  --mono: "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
    "PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", Arial, sans-serif;
  color-scheme: light;
}
[data-theme="dark"] {
  --bg: #1e1e20;
  --panel: #252529;
  --sunk: #252529;
  --line: #3a3a3f;
  --text: #eaecef;
  --dim: #9da5b0;
  --accent: #4fc08d;
  --accent-dim: #2f6b4f;
  --header-bg: rgba(30, 30, 32, 0.92);
  --code-text: #c8d3e0;
  --strong: #ffffff;
  --out-bg: #1e2a24;
  --out-text: #a8d8c2;
  --on-accent: #0b120e;
  --sidebar-bg: #202024;
  color-scheme: dark;
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
  -webkit-font-smoothing: antialiased;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }

/* ---- navbar ---- */
.navbar {
  position: sticky;
  top: 0;
  z-index: 40;
  height: var(--navbar-h);
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0 1.5rem;
  background: var(--header-bg);
  backdrop-filter: blur(6px);
  border-bottom: 1px solid var(--line);
}
.site-name {
  font-size: 1.35rem;
  font-weight: 700;
  letter-spacing: -0.01em;
  color: var(--text);
  white-space: nowrap;
}
.site-name span { color: var(--accent); }
.site-name:hover { text-decoration: none; }
.nav-links { display: flex; align-items: center; gap: 1.4rem; margin-left: 1rem; font-size: 0.95rem; }
.nav-link { color: var(--text); }
.nav-link:hover { color: var(--accent); text-decoration: none; }
.nav-link.active { color: var(--accent); font-weight: 600; }
.nav-controls { margin-left: auto; display: flex; align-items: center; gap: 0.5rem; }
.menu-toggle {
  display: none;
  align-items: center;
  justify-content: center;
  width: 2rem;
  height: 2rem;
  padding: 0;
  color: var(--dim);
  background: transparent;
  border: 1px solid var(--line);
  border-radius: 6px;
  cursor: pointer;
}
.menu-toggle svg { width: 1.1rem; height: 1.1rem; }
.lang-toggle {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--line);
  border-radius: 6px;
  overflow: hidden;
  font-family: var(--mono);
  font-size: 0.78rem;
  line-height: 1;
}
.lang-toggle .lang { display: inline-block; padding: 0.4rem 0.55rem; color: var(--dim); }
.lang-toggle a.lang:hover { color: var(--text); background: var(--panel); text-decoration: none; }
.lang-toggle .lang.active { color: var(--on-accent); background: var(--accent); font-weight: 600; }
.theme-toggle {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 2rem;
  height: 2rem;
  padding: 0;
  color: var(--dim);
  background: transparent;
  border: 1px solid var(--line);
  border-radius: 6px;
  cursor: pointer;
}
.theme-toggle:hover { color: var(--accent); }
.theme-toggle svg { width: 1rem; height: 1rem; display: block; }
.theme-toggle .icon-sun { display: none; }
.theme-toggle .icon-moon { display: block; }
[data-theme="dark"] .theme-toggle .icon-sun { display: block; }
[data-theme="dark"] .theme-toggle .icon-moon { display: none; }

/* ---- page: sidebar + content ---- */
.page { display: grid; grid-template-columns: 18rem minmax(0, 1fr); align-items: start; }
.sidebar {
  position: sticky;
  top: var(--navbar-h);
  height: calc(100vh - var(--navbar-h));
  overflow-y: auto;
  padding: 1.5rem 1rem 2rem;
  background: var(--sidebar-bg);
  border-right: 1px solid var(--line);
  font-size: 0.95rem;
}
.sidebar-group { margin-bottom: 1.75rem; }
.sidebar-heading {
  margin: 0.25rem 0 0.5rem 0.75rem;
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--dim);
}
.page-toc { list-style: none; margin: 0; padding: 0; }
.page-toc ul { list-style: none; margin: 0; padding-left: 0.85rem; }
.page-toc li { margin: 0.15rem 0; }
.page-toc a {
  display: block;
  padding: 0.2rem 0.75rem;
  color: var(--dim);
  font-size: 0.85rem;
  line-height: 1.4;
}
.page-toc a:hover { color: var(--accent); text-decoration: none; }
.page-toc a.active { color: var(--accent); font-weight: 600; }
.sidebar-mask { display: none; }

/* ---- content ---- */
.content {
  min-width: 0;
  max-width: 740px;
  margin: 0 auto;
  padding: 2rem 2.5rem 4rem;
  overflow-wrap: break-word;
}
.content h1 { font-size: 2.2rem; line-height: 1.3; margin: 0 0 1rem; }
.content h2 {
  font-size: 1.65rem;
  line-height: 1.35;
  margin: 2.5rem 0 1rem;
  padding-bottom: 0.35rem;
  border-bottom: 1px solid var(--line);
}
.content h3 { font-size: 1.3rem; margin: 1.8rem 0 0.8rem; }
.content h1, .content h2, .content h3 { font-weight: 600; }
.content h1, .content h2, .content h3 { scroll-margin-top: calc(var(--navbar-h) + 0.75rem); }
.content p { margin: 1rem 0; }
.content ul, .content ol { margin: 1rem 0; padding-left: 1.5rem; }
.content li { margin: 0.35rem 0; }
.content strong { font-weight: 600; color: var(--strong); }
.content img { max-width: 100%; }
code {
  font-family: var(--mono);
  font-size: 0.85em;
  color: var(--code-text);
  background: var(--panel);
  padding: 0.25rem 0.5rem;
  border-radius: 3px;
}
pre {
  position: relative;
  margin: 1rem 0;
  padding: 1.25rem 1.5rem;
  background: var(--sunk);
  border: 1px solid var(--line);
  border-radius: 6px;
  overflow: auto;
}
pre code {
  display: block;
  padding: 0;
  background: none;
  border: 0;
  color: var(--code-text);
  font-size: 0.85rem;
  line-height: 1.7;
  white-space: pre;
}
pre.output { background: var(--out-bg); border-color: var(--accent-dim); }
pre.output code { color: var(--out-text); }
pre .copy {
  position: absolute;
  top: 0.5rem;
  right: 0.5rem;
  padding: 0.15rem 0.45rem;
  font-family: var(--mono);
  font-size: 0.7rem;
  color: var(--dim);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 4px;
  cursor: pointer;
  opacity: 0;
  transition: opacity 120ms;
}
pre:hover .copy { opacity: 1; }
pre .copy:hover { color: var(--accent); }
table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: 0.95rem; }
th, td { border: 1px solid var(--line); padding: 0.6em 1em; text-align: left; vertical-align: top; }
th { background: var(--panel); font-weight: 600; }
blockquote {
  margin: 1rem 0;
  padding: 0.25rem 1rem;
  border-left: 0.2rem solid var(--line);
  color: var(--dim);
}
hr { border: 0; border-top: 1px solid var(--line); margin: 2rem 0; }
.header-anchor {
  float: left;
  margin-left: -1em;
  color: var(--accent);
  opacity: 0;
  text-decoration: none;
}
.content h2:hover .header-anchor, .content h3:hover .header-anchor { opacity: 1; text-decoration: none; }
.page-footer {
  margin-top: 3rem;
  padding-top: 1rem;
  border-top: 1px solid var(--line);
  color: var(--dim);
  font-size: 0.85rem;
}
.page-footer p { margin: 0.25rem 0; }

@media (max-width: 900px) {
  .nav-links { display: none; }
  .menu-toggle { display: inline-flex; }
  .navbar { padding: 0 1rem; gap: 0.6rem; }
  .site-name { font-size: 1.2rem; }
  .page { grid-template-columns: 1fr; }
  .sidebar {
    position: fixed;
    top: var(--navbar-h);
    left: 0;
    width: 80%;
    max-width: 20rem;
    height: calc(100vh - var(--navbar-h));
    transform: translateX(-100%);
    transition: transform 0.25s ease;
    z-index: 30;
    box-shadow: 2px 0 8px rgba(0, 0, 0, 0.12);
  }
  body.sidebar-open .sidebar { transform: none; }
  .sidebar-mask {
    display: none;
    position: fixed;
    inset: var(--navbar-h) 0 0;
    background: rgba(0, 0, 0, 0.4);
    z-index: 25;
  }
  body.sidebar-open .sidebar-mask { display: block; }
  .content { padding: 1.5rem 1.25rem 3rem; }
  table { display: block; overflow-x: auto; }
  th, td { overflow-wrap: anywhere; }
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

(function () {
  var root = document.documentElement;

  var btn = document.querySelector('.theme-toggle');
  if (btn) {
    var lightLabel = btn.getAttribute('data-label-light') || 'Switch to light theme';
    var darkLabel = btn.getAttribute('data-label-dark') || 'Switch to dark theme';
    function isDark() { return root.getAttribute('data-theme') === 'dark'; }
    function label() {
      var next = isDark() ? lightLabel : darkLabel;
      btn.setAttribute('aria-label', next);
      btn.title = next;
    }
    btn.addEventListener('click', function () {
      if (isDark()) {
        root.removeAttribute('data-theme');
        try { localStorage.setItem('emo-theme', 'light'); } catch (e) {}
      } else {
        root.setAttribute('data-theme', 'dark');
        try { localStorage.setItem('emo-theme', 'dark'); } catch (e) {}
      }
      label();
    });
    label();
  }

  var menu = document.querySelector('.menu-toggle');
  var mask = document.querySelector('.sidebar-mask');
  function closeSidebar() {
    document.body.classList.remove('sidebar-open');
    if (menu) menu.setAttribute('aria-expanded', 'false');
  }
  if (menu) {
    menu.addEventListener('click', function () {
      var open = document.body.classList.toggle('sidebar-open');
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
  }
  if (mask) mask.addEventListener('click', closeSidebar);
  document.querySelectorAll('.sidebar a').forEach(function (a) {
    a.addEventListener('click', closeSidebar);
  });

  document.querySelectorAll('.content h2[id], .content h3[id]').forEach(function (h) {
    if (h.querySelector('.header-anchor')) return;
    var a = document.createElement('a');
    a.className = 'header-anchor';
    a.href = '#' + h.id;
    a.textContent = '#';
    a.setAttribute('aria-hidden', 'true');
    h.insertBefore(a, h.firstChild);
  });

  var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.page-toc a'));
  if (tocLinks.length && 'IntersectionObserver' in window) {
    var byId = {};
    tocLinks.forEach(function (a) {
      var id = decodeURIComponent(a.getAttribute('href').slice(1));
      byId[id] = a;
    });
    var current = null;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var link = byId[entry.target.id];
        if (!link || link === current) return;
        if (current) current.classList.remove('active');
        link.classList.add('active');
        current = link;
      });
    }, { rootMargin: '-70px 0px -75% 0px' });
    document.querySelectorAll('.content h2[id], .content h3[id]').forEach(function (h) {
      observer.observe(h);
    });
  }
})();
"""

THEME_SCRIPT = """<script>
(function () {
  try {
    if (localStorage.getItem('emo-theme') === 'dark') {
      document.documentElement.setAttribute('data-theme', 'dark');
    }
  } catch (e) {}
})();
</script>"""

TEMPLATE = """<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="icon" href="/logo.png">
{theme_script}
<style>{style}</style>
</head>
<body>
<header class="navbar">
  <button class="menu-toggle" type="button" aria-label="{menu_label}" aria-expanded="false">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M3 6h18M3 12h18M3 18h18"/></svg>
  </button>
  <a class="site-name" href="{home_href}">emo<span>.docs</span></a>
  <nav class="nav-links">{nav_links}</nav>
  <div class="nav-controls">
    <div class="lang-toggle" role="group" aria-label="Language">{toggle_html}</div>
    <button class="theme-toggle" type="button" aria-label="{theme_label_dark}" title="{theme_label_dark}" data-label-light="{theme_label_light}" data-label-dark="{theme_label_dark}">
      <svg class="icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
      <svg class="icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
    </button>
  </div>
</header>
<div class="page">
  <aside class="sidebar" id="sidebar">
    {toc_group}
  </aside>
  <div class="sidebar-mask"></div>
  <main class="content">
{body}
    <footer class="page-footer">
      <p>{verified}</p>
      <p><a href="{source_href}">{source_label}</a> · <a href="https://github.com/emo-lang/emo">GitHub</a> · MIT License</p>
    </footer>
  </main>
</div>
<script>{script}</script>
</body>
</html>
"""


def rewrite_links(body, src_rel, repo, branch, links):
    """Point relative Markdown/directory links at the GitHub source."""
    base = posixpath.dirname(src_rel)

    def one(m):
        href = m.group(1)
        if href.startswith(("#", "http://", "https://", "mailto:", "//")):
            return m.group(0)
        path, sep, frag = href.partition("#")
        target = posixpath.normpath(posixpath.join(base, path)) if path else src_rel
        if target in links:
            url = links[target]
        else:
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


def render_toc(tokens):
    roots = tokens
    if roots and roots[0].get("level") == 1:
        roots = roots[0].get("children", [])
    if not roots:
        return ""

    def walk(items):
        out = ['<ul class="page-toc">']
        for t in items:
            out.append('<li><a href="#%s">%s</a>' % (t["id"], html.escape(t["name"])))
            if t.get("children"):
                out.append(walk(t["children"]))
            out.append("</li>")
        out.append("</ul>")
        return "".join(out)

    return walk(roots)


def render(page, repo, branch):
    src = os.path.join(ROOT, page["src"])
    with open(src, encoding="utf-8") as f:
        text = strip_fence_info(f.read())
    md = markdown.Markdown(
        extensions=["fenced_code", "tables", "toc", "sane_lists"],
        extension_configs={"toc": {"permalink": False}},
    )
    body = md.convert(text)
    body = rewrite_links(body, page["src"], repo, branch, page.get("links", {}))
    body = body.replace(
        '<pre><code class="language-output">',
        '<pre class="output"><code class="language-output">',
    )

    l10n = L10N[page["lang"]]
    idx = NAV_INDEX[page["id"]]
    nav_links = "".join(
        '<a class="nav-link%s" href="%s">%s</a>'
        % (" active" if i == idx else "", href, html.escape(label))
        for i, (href, label) in enumerate(l10n["nav"])
    )
    nav_links += '<a class="nav-link" href="https://github.com/emo-lang/emo">GitHub</a>'
    toc = render_toc(getattr(md, "toc_tokens", []))
    toc_group = (
        '<div class="sidebar-group"><p class="sidebar-heading">%s</p>%s</div>'
        % (html.escape(l10n["on_this_page"]), toc)
        if toc
        else ""
    )

    target = html.escape(page["switch_href"], quote=True)
    if page["lang"] == "en":
        toggle_html = (
            '<span class="lang active" aria-current="true">EN</span>'
            '<a class="lang" href="%s">\u4e2d\u6587</a>' % target
        )
    else:
        toggle_html = (
            '<a class="lang" href="%s">EN</a>'
            '<span class="lang active" aria-current="true">\u4e2d\u6587</span>' % target
        )

    return TEMPLATE.format(
        lang=page["lang"],
        title=html.escape(page["title"]),
        description=html.escape(page["description"]),
        theme_script=THEME_SCRIPT,
        menu_label=html.escape(l10n["menu"]),
        home_href="/" if page["lang"] == "en" else "/zh/",
        nav_links=nav_links,
        toggle_html=toggle_html,
        theme_label_light=html.escape(l10n["light"]),
        theme_label_dark=html.escape(l10n["dark"]),
        toc_group=toc_group,
        body=body,
        source_href=page["source_href"],
        source_label=html.escape(page["source_label"]),
        verified=page["verified"],
        style=STYLE,
        script=SCRIPT,
    )


def main():
    ap = argparse.ArgumentParser(description="Build the Emo documentation site.")
    ap.add_argument("--out", default=os.path.join(ROOT, "_build", "docs-site"))
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
        copy = os.path.join(copy_dir, os.path.basename(page["src"]))
        with open(copy, "w", encoding="utf-8") as f:
            f.write(raw)
        print("built %s" % os.path.relpath(copy, ROOT))

    logo = os.path.join(ROOT, "public", "assets", "logo.png")
    if os.path.exists(logo):
        shutil.copyfile(logo, os.path.join(out, "logo.png"))
        print("built %s" % os.path.relpath(os.path.join(out, "logo.png"), ROOT))


if __name__ == "__main__":
    main()
