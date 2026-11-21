// One instance per backend and AppID. A missing saved session is an intentional guest.
export function createSessionClient({ saved, save, send, loginCode, changed }) {
  let current = saved?.token ? saved : null
  let generation = 0
  let pending

  function assertCurrent(start) {
    if (start !== generation) throw new Error('已退出登录')
  }

  function revoke(token) {
    return send('session', { method: 'DELETE', token })
  }

  function exchange(scene) {
    if (pending) return pending
    const start = generation
    const operation = (async () => {
      const code = await loginCode()
      assertCurrent(start)
      if (!code) throw new Error('未取得微信登录凭证，请重试')
      const result = await send('session', { method: 'POST', data: { code, scene } })
      if (!result?.token || !(Date.parse(result.expires_at) > Date.now())) throw new Error('登录响应无效，请重试')
      if (start !== generation) {
        // Logout ran while Rails was issuing this otherwise orphaned credential.
        await revoke(result.token).catch(() => {})
        assertCurrent(start)
      }
      current = { token: result.token, expires_at: result.expires_at }
      save(current)
      changed(true)
      return current.token
    })().finally(() => { if (pending === operation) pending = null })
    pending = operation
    return operation
  }

  function signIn(scene) {
    if (pending) return pending
    if (current && Date.parse(current.expires_at) > Date.now()) return Promise.resolve(current.token)
    return exchange(scene)
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
    save(null)
    changed(false)
    return previous ? revoke(previous.token) : Promise.resolve()
  }

  return { signIn, request, signOut }
}
