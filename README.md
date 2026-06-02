# RCN Trade Eagle Eye

Valency RCN Trade Eagle Eye dashboard for shipment execution, origin dues, documentation, quality, buyer, forwarder, and risk monitoring.

## Live Workbook Flow

The dashboard first tries to load the latest deployed workbook from:

```text
data/rcn-mis.xlsx
```

That file is refreshed from the local OneDrive-synced MIS workbook by the sync script. If no workbook has been synced yet, the dashboard keeps the manual Excel upload screen available.

## OneDrive Sync

Copy the template and keep your local path private:

```powershell
Copy-Item scripts\sync.env.example scripts\sync.env
```

`scripts/sync.env` is gitignored. It should contain:

```env
RCN_MIS_SOURCE="C:\Users\KrishnaVajramati\OneDrive - Valency International Pte Ltd\VI-RCN - OPERATIONS\CASHEW 2026-27\MIS TRACKER 2026-27\Trade Ops relates\RCN MIS 2026-27 TRACKER V01.xlsx"
RCN_MIS_DEST=data/rcn-mis.xlsx
SYNC_BRANCH=main
```

Run on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync.ps1
```

The script copies the workbook into `data/rcn-mis.xlsx`, commits it, and pushes `main`, so Vercel redeploys with the latest file.

## OpenAI Chatbot

`api/chat.py` is a Vercel Python serverless function for Vee Patron. The OpenAI API key stays on the server and is never sent to the browser.

Set these Vercel environment variables:

```text
OPENAI_API_KEY=your key
OPENAI_MODEL=gpt-4o-mini
```

`OPENAI_MODEL` is optional. If `/api/chat` is unavailable or the key is not configured, Vee Patron falls back to the built-in dashboard rules.

## Local Run

Static local server:

```bash
npm run dev
```

For local `/api/chat` testing, use Vercel dev with `.env.local`:

```bash
vercel dev
```
