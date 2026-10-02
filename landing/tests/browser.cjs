// Run against a local preview: AMANU_PREVIEW_URL=http://127.0.0.1:8765 node tests/browser.cjs
// Requires Playwright and its Chromium browser.
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
    const base = process.env.AMANU_PREVIEW_URL || 'http://127.0.0.1:8765';
    const browser = await chromium.launch({ headless: true });
    try {
        for (const [platform, userAgent] of [
            ['mac', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'],
            ['mac', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1'],
            ['windows', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'],
        ]) {
            for (const [language, colorScheme] of ['en', 'ru'].flatMap(lang => ['light', 'dark'].map(theme => [lang, theme]))) {
                const context = await browser.newContext({ userAgent, colorScheme, deviceScaleFactor: platform === 'windows' || userAgent.includes('iPhone') ? 3 : 2,
                    viewport: userAgent.includes('iPhone') ? { width: 390, height: 844 } : { width: 1280, height: 900 } });
                const page = await context.newPage();
                const events = [];
                await page.route('**/m?**', async route => {
                    events.push(new URL(route.request().url()));
                    await route.fulfill({ status: 204 });
                });
                await page.goto(`${base}/${language}/`);
                const windows = page.locator('a[href$="/Amanu-stable-Setup.exe"]');
                assert.equal(await windows.count(), 2, `${language}: Windows download in hero and footer`);
                const mac = page.locator('a[href$="-macos-universal.dmg"]');
                assert.equal(await mac.count(), 2, `${language}: macOS download in hero and footer`);
                for (const link of [windows.first(), mac.first()]) {
                    // Cancel navigation, keeping the real click and analytics handler active.
                    await link.evaluate(el => el.addEventListener('click', e => e.preventDefault()));
                    await link.click();
                }
                await page.waitForTimeout(100);
                assert.equal(events.filter(url => url.searchParams.get('p') === 'download_clicked').length, 2,
                    `${language}: both platform clicks counted exactly once`);
                const imageSources = await page.locator('main picture img').evaluateAll(images => images.map(img => img.currentSrc));
                assert.equal(imageSources.length, 2);
                for (const src of imageSources) {
                    assert.equal(src.includes('/windows/'), platform === 'windows', `${userAgent}: ${src}`);
                }
                assert.equal(await page.locator('main picture img').evaluateAll(images => images.every(img => img.complete && img.naturalWidth > 0)), true,
                    `${language}/${platform}: the selected screenshot files load`);
                const resolution = await page.locator('main picture img').evaluateAll(images => images.map(img => ({
                    width: img.getBoundingClientRect().width,
                    pixels: img.naturalWidth,
                    required: img.getBoundingClientRect().width * devicePixelRatio,
                })));
                for (const image of resolution) {
                    assert.ok(image.pixels + 1 >= image.required,
                        `${language}/${platform}: screenshot has ${image.pixels}px for ${image.required}px Retina display`);
                }
                assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true,
                    `${language}/${platform}: no horizontal page overflow`);
                await context.close();
            }
        }
        console.log('PASS: macOS/iPhone/Windows screenshots at Retina resolution and both download events, EN/RU, light/dark');
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
