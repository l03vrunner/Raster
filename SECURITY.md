# Sikkerhet

Raster kjører bare på Mac-en den er bygget på. Den kontakter ingen tjener, og den har ingen konto.

## Hva appen kan gjøre

Når du har gitt tilgang, kan Raster se vindustilstanden til andre apper og åpne, skjule eller avslutte apper du har festet. Det skjer når du klikker eller velger det i menyen. Gi Tilgjengelighet bare til en `Raster.app` du har bygget selv med `./build.sh`.

`./build.sh` signerer med en ad hoc-signatur. Appen er ikke notarisert av Apple. Ikke last ned en ferdig `Raster.app` fra noen andre og gi den Tilgjengelighet.

## Hva som lagres

Lokalt, i appens egne innstillinger:

- stien til hver festet app, og et bokmerke som peker til den
- rekkefølgen

Første oppstart uten en slik liste leser `~/Library/Preferences/com.apple.dock.plist` og tar vare på app-stiene derfra. Innholdet i de appene leses ikke.

Start ved innlogging lagres av macOS, og bare hvis du slår det på.

Med `RASTER_DEBUG=1` skrives feilsøkingslinjer, inkludert navnene på de festede appene, til `/tmp/raster-status.txt`. Vanlig kjøring gjør ikke det.

## Rapportere et problem

Bruk en privat sikkerhetsrådgivning på dette lageret i GitHub. Ikke legg en sårbarhet i et vanlig issue.
