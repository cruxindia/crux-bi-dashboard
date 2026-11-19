# Upload from Google Drive

Prepared by Shantanu Suravase · 18-Nov-2026 · wave 112, set up in wave 113, links without sign-in in wave 113 (second request)

The upload page (Admin → Uploads) has a **Pick from Google Drive** card with one button per report folder: **Zonal Tracker**, **Point wise**,
**Case wise**. The folders are shared "Anyone with the link", so the buttons work for every admin **without a Google sign-in**:

1. Press **All 3 folders — check for new files** (or one folder button). The dashboard lists the folders and reads the files that are new, or changed
   since they were last imported, in the last 14 days (up to 25 per folder; Excel lock files "~$…" are skipped; Google Sheets are exported as .xlsx).
2. The files go through exactly the same steps as a dropped file: file type detected, personal data removed in the browser, checks — and land in the
   **review list**: a tick box per file, what is inside (rows by month, or the report date), location group and month, and the verdict. A file whose
   name says another month than its rows is flagged and not ticked; another copy of the same report is skipped but can be ticked instead; a file
   already imported cannot be ticked. Open "All files in …" to add any other file to the review (**Add ticked files to the review**).
3. Press **Import N ticked files**. Nothing is written before that. The files are registered on the server at once; if the page is closed before a
   file's turn, the next admin page opened (any device) reads it again from Drive and sends it.

**Status:** set up on 18-Nov-2026 in the Google Cloud project "BI Dashboard"; folder links work without sign-in (tested with all three folders).

## Folder links (admin, once)

Admin → Uploads → Pick from Google Drive → **Folder links**: paste each folder's link (in Google Drive: Share → General access "Anyone with the
link" → Copy link) and press **Save**. The link is kept in the database (`bi.app_setting`, key `google_drive`) and shown to admins only — never in
this public repository, because a link opens the folder.

Anyone who gets a folder link can open its files, including applicant details in Case Wise files. If you limit sharing to Crux accounts instead,
the buttons fall back to Google sign-in (each admin signs in with a company Google account; the OAuth client below is already set up).

## What the dashboard needs from Google (done 18-Nov-2026; kept for reference)

Do this with the Google account that owns or can see the three folders (a Google Workspace admin account is best).

1. **Project** — open <https://console.cloud.google.com/>, create a project (for example "Crux BI") or pick an existing one.
2. **APIs** — APIs & Services → Library → enable **Google Drive API** and **Google Picker API**.
3. **Consent screen** — APIs & Services → OAuth consent screen (Google Auth Platform → Branding / Audience):
   - App name "Crux BI", support e-mail, developer contact e-mail.
   - Audience: **Internal** if everyone who uploads uses the company Google Workspace domain. If uploaders use personal Gmail
     accounts, choose **External** and add each uploader under *Test users* (or publish the app).
   - Data access / scopes: add `https://www.googleapis.com/auth/drive.file` (access only to the files a person picks).
4. **OAuth client ID** — APIs & Services → Credentials → Create credentials → OAuth client ID → Application type **Web application**.
   Authorised JavaScript origins: `https://cruxindia.github.io` (no path, no trailing slash). No redirect URI is needed. Copy the
   **Client ID** (it ends with `.apps.googleusercontent.com`).
5. **Browser API key** — Credentials → Create credentials → API key → Edit:
   - Application restrictions: **Websites** → `https://cruxindia.github.io/*`
   - API restrictions: **Restrict key** → Google Picker API (and Google Drive API).
   Copy the key (it starts with `AIza`). The restriction means the key only works from the dashboard's own address.
6. **Project number** — Cloud console → the project menu → Project settings → **Project number** (digits only).
7. **Dashboard** — Admin login → Admin workspace → Uploads → *Pick from Google Drive* → **Set up Drive access** → paste the client
   ID, the API key and the project number → **Save Drive settings**. The three folder IDs are already filled in; change them here if
   the folders move.

## Google sign-in (fallback only)

Only when a folder is not shared by link: the card offers "Open … with Google sign-in". Google asks the admin to sign in and to allow "Crux BI"
to see the files they pick (once per browser session). Allow pop-ups for the dashboard page if the browser blocks the sign-in window.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| "The API developer key is invalid." | Google Picker API (and Google Drive API) not enabled in the project, or not ticked in the key's API restrictions, or the page opened from an address the key does not allow. Enable both APIs; key → API restrictions → Google Picker API and Google Drive API; Website restrictions → `https://cruxindia.github.io/*`. Changes can take a few minutes. |
| "Access blocked" / "not allowed" at sign-in | The account is outside the company Google Workspace (audience Internal), or the OAuth client does not list `https://cruxindia.github.io` as an authorised JavaScript origin. |
| The sign-in window does not appear | The browser blocked the pop-up; allow pop-ups for the dashboard and press the folder button again. |
| The folder opens empty | The signed-in account cannot open that folder; share it with them (viewer is enough). |

## Notes and limits

- With link sharing, no Google account is needed; with sign-in, each person must be able to open the folder in Google Drive.
- Native Google Sheets are exported to .xlsx before reading; uploaded .xlsx / .xls files are read as they are.
- The settings are stored in the database (`bi.app_setting`, key `google_drive`) and shown to admins only; the audit log records that
  a value was set, never the value. Changing a setting: same form. Removing access: delete the OAuth client or API key in Google Cloud.
- Nothing runs on a schedule: files are read only when an admin picks them. An automatic nightly pick-up from the folders would need a
  server-side Google service account with read access to the folders; ask if you want that as a next step.
