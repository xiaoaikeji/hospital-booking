// One instance per backend and AppID. A missing saved session is an intentional guest.
export function createSessionClient({ saved, save, send, loginCode, changed, deviceContext = () => ({}) }) {
  function credential({ token, expires_at, logout_token }) {
    return { token, expires_at, logout_token }
  }
  let current = saved?.token ? credential(saved) : null
  const revocations = new Set(Array.isArray(saved?.revocations) ? saved.revocations : [])
  const revoking = new Map()
  let generation = 0
  let pending

  function assertCurrent(start) {
    if (start !== generation) throw new Error('已退出登录')
  }

  // One write records both the guest state and the DELETE still owed to the server.
  function persist() {
    save(revocations.size ? { ...current, revocations: [...revocations] } : current)
  }

  function revoke(token) {
    if (revoking.has(token)) return revoking.get(token)
    const operation = send('session', { method: 'DELETE', token }).then(() => {
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
      const result = await send('session', { method: 'POST', data: { code, ...deviceContext(), ...entry } })
      if (!result?.token || !(Date.parse(result.expires_at) > Date.now())) throw new Error('登录响应无效，请重试')
      if (start !== generation) {
        // Logout ran while Rails was issuing this otherwise orphaned credential.
        const retired = result.logout_token || result.token
        revocations.add(retired)
        persist()
        await revoke(retired).catch(() => {})
        assertCurrent(start)
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

  async function request(path, { method = 'GET', data } = {}) {
    const start = generation
    if (!current) throw new Error('请先登录')
    const token = await signIn()
    assertCurrent(start)
    async function sendCurrent(token) {
      const result = await send(path, { method, data, token })
      assertCurrent(start)
      if (current.token !== token) throw new Error('登录状态已更新，请重试')
      return result
    }
    try {
      return await sendCurrent(token)
    } catch (error) {
      assertCurrent(start)
      if (error.statusCode !== 401 || error.code !== 'session_expired') throw error
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

  function signOut() {
    generation += 1
    const previous = current
    current = null
    pending = null
    if (previous) revocations.add(previous.logout_token || previous.token)
    persist()
    changed(false)
    return retryRevocations()
  }

  return { signIn, request, signOut, retryRevocations }
}
