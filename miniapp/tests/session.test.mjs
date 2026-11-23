import assert from 'node:assert/strict'
import { test } from 'node:test'
import { responseData } from '../request/http.js'
import { createSessionClient } from '../request/session.js'

function deferred() {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

const credential = token => ({ token, expires_at: new Date(Date.now() + 3600000).toISOString() })
const expired = () => Object.assign(new Error('expired'), { statusCode: 401, code: 'session_expired' })

function device(send, saved = credential('previous')) {
  const state = { saved, codes: 0 }
  const client = createSessionClient({
    saved, send, loginCode: async () => 'fixture-' + ++state.codes,
    save: value => { state.saved = value }, changed: () => {},
  })
  return { client, state }
}

test('simultaneous and late 401s share a login; reads use the new session', async () => {
  const late = deferred()
  const retried = []
  const { client, state } = device(async (path, { token }) => {
    if (path === 'session') return credential('renewed')
    if (token === 'previous') {
      if (path === 'late') await late.promise
      throw expired()
    }
    retried.push(path)
    return { user_no: 'fixture' }
  })
  const reads = ['first', 'second', 'late'].map(path => client.request(path))
  await Promise.all(reads.slice(0, 2))
  late.resolve()
  assert.deepEqual(await reads[2], { user_no: 'fixture' })
  assert.equal(state.codes, 1)
  assert.deepEqual(retried.sort(), ['first', 'late', 'second'])
})

test('a retried read cannot overwrite the profile after another renewal', async () => {
  const started = deferred()
  const delayed = deferred()
  let logins = 0
  const { client, state } = device(async (path, { token }) => {
    if (path === 'session') return credential('renewed-' + ++logins)
    if (path === 'slow' && token === 'renewed-1') {
      started.resolve()
      await delayed.promise
      return { user_no: 'previous-user' }
    }
    if (token !== 'renewed-2') throw expired()
    return { user_no: 'current-user' }
  })
  const slow = client.request('slow')
  await started.promise
  assert.deepEqual(await client.request('me'), { user_no: 'current-user' })
  delayed.resolve()
  await assert.rejects(slow, /状态已更新/)
  assert.equal(state.codes, 2)
})

test('logout discards a pending exchange and revokes its late credential without touching a later manual login', async () => {
  const started = deferred()
  const delayed = deferred()
  const revoked = []
  let logins = 0
  const { client, state } = device(async (path, { method, token }) => {
    if (method === 'DELETE') return revoked.push(token)
    if (path !== 'session') throw expired()
    if (++logins === 2) return credential('manual')
    started.resolve()
    await delayed.promise
    return credential('discarded')
  })
  const before = client.request('me')
  await started.promise
  await client.signOut()
  await assert.rejects(client.request('me'), /请先登录/)
  assert.equal(state.saved, null)
  await client.signIn()
  delayed.resolve()
  await assert.rejects(before, /退出/)
  assert.equal(state.saved.token, 'manual')
  assert.deepEqual(revoked, ['previous', 'discarded'])
})

test('neither a late profile nor a late 401 restores a signed-out device', async () => {
  const delayed = deferred()
  const started = deferred()
  let reads = 0
  const { client, state } = device(async (path, { method }) => {
    if (method === 'DELETE') return
    if (++reads === 2) started.resolve()
    await delayed.promise
    if (path === 'late') throw expired()
    return { user_no: 'old-user' }
  })
  const outcomes = Promise.allSettled([client.request('me'), client.request('late')])
  await started.promise
  await client.signOut()
  delayed.resolve()
  assert.deepEqual((await outcomes).map(r => r.status), ['rejected', 'rejected'])
  assert.equal(state.codes, 0)
  assert.equal(state.saved, null)
  const restarted = device(() => assert.fail('a guest made a request'), state.saved)
  await assert.rejects(restarted.client.request('me'), /请先登录/)
})

test('one-time phone codes, booking and payment writes are never automatically replayed', async () => {
  for (const path of ['phone_binding', 'appointments', 'payment']) {
    const calls = []
    const { client } = device(async (target, options) => {
      calls.push([target, options.method])
      if (target === 'session') return credential('renewed')
      if (target === 'me') return { user_no: 'fixture' }
      throw expired()
    })
    await assert.rejects(client.request(path, { method: 'POST' }), { code: 'confirmation_required' })
    assert.deepEqual(await client.request('me'), { user_no: 'fixture' })
    assert.deepEqual(calls, [[path, 'POST'], ['session', 'POST'], ['me', 'GET']])
  }
})

test('local expiry renews before sending and network errors keep the Booking session', async () => {
  let timeout = true
  const { client, state } = device(async (path, { token }) => {
    if (path === 'session') return credential('renewed')
    if (timeout) throw new Error('timeout')
    return token
  }, { token: 'stale', expires_at: new Date(0).toISOString() })
  await assert.rejects(client.request('phone_binding', { method: 'POST' }), /timeout/)
  assert.equal(state.saved.token, 'renewed')
  timeout = false
  assert.equal(await client.request('me'), 'renewed')
  assert.equal(state.codes, 1)
})

test('offline logout survives restart as a guest and revokes only the retired credential on reconnect', async () => {
  const offline = device(async () => { throw new Error('offline') }, { ...credential('private-access'), logout_token: 'logout-proof' })
  await assert.rejects(offline.client.signOut(), /offline/)
  assert.equal(offline.state.saved?.token, undefined)
  assert.deepEqual(offline.state.saved, { revocations: ['logout-proof'] })
  const revoked = []
  const restart = device(async (path, { method, token }) => {
    assert.equal(path, 'session')
    assert.equal(method, 'DELETE')
    revoked.push(token)
  }, offline.state.saved)
  await assert.rejects(restart.client.request('me'), /请先登录/)
  await Promise.all([restart.client.retryRevocations(), restart.client.retryRevocations()])
  assert.deepEqual(revoked, ['logout-proof'])
  assert.equal(restart.state.codes, 0)
  assert.equal(restart.state.saved, null)
})

test('a reconnect during a failed logout finishes revocation without touching a new login', async () => {
  const delayed = deferred()
  const retired = []
  const { client, state } = device(async (path, { method, token }) => {
    if (method === 'DELETE') {
      retired.push(token)
      if (retired.length === 1) { await delayed.promise; throw new Error('offline') }
    } else if (path === 'session') return credential('new-device-session')
    else return token
  })
  const offline = assert.rejects(client.signOut(), /offline/)
  await client.signIn()
  const reconnected = client.retryRevocations()
  delayed.resolve()
  await Promise.all([offline, reconnected])
  assert.deepEqual(retired, ['previous', 'previous'])
  assert.equal(state.saved.token, 'new-device-session')
  assert.equal(state.saved.revocations, undefined)
  assert.equal(await client.request('me'), 'new-device-session')
})

const disabled = () => Object.assign(new Error('账号已停用'), { statusCode: 403, code: 'account_disabled' })

test('account disablement clears the device and profile once, and late reads cannot repopulate them', async () => {
  const started = deferred()
  const delayed = deferred()
  let profile = { user_no: '12345678' }
  let saved = { ...credential('current'), user_no: profile.user_no }
  const notices = []
  const client = createSessionClient({
    saved, save: value => { saved = value }, loginCode: () => assert.fail('already signed in'),
    changed: (active, reason) => { if (!active) { profile = null; notices.push(reason) } },
    send: async (path, { method }) => {
      if (method === 'DELETE') return
      if (path === 'slow') { started.resolve(); await delayed.promise; return { user_no: '12345678' } }
      throw disabled()
    },
  })
  const late = client.request('slow').then(result => { profile = result })
  await started.promise
  await assert.rejects(client.request('me'), { code: 'account_disabled', message: '账号已停用' })
  delayed.resolve()
  await assert.rejects(late, /退出/)
  assert.equal(saved, null)
  assert.equal(profile, null)
  assert.deepEqual(notices, ['account_disabled'])
  await assert.rejects(client.request('me'), /请先登录/)
})

test('a late disablement for a replaced token cannot log out a new session', async () => {
  const started = deferred()
  const delayed = deferred()
  const { client, state } = device(async (path, { token }) => {
    if (path === 'slow') { started.resolve(); await delayed.promise; throw disabled() }
    if (path === 'session') return credential('new')
    if (token === 'previous') throw expired()
    return { user_no: '12345678' }
  })
  const late = client.request('slow')
  await started.promise
  await client.request('me')
  delayed.resolve()
  await assert.rejects(late, /状态已更新/)
  assert.equal(state.saved.token, 'new')
  assert.equal(state.saved.user_no, '12345678')
})

test('only explicit account or app disablement retires the session, including during silent renewal', async () => {
  const wrongApp403 = Object.assign(new Error('forbidden'), { statusCode: 403, appDisabled: false })
  const fake503Disabled = Object.assign(new Error('unavailable'), { statusCode: 503, appDisabled: true })
  for (const error of [wrongApp403, fake503Disabled, new Error('offline'), Object.assign(new Error(), { statusCode: 503, code: 'account_disabled' })]) {
    const { client, state } = device(async () => { throw error })
    await assert.rejects(client.request('me'), err => err === error)
    assert.equal(state.saved.token, 'previous')
  }
  const appReasons = []
  const appRevoked = []
  let appSaved = { ...credential('previous'), logout_token: 'logout-prev' }
  const appClient = createSessionClient({
    saved: appSaved, save: value => { appSaved = value }, loginCode: () => assert.fail('must not renew'),
    changed: (active, reason) => { if (!active) appReasons.push(reason) },
    send: async (path, { method, token, expectedStatus }) => {
      if (method === 'DELETE') {
        assert.equal(expectedStatus, 204)
        appRevoked.push(token)
        return
      }
      throw Object.assign(new Error('app paused'), { statusCode: 403, appDisabled: true })
    },
  })
  await assert.rejects(appClient.request('me'), { statusCode: 403, appDisabled: true })
  assert.equal(appSaved, null)
  assert.deepEqual(appReasons, ['app_disabled'])
  assert.deepEqual(appRevoked, ['logout-prev'])

  const { client, state } = device(async (path, { method }) => {
    if (method === 'DELETE') return
    if (path === 'session') throw disabled()
    throw expired()
  })
  await assert.rejects(client.request('me'), { code: 'account_disabled' })
  assert.equal(state.saved, null)
})

test('confirmed app disablement discards late manual login, silent renewal and profile reads, revokes late sessions, and allows recovery', async () => {
  // 1. Manual login in flight when app becomes disabled.
  const lateManual = deferred()
  const manualRevoked = []
  const manualEvents = []
  let manualSaved = null
  let logins = 0
  const manual = createSessionClient({
    saved: null, save: value => { manualSaved = value }, loginCode: async () => 'code-' + ++logins,
    changed: (active, reason) => manualEvents.push([active, reason]),
    send: async (path, { method, token, expectedStatus }) => {
      if (method === 'DELETE') {
        assert.equal(expectedStatus, 204)
        manualRevoked.push(token)
        return
      }
      if (path === 'session' && logins === 1) return await lateManual.promise
      if (path === 'session') return { ...credential('recovered'), logout_token: 'logout-recovered', user_no: '11111111' }
      return { user_no: '11111111' }
    },
  })
  const manualAttempt = manual.signIn()
  await Promise.resolve()
  await manual.signOut('app_disabled')
  lateManual.resolve({ ...credential('late-manual'), logout_token: 'logout-late-manual', user_no: '11111111' })
  await assert.rejects(manualAttempt, /退出/)
  assert.equal(manualSaved, null)
  assert.deepEqual(manualRevoked, ['logout-late-manual'])
  assert.deepEqual(manualEvents, [[false, 'app_disabled']])
  await assert.rejects(manual.request('me'), /请先登录/)
  // After app recovery, user can sign in again cleanly.
  assert.equal(await manual.signIn(), 'recovered')
  assert.deepEqual(await manual.request('me'), { user_no: '11111111' })
  assert.equal(manualSaved.token, 'recovered')

  // 2. Auto-relogin after session expiry + concurrent late profile read when app becomes disabled.
  const renewalStarted = deferred()
  const lateRenewal = deferred()
  const lateProfile = deferred()
  const autoRevoked = []
  let autoSaved = { ...credential('old-token'), logout_token: 'logout-old', user_no: '11111111' }
  let autoLogins = 0
  const auto = createSessionClient({
    saved: autoSaved, save: value => { autoSaved = value }, loginCode: async () => 'auto-' + ++autoLogins,
    changed: () => {},
    send: async (path, { method, token, expectedStatus }) => {
      if (method === 'DELETE') {
        assert.equal(expectedStatus, 204)
        autoRevoked.push(token)
        return
      }
      if (path === 'slow-me') return await lateProfile.promise
      if (path === 'me' && token === 'old-token') throw expired()
      if (path === 'session' && autoLogins === 1) {
        renewalStarted.resolve()
        return await lateRenewal.promise
      }
      if (path === 'session') return { ...credential('recovered-auto'), logout_token: 'logout-recovered-auto', user_no: '11111111' }
      return { user_no: '11111111' }
    },
  })
  const slowRead = auto.request('slow-me')
  const renewingRead = auto.request('me')
  await renewalStarted.promise
  await auto.signOut('app_disabled')
  lateProfile.resolve({ user_no: '11111111' })
  lateRenewal.resolve({ ...credential('late-renewed'), logout_token: 'logout-late-renewed', user_no: '11111111' })
  await assert.rejects(slowRead, /退出/)
  await assert.rejects(renewingRead, /退出/)
  assert.equal(autoSaved, null)
  assert.deepEqual(autoRevoked, ['logout-old', 'logout-late-renewed'])
  await assert.rejects(auto.request('me'), /请先登录/)
  assert.equal(await auto.signIn(), 'recovered-auto')
  assert.deepEqual(await auto.request('me'), { user_no: '11111111' })
})

test('a stale app-disabled error after recovery or token replacement cannot pause or revoke the new session', async () => {
  // 1. Delayed appDisabled from before disable -> recover -> new login must be rejected as stale without calling changed('app_disabled') or revoking the new token.
  const delayedError = deferred()
  const started = deferred()
  const revoked = []
  const disableNotices = []
  let saved = { ...credential('session-before'), logout_token: 'logout-before', user_no: '11111111' }
  const client = createSessionClient({
    saved, save: value => { saved = value }, loginCode: async () => 'code-new',
    changed: (active, reason) => { if (!active && reason === 'app_disabled') disableNotices.push(reason) },
    send: async (path, { method, token }) => {
      if (method === 'DELETE') { revoked.push(token); return }
      if (path === 'stale-me') {
        started.resolve()
        await delayedError.promise
        throw Object.assign(new Error('app paused'), { statusCode: 403, appDisabled: true })
      }
      if (path === 'session') return { ...credential('session-after'), logout_token: 'logout-after', user_no: '11111111' }
      return { user_no: '11111111' }
    },
  })
  const staleRead = client.request('stale-me')
  await started.promise
  await client.signOut('app_disabled')
  await client.signIn()
  assert.deepEqual(await client.request('me'), { user_no: '11111111' })
  delayedError.resolve()
  await assert.rejects(staleRead, /退出/)
  assert.equal(saved.token, 'session-after')
  assert.deepEqual(disableNotices, ['app_disabled'])
  assert.deepEqual(revoked, ['logout-before'])
  assert.deepEqual(await client.request('me'), { user_no: '11111111' })

  // 2. A late appDisabled for a replaced token in the same generation cannot retire the newer token.
  const replacedStarted = deferred()
  const replacedDelay = deferred()
  const replacedRevoked = []
  const replacedNotices = []
  let replacedSaved = { ...credential('previous'), logout_token: 'logout-previous' }
  const replaced = createSessionClient({
    saved: replacedSaved, save: value => { replacedSaved = value }, loginCode: async () => 'code-renew',
    changed: (active, reason) => { if (!active && reason === 'app_disabled') replacedNotices.push(reason) },
    send: async (path, { method, token }) => {
      if (method === 'DELETE') { replacedRevoked.push(token); return }
      if (path === 'slow') {
        replacedStarted.resolve()
        await replacedDelay.promise
        throw Object.assign(new Error('app paused'), { statusCode: 403, appDisabled: true })
      }
      if (path === 'session') return { ...credential('renewed'), logout_token: 'logout-renewed', user_no: '11111111' }
      if (token === 'previous') throw expired()
      return { user_no: '11111111' }
    },
  })
  const slow = replaced.request('slow')
  await replacedStarted.promise
  assert.deepEqual(await replaced.request('me'), { user_no: '11111111' })
  replacedDelay.resolve()
  await assert.rejects(slow, /状态已更新/)
  assert.equal(replacedSaved.token, 'renewed')
  assert.deepEqual(replacedNotices, [])
  assert.deepEqual(replacedRevoked, [])
})

test('offline logout keeps its revocation receipt across restarts until the backend returns 204', async () => {
  const initial = { ...credential('device-1'), logout_token: 'logout-dev-1', user_no: '11111111' }
  const offline = device(async () => { throw new Error('网络连接失败，请重试') }, initial)
  await assert.rejects(offline.client.signOut(), /网络连接失败/)
  assert.deepEqual(offline.state.saved, { revocations: ['logout-dev-1'] })

  const outcomes = [
    async () => responseData('wxA', { statusCode: 200, data: '<html>系统维护中</html>' }, 204),
    async () => responseData('wxA', { statusCode: 503, data: '<html>503</html>' }, 204),
    async () => { throw new Error('网络连接失败，请重试') },
  ]
  let persisted = offline.state.saved
  for (const simulate of outcomes) {
    const reopened = device(async (path, { method, token, expectedStatus }) => {
      assert.equal(path, 'session')
      assert.equal(method, 'DELETE')
      assert.equal(token, 'logout-dev-1')
      assert.equal(expectedStatus, 204)
      return await simulate()
    }, persisted)
    await assert.rejects(reopened.client.retryRevocations())
    assert.deepEqual(reopened.state.saved, { revocations: ['logout-dev-1'] })
    persisted = reopened.state.saved
  }

  const confirmed = device(async (path, { method, token, expectedStatus }) => {
    assert.equal(path, 'session')
    assert.equal(method, 'DELETE')
    assert.equal(token, 'logout-dev-1')
    assert.equal(expectedStatus, 204)
    return responseData('wxA', { statusCode: 204, data: '' }, expectedStatus)
  }, persisted)
  await confirmed.client.retryRevocations()
  assert.equal(confirmed.state.saved, null)
})

test('a 503 on the first profile read keeps the valid session so retry only reads me', async () => {
  let meAttempts = 0
  const calls = []
  const { client, state } = device(async (path, { method }) => {
    calls.push([method, path])
    if (path === 'session') return { ...credential('fresh-token'), logout_token: 'logout-fresh', user_no: '11111111' }
    if (++meAttempts === 1) throw Object.assign(new Error('服务暂不可用，请重试'), { statusCode: 503 })
    return { user_no: '11111111', booking_phone_required: false }
  }, null)

  await client.signIn()
  await assert.rejects(client.request('me'), { statusCode: 503 })
  assert.equal(state.saved.token, 'fresh-token')
  assert.equal(state.codes, 1)
  assert.deepEqual(await client.request('me'), { user_no: '11111111', booking_phone_required: false })
  assert.equal(state.codes, 1)
  assert.deepEqual(calls, [['POST', 'session'], ['GET', 'me'], ['GET', 'me']])
})

test('401 session_expired followed by failed re-login marks session stage and expires the stale local credential', async () => {
  let loginFails = true
  const calls = []
  let saved = { ...credential('expired-on-server'), logout_token: 'logout-old', user_no: '11111111' }
  const client = createSessionClient({
    saved, save: value => { saved = value },
    loginCode: async () => {
      if (loginFails) throw new Error('微信登录失败，请重试')
      return 'code-retry-ok'
    },
    changed: () => {},
    send: async (path, { method, token }) => {
      calls.push([method, path, token])
      if (path === 'session') return { ...credential('fresh-after-retry'), logout_token: 'logout-fresh', user_no: '11111111' }
      if (token === 'expired-on-server') throw expired()
      return { user_no: '11111111' }
    },
  })
  let err
  try { await client.request('me') } catch (caught) { err = caught }
  assert.equal(err?.stage, 'session')
  assert.equal(err?.sessionExpired, true)
  assert.ok(Date.parse(saved.expires_at) <= Date.now(), 'Stale credential must be marked locally expired')

  // Next manual login immediately exchanges without resending the dead token to /me.
  loginFails = false
  assert.equal(await client.signIn(), 'fresh-after-retry')
  assert.deepEqual(await client.request('me'), { user_no: '11111111' })
  assert.deepEqual(calls, [
    ['GET', 'me', 'expired-on-server'],
    ['POST', 'session', undefined],
    ['GET', 'me', 'fresh-after-retry'],
  ])
})

test('storage failure while tagging or identifying a legacy session keeps the tag in memory and persists once storage recovers', async () => {
  let storageBroken = true
  let saved = credential('legacy-token')
  const details = []
  const client = createSessionClient({
    saved,
    save: value => {
      if (storageBroken) throw new Error('storage unavailable')
      saved = value
    },
    loginCode: () => assert.fail('must not renew'),
    changed: (active, detail) => details.push([active, detail]),
    send: async () => ({ user_no: '11111111' }),
  })

  // First attempt fails to write storage, but still returns an in-memory session tag without throwing.
  const firstTag = client.ensurePendingSession()
  assert.ok(firstTag)
  assert.equal(client.pendingSessionId, firstTag)
  assert.equal(saved.session_id, undefined)

  // Once storage recovers while the app stays open, a subsequent ensurePendingSession persists the same tag.
  storageBroken = false
  assert.equal(client.ensurePendingSession(), firstTag)
  assert.equal(saved.session_id, firstTag)

  // Even if storage fails again while confirming user_no via /me, reading profile still succeeds.
  storageBroken = true
  assert.equal(await client.identifySavedSession(), '11111111')
  assert.equal(client.userNo, '11111111')
  assert.deepEqual(details, [[true, firstTag]])
})

test('a renewal to a different WeChat account cannot submit the previous account’s pending write', async () => {
  const sent = []
  const { client, state } = device(async (path, { method }) => {
    if (method === 'DELETE') return
    sent.push(path)
    return { ...credential('new'), user_no: '22222222' }
  }, { ...credential('old'), expires_at: new Date(0).toISOString(), user_no: '11111111' })
  await assert.rejects(client.request('entry_scenes', { method: 'POST' }), /退出/)
  assert.deepEqual(sent, ['session'])
  assert.equal(state.saved.user_no, '22222222')
})

test('an old session can claim a source only when its own credential proves who was visiting', async () => {
  let online = false
  const replacedDetails = []
  let replacedSaved = credential('previous')
  const replaced = createSessionClient({
    saved: replacedSaved, save: value => { replacedSaved = value }, loginCode: async () => 'fixture-1',
    changed: (active, detail) => replacedDetails.push([active, detail]),
    send: async (path, { token }) => {
      if (!online) throw new Error('offline')
      if (path === 'session') return { ...credential('replacement'), user_no: '22222222' }
      if (token === 'previous') throw expired()
      return { user_no: '22222222' }
    },
  })
  const tag = replaced.ensurePendingSession()
  assert.ok(tag)
  assert.equal(replacedSaved.session_id, tag)
  await assert.rejects(replaced.identifySavedSession(), /offline/)
  online = true
  assert.equal(await replaced.identifySavedSession(), undefined)
  assert.equal(replaced.userNo, '22222222')
  assert.equal(replacedSaved.session_id, undefined)
  assert.deepEqual(replacedDetails, [[true, undefined]])

  const confirmedDetails = []
  let oldSaved = credential('previous')
  const firstBoot = createSessionClient({
    saved: oldSaved, save: value => { oldSaved = value }, loginCode: () => assert.fail('already signed in'),
    changed: () => {}, send: async () => { throw new Error('offline') },
  })
  const persistedTag = firstBoot.ensurePendingSession()
  assert.ok(persistedTag)
  assert.equal(oldSaved.session_id, persistedTag)

  const restarted = createSessionClient({
    saved: oldSaved, save: value => { oldSaved = value }, loginCode: () => assert.fail('already signed in'),
    changed: (active, detail) => confirmedDetails.push([active, detail]),
    send: async () => ({ user_no: '11111111' }),
  })
  assert.equal(restarted.ensurePendingSession(), persistedTag)
  assert.equal(await restarted.identifySavedSession(), '11111111')
  assert.equal(oldSaved.user_no, '11111111')
  assert.equal(oldSaved.session_id, undefined)
  assert.deepEqual(confirmedDetails, [[true, persistedTag]])
})
