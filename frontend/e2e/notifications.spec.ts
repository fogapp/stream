import { expect, test } from "./support/harness";

// The bell in the sidebar counts unread notifications; its page is where
// they can be read and cleared. Seeded: two unread rows, one with a link
// (lib/tasks/e2e.rake). The specs run in order and share the seed, so the
// first reads one row and the second clears the rest — whatever else has
// arrived by then, since the harness's server runs jobs as they come.

test("following a notification's link marks it read and opens its page", async ({ page }) => {
  // Counted from what's there: jobs run by earlier specs (a Grid reminder)
  // may have added rows of their own beside the seeded two.
  await page.goto("/notifications");
  await expect(page.getByText("TV is not visible from inside Stream")).toBeVisible();
  const unread = page.getByRole("button", { name: "Mark read" });
  const before = await unread.count();
  expect(before).toBeGreaterThanOrEqual(2);
  const read = page.waitForResponse((response) => /\/notifications\/[^/]+\/read$/.test(response.url()));
  await page.getByRole("link", { name: /3 new titles found/ }).click();
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
  // A full reload would cancel the read still on its way.
  await read;
  await page.goto("/notifications");
  await expect(unread).toHaveCount(before - 1);
});

test("the bell opens the notifications page and marking all read clears its count", async ({ page }) => {
  await page.goto("/");
  const bell = page.getByRole("link", { name: /^Notifications, [1-9]\d* unread$/ }).first();
  await expect(bell).toBeVisible();
  await bell.click();

  await expect(page.getByRole("heading", { name: "Notifications" })).toBeVisible();
  await expect(page.getByText("TV is not visible from inside Stream")).toBeVisible();
  await expect(page.getByText("Library unreachable")).toBeVisible();

  await page.getByRole("button", { name: "Mark all read" }).click();
  await expect(page.getByRole("link", { name: "Notifications, 0 unread" }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Mark read" })).toHaveCount(0);
});
