import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  RevealOutputChannelOn,
  ServerOptions,
  State,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let output: vscode.OutputChannel;
let packageProvider: PackageProvider;

// ---------------------------------------------------------------------------
// Server discovery
// ---------------------------------------------------------------------------

function serverExecutableName(): string {
  return process.platform === 'win32' ? 'emo-lsp.exe' : 'emo-lsp';
}

/** Locate `emo-lsp`: the configured path, the bundled copy, then PATH. */
function resolveServerPath(context: vscode.ExtensionContext): string {
  const configured = vscode.workspace.getConfiguration('emo').get<string>('serverPath');
  if (configured && configured.trim() !== '') {
    return configured.trim();
  }
  const bundled = context.asAbsolutePath(path.join('server', serverExecutableName()));
  if (fs.existsSync(bundled)) {
    return bundled;
  }
  return serverExecutableName();
}

function registryEndpoint(context: vscode.ExtensionContext): string | undefined {
  const configured = vscode.workspace.getConfiguration('emo').get<string>('registry');
  if (configured && configured.trim() !== '') {
    return configured.trim();
  }
  if (process.env.EMO_REGISTRY && process.env.EMO_REGISTRY.trim() !== '') {
    return process.env.EMO_REGISTRY.trim();
  }
  const bundled = context.asAbsolutePath(path.join('server', 'registry'));
  return fs.existsSync(bundled) ? bundled : undefined;
}

// ---------------------------------------------------------------------------
// Client lifecycle
// ---------------------------------------------------------------------------

async function startClient(context: vscode.ExtensionContext): Promise<void> {
  const serverPath = resolveServerPath(context);
  if (path.isAbsolute(serverPath) && !fs.existsSync(serverPath)) {
    void vscode.window.showErrorMessage(
      `Emo: the language server was not found at ${serverPath}. ` +
        `Build it with \`dune build\` and set "emo.serverPath", or install \`emo-lsp\` on your PATH.`,
    );
    return;
  }

  const emoPath = vscode.workspace.getConfiguration('emo').get<string>('emoPath') || 'emo';
  const serverOptions: ServerOptions = {
    command: serverPath,
    args: [],
    options: {
      env: { ...process.env, EMO_BIN: emoPath },
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'emo' }],
    initializationOptions: { registry: registryEndpoint(context) },
    outputChannel: output,
    revealOutputChannelOn: RevealOutputChannelOn.Never,
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/{package.emo,package.lock,.emo}'),
    },
  };

  client = new LanguageClient('emo', 'Emo Language Server', serverOptions, clientOptions);

  client.onDidChangeState((e) => {
    if (e.newState === State.Running) {
      output.appendLine('[client] connected to emo-lsp');
    }
  });

  await client.start();
}

// ---------------------------------------------------------------------------
// Package management
// ---------------------------------------------------------------------------

interface LockedInfo {
  version: string;
  checksum: string;
}

interface DepInfo {
  name: string;
  required: string;
  locked: LockedInfo | null;
  available: string[];
}

interface ManifestInfo {
  path: string;
  name: string;
  version: string;
  targets: string[];
  deps: DepInfo[];
}

interface PackageInfo {
  root: string;
  manifest: ManifestInfo | null;
  registry: string | null;
}

interface CommandResult {
  ok: boolean;
  code: number;
  output: string;
}

/** The directory the package commands should run in. */
function workspaceRoot(): string | undefined {
  const active = vscode.window.activeTextEditor?.document.uri;
  if (active && active.scheme === 'file') {
    return path.dirname(active.fsPath);
  }
  const folder = vscode.workspace.workspaceFolders?.[0];
  return folder ? folder.uri.fsPath : undefined;
}

async function packageInfo(): Promise<PackageInfo | undefined> {
  if (!client) {
    return undefined;
  }
  const root = workspaceRoot();
  try {
    return await client.sendRequest<PackageInfo>('emo/packageInfo', { root: root ?? '' });
  } catch {
    return undefined;
  }
}

