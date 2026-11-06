import { expect, test } from "./support/harness";

// Settings is the admin surface: every tab must at least render, and
// the API-tokens tab must mint a token and reveal it exactly once.

const TABS = ["General", "Users", "API tokens", "Background jobs", "About"];

test("every settings tab renders", async ({ page }) => {
  await page.goto("/settings");
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
  for (const name of TABS) {
    await page.getByRole("tab", { name }).click();
    await expect(page.getByRole("tab", { name })).toHaveAttribute("aria-selected", "true");
  }
});

test("the API tokens tab mints a token and shows it once", async ({ page }) => {
  await page.goto("/settings?tab=tokens");
  // The header's button; the empty state offers one of the same name.
  await page.getByRole("button", { name: "New token", exact: true }).last().click();
  await page.getByLabel("Name").fill("Playwright token");
  await page.getByRole("button", { name: /create token/i }).click();
  await expect(page.getByText(/won't be shown again/i)).toBeVisible();
  // The plaintext, not the truncated echo the token list shows beside it.
  const token = (await page.locator("code").getByText(/^stream_/).textContent()) ?? "";
  expect(token).toMatch(/^stream_[0-9a-f]+$/);
  await page.getByRole("button", { name: /copied it/i }).click();
  await expect(page.getByText("Playwright token")).toBeVisible();
});
