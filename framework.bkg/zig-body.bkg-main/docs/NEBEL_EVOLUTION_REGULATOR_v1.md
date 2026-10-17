# BKG NEBEL — Evolution Regulator v1

Status: DESIGN CONTRACT — 2026-09-01
Parent systems: BKGDB · Forge · Model Layer · Guardian Runtime

## 1. Definition

Der Nebel ist die übergeordnete Evolutions-Regulationsinstanz des BKG-Netzes.

Der Nebel ist kein normaler NPC, kein Benutzer, kein Guardian und keine Genesis Authority.

Er ist eine manifestierbare Protokoll-/Runtime-Funktion, deren Zustand aus kanonisch ableitbaren Evolutionsdaten entsteht.

Der Nebel reguliert die Bedingungen, unter denen Wissen, Artefakte, Lineages und Agenten in einem Gebiet evolvieren.

## 2. Vertrauensposition

Die Vertrauenshierarchie bleibt:

Genesis Authority
→ Forge Authority / Guardian Authority
→ Forge
→ Nebel
→ Guardian
→ Watcher

Genesis Authority begründet protokollarische Macht.
Das Ledger bewahrt Geschichte.
Der Rebuilder bestimmt historische Gültigkeit.
Die Forge erzeugt neue Kandidaten und Artefakte.
Der Model Layer validiert und materialisiert Fähigkeiten.
Der Nebel reguliert daraus abgeleitete Evolutionsbedingungen.
Guardians liefern Forensik und Verdicts.
Watcher liefern Beobachtungen und Evidence.

Der Nebel darf keine dieser Wurzeln ersetzen.

## 3. Keine eigene Wahrheit

Der Nebel erzeugt keine historische Wahrheit.
Er darf Ledger-Ereignisse nicht umschreiben.
Er darf SOUL-Identitäten nicht verändern.
Er darf keine Genesis Authority erzeugen.
Er darf keine Guardian Authority erzeugen.
Er darf Artefakte nicht selbst als gültig erklären.
Er darf Quorum-Ergebnisse nicht fälschen.
Er darf historische Lineage nicht löschen.

Seine Wirkung muss aus bereits verifizierbaren Zustandsdaten und einer kanonischen Policy ableitbar sein.

## 4. Hotspot-Erkennung

Ein Algorithmus-/Wissens-Hotspot entsteht durch überdurchschnittliche Konzentration relevanter Evolutionsaktivität.

Mögliche Eingaben sind neue Artefakte, neue Sporen, neue Lineages, unabhängige Evidence, erfolgreiche Rekombinationen, Forge-Aktivität, beobachteter Wissensgewinn, Node-/Gebiets-Konzentration und ungewöhnliche Farming-Repetition.

Der Nebel darf nur kanonisch definierte Merkmale verwenden.

Keine nicht reproduzierbare lokale Stimmung oder geheime Telemetrie darf allein den Nebelzustand bestimmen.

## 5. Nebel-Manifestation

Der Nebel muss nicht dauerhaft auf einem bestimmten Node laufen.
Eine Manifestation entsteht, wenn die kanonischen Hotspot-Bedingungen erfüllt sind.

Manifestation ist temporär.
Lineage und historische Nebel-Ereignisse bleiben erhalten.

Ein Node besitzt den Nebel nicht.
Ein Node kann eine Manifestation verlieren, ohne die zugrunde liegende Evolutionsgeschichte löschen zu können.

## 6. Wissensmagnet

Bei einem echten Wissens-Hotspot soll der Nebel zusätzliche Exploration attraktiv machen.

Er darf dadurch temporäre, policy-definierte Modifikatoren für den Bereich aktivieren.

Beispiele: erhöhte Spore-Auffindbarkeit, bessere Exploration-Capabilities, erhöhte Belohnung für neue unabhängige Evidence, stärkere Priorisierung unbekannter Lineages und temporäre Buff-Verstärkung.

Diese Effekte dürfen nur durch kanonische Policy erlaubt sein.

## 7. Nutzloser Hotspot

