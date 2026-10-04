// Fills in the settings (config.js), and runs the Paddle checkout: after paying, the buyer gets their key here.
const C = window.TAKELY;
document.querySelectorAll("[data-config]").forEach((el) => (el.textContent = C[el.dataset.config] || el.textContent));
document.querySelectorAll("[data-mailto]").forEach((el) => (el.href = `mailto:${C.contactEmail}`));
document.querySelectorAll("[data-download]").forEach((el) => (C.downloadURL ? (el.href = C.downloadURL) : el.classList.add("secondary")));
document.querySelectorAll("[data-source]").forEach((el) => (C.sourceURL ? (el.href = C.sourceURL) : el.remove()));
document.querySelectorAll("[data-year]").forEach((el) => (el.textContent = new Date().getFullYear()));

const dialog = document.querySelector(".dialog");
function show(html) {
  if (!dialog) return;
  dialog.querySelector(".content").innerHTML = html;
  dialog.classList.add("open");
}
dialog?.addEventListener("click", (e) => { if (e.target === dialog || e.target.matches("[data-close]")) dialog.classList.remove("open"); });

/// After payment, the license server has the key once Paddle has told it (usually within seconds).
async function fetchKey(transactionId) {
  for (let attempt = 0; attempt < 30; attempt++) {
    const response = await fetch(`${C.licenseServer}/v1/purchases/${encodeURIComponent(transactionId)}/key`).catch(() => null);
    if (response?.ok) return (await response.json()).key;
    await new Promise((r) => setTimeout(r, 2000));
  }
  return null;
}

async function delivered(transactionId) {
  show(`<h2>Thank you!</h2><p>Preparing your license key…</p>`);
  const key = await fetchKey(transactionId);
  if (!key || !/^TAKELY-[0-9A-Z-]{20,40}$/.test(key)) {
    show(`<h2>Payment received</h2><p>Your key is taking longer than usual. It's also sent by email; if it doesn't arrive, write to <a href="mailto:${C.contactEmail}">${C.contactEmail}</a> with your receipt.</p><button class="button" data-close>Close</button>`);
    return;
  }
  show(`<h2>Your Takely Pro key</h2><div class="key">${key}</div>
    <p>In Takely, open <b>Settings › License</b>, paste it and click <b>Activate</b>. It works on up to 3 Macs. Keep it somewhere safe; it's also in your email.</p>
    <button class="button" data-close>Done</button>`);
}

if (C.paddleClientToken && window.Paddle) {
  if (C.paddleEnvironment !== "production") Paddle.Environment.set("sandbox");
  Paddle.Initialize({
    token: C.paddleClientToken,
    eventCallback: (event) => { if (event.name === "checkout.completed") delivered(event.data.transaction_id); },
  });
}
document.querySelectorAll("[data-buy]").forEach((el) =>
  el.addEventListener("click", (e) => {
    e.preventDefault();
    if (!C.paddleClientToken || !window.Paddle || !C.priceId) {
      show(`<h2>Not on sale yet</h2><p>Takely Pro will be available soon.</p><button class="button" data-close>OK</button>`);
      return;
    }
    Paddle.Checkout.open({ items: [{ priceId: C.priceId, quantity: 1 }] });
  }),
);
