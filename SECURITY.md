# Security

Raster runs only on the Mac it is built on. It contacts no server, and it has no account.

## What the app can do

Once you grant access, Raster can see the window state of other apps and open, hide, or quit apps you have pinned. That happens when you click or choose it in the menu. Grant Accessibility only to a `Raster.app` you built yourself with `./build.sh`.

`./build.sh` signs with an ad hoc signature. The app is not notarized by Apple. Do not download a finished `Raster.app` from someone else and grant it Accessibility.

## What is stored

Locally, in the app’s own settings:

- the path of each pinned app, and a bookmark that points to it
- the order

The first launch without such a list reads `~/Library/Preferences/com.apple.dock.plist` and keeps the app paths from there. The contents of those apps are not read.

Open at Login is stored by macOS, and only if you turn it on.

With `RASTER_DEBUG=1`, debug lines, including the names of the pinned apps, are written to `/tmp/raster-status.txt`. A normal launch does not do that.

## Reporting a problem

Use a private security advisory on this GitHub repository. Do not put a vulnerability in a public issue.
