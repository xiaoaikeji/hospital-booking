// A real foreground entry keeps its ID until Rails acknowledges it, even across process restarts.
export function createEntryQueue({ storage, sessionKey, submit }) {
  const key = sessionKey + ':entries'
  let entries = []
  try {
    const saved = storage.getStorageSync(key)
    if (Array.isArray(saved)) entries = saved.filter(entry => typeof entry?.entry_id === 'string')
  } catch { /* Unavailable storage must not prevent the user from signing in. */ }
  let owner
  let generation = 0
  let sending

  function persist() {
    // Source tracking is optional. If storage is full, the running app can still deliver its in-memory entries.
    try {
      if (entries.length) storage.setStorageSync(key, entries)
      else storage.removeStorageSync(key)
    } catch {}
  }

  function add(entry) {
    if (!entry || (!owner && entries.some(item => !item.intended_user_no))) return
    const id = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() :
      Date.now().toString(36) + '-' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2)
    entries.push({ ...entry, entry_id: id, intended_user_no: owner })
    persist()
  }

  function activate(userNo) {
    if (!userNo || userNo === owner) return
    owner = userNo
    generation++
    sending = null
    const guestEntries = entries.filter(entry => !entry.intended_user_no)
    if (guestEntries.length) {
      for (const entry of guestEntries) entry.intended_user_no = userNo
      persist()
    }
  }

  function leave() {
    owner = undefined
    generation++
    sending = null
    // Confirmed owners keep their pending visits for their next login. An unclaimed visit cannot follow a logout.
    entries = entries.filter(entry => entry.intended_user_no)
    persist()
  }

  function flush() {
    if (sending) return sending
    if (!owner) return Promise.resolve()
    const start = generation
    const operation = (async () => {
      while (start === generation) {
        const entry = entries.find(item => item.intended_user_no === owner)
        if (!entry) return
        await submit(entry)
        if (start !== generation) return
        entries.splice(entries.indexOf(entry), 1)
        persist()
      }
    })().finally(() => { if (sending === operation) sending = null })
    sending = operation
    return operation
  }

  async function retry() {
    const start = generation
    // Reconnection may arrive while the original offline request is still failing.
    if (sending) await sending.catch(() => {})
    if (start === generation) await flush()
  }

  return { add, activate, leave, flush, retry, get pending() { return !!owner && entries.some(entry => entry.intended_user_no === owner) } }
}
