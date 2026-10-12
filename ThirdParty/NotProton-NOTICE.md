# NotProton-derived native Steam compatibility

Synthehol's native Steam compatibility work is derived from and designed to
incorporate components from [NotProton](https://github.com/NotProtonNot/NotProton),
whose bulk source is licensed under GNU GPL version 3.

NotProton's `lsteamclient` is derived from Valve Proton and is licensed under
the Steamworks SDK License. Its `steam-shim` is a port of Proton 9's
`steam_helper`, licensed BSD-3-Clause, and compiles against Steamworks SDK,
OpenVR (BSD-3-Clause), and Wine (LGPL-2) headers. Font assets retain their
individual upstream licenses. JsonCpp and cJSON carry their upstream public
domain/MIT terms.

The initial Synthehol integration contains native Steam discovery, launch, and
deployment-boundary code but does not yet redistribute those binary payloads.
Before enabling payload installation, copy all applicable upstream license
texts and notices alongside the incorporated source and release artifacts.
