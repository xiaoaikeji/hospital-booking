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
  const revocations = new Set(Array.isArray(saved?.revocations) ? saved.revocations : [])
  const revoking = new Map()
  let generation = 0
  let pending

  function assertCurrent(start) {
    if (start !== generation) throw new Error('已退出登录')
  }

  async function sendForAccount(path, options, start) {
    try {
      return await send(path, options)
    } catch (error) {
      if (error.statusCode === 403 && error.appDisabled) {
        // Confirmed app disablement retires this session and invalidates in-flight logins and reads.
        if (start === generation) signOut('app_disabled').catch(() => {})
        throw error
      }
      assertCurrent(start)
      if (error.statusCode === 403 && error.code === 'account_disabled') {
        if (options.token && options.token !== current?.token) throw new Error('登录状态已更新，请重试')
        signOut('account_disabled').catch(() => {})
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
      persist()
      changed(true)
      return current.token
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
    if (!current) throw new Error('请先登录')
    const token = await signIn()
    assertCurrent(start)
    async function sendCurrent(token) {
      const result = await sendForAccount(path, { method, data, token, expectedStatus }, start)
      assertCurrent(start)
      if (current.token !== token) throw new Error('登录状态已更新，请重试')
      if (path === 'me' && result?.user_no && !current.user_no) {
        // A device signed in before login responses included the Booking user number.
        const confirmedSession = current.session_id
        current.user_no = result.user_no
        delete current.session_id
        persist()
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

    const renewed = current.token === token ? await exchange() : current.token
    assertCurrent(start)
    // Only reads are replayed. A phone code, booking or payment needs a new user action.
    if (method !== 'GET') {
      const error = new Error('登录已恢复，请重新确认')
      error.code = 'confirmation_required'
      throw error
    }
    return sendCurrent(renewed)
  }

  function signOut(reason) {
    generation += 1
    const previous = current
    current = null
    pending = null
    if (previous) revocations.add(previous.logout_token || previous.token)
    persist()
    changed(false, reason)
    if (reason === 'app_disabled' && !previous) return Promise.resolve()
    return retryRevocations()
  }

  function ensurePendingSession() {
    if (!current || current.user_no) return undefined
    if (!current.session_id) {
      current.session_id = newSessionId()
      persist()
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
