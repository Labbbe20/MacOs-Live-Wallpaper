# Lokales Wallpaper-Profil

Der Build erwartet eine lokale, rein technische MOV-Vorlage. Sie wird nicht mit dem öffentlichen Quellcode verteilt. Die zeitgesteuerten Apple-Metadaten sind teilweise undokumentiert und können Angaben zur ursprünglichen Aufnahme enthalten.

Wenn du bereits ein `Wallpaper-Profil.mov` hast, setze `WALLPAPER_PROFILE` auf diese Datei oder speichere sie hier unter diesem Namen. Der Build legt sie unter demselben Namen im App-Bundle ab. Die lokale Datei wird durch Git ignoriert.

Wenn du einen kompatiblen, auf dem iPhone getesteten Referenzfilm hast, verwende `WALLPAPER_DONOR=/pfad/zum/Referenzfilm.mov`. Alternativ kannst du die Vorlage separat extrahieren:

```sh
python3 tools/freeze_template.py /pfad/zum/Referenzfilm.mov App/Resources/Wallpaper-Profil.mov
```

Das App-Profil erwartet eine Präsentationsdauer von 3 s bei 600 Ticks pro Sekunde, die drei passenden Metadatenspuren mit IDs 2, 3 und 4 und das Schlüsselfoto bei Tick 920. Der Referenzfilm sollte aufrecht kodiert sein und eine passende Standbildtransformation für 886 × 1920 haben. Das Werkzeug kopiert die Metadatenspuren, aber keine Videoframes, Standbilder, Audiodaten oder globale Live-Photo-Kennung.
