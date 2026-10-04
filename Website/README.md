# Takely website

Static pages for Cloudflare Pages (or any static host): `index.html` (features, pricing, Paddle checkout that hands the buyer their key), `terms.html`, `privacy.html`, `refunds.html`.

1. Fill in `config.js`: your legal name (as registered with Paddle), support email, price label, download link, and — once Paddle is set up — the client-side token, price ID and the license server URL.
2. Read the legal pages and adjust them to your situation (they're a starting point, not legal advice).
3. Publish: Cloudflare dashboard › Workers & Pages › Create › Pages › upload this folder (or connect the repository with `Website` as the root). Add your custom domain.
4. In Paddle: add the domain under Checkout settings (approved domains), set the default payment link to this site, and submit the site for review.
