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
