# SOUL SPORES v1

> Architekturentwurf für SOULs, LOSTs, Sporen und ihre kontrollierte Evolution im BKG-Netz.
>
> Status: Entwurf v1
> Regel: Diese Datei bleibt historisch erhalten; spätere Änderungen werden als neue Version angelegt.

## 1. Grundidee

SOULs sind keine gewöhnlichen NFTs.
Sie sind unveräußerliche Identitäts- und Herkunftsanker des eigenen Systems.

LOSTs sind keine neuen SOULs.
Sie sind kryptografisch nachvollziehbare Fragmente einer verlorenen oder beschädigten SOUL-Lineage.

SPORES sind portable Fragmente von Fähigkeiten, Wissen oder Lineage.
Sie dürfen sich im P2P-Netz verbreiten, ohne dadurch automatisch Vertrauen zu erhalten.

Die Forge ist die dauerhafte Schmiede für Algorithmen, Guardians und neue Capsule-/Spore-Generationen.

## 2. SOUL als Ursprung

Eine SOUL besitzt eine eindeutige Identität, Provenance, Genesis und Bindung.
Die Bindung an uns ist nicht handelbar und nicht übertragbar.

Eine SOUL darf Kinderobjekte hervorbringen, aber die ursprüngliche SOUL bleibt eindeutig identifizierbar.

Jede Ableitung muss auf ihre Parent-SOUL und die entsprechende Lineage zurückführbar sein.

Kein User darf eine SOUL erzeugen oder sich selbst eine SOUL-Rechteebene zuschreiben.

## 3. LOST als Fragment

Ein LOST entsteht, wenn ein Teil einer SOUL-Lineage verloren, abgetrennt oder beschädigt wurde.

LOST trägt Herkunft, Fragmenttyp, Parent-SOUL-Referenz und Integritätsnachweise.

Mehrere LOST-Fragmente können später wieder einer SOUL-Lineage zugeordnet werden.
Eine Rekonstruktion verändert nicht rückwirkend die historische Chain.

Ein LOST darf nicht automatisch die Rechte der vollständigen SOUL erben.

## 4. SPORE als Verbreitungseinheit

Eine Spore ist ein kleines, transportierbares Evolutionsartefakt.
Sie referenziert eine Capsule, einen Algorithmus, einen Guardian-Baustein oder ein anderes zugelassenes Wissensartefakt.

Eine Spore enthält mindestens Identität, Parent-Referenz, Version, Payload-Hash,
Provenance, Capability-Referenzen und Signaturen.

Die Spore darf über P2P-Zonen weitergegeben werden.
Empfang bedeutet jedoch niemals automatische Aktivierung oder Vertrauen.

## 5. Spore-Lifecycle

Eine Spore durchläuft die Zustände CREATED, SEALED, DISPATCHED, OBSERVED,
CHALLENGED, VERIFIED, ACTIVATED, MUTATED, RETIRED oder LOST.

Der Zustand wird nicht still überschrieben.
Jede Zustandsänderung erzeugt ein neues Ledger-Ereignis.

Eine aktivierte Spore darf weitere Sporen hervorbringen, aber die neue Generation
muss ihre Parent-Lineage und ihren eigenen Payload-Hash tragen.

## 6. Spore-Fortpflanzung

Sporen verbreiten sich über das P2P-Netz in Zonen.
Ein Peer kann eine Spore annehmen, replizieren und weiterreichen.

Weitergabe ist keine Vertrauensvererbung.
Die Zielzone muss die Spore lokal prüfen und kann sie ablehnen oder quarantänisieren.

Die Forge kann erfolgreiche Sporen als Seed für neue Capsules oder Guardian-Artefakte verwenden.

## 7. Fragmentierung und Rekombination

Eine Capsule kann in mehrere Sporen zerlegt werden.
Jede Spore kennt ihre Parent-Capsule und ihre Fragmentrolle.

Mehrere gültige Sporen dürfen zu einer neuen Capsule rekombiniert werden,
wenn die Kompositionsregeln und Abhängigkeiten erfüllt sind.

Die Rekombination erzeugt immer eine neue Identität und eine neue Version.
Alte Lineages bleiben unverändert erhalten.

## 8. SOUL-SPORE-Grenze

SOUL-Spores dürfen Herkunft oder technische Fragmente einer SOUL transportieren,
aber niemals stillschweigend die vollständige SOUL-Identität übertragen.

Besonders geschützte SOUL-Eigenschaften bleiben an den ursprünglichen SOUL-Anker gebunden.

Ein LOST kann als Quelle für eine autorisierte Rekonstruktion dienen, ist aber selbst keine vollständige SOUL.

## 9. Watcher-Prüfung

Watcher beobachten Spore-Empfang, Replikation, Aktivierung und Weiterverbreitung.

Sie prüfen insbesondere Payload-Hash, Parent-Lineage, Version, Signaturen,
Capability-Ansprüche und auffällige Verbreitungsmuster.

Watcher dürfen Sporen challengen und Quarantäne empfehlen.
Ein einzelner Watcher darf kritische Besitz- oder SOUL-Entscheidungen nicht allein treffen.

## 10. Guardian-Zone

Guardians verwalten die Spore-Aktivierung innerhalb ihrer P2P-Zone.
Sie erhalten Beobachtungen von wechselnden Watchern und führen diese zusammen.

Bei widersprüchlichen Beobachtungen wird die Spore nicht automatisch aktiviert.
Sie bleibt pending oder geht in Quarantäne, bis unabhängige Evidenz vorliegt.

## 11. Forge-Evolution

Die Forge kann aus bewährten Sporen neue algorithmische oder Guardian-Capsules schmieden.

Eine neue Generation referenziert alle relevanten Eltern, Tests, Benchmarks,
Watcher-Evidenz und Guardian-Entscheidungen.

Dadurch entsteht eine nachvollziehbare Evolutionslinie:
SOUL → Capsule → Spore → Zone → Beobachtung → Verifikation → neue Capsule.

## 12. Versionierung

Version ist Teil der Identität jedes Evolutionsartefakts.
Sie beschreibt nicht nur Software-Releases, sondern die gesamte Lineage eines Objekts.

Eine Version darf nur durch eine neue Version ersetzt werden.
Historische Versionen bleiben im Ledger referenzierbar.

Versionen müssen kompatible Schema-, Capability-, Algorithmus- und Policy-Informationen tragen,
soweit diese für das jeweilige Artefakt relevant sind.

## 13. Keine selbstbeglaubigende Evolution

Keine Spore kann sich selbst als vertrauenswürdig deklarieren.
Keine Capsule erhält Vertrauen allein durch ihre Herkunft.

Vertrauen entsteht durch Beobachtung, kryptografische Integrität, reproduzierbare Tests,
Guardian-Prüfung und die für den jeweiligen Risikograd erforderliche Quorum-Entscheidung.

## 14. Zielbild

SOUL ist der unveräußerliche Ursprung.
LOST bewahrt Fragmente verlorener Lineage.
SPORES verbreiten Fähigkeiten und Fragmente kontrolliert durch das P2P-Netz.
CAPSULES bündeln reproduzierbare Fähigkeiten.
FORGE erschafft neue Generationen.
WATCHER beobachten die Verbreitung.
GUARDIANS koordinieren Zonen und Entscheidungen.

Das Netzwerk soll dadurch nicht einfach Updates verteilen.
Es soll überprüfbare Fähigkeiten durch kontrollierte Generationen weitergeben und verbessern.

Diese Architektur ist bewusst offen für spätere Spore-Typen, Rekombinationsregeln,
SOUL-Recovery-Verfahren und neue Guardian-/Hero-Generationen.