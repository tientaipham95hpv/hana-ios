# Character Media publish tools

Build the current publish directory outside the Git checkout:

```powershell
python tools/media_vault/publish_media.py `
  --source ..\assets_processed\hana `
  --manifest app\assets\character\character_manifest.json `
  --output ..\builds\phase6_7_media_publish
```

Serve it locally with byte-range support:

```powershell
python tools/media_vault/serve_media.py `
  --root ..\builds\phase6_7_media_publish --port 8765
```

Use `--fail-first 2`, `--corrupt-asset chr_001`, or `--offline` to exercise retry, integrity, and offline behavior. Configure the app with `HANA_MEDIA_BASE_URL`; the manifest URL can be overridden independently with `HANA_MEDIA_MANIFEST_URL`. Use HTTPS for a physical iPhone unless the development host has an appropriate local transport exception.
