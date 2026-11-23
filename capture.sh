#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
: "${CAPTURE_URL:?Set CAPTURE_URL to the exact preview URL}"
: "${CAPTURE_DIR:?Set CAPTURE_DIR to the evidence output directory}"
run() {
  /usr/bin/time -p "$@"
}

run mkdir -p "$CAPTURE_DIR"
run node --input-type=module <<'NODE'
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const runtime = join(process.env.HOME, '.local/share/omgithub-playwright')
const require = createRequire(join(runtime, 'package.json'))
const { chromium } = require('playwright')
const config = JSON.parse(readFileSync(join(runtime, process.platform === 'darwin' ? 'metal.json' : 'linux.json'), 'utf8'))
const url = process.env.CAPTURE_URL
const output = process.env.CAPTURE_DIR
const transientStatuses = new Set([408, 429, 500, 502, 503, 504])
let browser

async function timed(label, operation) {
  const started = performance.now()
  try {
    return await operation()
  } finally {
    console.log(`timing ${label}: real ${((performance.now() - started) / 1000).toFixed(2)}s`)
  }
}

try {
  const parsed = new URL(url)
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error(`Unsupported capture URL: ${url}`)
  if (process.platform === 'linux') process.env.DISPLAY ||= ':' + readFileSync(join(runtime, 'display'), 'utf8').trim()
  try {
    browser = await timed('browser launch', () => chromium.launch({ ...config.browser.launchOptions, timeout: 30000 }))
  } catch (error) {
    console.error(`Browser launch failed: ${error.message}`)
    process.exitCode = 75
    throw error
  }

  for (const [name, width, height, isMobile] of [
    ['desktop', 1440, 900, false],
    ['mobile', 390, 844, true]
  ]) {
    let page
    try {
      page = await timed(`${name} page creation`, () => browser.newPage({ viewport: { width, height }, isMobile, hasTouch: isMobile }))
    } catch (error) {
      console.error(`Browser page creation failed (${name}): ${error.message}`)
      process.exitCode = 75
      throw error
    }
    page.setDefaultTimeout(20000)
    const pageErrors = []
    page.on('pageerror', error => pageErrors.push(error.message))
    let response
    try {
      response = await timed(`${name} navigation`, () => page.goto(url, { waitUntil: 'load', timeout: 45000 }))
    } catch (error) {
      console.error(`Navigation failed (${name}): ${error.message}`)
      process.exitCode = 75
      throw error
    }
    if (!response) {
      console.error(`Navigation returned no response (${name})`)
      process.exitCode = 75
      throw new Error('Navigation returned no response')
    }
    if (!response.ok()) {
      const status = response.status()
      console.error(`Preview returned HTTP ${status} (${name})`)
      process.exitCode = transientStatuses.has(status) ? 75 : 1
      throw new Error(`Preview returned HTTP ${status}`)
    }

    try {
      await timed(`${name} content readiness`, async () => {
        await page.waitForFunction(() => {
          const ui = document.querySelector('#ui')
          const canvas = document.querySelector('#c')
          if (!ui || !canvas) return false
          const style = getComputedStyle(ui)
          const rect = ui.getBoundingClientRect()
          return document.readyState === 'complete' && style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0 && canvas.width > 0 && canvas.height > 0 && !!canvas.getContext('2d')
        }, undefined, { timeout: 15000 })
        await page.locator('#play').click({ timeout: 10000 })
        await page.waitForFunction(() => document.querySelector('#start')?.classList.contains('hidden') && document.querySelector('#c')?.width > 0, undefined, { timeout: 5000 })
        await page.waitForTimeout(1000)
      })
    } catch (error) {
      console.error(`Rendered content check failed (${name}): ${error.message}`)
      process.exitCode ||= 1
      throw error
    }
    if (pageErrors.length) {
      console.error(`Page script error (${name}): ${pageErrors.join('; ')}`)
      process.exitCode = 1
      throw new Error('Page script error')
    }
    try {
      await timed(`${name} screenshot`, () => page.screenshot({ path: join(output, `final-${name}.png`), timeout: 30000 }))
    } catch (error) {
      console.error(`Screenshot failed (${name}): ${error.message}`)
      process.exitCode ||= (error.name === 'TimeoutError' || !browser.isConnected() ? 75 : 1)
      throw error
    } finally {
      await timed(`${name} page close`, () => page.close()).catch(error => {
        console.error(`Page cleanup failed (${name}): ${error.message}`)
        process.exitCode ||= 75
      })
    }
    console.log(`Captured ${name}: ${join(output, `final-${name}.png`)}`)
  }
} catch (error) {
  console.error(error.message)
  process.exitCode ||= 1
} finally {
  if (browser) {
    try {
      await timed('browser close', () => browser.close())
    } catch (error) {
      console.error(`Browser cleanup failed: ${error.message}`)
      process.exitCode ||= 75
    }
  }
}
NODE
