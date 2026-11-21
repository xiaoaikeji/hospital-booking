import assert from 'node:assert/strict'
import { test } from 'node:test'
import { effectiveWebviewUrl } from '../utils/page-link.js'

const url = 'https://example.test/booking'
const link = { id: 71, link_type: 'webview', url }
const resolve = (status, entry = link, openUrl = '') => effectiveWebviewUrl({
  id: '71', status, links: { home_banner: [], profile_menu: entry ? [entry] : [] }, openUrl,
})

test('a pending or failed check retains only a webpage already opened on this page', () => {
  for (const status of ['loading', 'error']) {
    assert.equal(resolve(status, link, url), url)
    assert.equal(resolve(status), '')
  }
  assert.equal(resolve('ready'), url)
  assert.equal(resolve('ready', link, url), url)
})

test('confirmed disable, deletion and destination changes replace the open URL', () => {
  assert.equal(resolve('disabled', link, url), '')
  assert.equal(resolve('ready', null, url), '')
  assert.equal(resolve('ready', { ...link, link_type: 'page' }, url), '')
  const changedUrl = 'https://example.test/new-booking'
  assert.equal(resolve('ready', { ...link, url: changedUrl }, url), changedUrl)
})
