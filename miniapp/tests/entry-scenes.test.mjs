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