async function runCommand(command: string, args: string[] = []): Promise<CommandResult | undefined> {
  if (!client) {
    void vscode.window.showWarningMessage('Emo: the language server is not running.');
    return undefined;
  }
  try {
    const result = await client.sendRequest<CommandResult>('workspace/executeCommand', {
      command,
      arguments: args,
    });
    output.append(`\n$ ${command}${args.length ? ' ' + args.join(' ') : ''}\n${result.output}`);
    return result;
  } catch (e) {
    output.appendLine(`[client] command failed: ${String(e)}`);
    void vscode.window.showErrorMessage(`Emo: ${String(e)}`);
    return undefined;
  }
}

async function runAndReport(command: string, args: string[] = []): Promise<void> {
  const result = await runCommand(command, args);
  if (!result) {
    return;
  }
  if (result.ok) {
    void vscode.window.showInformationMessage(`Emo: \`${command}\` succeeded.`);
  } else {
    const choice = await vscode.window.showErrorMessage(
      `Emo: \`${command}\` failed (exit ${result.code}).`,
      'Show Output',
    );
    if (choice === 'Show Output') {
      output.show(true);
    }
  }
}

class PackageProvider implements vscode.TreeDataProvider<PackageNode> {
  private readonly onDidChange = new vscode.EventEmitter<PackageNode | undefined>();
  readonly onDidChangeTreeData = this.onDidChange.event;

  refresh(): void {
    this.onDidChange.fire(undefined);
  }

  async getChildren(element?: PackageNode): Promise<PackageNode[]> {
    if (element) {
      return element.children ?? [];
    }
    const info = await packageInfo();
    if (!info || !info.manifest) {
      return [];
    }
    const manifest = info.manifest;
    const nodes: PackageNode[] = [
      {
        kind: 'manifest',
        label: `package.emo`,
        description: `${manifest.name} ${manifest.version}`,
        tooltip: `targets: ${manifest.targets.join(', ') || '(none)'}`,
        manifest,
      },
    ];
    for (const dep of manifest.deps) {
      const versions: PackageNode[] = [...dep.available]
        .reverse()
        .map((v) => ({
          kind: 'version' as const,
          label: v,
          description: v === dep.locked?.version ? 'locked' : v === dep.required ? 'required' : '',
          dep,
          version: v,
        }));
      nodes.push({
        kind: 'dep',
        label: dep.name,
        description: dep.locked ? `${dep.required} (locked ${dep.locked.version})` : `${dep.required} (unresolved)`,
        tooltip: `required ${dep.required}${dep.locked ? `, locked ${dep.locked.version}` : ''}`,
        dep,
        children: versions,
      });
    }
    return nodes;
  }

  getTreeItem(element: PackageNode): vscode.TreeItem {
    const collapsible =
      element.children && element.children.length > 0
        ? vscode.TreeItemCollapsibleState.Collapsed
        : vscode.TreeItemCollapsibleState.None;

    if (element.kind === 'version') {
      const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.None);
      item.description = element.description;
      item.contextValue = 'emo.packageVersion';
      item.command = {
        command: 'emo.deps.update',
        title: 'Update dependency',
        arguments: [element.dep?.name, element.version],
      };
      return item;
    }

    const item = new vscode.TreeItem(element.label, collapsible);
    item.description = element.description;
    item.tooltip = element.tooltip;
    if (element.kind === 'manifest') {
      item.contextValue = 'emo.manifest';
      item.iconPath = new vscode.ThemeIcon('package');
      if (element.manifest) {
        item.command = {
          command: 'vscode.open',
          title: 'Open manifest',
          arguments: [vscode.Uri.file(element.manifest.path)],
        };
      }
    } else {
      item.contextValue = 'emo.dependency';
      item.iconPath = new vscode.ThemeIcon(
        element.dep?.locked ? 'lock' : 'warning',
        element.dep?.locked ? undefined : new vscode.ThemeColor('problemsWarningIcon.foreground'),
      );
    }
    return item;
  }
}

