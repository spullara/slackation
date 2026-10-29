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

Status priority is geofence > Driving > Other. A geofence entry sends the place status immediately, even when motion still reports driving.
On exit, the app reads motion history before it selects Driving or Other.

Driving ends after two minutes of stationary or walking activity. Unknown or low-confidence activity does not end Driving.

## License

This project uses the [MIT License](LICENSE). The bundled emoji data retains its [separate license](Whereabouts/Emoji/Emoji-LICENSE.txt).

## Webhook destinations

In **Destinations**, tap **Add webhook**. Enter a name and an HTTPS URL, then tap **Save**.
Each webhook has its own switch, last successful send time, and error on Home.
Tap its name to edit it. Swipe left to delete it.
To add or change a signing secret, enable **Replace saved secret**. An empty replacement removes the secret.
Secrets stay in the device Keychain. The configuration file stores no secrets.

**Send test** sends the current status with `event: "test"` and shows the HTTP result.
It uses the editor values without saving them or changing automatic-send deduplication.
Automatic updates use this versioned JSON body:

```json
{"version":1,"event":"status.changed","kind":"geofence","location":"Office","geofenceId":"00000000-0000-0000-0000-000000000001","text":"At the office","emoji":"🏢","emojiShortcode":":office:","timestamp":"2026-10-29T01:00:00Z"}
```

`kind` is `geofence`, `driving`, or `other`. Driving and Other use `null` for `geofenceId`.
`emoji` contains Unicode when available. For a custom Slack emoji, it contains the shortcode as a fallback.
The body never contains coordinates. The endpoint receives the location name and status text.

Requests use POST, `Content-Type: application/json`, and a 15-second timeout.
Any 2xx response succeeds. HTTP 429 and 5xx responses get one retry.
The retry uses `Retry-After` seconds or an HTTP date, capped at 30 seconds. Missing or invalid values use one second.
Other responses fail without a retry. Redirects are not followed.

If a secret exists, `X-Whereabouts-Signature` contains `sha256=` plus the lowercase HMAC-SHA256 hex digest of the raw body.
`X-Whereabouts-Timestamp` matches the UTC ISO 8601 timestamp inside the signed body.
The receiver must verify the raw bytes before it trusts the JSON. This Python example uses receiver-provided `raw_body`, `headers`, and `secret`:

```python
import datetime, hashlib, hmac, json
expected = "sha256=" + hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
if not hmac.compare_digest(expected, headers.get("X-Whereabouts-Signature", "")):
    raise ValueError("Invalid signature")
payload = json.loads(raw_body)
stamp = payload["timestamp"]
if stamp != headers.get("X-Whereabouts-Timestamp"):
    raise ValueError("Invalid timestamp")
sent = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
if abs((datetime.datetime.now(datetime.timezone.utc) - sent).total_seconds()) > 300:
    raise ValueError("Expired request")
```

Store recently accepted signatures to reject replayed requests. A retry uses the same body and signature.
Return a 2xx response for an already processed request to avoid duplicate work.
