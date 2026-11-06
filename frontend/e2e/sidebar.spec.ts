import { expect, test } from "./support/harness";

// The sidebar's "…": move and hide items for this profile, bring a hidden
// one back from More, and start a library scan.
test("sidebar items can be moved, hidden, brought back and scanned", async ({ page, session }) => {
  const headers = { Authorization: `Bearer ${session.token}` };
  await page.request.put("/api/v1/sidebar", { headers, data: { order: [], hidden: [] } });
  try {
    await page.goto("/");
    const nav = page.getByRole("navigation");
    const labels = () => nav.getByRole("link").allInnerTexts();

    // Hidden until the row is hovered.
    const more = nav.getByRole("button", { name: "More for Movies" });
    await expect(more).toHaveCSS("opacity", "0");
    await nav.getByRole("link", { name: "Movies" }).hover();
    await expect(more).toHaveCSS("opacity", "1");

    // The first item can't go up.
    await nav.getByRole("link", { name: "Corpus" }).hover();
    await nav.getByRole("button", { name: "More for Corpus" }).click();
    await expect(page.getByRole("menuitem", { name: "Move up" })).toHaveAttribute("aria-disabled", "true");
    await page.keyboard.press("Escape");

    await nav.getByRole("link", { name: "Movies" }).hover();
    await more.click();
    await page.getByRole("menuitem", { name: "Move down" }).click();
    const tvFirst = async () => {
      const order = await labels();
      return order.includes("Movies") && order.indexOf("TV Shows") < order.indexOf("Movies");
    };
    await expect.poll(tvFirst).toBe(true);

    // It sticks across a reload: the profile keeps it.
    await page.reload();
    await expect.poll(tvFirst).toBe(true);

    await nav.getByRole("link", { name: "Playlists" }).hover();
    await nav.getByRole("button", { name: "More for Playlists" }).click();
    await page.getByRole("menuitem", { name: "Hide from sidebar" }).click();
    await expect(nav.getByRole("link", { name: "Playlists" })).toHaveCount(0);
    await nav.getByRole("button", { name: "More (1)" }).click();
    await expect(nav.getByRole("link", { name: "Playlists" })).toBeVisible();
    await nav.getByRole("link", { name: "Playlists" }).hover();
    await nav.getByRole("button", { name: "More for Playlists" }).click();
    await page.getByRole("menuitem", { name: "Show in sidebar" }).click();
    await expect(nav.getByRole("button", { name: /^More \(/ })).toHaveCount(0);

    // An admin scans a library from its "…".
    await nav.getByRole("link", { name: "TV Shows" }).hover();
    await nav.getByRole("button", { name: "More for TV Shows" }).click();
    const scanned = page.waitForResponse((response) => /\/api\/v1\/libraries\/[^/]+\/scan$/.test(response.url()));
    await page.getByRole("menuitem", { name: "Scan library files" }).click();
    expect((await scanned).status()).toBe(202);
    await expect(page.getByText("Scanning TV Shows…")).toBeVisible();
  } finally {
    await page.request.put("/api/v1/sidebar", { headers, data: { order: [], hidden: [] } });
  }
});

// The desktop sidebar folds to a rail of icons, and this browser remembers it.
test("the sidebar collapses to icons and stays collapsed", async ({ page }) => {
  await page.goto("/");
  const aside = page.getByRole("complementary", { name: "Navigation" });
  const nav = page.getByRole("navigation");
  await expect(nav.getByRole("link", { name: "Movies" })).toBeVisible();

  await page.getByRole("button", { name: "Collapse sidebar" }).click();
  await expect.poll(async () => (await aside.boundingBox())?.width).toBe(64);
  // Still a named link, just no "…" and no visible label.
  await expect(nav.getByRole("link", { name: "Movies" })).toHaveAttribute("title", "Movies");
  await expect(nav.getByRole("button", { name: "More for Movies" })).toHaveCount(0);

  await page.reload();
  await expect(page.getByRole("button", { name: "Expand sidebar" })).toBeVisible();
  await page.getByRole("button", { name: "Expand sidebar" }).click();
  await expect(nav.getByRole("button", { name: "More for Movies" })).toHaveCount(1);
  await expect.poll(async () => (await aside.boundingBox())?.width).toBe(240);
});
