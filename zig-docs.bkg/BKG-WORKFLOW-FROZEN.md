# BKG Workflow Frozen Rules

## 1. Status

Diese Regeln sind ab 2026-09-03 eingefroren.

Sie gelten für alle BKG-Zig-Implementierungen und Coding-Agenten.

Architekturregeln dürfen nicht stillschweigend durch einen Agenten geändert werden.

## 2. Layer-Reihenfolge

Der verbindliche Implementierungsfluss ist:

```text
zig-soul.bkg/zig.vanilla → zig-soul.bkg/banana.bkg → zig-body.bkg → zig-app.bkg
```

Jede Änderung beginnt immer in der untersten betroffenen Schicht.

## 3. Vanilla First: Nur prüfen

Zuerst wird `zig-soul.bkg/zig.vanilla` geprüft.

`zig.vanilla` ist eine unveränderliche Referenz. Vanilla wird in diesem Workflow niemals gepatcht, erweitert oder auf die verwendete Zig-Version migriert.

Wenn eine benötigte primitive Funktion bereits vorhanden ist, wird ihre Existenz und Semantik geprüft und die vorhandene Referenz verwendet.

Wenn eine Funktion in Vanilla fehlt oder Banana mit dem Vanilla-Quellstand beziehungsweise der verwendeten Zig-Version inkompatibel ist, wird **nicht Vanilla geändert**. Die notwendige Kompatibilitäts- oder Framework-Anpassung erfolgt in Banana.

Vanilla dient damit ausschließlich als Referenz- und Vergleichsstand; ein Vanilla-Build-Gate ist kein Freibrief für Änderungen an Vanilla.

## 4. Banana Second

Nach erfolgreichem Vanilla-Gate wird `zig-soul.bkg/banana.bkg` geprüft.

Banana enthält Framework-Lifecycle und Framework-Abstraktionen.

Fehlt dort eine benötigte Framework-Funktion, wird sie in Banana implementiert.

Danach müssen Banana-Build und Tests erfolgreich sein.

Erst dann darf Body geändert werden.

## 5. Body Third

Nach erfolgreichem Banana-Gate wird `zig-body.bkg` geprüft.

Body darf Banana-Funktionen konsumieren, aber deren Implementierung nicht duplizieren.

Nur notwendige BKG-API-, Export- oder Adapter-Schichten werden ergänzt.

Danach müssen Body-Build und Tests erfolgreich sein.

Erst dann darf die App geändert werden.

## 6. App Last

Erst nach einem grünen Body-Gate wird die konkrete Anwendung geändert.

Die App implementiert nur anwendungsspezifische Logik.

Framework-Primitiven gehören nicht in die App, wenn sie in einer unteren Schicht
korrekt implementiert werden können.

## 7. Gate-Regel

Nach jeder Schicht gilt:

```text
ändern → testen → Build prüfen → erst danach nächste Schicht
```

Bei einem Fehler wird zuerst die betroffene niedrigere Schicht repariert.

Nicht mit Workarounds in einer höheren Schicht weitermachen.

## 8. Keine Layer-Umgehung

Nicht erlaubt:

```text
App → Workaround → fehlende Body-Funktion
App → eigene Banana-Implementierung
Body → eigene Vanilla-Primitive
Banana → Duplikat einer vorhandenen Vanilla-Primitive
```

Der richtige Weg ist immer die fehlende Fähigkeit dort zu ergänzen, wo sie
architektonisch hingehört.

## 9. Produktionsregel

Keine Mocks.

Keine Stubs.

Keine Platzhalter.

Keine Fake-Implementierungen.

Keine versteckten Node-, TypeScript- oder externen Runtime-Abhängigkeiten.

Implementierungen müssen nativ in der vorgesehenen BKG-Zig-Schicht erfolgen.

## 10. Änderungsdisziplin

Vor jeder Änderung ist der aktuelle Git-Status zu prüfen.

Fremde oder bereits vorhandene Änderungen dürfen nicht überschrieben werden.

Nur Dateien des aktuellen Arbeitsschritts werden committed.

Jede abgeschlossene Änderung erhält einen nachvollziehbaren Git-Commit.

## 11. Dokumentationspflicht

Vor und nach jeder Änderung wird `/srv/bkg/playground/zig-docs.bkg/notizbuch.md`
aktualisiert.

Jeder Eintrag beschreibt Änderung, Begründung und Testergebnis.

Diese Dokumentationspflicht gilt ebenfalls für Agenten.

## 12. Branch-Regel

Arbeitet ein Layer auf einem ausdrücklich vorgesehenen Branch, bleibt der Agent
dort.

Keine neuen Parallel-Branches ohne ausdrücklichen Auftrag.

Beispiel für Banana:

```text
zig-banana
```

Nach erfolgreichem Gate wird ausschließlich der vorgesehene Branch gepusht.

## 13. Dependency-Regel

BKG-App-Abhängigkeiten verwenden die lokale Framework-Struktur.

Für App-Abhängigkeiten gilt insbesondere:

```text
path=../../zig-body.bkg
```

Keine Hash-Lock- oder `zig fetch`-Umgehung des lokalen BKG-Workflows.

## 14. Abschlussregel

Ein Feature gilt erst als abgeschlossen, wenn alle tatsächlich betroffenen Layer
von unten nach oben erfolgreich geprüft wurden.

Ein grüner App-Build allein ersetzt keine fehlenden Tests der unteren Layer.

## 15. Verbindliche Kurzform

```text
SOUL prüfen
→ falls nötig SOUL bauen
→ SOUL testen
→ BANANA prüfen
→ falls nötig BANANA bauen
→ BANANA testen
→ BODY prüfen
→ falls nötig BODY bauen
→ BODY testen
→ APP integrieren
→ APP testen
```

Diese Reihenfolge ist die eingefrorene BKG-Workflow-Regel.
