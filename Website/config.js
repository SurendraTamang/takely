// Everything to fill in before publishing (see README.md). Shown on every page.
window.TAKELY = {
  seller: "[Your legal name]", // as registered with Paddle
  contactEmail: "[support email]",
  priceLabel: "$49", // what the Pro price shows as (the real price is set in Paddle)
  downloadURL: "", // the DMG, e.g. https://updates.example.com/Takely-0.2.0.dmg
  sourceURL: "", // the open-source repository, e.g. https://github.com/you/takely
  updated: "2026-10-04", // shown on the legal pages
  // Paddle Billing (Paddle › Developer tools › Authentication › client-side token; Catalog › price ID pri_…)
  paddleEnvironment: "sandbox", // "production" when your account is approved
  paddleClientToken: "",
  priceId: "",
  // The license server (Packages/TakelyPro/Server/license), e.g. https://takely-license.you.workers.dev
  licenseServer: "",
};