interface PackageNode {
  kind: 'manifest' | 'dep' | 'version';
  label: string;
  description?: string;
  tooltip?: string;
  manifest?: ManifestInfo;
  dep?: DepInfo;
  version?: string;
  children?: PackageNode[];
}

async function updateDependency(name?: string, version?: string): Promise<void> {
  if (!name) {
    const info = await packageInfo();
    if (!info?.manifest || info.manifest.deps.length === 0) {
      void vscode.window.showInformationMessage('Emo: no dependencies in package.emo.');
      return;
    }
    const picked = await vscode.window.showQuickPick(
      info.manifest.deps.map((d) => ({
        label: d.name,
        description: `required ${d.required}`,
        detail: d.available.length ? `available: ${d.available.join(', ')}` : undefined,
      })),
    );
    if (!picked) {
      return;
    }
    name = picked.label;
  }
  if (!version) {
    const info = await packageInfo();
    const dep = info?.manifest?.deps.find((d) => d.name === name);
    if (dep && dep.available.length > 0) {
      const picked = await vscode.window.showQuickPick([...dep.available].reverse(), {
        placeHolder: `Pick a version for ${name}`,
      });
      if (!picked) {
        return;
      }
      version = picked;
    }
  }
  if (version) {
    // Re-pin in the manifest, then re-resolve: resolution stays explicit.
    const info = await packageInfo();
    if (info?.manifest) {
      const doc = await vscode.workspace.openTextDocument(info.manifest.path);
      const text = doc.getText();
      const pattern = new RegExp(`(\\b${escapeRegExp(name)}\\s*=\\s*)"[^"]*"`);
      const next = text.replace(pattern, `$1"${version}"`);
      if (next !== text) {
        const edit = new vscode.WorkspaceEdit();
        edit.replace(
          doc.uri,
          new vscode.Range(doc.positionAt(0), doc.positionAt(text.length)),
          next,
        );
        await vscode.workspace.applyEdit(edit);
        await doc.save();
      }
    }
  }
  await runAndReport('emo.deps.update', [name]);
  packageProvider.refresh();
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  output = vscode.window.createOutputChannel('Emo');
  context.subscriptions.push(output);

  packageProvider = new PackageProvider();
  const tree = vscode.window.createTreeView('emoPackages', {
    treeDataProvider: packageProvider,
    showCollapseAll: true,
  });
  context.subscriptions.push(tree);

  const activeFilePath = (): string | undefined => {
    const editor = vscode.window.activeTextEditor;
    if (editor && editor.document.languageId === 'emo') {
      return editor.document.uri.fsPath;
    }
    return undefined;
  };

  const registrations: Array<[string, (...args: any[]) => unknown]> = [
    [
      'emo.restartServer',
      async () => {
        if (client) {
          await client.stop();
        }
        await startClient(context);
        packageProvider.refresh();
      },
    ],
    ['emo.deps.resolve', async () => { await runAndReport('emo.deps.resolve'); packageProvider.refresh(); }],
    ['emo.deps.update', async (name?: string, version?: string) => updateDependency(name, version)],
    ['emo.deps.list', async () => { await runAndReport('emo.deps.list'); }],
    [
      'emo.package.init',
      async () => {
        await runAndReport('emo.package.init');
        packageProvider.refresh();
      },
    ],
    ['emo.check', async () => { const f = activeFilePath(); if (f) { await runAndReport('emo.check', [f]); } }],
    ['emo.build', async () => { const f = activeFilePath(); if (f) { await runAndReport('emo.build', [f]); } }],
    ['emo.run', async () => { const f = activeFilePath(); if (f) { await runAndReport('emo.run', [f]); } }],
    ['emo.packages.refresh', () => packageProvider.refresh()],
  ];
  for (const [command, handler] of registrations) {
    context.subscriptions.push(vscode.commands.registerCommand(command, handler));
  }

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      const base = path.basename(doc.uri.fsPath);
      if (base === 'package.emo' || base === 'package.lock') {
        packageProvider.refresh();
      }
    }),
  );

  await startClient(context);
  packageProvider.refresh();
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
}
