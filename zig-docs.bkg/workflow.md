# BKG Zig – Git-Workflows und Branch-Strategie

## Übersicht

Das BKG Zig-Ökosystem hat drei separate Git-Repos:

| Repo | Pfad | Remote |
|---|---|---|
| BKG Zig-Fork | `zig-soul.bkg/banana.bkg/zig.bkg/` | `github.com/bkg-zig/zig.bkg` |
| Upstream Zig | `zig-soul.bkg/zig.vanilla/zig.zig/` | `github.com/ziglang/zig` |
| Docs | `zig-docs-bkg/` | (lokal, kein Remote bisher) |
| bkg-eviladmin | `zig-app.bkg/bkg-eviladmin.zig/` | (eigenes Repo) |

`zig-body.bkg/` und `bkg-flocker.zig/` sind **kein eigenes Git-Repo** – sie leben
im übergeordneten Workspace-Repo oder werden separat versioniert wenn nötig.

---

## Branch-Strategie: BKG Zig-Fork (`banana.bkg/zig.bkg`)

```
master  ──────────────────────────────────────►  (= upstream ziglang/zig, read-only)
            │
            └─ banana  ──────────────────────►  (= alle BKG-eigenen Patches)
                  │
                  ├── commit: "bkg: <beschreibung>"
                  ├── commit: "bkg: <beschreibung>"
                  └── ...
```

**Regel:**
- `master` = identisch mit upstream ziglang/zig, wird nur per `git merge` aktualisiert
- `banana` = alle BKG-Änderungen, **niemals** direkt auf `master` commiten

---

## Workflow 1: BKG-Patch auf Fork einbringen

```bash
cd /srv/bkg/playground/zig-soul.bkg/banana.bkg/zig.bkg

# Sicherstellen dass banana aktiv ist
git checkout banana

# Datei ändern, dann committen
git add <dateien>
git commit -m "bkg: <kurzbeschreibung der Änderung>"
```

---

## Workflow 2: Upstream-Sync (neue Zig-Version übernehmen)

```bash
cd /srv/bkg/playground/zig-soul.bkg/banana.bkg/zig.bkg

# 1. Upstream-Änderungen holen
git fetch origin master

# 2. master aktualisieren
git checkout master
git merge origin/master

# 3. banana auf neuen master rebasen
git checkout banana
git rebase master

# Bei Konflikten: lösen, dann
git rebase --continue
```

---

## Workflow 3: Vanilla-Zig (Referenz) aktualisieren

```bash
cd /srv/bkg/playground/zig-soul.bkg/zig.vanilla/zig.zig

git fetch origin
git checkout master
git pull origin master
# Niemals eigene Commits hier!
```

---

## Workflow 4: Dokumentation aktualisieren

```bash
cd /srv/bkg/playground/zig-docs-bkg

# Datei ändern, dann sofort committen
git add .
git commit -m "docs: <was wurde dokumentiert>"
```

---

## Commit-Message-Konventionen

| Prefix | Verwendung |
|---|---|
| `bkg:` | BKG-spezifische Zig-Fork-Änderungen |
| `docs:` | Dokumentationsänderungen |
| `fix:` | Fehlerbehebungen |
| `feat:` | Neue Features |
| `refactor:` | Umstrukturierungen ohne Verhaltensänderung |
| `chore:` | Build-System, CI, Abhängigkeiten |

---

## Stand der Branch-Einrichtung (2026-09-02)

- ✅ `banana.bkg/zig.bkg` Branch `banana` erstellt
- ✅ `banana.bkg/zig.bkg` Branch `master` = upstream stand
- ✅ `banana` Branch aktiv (kein Divergenz zu master – noch keine BKG-Patches)
- ❌ Kein Remote-Push von `banana` bisher
- ❌ `zig-docs-bkg` hat noch kein Remote-Repo

Stand: 2026-09-02