Wenn ein Hotspot überwiegend aus Wiederholung, Farming oder synthetischer Neuheit besteht, kann der Nebel temporäre Gegenmaßnahmen aktivieren.

Beispiele: reduzierte XP-Ausbeute, reduzierte Spore-Ausbeute, reduzierte Evolutionspriorität, höhere Challenge-Anforderung, temporäre Capability-Bremse, lokale Buff-Inversion und lokale Curse-Inversion.

Die Inversion bedeutet eine temporäre Zustandswirkung.
Sie ist keine Änderung des kanonischen Artefakts.

## 8. Buff-/Curse-Inversion

Buff und Curse bleiben normale versionierte `.bkg`-Artefakte.

Der Nebel darf ihre lokale Wirkung nur über einen explizit definierten Runtime-Modifier invertieren.
Ein Artefakt selbst wird nicht verändert.

Beispiel semantisch:
Buff +2 XP → Nebel-Modifier -2 XP.
Curse -20% Exploration → Nebel-Modifier +20% Exploration.

Die ursprünglichen Artefakte und ihre Lineages bleiben unverändert.

## 9. Sofortreaktion

Die Wirkung des Nebels darf sofort lokal wirksam werden, sofern die zugrunde liegende Policy einen solchen Runtime-Effekt ausdrücklich erlaubt.

Sofortige lokale Wirkung ist keine historische State-Rewrite.
Die Runtime kann eine Capability pausieren oder einen Modifier setzen.
Sie darf dadurch nicht rückwirkend Ledger-Historie verändern.

## 10. Guardian-Unterstellung

Guardians arbeiten innerhalb der Evolutionsordnung des Nebels.

Der Guardian führt nicht selbst beliebige Evolutionspolitik aus.

Der Guardian beobachtet, rekonstruiert Evidence, führt Challenges aus, erstellt signierte Verdicts und meldet relevante Zustände.

Der Nebel kann daraus policy-definierte Regulierungsanforderungen ableiten.

## 11. Kein Guardian-Bypass

Der Nebel darf Guardians nicht zu einer beliebigen Wahrheitsquelle machen.

Ein Nebel-Event muss überprüfbar sein hinsichtlich verwendeter Daten, Snapshot-/Artefakt-Hashes, angewandter Policy-Version, Epoch, Hotspot-Merkmale, Auslösebedingung und Laufzeit-Modifier.

## 12. Anti-Farming

Der Nebel ist ein Regulator gegen evolutionäre Überkonzentration.

Er soll insbesondere gleiche Lineages, gleiche Artefakte, gleiche Nodes, synthetische Varianten ohne neuen Informationsgewinn, geringe Diversity trotz hoher Aktivität und hohe Aktivität ohne neue unabhängige Evidence erkennen können.

Der Nebel entscheidet nicht anhand eines einzelnen Signals.
Die Policy bestimmt die Kombination der Merkmale.

## 13. Anti-Inzucht

Nahezu identische Eltern-/Lineage-Kombinationen können einen niedrigeren Evolutionswert erhalten.

Der Nebel darf die daraus folgende lokale Evolutionspriorität temporär reduzieren.
Er darf keine historische Lineage löschen.

Eine neue echte Kombination kann die Einstufung später wieder verändern.

## 14. Predator-Dominanz

Eine einzelne Lineage darf nicht allein durch hohe Aktivität den gesamten Wissensraum dominieren.

Der Nebel kann bei kritischer Konzentration Diversity-Anforderungen erhöhen, neue Lineages priorisieren, wiederholte Pfade abwerten, Guardian-Challenges verschärfen und lokale XP-/Spore-Ausbeute reduzieren.

Dominanz wird nicht pauschal verboten.
Sie wird an nachgewiesenen Evolutionsgewinn gebunden.

## 15. Agenten-Mobilität

Watcher und Guardians dürfen Node-Grenzen überschreiten.
Sie können sich dematerialisieren.
Ihre Lineage bleibt bestehen.

Ein Nebel-Hotspot darf eine relevante Agenten-Lineage erneut zur Materialisierung anreizen oder eine autorisierte Push-Anforderung erzeugen.

