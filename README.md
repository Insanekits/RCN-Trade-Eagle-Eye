# RCN Trade Eagle Eye

A lightweight, static Trade Eagle Eye dashboard for RCN trade monitoring. The repository is organised in the same simple deployment style as the referenced Logistics Control Tower UI: `data/`, `scripts/`, `index.html`, `package.json`, and `vercel.json` live at the repository root.

## Repository layout

```text
data/                  Dashboard JSON data consumed by the UI
scripts/               Workbook sync utilities
index.html             Static dashboard application
package.json           Local run and sync commands
sync.env               Workbook path and sync settings
vercel.json            Static Vercel routing and cache headers
```

## Workbook configuration

The `sync.env` file is configured with the MIS tracker workbook path shared for this repo:

```env
EXCEL_WORKBOOK_PATH="C:\Users\KrishnaVajramati\OneDrive - Valency International Pte Ltd\VI-RCN - OPERATIONS\CASHEW 2026-27\MIS TRACKER 2026-27\RCN MIS 2026-27 TRACKER V01.xlsx"
OUTPUT_JSON=data/trade_eagle_eye.json
SHEET_NAME=
```

Leave `SHEET_NAME` blank to use the active worksheet, or set it to a specific worksheet tab name.

## Run locally

```bash
npm run dev
```

Then open <http://localhost:5173>.

## Sync Excel data

The sync script reads the workbook configured in `sync.env` and writes `data/trade_eagle_eye.json`.

```bash
python -m pip install openpyxl
npm run sync
```

If the workbook is not available on the current machine, the dashboard will continue to use the checked-in sample JSON until the sync command is run in the correct Windows/OneDrive environment.

## Validate sync configuration

```bash
npm run validate
```

This checks the `sync.env` values without opening the Excel workbook.

## Deploy

This is a static site. Vercel can serve it directly from the repository root using the included `vercel.json` rewrite rules.
