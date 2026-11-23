import assert from 'node:assert/strict'
import { test } from 'node:test'
import { deviceContext, entrySource, loginFailureState } from '../utils/login-context.js'
import { createSessionClient } from '../request/session.js'

test('a real scan carries its launch code and decoded channel, silent renewal has no entry', async () => {
  const entry = entrySource({ scene: 1047, query: { scene: encodeURIComponent('门诊大厅') } })
  assert.deepEqual(entry, { launch_scene: 1047, channel_scene: '门诊大厅' })
  assert.equal(entrySource({}), undefined)
  const exchanges = []
  const client = createSessionClient({
    loginCode: async () => 'fixture', save() {}, changed() {}, deviceContext: () => ({ device_model: 'fixture-model' }),
    send: async (path, options) => {
      if (path === 'session') {
        exchanges.push(options.data)
        return { token: String(exchanges.length), expires_at: new Date(Date.now() + 60000).toISOString() }
      }
      if (options.token === '1') throw Object.assign(new Error(), { code: 'session_expired', statusCode: 401 })
      return {}
    },
  })
  await client.signIn(entry)
  await client.request('me')
  assert.deepEqual(exchanges, [{ code: 'fixture', device_model: 'fixture-model', ...entry }, { code: 'fixture', device_model: 'fixture-model' }])
})

test('device context drops tools, errors and unknown fields independently', () => {
  assert.deepEqual(deviceContext(() => ({ platform: 'devtools', model: 'iPhone', system: 'iOS 17' })), {})
  assert.deepEqual(deviceContext(() => { throw new Error('not supported') }), {})
  assert.deepEqual(deviceContext(() => ({ platform: 'ios', model: 'unknown', system: 'iOS 17' })),
    { device_platform: 'ios', operating_system: 'iOS 17' })
  assert.deepEqual(deviceContext(() => ({ platform: 'android', model: 'Fixture', osName: 'Android', osVersion: '14' })),
    { device_platform: 'android', device_model: 'Fixture', operating_system: 'Android 14' })
})

test('loginFailureState offers profile retry only for temporary failures after login succeeded', () => {
  const unavailable = Object.assign(new Error('服务暂不可用，请重试'), { statusCode: 503 })
  assert.deepEqual(loginFailureState(unavailable, true), { profileRetry: true, feedback: '已登录，暂时无法读取资料' })
  assert.deepEqual(loginFailureState(unavailable, false), { profileRetry: false, feedback: '服务暂不可用，请重试' })
  assert.deepEqual(
    loginFailureState(Object.assign(new Error('请重新登录'), { statusCode: 401, code: 'session_expired' }), true),
    { profileRetry: false, feedback: '请重新登录' },
  )
  assert.deepEqual(
    loginFailureState(Object.assign(new Error('账号已停用'), { statusCode: 403, code: 'account_disabled' }), false),
    { profileRetry: false, feedback: '账号已停用' },
  )
  assert.deepEqual(
    loginFailureState(Object.assign(new Error('服务暂不可用，请重试'), { statusCode: 403, appDisabled: true }), false),
    { profileRetry: false, feedback: '服务暂不可用，请重试' },
  )
})
