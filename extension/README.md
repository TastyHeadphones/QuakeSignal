# QuakeSignal for Chrome

Free and open-source earthquake monitoring in Chrome. The Manifest V3
extension connects directly to Wolfx, keeps recent events in local browser
storage, and can show a browser notification and play an alarm for matching
earthquake warnings. It does not use the QuakeSignal backend.

## Local testing

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked** and select this `extension/` directory.
4. Open QuakeSignal and use **Test alarm & notification**.

```bash
npm test
npm run package
```

The Web Store ZIP is written to `dist/quakesignal-chrome-v0.1.0.zip`.
