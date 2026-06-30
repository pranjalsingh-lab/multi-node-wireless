// Backend (API) base URL - read by index.html before it makes any request.
//
// Local dev (the backend serves this page itself): leave empty → same origin.
// Production (this page on Vercel, API on Render/Railway/Fly): set the full
// backend URL, no trailing slash, e.g.
//
//   window.API_BASE = "https://wireless-device-lab-api.onrender.com";
//
window.API_BASE = "wireless-device-lab-api-production.up.railway.app";
