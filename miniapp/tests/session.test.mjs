import assert from 'node:assert/strict'
import { test } from 'node:test'
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

test('only explicit account disablement retires the session, including during silent renewal', async () => {
  const appPaused = Object.assign(new Error('app paused'), { statusCode: 403, appDisabled: true })
  for (const error of [appPaused, new Error('offline'), Object.assign(new Error(), { statusCode: 503, code: 'account_disabled' })]) {
    const { client, state } = device(async () => { throw error })
    await assert.rejects(client.request('me'), err => err === error)
    assert.equal(state.saved.token, 'previous')
  }
  const { client, state } = device(async (path, { method }) => {
    if (method === 'DELETE') return
    if (path === 'session') throw disabled()
    throw expired()
  })
  await assert.rejects(client.request('me'), { code: 'account_disabled' })
  assert.equal(state.saved, null)
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
  const { client } = device(async (path, { token }) => {
    if (!online) throw new Error('offline')
    if (path === 'session') return { ...credential('replacement'), user_no: '22222222' }
    if (token === 'previous') throw expired()
    return { user_no: '22222222' }
  })
  await assert.rejects(client.identifySavedSession(), /offline/)
  online = true
  assert.equal(await client.identifySavedSession(), undefined)
  assert.equal(client.userNo, '22222222')

  const old = device(async () => ({ user_no: '11111111' }))
  assert.equal(await old.client.identifySavedSession(), '11111111')
  assert.equal(old.state.saved.user_no, '11111111')
})
