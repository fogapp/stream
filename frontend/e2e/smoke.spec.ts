import { HARNESS_USER, expect, test } from "./support/harness";

// The path a person walks on day one: sign in and land on Home. Real SPA,
// real API, seeded household.

test("the login form signs in and lands on Home", async ({ browser }) => {
  // A fresh context without the planted token: this one spec exercises the
  // form itself.
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("/login");
  await page.getByLabel("Email").fill(HARNESS_USER.email);
  await page.getByLabel("Password").fill(HARNESS_USER.password);
  // Exact: the login page also offers "Sign in with a passkey".
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Continue watching" })).toBeVisible();
  await context.close();
});

test("the sidebar lists each library", async ({ page }) => {
  await page.goto("/");
  const nav = page.getByRole("navigation");
  await expect(nav.getByRole("link", { name: "Movies" })).toBeVisible();
  await expect(nav.getByRole("link", { name: "TV Shows" })).toBeVisible();
});

test("a TV's QR code survives signing in: /pair keeps its code", async ({ browser }) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("/pair?code=abcd-efgh");
  await expect(page).toHaveURL(/\/login$/);
  await page.getByLabel("Email").fill(HARNESS_USER.email);
  await page.getByLabel("Password").fill(HARNESS_USER.password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).toHaveURL(/\/pair\?code=abcd-efgh$/);
  await expect(page.getByLabel("Code")).toHaveValue("ABCD-EFGH");
  await context.close();
});
