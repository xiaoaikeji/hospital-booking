import assert from 'node:assert/strict'
import { test } from 'node:test'
import { configurationResult } from '../request/http.js'
import { phoneAuthorizationOutcome } from '../utils/phone-authorization.js'

test('only a disabled response for the current app suspends service', () => {
  const data = { provider: 'wechat', appid: 'wxA', status: 'disabled' }
  const response = { statusCode: 403, data }
  assert.deepEqual(configurationResult('wxA', response), { status: 'disabled' })
  assert.deepEqual(configurationResult('wxB', response), { status: 'error' })
  assert.deepEqual(configurationResult('wxA', { statusCode: 403, data: { error: 'forbidden' } }), { status: 'error' })
  assert.deepEqual(configurationResult('wxA', { statusCode: 503, data }), { status: 'error' })
  const active = { ...data, status: 'active', links: { home_banner: [], profile_menu: [] } }
  assert.deepEqual(configurationResult('wxA', { statusCode: 200, data: active }), { status: 'ready', config: active })
  assert.deepEqual(configurationResult('wxA', { statusCode: 200, data: { ...active, links: {} } }), { status: 'error' })
})

test('a phone authorization code, cancellation and service errors have distinct outcomes', () => {
  assert.equal(phoneAuthorizationOutcome({ code: 'fixture-code', errMsg: 'getPhoneNumber:ok' }), 'authorized')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail user deny' }), 'denied')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail cancel' }), 'denied')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail jsapi has no permission' }), 'failed')
  assert.equal(phoneAuthorizationOutcome({ code: ' ', errMsg: 'getPhoneNumber:ok' }), 'failed')
  assert.equal(phoneAuthorizationOutcome(null), 'failed')
})