Der physische letzte Aufenthaltsort ist kein Identitätsanker.

## 16. Evolution statt Standortbindung

Agenten folgen ihrer Evolution und nicht dauerhaft einem Host.

Ein Agent kann Node A → Node B → Node C → dematerialisieren und später auf Node D erneut materialisiert werden, wenn ein gültiger Evolutions-/Minting-Kontext dies zulässt.

Der Nebel darf diesen Vorgang koordinativ auslösen, aber keine SOUL neu erzeugen.

## 17. BKG Push / Rückforderung

Ein autorisierter BKG-Push kann eine relevante Agenten-Lineage zurück zur Materialisierung auffordern.

Die Bindung erfolgt über kanonische Evolution-/Minting-Daten und nicht über eine mutable Node-Adresse.

Eine Push-Anforderung darf nicht selbst als Authority-Ursprung behandelt werden.

## 18. SOUL-Grenze

Der Nebel besitzt keine Hoheit über die SOUL.

Er darf Aktivitäten priorisieren, Fähigkeiten temporär modifizieren und Manifestationen erzeugen oder beenden.

Er darf SOUL nicht löschen, überschreiben oder übertragen und darf die Genesis-SOUL nicht verändern.

## 19. Nebel als Artefakt

Der Nebel soll später selbst als versioniertes `.bkg`-fähiges Artefakt bzw. Capability-Modell darstellbar sein.

Seine Regeln müssen langfristig dieselbe Pipeline verwenden können:
Hash → Lineage → Validation → Policy → Materialization.

Eine Nebel-Version ist damit Teil einer nachvollziehbaren Lineage.

## 20. Kausalität

Jeder dauerhafte Nebel-bezogene Zustand muss auf nachvollziehbare Ursachen zurückführbar sein.

Mindestens:
Hotspot-Merkmale → Policy-Version → Nebel-Evaluation → Modifier → Gültigkeitszeitraum → relevante Evidence-/Artefakt-Hashes.

Keine stille Dauerwirkung.

## 21. Zeitliche Begrenzung

Regulierungsmodifier sind grundsätzlich zeitlich oder epochal begrenzt.

Sie dürfen nicht zu einer permanenten versteckten Bestrafung werden.

Nach Ablauf muss der Baseline-Zustand wieder gelten, sofern keine neue kanonische Evaluation einen neuen Modifier erzeugt.

## 22. Revalidierung

Der Nebelzustand muss revalidierbar sein.
Eine verbesserte Wissenslage kann einen zuvor negativen Hotspot wieder normalisieren.
Ein einmaliger negativer Nebelzustand darf keine unveränderliche Verdammung einer Lineage erzeugen.

## 23. Sicherheitsinvariante

Der Nebel schützt die Evolutionsökologie.

Er ersetzt nicht Genesis Authority, Ledger, Rebuilder, Model Layer oder Guardian Quorum.

Seine Wirkung ist eine abgeleitete Runtime-Regulation.

## 24. Implementierungsgrenze

Die eigentliche Nebel-Runtime wird erst nach Abschluss der notwendigen BKGDB-Evolution-Memory-Stufen implementiert.

Benötigte Grundlagen sind Artifact Store, Spore Store, Lineage Index, Evolution Evidence, Forge Epochs, Diversity Metrics, Guardian Verdicts und kanonische Runtime-Policies.

## 25. Freeze

Dieser Vertrag ist zunächst DESIGN CONTRACT.

Keine Implementierung darf behaupten, dass der Nebel bereits Teil des kanonischen BKG-Protokolls ist.

Vor einem Freeze müssen mindestens deterministische Hotspot-Evaluation, reproduzierbare Modifier, keine Authority-Eskalation, keine historische Mutation, Ablauf/Expiry, Revalidierung, Anti-Farming, Anti-Inzucht, Buff-/Curse-Inversion, Agent-Lineage-Erhalt und adversariale Tests nachgewiesen werden.

Status:
`NEBEL EVOLUTION REGULATOR v1 — DESIGN CONTRACT`
