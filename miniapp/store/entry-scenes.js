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

  function newEntryId() {
    return typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() :
      Date.now().toString(36) + '-' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2)
  }

  function add(entry) {
    if (!entry || (!owner && entries.some(item => !item.intended_user_no && !item.pending_session))) return
    entries.push({ ...entry, entry_id: newEntryId(), intended_user_no: owner })
    persist()
  }

  // Legacy credentials without user_no stage only their first offline scan until the same session confirms its owner.
  function addForSession(sessionId, entry) {
    if (!entry || !sessionId || owner) return
    if (entries.some(item => !item.intended_user_no && item.pending_session === sessionId)) return
    entries.push({ ...entry, entry_id: newEntryId(), pending_session: sessionId })
    persist()
  }

  function pruneSessions(activeSessionId) {
    const kept = entries.filter(item => !item.pending_session || (activeSessionId && item.pending_session === activeSessionId))
    if (kept.length === entries.length) return
    entries = kept
    persist()
  }

  function activate(userNo, confirmedSessionId) {
    if (!userNo) return
    if (userNo !== owner) {
      owner = userNo
      generation++
      sending = null
    }
    let dirty = false
    const next = []
    for (const entry of entries) {
      if (entry.intended_user_no) {
        next.push(entry)
      } else if (!entry.pending_session) {
        entry.intended_user_no = userNo
        next.push(entry)
        dirty = true
      } else if (confirmedSessionId && entry.pending_session === confirmedSessionId) {
        delete entry.pending_session
        entry.intended_user_no = userNo
        next.push(entry)
        dirty = true
      } else {
        dirty = true
      }
    }
    if (dirty) {
      entries = next
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

  return {
    add, addForSession, pruneSessions, activate, leave, flush, retry,
    hasPendingSession: sessionId => !!sessionId && entries.some(item => !item.intended_user_no && item.pending_session === sessionId),
    get pending() { return !!owner && entries.some(entry => entry.intended_user_no === owner) },
  }
}
