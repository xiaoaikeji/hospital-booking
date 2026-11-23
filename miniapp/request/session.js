// One instance per backend and AppID. A missing saved session is an intentional guest.
export function createSessionClient({ saved, save, send, loginCode, changed, deviceContext = () => ({}) }) {
  function newSessionId() {
    return typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() :
      Date.now().toString(36) + '-' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2)
  }

  function credential({ token, expires_at, logout_token, user_no, session_id }) {
    const record = { token, expires_at, logout_token, user_no }
    if (!user_no && session_id) record.session_id = session_id
    return record
  }
  let current = saved?.token ? credential(saved) : null
  let pendingSessionDirty = false
  const revocations = new Set(Array.isArray(saved?.revocations) ? saved.revocations : [])
  const revoking = new Map()
  let generation = 0
  let pending

  function sessionError(message) {
    const error = new Error(message)
    error.stage = 'session'
    return error
  }

  function assertCurrent(start) {
    if (start !== generation) throw sessionError('已退出登录')
  }

  async function sendForAccount(path, options, start) {
    try {
      return await send(path, options)
    } catch (error) {
      assertCurrent(start)
      if (error.statusCode === 403 && (error.appDisabled || error.code === 'account_disabled')) {
        // Only a still-current request may retire the session or pause the app.
        if (options.token && options.token !== current?.token) throw sessionError('登录状态已更新，请重试')
        signOut(error.appDisabled ? 'app_disabled' : 'account_disabled').catch(() => {})
      }
      throw error
    }
  }

  // One write records both the guest state and the DELETE still owed to the server.
  function persist() {
    save(revocations.size ? { ...current, revocations: [...revocations] } : current)
  }

  function revoke(token) {
    if (revoking.has(token)) return revoking.get(token)
    // Only the backend's 204 confirms revocation; gateway 200 maintenance pages must retain the receipt.
    const operation = send('session', { method: 'DELETE', token, expectedStatus: 204 }).then(() => {
      revocations.delete(token)
      persist()
    }).finally(() => { revoking.delete(token) })
    revoking.set(token, operation)
    return operation
  }

  async function retryRevocations() {
    await Promise.all([...revocations].map(async token => {
      // Reconnection can arrive before a disconnected request has reported its failure.
      if (revoking.has(token)) await revoking.get(token).catch(() => {})
      if (revocations.has(token)) await revoke(token)
    }))
  }

  function exchange(entry) {
    if (pending) return pending
    const start = generation
    const operation = (async () => {
      try {
        const code = await loginCode()
        assertCurrent(start)
        if (!code) throw new Error('未取得微信登录凭证，请重试')
        const result = await sendForAccount('session', { method: 'POST', data: { code, ...deviceContext(), ...entry } }, start)
        if (!result?.token || !(Date.parse(result.expires_at) > Date.now())) throw new Error('登录响应无效，请重试')
        if (start !== generation) {
          // Logout ran while Rails was issuing this otherwise orphaned credential.
          const retired = result.logout_token || result.token
          revocations.add(retired)
          persist()
          await revoke(retired).catch(() => {})
          assertCurrent(start)
        }
        if (current?.user_no && result.user_no && current.user_no !== result.user_no) {
          // The new WeChat identity cannot continue any read, write or upload started for the old one.
          signOut('account_changed').catch(() => {})
        }
        current = credential(result)
        pendingSessionDirty = false
        persist()
        changed(true)
        return current.token
      } catch (error) {
        if (error && typeof error === 'object') error.stage = 'session'
        throw error
      }
    })().finally(() => { if (pending === operation) pending = null })
    pending = operation
    return operation
  }

  function signIn(entry) {
    if (pending) return pending
    if (current && Date.parse(current.expires_at) > Date.now()) return Promise.resolve(current.token)
    return exchange(entry)
  }

  async function request(path, { method = 'GET', data, expectedStatus } = {}) {
    const start = generation
    if (!current) throw sessionError('请先登录')
    const token = await signIn()
    assertCurrent(start)
    async function sendCurrent(token) {
      const result = await sendForAccount(path, { method, data, token, expectedStatus }, start)
      assertCurrent(start)
      if (current.token !== token) throw sessionError('登录状态已更新，请重试')
      if (path === 'me' && result?.user_no && !current.user_no) {
        // A device signed in before login responses included the Booking user number.
        const confirmedSession = current.session_id
        current.user_no = result.user_no
        delete current.session_id
        pendingSessionDirty = false
        try { persist() } catch { /* Storage failures must not prevent reading the user's profile. */ }
        changed(true, confirmedSession)
      }
      return result
    }
    try {
      return await sendCurrent(token)
    } catch (error) {
      if (error.statusCode !== 401 || error.code !== 'session_expired') throw error
      assertCurrent(start)
    }

    let renewed
    if (current.token === token) {
      try {
        renewed = await exchange()
      } catch (error) {
        // Rails already rejected this credential. A failed renewal ends only that device session.
        if (start === generation && current?.token === token) {
          clearLocalSession('session_expired')
          if (error && typeof error === 'object') error.sessionExpired = true
        }
        throw error
      }
    } else {
      renewed = current.token
    }
    assertCurrent(start)
    // Only reads are replayed. A phone code, booking or payment needs a new user action.
    if (method !== 'GET') {
      const error = new Error('登录已恢复，请重新确认')
      error.code = 'confirmation_required'
      throw error
    }
    return sendCurrent(renewed)
  }

  function clearLocalSession(reason) {
    generation += 1
    current = null
    pending = null
    pendingSessionDirty = false
    try { persist() } catch { /* Keep the device signed out in memory if storage is unavailable. */ }
    changed(false, reason)
  }

  function signOut(reason) {
    const previous = current
    if (previous) revocations.add(previous.logout_token || previous.token)
    clearLocalSession(reason)
    if (reason === 'app_disabled' && !previous) return Promise.resolve()
    return retryRevocations()
  }

  function ensurePendingSession() {
    if (!current || current.user_no) return undefined
    if (!current.session_id) {
      current.session_id = newSessionId()
      pendingSessionDirty = true
    }
    if (pendingSessionDirty) {
      try {
        persist()
        pendingSessionDirty = false
      } catch { /* Keep the session tag in memory and persist once storage recovers. */ }
    }
    return current.session_id
  }

  async function identifySavedSession() {
    const savedSession = current
    if (savedSession && !savedSession.user_no) await request('me')
    // If an unidentifiable old token needed replacing, its original owner was never confirmed.
    return savedSession === current ? current?.user_no : undefined
  }

  return {
    signIn, request, signOut, retryRevocations, identifySavedSession, ensurePendingSession,
    get userNo() { return current?.user_no },
    get pendingSessionId() { return current && !current.user_no ? current.session_id : undefined },
  }
}
