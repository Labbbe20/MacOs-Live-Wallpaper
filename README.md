# MacOs-Live-Wallpaper

Eine macOS-App, die aus einem Video ein Live Photo für den iPhone-Sperrbildschirm macht. Video hineinziehen, **In Fotos sichern** wählen oder das fertige HEIC/MOV-Paar exportieren. Das letzte Videobild wird automatisch zum Standbild. Die Verarbeitung läuft lokal.

Das Videoprofil basiert auf einem am iPhone getesteten Wallpaper. Die App hält das Hochformatprofil, den Schlüsselfoto-Zeitpunkt und die zeitgesteuerten Metadaten ein. Sie legt den sichtbaren Aufbau in die letzten 0,3 Sekunden vor dem Schlüsselfoto. Ob iOS die Bewegung für ein bestimmtes Motiv freigibt, lässt sich erst am Gerät prüfen.

## Download und Releases

Fertige DMGs für Apple Silicon (macOS 14 oder neuer) stehen unter [Releases](https://github.com/Labbbe20/MacOs-Live-Wallpaper/releases). Die App enthält den Encoder und ein aus einer [öffentlichen MIT-Vorlage](https://github.com/tmfadhlul/apple-video-to-livephotos/tree/d0c2bf897962762fde4f1e0a1ec78a7948ff0567/templates) abgeleitetes Metadatenprofil. Diese Vorlage ist unabhängig von dem lokalen Profil aus dem ursprünglichen iPhone-Test. Die App ist lokal signiert und nicht von Apple notarisiert.

Jeder Push auf `main` startet [Build macOS DMG](.github/workflows/release.yml). Nach erfolgreicher Prüfung legt die Action einen Versions-Tag für den gebauten Commit und einen öffentlichen GitHub-Release an. Die DMG, ihre SHA-256-Datei und die Encoder-Quellen stehen dann unter **Assets**. Die automatische Version lautet `v1.0.<Workflow-Nummer>`.

Manuell: **Actions → Build macOS DMG → Run workflow → Branch: main → Run workflow**. Optional lässt sich eine freie Version wie `v1.0.0` angeben. Wer nur einen Build testen will, deaktiviert **Publish a public GitHub Release**; das Ergebnis steht dann als Workflow-Artefakt bereit.

## Bauen

Benötigt werden macOS 14 oder neuer, Xcode Command Line Tools und ein eigenständiges FFmpeg für die passende Mac-Architektur mit `libx265` und `zscale`. Wenn du die Metadatenvorlage aus einem MOV gewinnen willst, brauchst du zusätzlich Python 3.10 oder neuer.

Aus dem Repository-Ordner:

```sh
FFMPEG_BINARY=/pfad/zu/ffmpeg \
WALLPAPER_PROFILE=/pfad/zu/Wallpaper-Profil.mov \
zsh ./App/build.sh
```

Der Build erzeugt eine lokal signierte **Live Wallpaper.app** im Repository-Ordner. Alternativ kannst du statt `WALLPAPER_PROFILE` mit `WALLPAPER_DONOR` einen [geeigneten Referenzfilm](App/Resources/README.md) angeben. Die konkreten Metadaten aus dem ursprünglichen Test bleiben lokal; weder die Mediendateien noch das fertige App-Bundle oder FFmpeg liegen im Repository.

## Verwenden

1. **Live Wallpaper.app** öffnen und ein kurzes MOV- oder MP4-Video hineinziehen.
2. **In Fotos sichern** wählen. Bei aktivem iCloud-Fotos erscheint es auch auf dem iPhone. Alternativ **Dateien sichern…** wählen und HEIC sowie MOV gemeinsam importieren.
3. Auf dem iPhone **Einstellungen → Hintergrundbild → Fotos → Live Photo** öffnen und die Wiedergabetaste aktivieren. Die Bewegung beim Aufwecken prüfen.

Die App schneidet Videos bei Bedarf mittig ins Hochformat. Kurze Clips mit einem klaren Bewegungsablauf und einem passenden Endbild eignen sich am besten.

## Aufbau

- [App/](App) — SwiftUI-Oberfläche, FFmpeg-Verarbeitung, ImageIO und PhotoKit, QuickTime-Multiplexing und Build-Skript.
- [tools/](tools) — Werkzeuge zum Extrahieren der Metadatenvorlage sowie zur Analyse und manuellen Erstellung von Live-Photo-Paaren.

[Apple: Live Photo als Sperrbildschirm-Hintergrund verwenden](https://support.apple.com/de-de/120734)
