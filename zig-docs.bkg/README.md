# BKG Zig Dokumentation – Startseite

Dieses Verzeichnis ist die einzige autoritative Quelle für alle
Entscheidungen, Regeln und den aktuellen Stand aller BKG Zig Projekte.

## Wichtiger Hinweis zum Vorlesen

Alle Texte hier sind auf Deutsch verfasst und können laut vorgelesen werden.
Fachbegriffe wie "build.zig" sprich: "build punkt zig".
Verzeichnisnamen wie "zig-body.bkg" sprich: "zig body punkt bkg".

---

## Inhaltsverzeichnis

### Allgemeine Dokumentation

- README.md – Diese Startseite
- architektur.md – Verzeichnisstruktur und Zielarchitektur
- regeln.md – Verbindliche Regeln und Konventionen
- workflow.md – Git-Workflows und Branch-Strategie
- todo.md – Offene Aufgaben
- entscheidungen.md – Protokoll aller Architekturentscheidungen

### Projektbücher (pro Projekt)

- projekte/zig-body.bkg/status.md – Framework-Stand
- projekte/zig-soul.bkg/status.md – Fork-Stand
- projekte/zig-app.bkg/bkg-flocker.zig/status.md – Docker-UI Stand
- projekte/zig-app.bkg/bkg-eviladmin.zig/status.md – Admin-Backend Stand
- projekte/zig-app.bkg/bkg-forgekb.zig/status.md – Knowledge-Base Stand

### Talk-Bereich (Kommunikation)

- talk/eingehend/ – Aufgaben und Nachrichten die reinkommen
- talk/ausgehend/ – Erledigte Antworten und Ergebnisse
- talk/fragen/ – Offene Fragen die beantwortet werden müssen

---

## Gesamtstruktur aller Projekte

```
/srv/bkg/playground/
  zig-soul.bkg/    Zig Sprachbasis und Fork
  zig-body.bkg/    Framework Bibliotheken
  zig-app.bkg/     Alle Anwendungen
  zig-docs.bkg/    Diese Dokumentation
```

Stand: 2026-09-02
