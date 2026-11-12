# Digital Supply Chain 360

A mobile-first, interactive digital control tower for teaching and exploring an end-to-end supply chain. The project uses **simulated data only** and is designed to run as a static website.

## What is included

- End-to-end flow: supplier → factory → warehouse → transport → distribution → customer
- Interactive 3D supply-chain network (Three.js)
- Physical goods flow and digital information flow
- Simulated KPI cards, event feed, and disruption scenario
- Responsive layout for phones, tablets, and classroom displays

## Run locally

Because the app uses JavaScript modules, serve the folder through a local web server:

```bash
python -m http.server 8000
```

Then open http://localhost:8000.

## Deploy on Render (free static site)

1. Create a **Static Site** on Render and connect this repository.
2. Build command: leave empty.
3. Publish directory: `.`
4. Deploy.

No backend, database, API key, or live company connection is required.

## Project files

- `index.html` — app structure
- `styles.css` — responsive visual system
- `app.js` — Three.js scene and simulated interactions

## Data and learning note

All figures, locations, events, and scenarios are fictional demonstration data. They are intended for classroom learning, not operational decisions.
