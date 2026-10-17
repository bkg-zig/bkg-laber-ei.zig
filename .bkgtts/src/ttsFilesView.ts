import * as fs from "fs/promises";
import * as vscode from "vscode";

class TtsFileItem extends vscode.TreeItem {
  constructor(
    label: string,
    readonly uri: vscode.Uri,
    readonly isDirectory: boolean,
    collapsibleState: vscode.TreeItemCollapsibleState,
  ) {
    super(label, collapsibleState);
    this.resourceUri = uri;
    this.tooltip = uri.fsPath;

    if (isDirectory) {
      this.contextValue = "copilotTtsDirectory";
    } else {
      this.contextValue = "copilotTtsFile";
      this.command = {
        command: "copilot-tts.openFile",
        title: "Open TTS File",
        arguments: [uri],
      };
    }
  }
}

export class TtsFilesView
  implements vscode.TreeDataProvider<TtsFileItem>, vscode.Disposable
{
  private readonly _changeEmitter = new vscode.EventEmitter<
    TtsFileItem | undefined
  >();
  private readonly _watcher: vscode.FileSystemWatcher;

  readonly onDidChangeTreeData = this._changeEmitter.event;

  constructor(private readonly _storageUri: vscode.Uri) {
    this._watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(_storageUri, "**/*"),
    );
    this._watcher.onDidCreate(() => this.refresh());
    this._watcher.onDidChange(() => this.refresh());
    this._watcher.onDidDelete(() => this.refresh());
  }

  getTreeItem(element: TtsFileItem): vscode.TreeItem {
    return element;
  }

  async getChildren(element?: TtsFileItem): Promise<TtsFileItem[]> {
    if (!element) {
      return [
        new TtsFileItem(
          "Extension data",
          this._storageUri,
          true,
          vscode.TreeItemCollapsibleState.Expanded,
        ),
      ];
    }

    if (!element.isDirectory) {
      return [];
    }

    let entries: import("fs").Dirent[];
    try {
      entries = await fs.readdir(element.uri.fsPath, { withFileTypes: true });
    } catch (error) {
      if (
        typeof error === "object" &&
        error !== null &&
        "code" in error &&
        error.code === "ENOENT"
      ) {
        return [
          new TtsFileItem(
            "No TTS files created yet",
            element.uri,
            false,
            vscode.TreeItemCollapsibleState.None,
          ),
        ];
      }
      throw error;
    }

    const items = await Promise.all(
      entries.map(async (entry) => {
        const uri = vscode.Uri.joinPath(element.uri, entry.name);
        const isDirectory = entry.isDirectory();
        if (isDirectory) {
          return new TtsFileItem(
            entry.name,
            uri,
            true,
            vscode.TreeItemCollapsibleState.Collapsed,
          );
        }

        const item = new TtsFileItem(
          entry.name,
          uri,
          false,
          vscode.TreeItemCollapsibleState.None,
        );
        return item;
      }),
    );

    items.sort((left, right) => {
      if (left.isDirectory !== right.isDirectory) {
        return left.isDirectory ? -1 : 1;
      }
      return left.label!.toString().localeCompare(right.label!.toString());
    });
    return items;
  }

  refresh(): void {
    this._changeEmitter.fire(undefined);
  }

  dispose(): void {
    this._watcher.dispose();
    this._changeEmitter.dispose();
  }
}
