# Installing WreckBox on a Mac

WreckBox runs on **Apple Silicon Macs** (M1 or newer, MacBook Neo included) with **macOS 13 Ventura or later**.
Everything it needs is inside the app, so you don't have to install Python, Homebrew or anything else.

## 1. Download

Get **WreckBox-mac-arm64.zip** from the latest release:
https://github.com/moloyb301-eng/wreckbox-releases/releases/latest

Double-click the zip and drag **WreckBox** into **Applications**.

## 2. First launch

WreckBox isn't signed by Apple (it's free and open source, without a paid developer account), so the first time you
open it macOS blocks it:

1. Double-click WreckBox. macOS says it "can't be opened". Click **Done** (not Move to Bin).
2. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to "WreckBox was blocked".
3. Enter your Mac password, then click **Open Anyway** again.

This happens only once. Updates install from inside the app and open normally.

## 3. Setup

A setup window opens on first launch. You can come back to it any time from **WreckBox → Setup…**.

- **Library:** your music goes to `Music/DJ Library` in your home folder.
- **Playlists:** click **+** next to Playlists and paste a Spotify, YouTube or YouTube Music playlist link.
  To sync all your Spotify playlists and Liked Songs, connect **your own** Spotify:
  1. Open https://developer.spotify.com/dashboard, log in with your Spotify account and click **Create app**.
  2. Give it any name. Set the Redirect URI to `http://127.0.0.1:8888/callback`, tick **Web API**, then **Save**.
  3. Copy the **Client ID** into WreckBox and click **Connect**.

  Nobody else's Spotify is used, so this only ever sees your own playlists. Spotify only runs developer apps for
  **Premium** accounts. Without Premium, add playlists from YouTube / YouTube Music links instead.
- **Soulseek:** enter your Soulseek username and password. If you don't have an account, pick a new name and one is created the first time you sign in.
- **YouTube:** sign in to YouTube in your browser (Chrome, Brave, Edge, Firefox or Safari) and pick that browser.
  The first time, macOS asks to let WreckBox use "Chrome Safe Storage" (or your browser's). Enter your Mac password and choose
  **Always Allow**. For Safari, give WreckBox Full Disk Access instead.

## 4. Use a VPN when downloading

Soulseek shows your IP address to the people you download from. Turn on your VPN before any download.
WreckBox reminds you each time one starts.

## Friends' music

Under **Friends** you can paste a friend's key (`WBX-…`) or open their share link to stream and download what they
shared. Under **Share yours** you can make keys for your own library or a single playlist, and revoke them any time.
Friends can reach your music only while your WreckBox is open and **Use from anywhere** is on (Sync to phone).

## Android

Install **WreckBox.apk** from the same release page. Android asks you to allow installing from your browser or
Files app the first time.

## If something goes wrong

- **"WreckBox is damaged and can't be opened"**: the download was quarantined. In Terminal run
  `xattr -dr com.apple.quarantine /Applications/WreckBox.app`, then open it again.
- **Report a bug:** use the bug button in the app.
