# Nowah for Omarchy

An [Omarchy](https://omarchy.org) shell plugin for [Nowah](https://app.nowah.xyz), the AI travel booking app. Adds a Nowah button to the bar with a "Where to?" panel: type a query (flights, hotels, anything) and it opens in a dedicated Nowah app window with the search already running. Quick chips jump straight to Trips, Plans, eSIM, and Visa.

- **Left click** the bar icon — open the search panel
- **Right click** — open the Nowah app window directly
- **Enter** in the panel — run the search in the app window
- **Flights / Hotels chips** — seed the search box; **Trips / Plans / eSIM / Visa** — deep-link into the app

Full flows (search results, booking, payment, sign-in) run in the real Nowah web app via `omarchy-launch-webapp`, so nothing is re-implemented in the shell.

## Requirements

Omarchy 4.0 "Quattro" or later (the Quickshell-based shell with plugin support).

## Install

```bash
omarchy plugin add https://github.com/maslinedwin/nowah-travel --enable
```

Or from the Omarchy menu: **Setup > Plugins**.

## Develop locally

Copy this directory to the plugin location, named by its id:

```bash
cp -r nowah-plugin ~/.config/omarchy/plugins/xyz.nowah.travel
```

Then enable it via the Omarchy menu (**Setup > Plugins**), or:

```bash
omarchy-shell shell rescanPlugins
omarchy-shell shell setPluginEnabled xyz.nowah.travel true
```

Edits to files under `~/.config/omarchy/plugins/` hot-reload automatically. To lint and validate:

```bash
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
omarchy plugin validate ~/.config/omarchy/plugins/xyz.nowah.travel
```

## Publishing to the marketplace

Submit the repo at [plugins.omarchy.org](https://plugins.omarchy.org) via the issue template on [omacom/omarchy-plugin-marketplace](https://github.com/omacom/omarchy-plugin-marketplace) (verification pins a commit SHA; re-verify after releases).

## License

MIT — see [LICENSE](./LICENSE).
