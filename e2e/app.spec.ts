import { test, expect } from '@playwright/test';
import site from '../src/site.json';

test.describe('Home page', () => {
  test('has the application name as its title', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(site.name);
  });

  test('shows the main content', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('main')).toBeVisible();
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(site.name);
  });
});

test.describe('Health endpoint', () => {
  test('returns 200', async ({ request }) => {
    const response = await request.get('/api/health');
    expect(response.ok()).toBeTruthy();
    expect((await response.json()).status).toBe('healthy');
  });
});
