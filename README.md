# Raster

En liten menylinje-app for macOS. Festede apper vises ved siden av Raster-ikonet. Et klikk åpner appen, henter vinduet frem, eller skjuler den når et vindu allerede er synlig.

Krever macOS 14 eller nyere. Grensesnittet er på norsk.

## Bygg

Xcode må være installert, på grunn av `swiftc` og Icon Composer.

```bash
./build.sh
```

Det lager `Raster.app` i denne mappen. Appen signeres bare for denne Mac-en, ikke for distribusjon. Første åpning kan macOS stoppe. Høyreklikk appen og velg Åpne.

`Raster.app/` og `build/` legges ikke i git.

## Tilgang

Raster har ingen nettverkstilgang og ingen konto.

- **Dock-listen** leses én gang, første gang det ikke finnes en egen liste, for å hente appene du allerede har festet.
- **Tilgjengelighet** brukes til å se om et vindu er minimert og til å hente det frem. Uten den tillatelsen åpnes appen likevel, men minimerte vinduer kan ikke hentes frem. Du blir spurt første gang det trengs.
- **Styring av andre apper** brukes når du klikker eller velger åpne, skjul eller avslutt.

Det som lagres, blir liggende i Raster sine egne innstillinger på denne Mac-en. Hele forklaringen ligger i appen under Personvern, og i [PrivacyPolicy.txt](PrivacyPolicy.txt).

## Sikkerhet

Se [SECURITY.md](SECURITY.md).
