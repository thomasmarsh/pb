// tests/click-test.mjs — Playwright diagnostic: click library node, check expansion
import { chromium } from 'playwright';

const browser = await chromium.launch();
const page = await browser.newPage();

const logs = [];
page.on('console', msg => logs.push(msg.text()));

await page.goto('http://localhost:8000');
await page.waitForTimeout(2000);

// Navigate to Explore
const exploreLink = page.locator('a', { hasText: 'Explore' });
await exploreLink.click();
await page.waitForTimeout(2000);

// Count library nodes
const libNodes = await page.locator('.lib-node .tree-node-row').count();
console.log(`Library nodes found: ${libNodes}`);

if (libNodes > 0) {
  const firstLib = page.locator('.lib-node .tree-node-row').first();
  const text = await firstLib.textContent();
  console.log(`Clicking: "${text?.trim().substring(0, 80)}"`);
  await firstLib.click();
  await page.waitForTimeout(1000);

  // Check console diagnostics
  const tnLogs = logs.filter(l => l.includes('[TreeNode]'));
  console.log(`TreeNode logs: ${tnLogs.length}`);
  tnLogs.forEach(l => console.log(`  ${l}`));

  // Check if children appeared
  const childNodes = await page.locator('.lib-node .obj-node, .lib-node .tree-children').count();
  console.log(`Object nodes / children divs: ${childNodes}`);

  // Check expandedNodes size via page.evaluate
  const expandedSize = await page.evaluate(() => {
    // Access the SolidJS store signal — try to find it
    const appEl = document.getElementById('app');
    return appEl ? 'app element exists' : 'no app element';
  });
  console.log(`App element: ${expandedSize}`);

  // Check all tree node rows
  const allRows = await page.locator('.tree-node-row').count();
  console.log(`Total tree-node-rows: ${allRows}`);
}

await browser.close();
