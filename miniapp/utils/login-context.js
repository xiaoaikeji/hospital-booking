export function entrySource(options) {
  const entry = {}
  if (/^[1-9]\d{3}$/.test(String(options?.scene))) entry.launch_scene = Number(options.scene)
  let channel = options?.query?.scene
  if (typeof channel === 'string') {
    try { channel = decodeURIComponent(channel) } catch { /* Keep a literal percent in a channel name. */ }
    channel = channel.trim()
    if (channel && channel.length <= 128 && !/[\u0000-\u001f\u007f]/.test(channel)) entry.channel_scene = channel
  }
  return Object.keys(entry).length ? entry : undefined
}

export function loginFailureState(error, isSignedIn) {
  if (isSignedIn && !error?.appDisabled && error?.code !== 'account_disabled' && error?.code !== 'session_expired') {
    return { profileRetry: true, feedback: '已登录，暂时无法读取资料' }
  }
  return { profileRetry: false, feedback: error?.message || '登录失败，请重试' }
}

export function deviceContext(read = () => typeof wx !== 'undefined' && wx.getDeviceInfo ? wx.getDeviceInfo() : uni.getDeviceInfo?.()) {
  try {
    const info = read()
    if (!info || /devtools|simulator|emulator|模拟器|开发者工具/i.test([info.platform, info.model, info.deviceModel].join(' '))) return {}
    const result = {}
    const values = {
      device_platform: info.platform, device_model: info.model || info.deviceModel,
      operating_system: info.system || (info.osVersion && [info.osName, info.osVersion].filter(Boolean).join(' ')),
    }
    for (const [field, value] of Object.entries(values)) {
      if (typeof value === 'string' && value.trim() && value.length <= 100 && !/unknown|未知/i.test(value)) result[field] = value.trim()
    }
    return result
  } catch { return {} }
}
