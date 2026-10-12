This directory is the build-time landing area for Synthehol's native Steam
compatibility payload. It is intentionally incomplete in source checkouts.

Release builds populate it from the vendored NativeSteamCompatibility target.
NativeSteamPayload validates every required component before the installer is
enabled, so this placeholder can never be mistaken for a usable payload.
