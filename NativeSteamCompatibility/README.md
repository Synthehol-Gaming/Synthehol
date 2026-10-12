# Synthehol Native Steam Compatibility

This target is Synthehol's vendored fork of the native Steam injection and
overlay components originally developed by NotProton. It is built and packaged
entirely inside this repository; users do not install or run NotProton.

The upstream snapshot corresponds to NotProton 1.1.5 plus Dobby commit
`5dfc8546954ce3b3198132ab13fddb89ee92cdd7`. Upstream license texts and NOTICE
are retained in `Upstream/`.

Run `make -C NativeSteamCompatibility payload` to compile universal dylibs and
stage the validated payload in SyntheholKit resources. The Wine/Steam bridge and
CrossOver runner patcher remain the next payload layer.
