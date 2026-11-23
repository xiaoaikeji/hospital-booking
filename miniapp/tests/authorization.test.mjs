import assert from 'node:assert/strict'
import { test } from 'node:test'
import { configurationResult, responseData } from '../request/http.js'
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

test('responseData enforces expectedStatus and marks appDisabled only for the current app', () => {
  assert.equal(responseData('wxA', { statusCode: 204, data: '' }, 204), '')
  assert.throws(() => responseData('wxA', { statusCode: 200, data: '<html>维护中</html>' }, 204), /尚未确认/)
  assert.throws(() => responseData('wxA', { statusCode: 503, data: '<html>维护中</html>' }, 204), { statusCode: 503, appDisabled: false })
  assert.throws(
    () => responseData('wxA', { statusCode: 403, data: { provider: 'wechat', appid: 'wxA', status: 'disabled' } }),
    { statusCode: 403, appDisabled: true },
  )
  assert.throws(
    () => responseData('wxB', { statusCode: 403, data: { provider: 'wechat', appid: 'wxA', status: 'disabled' } }),
    { statusCode: 403, appDisabled: false },
  )
  assert.throws(
    () => responseData('wxA', { statusCode: 503, data: { provider: 'wechat', appid: 'wxA', status: 'disabled' } }),
    { statusCode: 503, appDisabled: false },
  )
})

test('a phone authorization code, cancellation and service errors have distinct outcomes', () => {
  assert.equal(phoneAuthorizationOutcome({ code: 'fixture-code', errMsg: 'getPhoneNumber:ok' }), 'authorized')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail user deny' }), 'denied')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail cancel' }), 'denied')
  assert.equal(phoneAuthorizationOutcome({ errMsg: 'getPhoneNumber:fail jsapi has no permission' }), 'failed')
  assert.equal(phoneAuthorizationOutcome({ code: ' ', errMsg: 'getPhoneNumber:ok' }), 'failed')
  assert.equal(phoneAuthorizationOutcome(null), 'failed')
})
