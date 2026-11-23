import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createEntryQueue } from '../store/entry-scenes.js'
import { entrySource } from '../utils/login-context.js'

function memoryStorage() {
  const values = new Map()
  return {
    getStorageSync: key => structuredClone(values.get(key)),
    setStorageSync: (key, value) => values.set(key, structuredClone(value)),
    removeStorageSync: key => values.delete(key),
  }
}

const hall = entrySource({ scene: 1047, query: { scene: encodeURIComponent('门诊大厅') } })
const recent = entrySource({ scene: 1089 })

test('a guest keeps only the first scan across restarts, even when the next launch is from recently used', async () => {
  const storage = memoryStorage()
  const sessionKey = 'booking-session:fixture-origin:app-a'
  const sent = []
  let offline = true
  const start = () => createEntryQueue({ storage, sessionKey, submit: async row => {
    sent.push(structuredClone(row))
    if (offline) throw new Error('lost acknowledgement')
  } })
  const dayOne = start()
  dayOne.add(hall)
  await dayOne.retry()
  assert.deepEqual(sent, [])

  const dayTwo = start()
  for (let i = 0; i < 20; i++) dayTwo.add(recent)
  assert.equal(storage.getStorageSync(sessionKey + ':entries').length, 1)
  dayTwo.activate('11111111')
  dayTwo.add(recent) // A real foreground visit after authentication.
  await assert.rejects(dayTwo.flush(), /acknowledgement/)
  assert.equal(storage.getStorageSync(sessionKey + ':entries').length, 2)
  offline = false
  const again = start()
  again.activate('11111111')
  await Promise.all([again.flush(), again.retry()])
  await again.retry()
  assert.deepEqual(sent.map(row => row.launch_scene), [1047, 1047, 1089])
  assert.deepEqual(sent[0], sent[1])
  assert.equal(sent[0].channel_scene, '门诊大厅')
  assert.equal(sent[0].intended_user_no, '11111111')
  assert.notEqual(sent[1].entry_id, sent[2].entry_id)
  assert.equal(storage.getStorageSync(sessionKey + ':entries'), undefined)
})

test('sign-out, another account, another AppID or another backend cannot consume someone else’s source', async () => {
  const storage = memoryStorage()
  const sent = []
  const open = sessionKey => createEntryQueue({ storage, sessionKey, submit: async entry => { sent.push([sessionKey, { ...entry }]) } })
  const key = 'booking-session:fixture-origin:app-a'
  let queue = open(key)
  queue.add(hall)
  queue.activate('11111111')
  queue.leave()
  for (const scope of ['booking-session:fixture-origin:app-b', 'booking-session:another-origin:app-a']) {
    const separate = open(scope)
    separate.activate('11111111')
    await separate.flush()
  }
  queue = open(key)
  queue.add(recent)
  queue.activate('22222222')
  await queue.flush()
  assert.deepEqual(sent.map(([, row]) => [row.intended_user_no, row.launch_scene]), [['22222222', 1089]])
  queue.leave()
  queue.activate('11111111')
  await queue.flush()
  assert.equal(sent[1][1].channel_scene, '门诊大厅')
  assert.equal(sent[1][1].intended_user_no, '11111111')
  assert.equal(storage.getStorageSync(key + ':entries'), undefined)
})

test('source storage failures still allow in-memory recording and acknowledgement', async () => {
  const fail = () => { throw new Error('storage unavailable') }
  const storage = { getStorageSync: fail, setStorageSync: fail, removeStorageSync: fail }
  const sent = []
  const queue = createEntryQueue({ storage, sessionKey: 'fixture-scope', submit: async row => { sent.push(row.launch_scene) } })
  queue.add(hall)
  queue.activate('11111111')
  await queue.flush()
  assert.deepEqual(sent, [1047])
  assert.equal(queue.pending, false)
})

