# Roadmap

OneShot ships in small, usable milestones. Checked items are done.

## M1: MVP (daily driver)

- [x] Menu bar app, global hotkeys (Carbon, no Accessibility permission needed)
- [x] ⇧⌘4 area capture straight to the clipboard
- [x] Frozen-screen selection with magnifier loupe and size label
- [x] Window capture (Space during selection), optional shadow
- [x] Fullscreen capture, previous area capture
- [x] Save to a chosen folder (PNG/JPEG, Retina DPI metadata, optional 1x)
- [x] File name pattern with placeholders ({date}, {time}, {random}, {random:N}, {app}, …)
- [x] Quick Access overlay: Copy, Save, Pin, Copy Text, Open, drag & drop
- [x] Pin screenshots: always on top, resize, opacity, click-through lock, all Spaces
- [x] Pin image from clipboard
- [x] OCR and QR/barcode to clipboard (on-device)
- [x] Toggle the built-in macOS screenshot shortcuts
- [x] Customizable shortcuts (recorder UI, conflict detection)
- [x] Copy-only capture (no preview, no file)
- [x] Settings window, launch at login

## Task List
- [x] Crosshair guide lines across the screen
- [x] Self-timer (3/5/10 s)
- [x] Hide desktop icons during capture (and desktop widgets)
- [x] App icon
- [ ] M3: S3 upload
  - [ ] Any S3-compatible provider (AWS, Cloudflare R2, MinIO, Backblaze B2): endpoint, bucket, region, key prefix
  - [ ] Public or presigned URL copied to the clipboard after upload
  - [ ] Custom domain / CDN base URL
  - [ ] Upload from Quick Access, pins, and as an automatic after-capture action
  - [ ] Upload history with delete
  - [ ] Credentials stored in the Keychain
- [ ] M4: Scrolling capture
  - [ ] Select an area, auto-scroll (or manual scroll) and stitch frames into one tall image
  - [ ] Live preview of the stitched result, stop at any time
- [ ] M5: Background tool
  - [ ] Backgrounds: gradients, solid colors, images
  - [ ] Padding, corner radius, shadow, alignment
  - [ ] Aspect ratio presets (16:9, 1:1, 4:3, social sizes)
  - [ ] Saved custom presets
- [ ] History and semantic search
  - [ ] Local history of every capture (SQLite + thumbnails, capture app/window metadata)
  - [ ] Background indexing: on-device OCR plus vision-model captions and tags
  - [ ] Hybrid search: full-text (FTS5) + embeddings (sqlite-vec)
  - [ ] Providers: OpenAI, Anthropic, Google Gemini, Ollama (fully local)
  - [ ] Filters by date, app and window title
  - [ ] Actions from results: copy, pin, reveal in Finder, upload
  - [ ] Retention policy, pause/resume indexing
- [ ] M7: Onboarding wizard
  - [ ] Permissions (Screen Recording; Accessibility where needed)
  - [ ] Save folder and default after-capture actions
  - [ ] Shortcut setup, including taking over the macOS shortcuts
  - [ ] Optional S3 setup with "Test connection"
  - [ ] Optional LLM provider and API key (skippable; Ollama needs no key)
- [ ] Annotation tools
- [ ] Screen recording / GIF
- [ ] URL scheme and CLI (`oneshot://capture-area`) for Raycast/Alfred
- [ ] Auto-update via Sparkle
