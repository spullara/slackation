# Whereabouts

Whereabouts is an iPhone app that sets your Slack status from saved geofences.
The app requires iOS 17 or later. This scaffold contains the shared models and JSON storage.

## Build and run

1. Install Xcode and an iOS simulator runtime.
2. Select Xcode in Settings > Locations > Command Line Tools.
3. Install XcodeGen with `brew install xcodegen`.
4. Run `scripts/build.sh` to generate the project and build the app.
5. Run `scripts/test.sh` to run the unit tests.
6. Open `Whereabouts.xcodeproj`, select an iPhone simulator, and press Run.

The scripts select an available iPhone simulator. To select a specific simulator, set `SIMULATOR_ID` to its UUID.
For a physical iPhone, select your signing team in Xcode before you run the app.
The generated Xcode project is not committed. Change `project.yml` to change the project settings.

## Source layout

- `Whereabouts/Models`: `Geofence` and `OtherStatus` value types.
- `Whereabouts/Storage`: observable `GeofenceStore`.
- `Whereabouts/UI`: the placeholder root view.
- `WhereaboutsTests`: unit tests.
- `scripts`: project generation, build, and test commands.

The store uses `Application Support/Whereabouts/geofences.json` inside the app container.
Call `load()` at startup. Call `save(geofences:otherStatus:)` to save changes.
Both methods throw errors for the caller to show. The store accepts at most 20 geofences with unique IDs.
A failed save preserves the previous state. Tests use temporary files outside the app data path.

## Driving detection

Driving ends after two minutes of stationary or walking activity. Unknown or low-confidence activity does not end Driving.

## License

This project uses the [MIT License](LICENSE). The bundled emoji data retains its [separate license](Whereabouts/Emoji/Emoji-LICENSE.txt).