test('a legacy session keeps its first offline scan across restarts and only claims it for the confirmed owner', async () => {
  const storage = memoryStorage()
  const key = 'booking-session:fixture-origin:app-a'
  const sent = []
  const open = (sessionKey = key) => createEntryQueue({ storage, sessionKey, submit: async row => { sent.push([sessionKey, structuredClone(row)]) } })

  // Day 1 offline: legacy session stages the hall QR scan.
  const offline = open()
  offline.addForSession('legacy-sess-1', hall)
  assert.equal(offline.hasPendingSession('legacy-sess-1'), true)

  // Day 2 online: recently used 1089 must not overwrite the staged 1047 + channel.
  const reopened = open()
  reopened.pruneSessions('legacy-sess-1')
  reopened.addForSession('legacy-sess-1', recent)
  assert.equal(storage.getStorageSync(key + ':entries').length, 1)
  reopened.activate('11111111', 'legacy-sess-1')
  await reopened.flush()
  assert.equal(sent.length, 1)
  assert.equal(sent[0][1].launch_scene, 1047)
  assert.equal(sent[0][1].channel_scene, '门诊大厅')
  assert.equal(sent[0][1].intended_user_no, '11111111')
  assert.equal(sent[0][1].pending_session, undefined)
  assert.equal(storage.getStorageSync(key + ':entries'), undefined)

  // Unconfirmed legacy scan must never leak on account switch, logout, AppID change or backend change.
  const leakCheck = open()
  leakCheck.addForSession('legacy-sess-2', hall)
  for (const otherScope of ['booking-session:fixture-origin:app-b', 'booking-session:other-origin:app-a']) {
    const isolated = open(otherScope)
    isolated.activate('22222222', 'legacy-sess-2')
    await isolated.flush()
  }
  assert.equal(sent.length, 1)
  // Expired legacy session replaced by another account (no confirmedSessionId): must discard.
  const replaced = open()
  replaced.activate('22222222')
  await replaced.flush()
  assert.equal(sent.length, 1)
  assert.equal(storage.getStorageSync(key + ':entries'), undefined)

  // Sign-out discards an unconfirmed legacy scan before another user logs in.
  const beforeLogout = open()
  beforeLogout.addForSession('legacy-sess-3', hall)
  beforeLogout.leave()
  assert.equal(storage.getStorageSync(key + ':entries'), undefined)
  beforeLogout.activate('22222222')
  await beforeLogout.flush()
  assert.equal(sent.length, 1)
})

test('a legacy scan staged during a storage outage stays in memory, persists after recovery and is never overwritten by 1089', async () => {
  const backing = memoryStorage()
  let storageBroken = true
  const flakyStorage = {
    getStorageSync: key => backing.getStorageSync(key),
    setStorageSync: (key, value) => {
      if (storageBroken) throw new Error('storage full')
      backing.setStorageSync(key, value)
    },
    removeStorageSync: key => {
      if (storageBroken) throw new Error('storage full')
      backing.removeStorageSync(key)
    },
  }
  const key = 'booking-session:fixture-origin:app-a'
  const sent = []
  const queue = createEntryQueue({ storage: flakyStorage, sessionKey: key, submit: async row => { sent.push(structuredClone(row)) } })

  // Storage fails on the first hall QR scan, so it stays in memory.
  queue.addForSession('legacy-mem-1', hall)
  assert.equal(queue.hasPendingSession('legacy-mem-1'), true)
  assert.equal(backing.getStorageSync(key + ':entries'), undefined)

  // Storage recovers while app stays open; entering from 1089 must keep 1047 and flush it to disk.
  storageBroken = false
  queue.addForSession('legacy-mem-1', recent)
  const stored = backing.getStorageSync(key + ':entries')
  assert.equal(stored?.length, 1)
  assert.equal(stored[0].launch_scene, 1047)
  assert.equal(stored[0].channel_scene, '门诊大厅')

  // Confirming the original owner reports 1047 once.
  queue.activate('11111111', 'legacy-mem-1')
  await queue.flush()
  assert.equal(sent.length, 1)
  assert.equal(sent[0].launch_scene, 1047)
  assert.equal(sent[0].channel_scene, '门诊大厅')
  assert.equal(sent[0].intended_user_no, '11111111')
  assert.equal(backing.getStorageSync(key + ':entries'), undefined)
})
