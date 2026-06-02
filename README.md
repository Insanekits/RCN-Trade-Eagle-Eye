# RCN Trade Eagle Eye

Upload-first Valency RCN Logistics Control Tower dashboard for shipment execution, origin dues, documentation, quality, buyer, forwarder, and risk monitoring.

## What the dashboard does

The dashboard starts blank and asks the user to upload an Excel or CSV MIS workbook. It uses the browser-side SheetJS parser from CDN to read the selected sheet, auto-prefers `MIS 2026`, and converts workbook rows into dashboard records.

After analysis it renders:

- Overview KPIs, trade position mix, and execution stage flow.
- Origin Dues Radar and Origin Dues Matrix with contract-level pending checkpoints.
- Shipment search and CSV export.
- Document, quality, buyer, forwarder, risk, and data map views.
- A small in-page assistant named Vee for quick MIS summaries after upload.

No MIS data is embedded in the HTML file.

## Repository layout

```text
index.html             Static upload-first dashboard application
package.json           Local static-server command
vercel.json            Static Vercel routing and cache headers
```

## Run locally

```bash
npm run dev
```

Then open <http://localhost:5173>.

## Deploy

This is a static site. Vercel can serve it directly from the repository root using the included `vercel.json` rewrite rule.
