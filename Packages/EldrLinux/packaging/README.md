# EldrChat Linux packaging

- `eldr-chat.desktop`: install to `$PREFIX/share/applications/`. `Exec=eldr-gtk` assumes the binary is on `PATH`.
- `icons/eldr-chat-{48,128,256}.png`: install as `$PREFIX/share/icons/hicolor/<N>x<N>/apps/eldr-chat.png`. They're exported from `App/PQRC/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.

eldr-gtk gets its passphrase from `ELDR_CHAT_PASSPHRASE_FILE` or `ELDR_CHAT_PASSPHRASE`, and its state directory from `--state` (defaults to `~/.local/share/eldr-chat`).
