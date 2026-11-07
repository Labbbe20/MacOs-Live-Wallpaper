# MacOs-Live-Wallpaper

Eine macOS-App, die aus einem Video ein Live Photo für den iPhone-Sperrbildschirm macht. Video hineinziehen, **In Fotos sichern** wählen oder das fertige HEIC/MOV-Paar exportieren. Das letzte Videobild wird automatisch zum Standbild. Die Verarbeitung läuft lokal.

Das Videoprofil basiert auf einem am iPhone getesteten Wallpaper. Die App hält das Hochformatprofil, den Schlüsselfoto-Zeitpunkt und die zeitgesteuerten Metadaten ein. Sie legt den sichtbaren Aufbau in die letzten 0,3 Sekunden vor dem Schlüsselfoto. Ob iOS die Bewegung für ein bestimmtes Motiv freigibt, lässt sich erst am Gerät prüfen.

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
